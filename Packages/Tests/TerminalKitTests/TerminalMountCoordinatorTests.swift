import AgentCore
import AppKit
@testable import TerminalKit
import XCTest

// TerminalMountCoordinator error paths and constraint bookkeeping (§3.8):
// the two typed mount rejections fire before any reparenting/native traffic,
// and repeated park→mount cycles deactivate the previous fill constraints
// instead of accumulating them.

@MainActor final class TerminalMountCoordinatorTests: XCTestCase {
    // MARK: - Fixtures (reuses SharedFakes.swift doubles)

    private func makeCoordinator() throws -> (TerminalMountCoordinator, FakeParkingHost, FakeEngine, GhosttySurface) {
        let engine = FakeEngine()
        let parking = FakeParkingHost()
        let coordinator = TerminalMountCoordinator(parkingHost: parking)
        let surface = try GhosttySurface(
            engine: engine, terminalID: TerminalID(), generation: .initial,
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        return (coordinator, parking, engine, surface)
    }

    private func fakeNative(_ surface: GhosttySurface) throws -> FakeNativeSurface {
        try XCTUnwrap(surface.native as? FakeNativeSurface)
    }

    /// Asserts that no native call of `kind` was appended after the snapshot.
    private func assertNoNewCalls(
        _ kind: String,
        after snapshot: [FakeNativeSurface.Call],
        on native: FakeNativeSurface,
        _ message: String
    ) {
        for call in native.calls.dropFirst(snapshot.count) where call.kind == kind {
            XCTFail("\(message): unexpected \(kind) call \(call)")
        }
    }

    // MARK: A1

    func testMountIntoParkingHostContainerThrowsAndLeavesViewParked() throws {
        let (coordinator, parking, engine, surface) = try makeCoordinator()
        defer { engine.shutdown() }

        // Park the surface first so its view genuinely lives in the host —
        // the state a real parked surface is always in (§3.8).
        coordinator.park(surface)
        let native = try fakeNative(surface)
        let callsBeforeAttempt = native.calls

        XCTAssertThrowsError(
            try coordinator.mount(surface, into: parking.parkingContentView, paneID: PaneID())
        ) { error in
            XCTAssertEqual(error as? TerminalKitError, .mountIntoParkingHost(terminalID: surface.terminalID))
        }
        XCTAssertEqual(surface.presentation, .parked)
        XCTAssertTrue(parking.contains(surface.view), "the rejected mount must not reparent the view")
        assertNoNewCalls("setOccluded", after: callsBeforeAttempt, on: native,
                         "rejected parking-host mount")
    }

    // MARK: A2

    func testMountOfClosingSurfaceThrowsSurfaceClosingWithoutSideEffects() throws {
        let (coordinator, parking, engine, surface) = try makeCoordinator()
        defer { engine.shutdown() }

        coordinator.park(surface)
        // Phase-1 teardown: marks isClosing and unparents the view.
        surface.beginTeardown()
        let native = try fakeNative(surface)
        let callsAtTeardownStart = native.calls

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertThrowsError(
            try coordinator.mount(surface, into: container, paneID: PaneID())
        ) { error in
            XCTAssertEqual(error as? TerminalKitError, .surfaceClosing(terminalID: surface.terminalID))
        }
        XCTAssertEqual(surface.presentation, .parked)
        XCTAssertFalse(parking.contains(surface.view),
                       "teardown removed the view; a rejected mount must not re-add it")
        for call in native.calls.dropFirst(callsAtTeardownStart.count) {
            XCTAssertNotEqual(call.kind, "resize", "closing surface must not be resized by a rejected mount")
            XCTAssertNotEqual(call.kind, "setOccluded", "closing surface must not be re-occluded by a rejected mount")
        }
    }

    // MARK: A3

    func testRepeatedParkMountCyclesDoNotAccumulateFillConstraints() throws {
        let (coordinator, parking, engine, surface) = try makeCoordinator()
        defer { engine.shutdown() }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let paneID = PaneID()
        try coordinator.mount(surface, into: container, paneID: paneID)

        for _ in 0 ..< 3 {
            coordinator.park(surface)
            try coordinator.mount(surface, into: container, paneID: paneID)
        }

        // Fill edges are installed on the container; deactivated predecessors
        // linger in .constraints but report isActive == false.
        let activeFillConstraints = container.constraints.filter(\.isActive)
        XCTAssertEqual(activeFillConstraints.count, 4,
                       "every cycle must deactivate the previous fill set; exactly the 4 edges remain")
        XCTAssertEqual(surface.presentation, .mounted(paneID))
        XCTAssertFalse(parking.contains(surface.view))
    }

    // MARK: A4

    func testParkOfClosingSurfaceIsNoOpPreservingMountedPresentation() throws {
        let (coordinator, parking, engine, surface) = try makeCoordinator()
        defer { engine.shutdown() }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let paneID = PaneID()
        try coordinator.mount(surface, into: container, paneID: paneID)

        // Snapshot strictly after beginTeardown so beginTeardown's own
        // unfocus does not count against park's guard.
        surface.beginTeardown()
        let native = try fakeNative(surface)
        let callsAfterTeardownStart = native.calls

        coordinator.park(surface)

        XCTAssertEqual(surface.presentation, .mounted(paneID),
                       "park of a closing surface must not clobber teardown-phase-1 state")
        XCTAssertFalse(parking.contains(surface.view))
        let newCalls = Array(native.calls.dropFirst(callsAfterTeardownStart.count))
        XCTAssertTrue(newCalls.isEmpty,
                      "the park guard must prevent any occlusion/focus traffic; got \(newCalls.map(\.kind))")
    }

    // MARK: R20-CB1 — ClipboardBridge policy closure (§3.20)

    /// Default-deny read policy, the two-flag selection conjunction, mime
    /// filtering and nil-payload drops; permitted selection writes land
    /// byte-exact on the PRIVATE org.agentterminal.selection pasteboard.
    /// NSPasteboard.general is never written by this test.
    func testClipboardPolicyDefaultsDenyReadAndSelectionWritesFilterMimeAndDropNilPayloads() {
        let defaultBridge = ClipboardBridge(policy: .init())
        XCTAssertFalse(defaultBridge.readPolicyClosure(.standard),
                       "programmatic reads are exfiltration channels: denied by default")
        XCTAssertFalse(defaultBridge.readPolicyClosure(.selection))

        let readOnly = ClipboardBridge(policy: .init(allowProgrammaticRead: true))
        XCTAssertTrue(readOnly.readPolicyClosure(.standard))
        XCTAssertFalse(readOnly.readPolicyClosure(.selection),
                       "selection reads need BOTH flags (read AND selection)")

        let permissive = ClipboardBridge(policy: .init(allowProgrammaticRead: true,
                                                       allowProgrammaticWrite: true,
                                                       allowSelectionClipboard: true))
        XCTAssertTrue(permissive.readPolicyClosure(.standard))
        XCTAssertTrue(permissive.readPolicyClosure(.selection))

        let selection = NSPasteboard(name: NSPasteboard.Name("org.agentterminal.selection"))
        selection.clearContents()
        let baseline = selection.changeCount

        // Nil kind / nil data are silent no-ops.
        permissive.write(kind: nil, mime: nil, data: "x")
        permissive.write(kind: .selection, mime: nil, data: nil)
        XCTAssertEqual(selection.changeCount, baseline, "nil kind/data never touch the pasteboard")

        // A permitted selection write lands byte-exact on the private board.
        permissive.write(kind: .selection, mime: nil, data: "x")
        XCTAssertEqual(selection.string(forType: .string), "x")
        let afterWrite = selection.changeCount

        // Foreign mimes are dropped.
        permissive.write(kind: .selection, mime: "image/png", data: "y")
        XCTAssertEqual(selection.string(forType: .string), "x")
        XCTAssertEqual(selection.changeCount, afterWrite,
                       "a foreign mime must not clobber the pasteboard")

        // Both plain-text mime forms are accepted; text/plain;charset=utf-8
        // is the canonical OSC 52 payload type.
        permissive.write(kind: .selection, mime: "text/plain;charset=utf-8", data: "y")
        XCTAssertEqual(selection.string(forType: .string), "y")
        permissive.write(kind: .selection, mime: "text/plain", data: "z")
        XCTAssertEqual(selection.string(forType: .string), "z")

        // The default bridge denies selection writes outright.
        defaultBridge.write(kind: .selection, mime: "text/plain", data: "nope")
        XCTAssertEqual(selection.string(forType: .string), "z",
                       "default policy must not mirror anything into the selection board")
    }

    // MARK: R-perf — window-level occlusion (§3.8)

    /// Mounted surfaces render only while their host window is actually
    /// visible: mount derives the initial occlusion from the container's
    /// window, and the surface view keeps flipping on
    /// NSWindow.didChangeOcclusionState. occlusionState never reports
    /// .visible inside a headless test runner, so the flip path is driven
    /// through the view's windowVisibleOverride seam; mount's live read is
    /// pinned against a never-ordered window (deterministically not
    /// .visible).
    func testMountOcclusionFollowsHostWindowVisibility() throws {
        let (coordinator, _, engine, surface) = try makeCoordinator()
        defer { engine.shutdown() }
        coordinator.park(surface)
        let native = try fakeNative(surface)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.contentView = container
        defer { window.orderOut(nil) }

        // Born hidden: mounting into a not-yet-visible window must throttle
        // (live read — the seam is still nil here).
        XCTAssertFalse(window.occlusionState.contains(.visible))
        try coordinator.mount(surface, into: container, paneID: PaneID())
        XCTAssertTrue(
            native.calls.contains { $0.kind == "setOccluded" && $0.detail == "1" },
            "mount into a covered window must keep the surface occluded"
        )

        // Showing the window unthrottles through the view's occlusion sync.
        surface.view.windowVisibleOverride = true
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification, object: window
        )
        XCTAssertTrue(
            native.calls.contains { $0.kind == "setOccluded" && $0.detail == "0" },
            "visible window must unthrottle the mounted surface"
        )

        // Hiding it again re-throttles through the same path.
        surface.view.windowVisibleOverride = false
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification, object: window
        )
        let lastOcclusion = native.calls.reversed().first { $0.kind == "setOccluded" }
        XCTAssertEqual(lastOcclusion?.detail, "1", "re-hidden window must re-throttle")
    }
}

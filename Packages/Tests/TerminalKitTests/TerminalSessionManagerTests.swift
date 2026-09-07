import AgentCore
import AppKit
@testable import TerminalKit
import XCTest

// Mount/park bookkeeping (§3.8): reparent never changes generation; parked
// surfaces are occluded and un-focused, mounted surfaces visible + focused;
// exit polling flips the session phase through the primary (poll) path.

@MainActor final class TerminalSessionManagerTests: XCTestCase {
    private func makeManager() throws -> (
        manager: TerminalSessionManager,
        engine: FakeEngine,
        parking: FakeParkingHost,
        session: TerminalSession
    ) {
        let engine = FakeEngine()
        let parking = FakeParkingHost()
        let manager = TerminalSessionManager(engine: engine, parkingHost: parking)
        let session = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        return (manager, engine, parking, session)
    }

    func testLaunchParksSurfaceInParkingHostWithoutGenerationChange() throws {
        let (manager, _, parking, session) = try makeManager()

        XCTAssertEqual(session.presentation, .parked)
        XCTAssertEqual(session.surfaceGeneration, .initial)
        XCTAssertEqual(manager.session(for: session.id)?.surfaceGeneration, .initial)
        guard case .running = session.processPhase else {
            return XCTFail("fresh terminal should be running")
        }
        // The parking host owns nothing yet — surfaces start parked by state,
        // and the first explicit park/mount moves the view.
        _ = parking
    }

    func testMountAndParkCyclePreservesGenerationAndPTYIdentity() throws {
        let (manager, engine, parking, session) = try makeManager()
        defer { engine.shutdown() }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let paneID = PaneID()
        let surfaceObject = try XCTUnwrap(manager.surface(for: session.id))

        try manager.mount(terminalID: session.id, paneID: paneID, container: container)
        var stored = manager.session(for: session.id)
        XCTAssertEqual(stored?.presentation, .mounted(paneID))
        // Mounted: the parking host no longer owns the view.
        XCTAssertFalse(parking.contains(surfaceObject.view))

        try manager.park(terminalID: session.id)
        stored = manager.session(for: session.id)
        XCTAssertEqual(stored?.presentation, .parked)
        // Parked: the view lives in the parking host again.
        XCTAssertTrue(parking.contains(surfaceObject.view))

        // The real invariant: same surface handle across the cycle.
        XCTAssertEqual(manager.allSessions.count, 1)
        XCTAssertEqual(stored?.id, session.id)
        XCTAssertEqual(stored?.surfaceGeneration, .initial)

        // Mount again — presentation follows, generation still untouched.
        try manager.mount(terminalID: session.id, paneID: PaneID(), container: container)
        XCTAssertEqual(manager.session(for: session.id)?.presentation.isMounted, true)
        XCTAssertEqual(manager.session(for: session.id)?.surfaceGeneration, .initial)
    }

    func testOcclusionAndFocusFollowPresentation() throws {
        let (manager, engine, parking, session) = try makeManager()
        defer { engine.shutdown() }

        let surface = try XCTUnwrap(manager.surface(for: session.id)?.native as? FakeNativeSurface)
        try manager.mount(
            terminalID: session.id,
            paneID: PaneID(),
            container: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        )

        XCTAssertTrue(surface.calls.contains {
            $0.kind == "setOccluded" && $0.detail == "0"
        })
        XCTAssertTrue(surface.calls.contains {
            $0.kind == "setFocus" && $0.detail == "1"
        })

        try manager.park(terminalID: session.id)
        XCTAssertTrue(surface.calls.contains {
            $0.kind == "setOccluded" && $0.detail == "1"
        })
        XCTAssertTrue(surface.calls.contains {
            $0.kind == "setFocus" && $0.detail == "0"
        })
        let surfaceObject = try XCTUnwrap(manager.surface(for: session.id))
        XCTAssertTrue(parking.contains(surfaceObject.view))
    }

    func testExitPollingIsPrimaryLifecycleSignal() async throws {
        let (manager, engine, _, session) = try makeManager()
        defer { engine.shutdown() }

        let surface = try XCTUnwrap(manager.surface(for: session.id)?.native as? FakeNativeSurface)
        let expectation = expectation(description: "exit observed")
        nonisolated(unsafe) var exitTerminalID: TerminalID?
        manager.processExitSink = { terminalID, _, _ in
            exitTerminalID = terminalID
            expectation.fulfill()
        }

        // Child exits — no SHOW_CHILD_EXITED event is delivered at all.
        surface.processExitedFlag = true
        manager.pollProcessExits()

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(exitTerminalID, session.id)
        // Parked terminal: the reclaim policy tears it down without a user
        // close. The reclaim runs as a MainActor Task (never inline inside
        // a sink delivery); yield once, then drain the two-phase queue.
        await Task.yield()
        manager.teardownQueueForTesting().drainForTesting()
        XCTAssertNil(manager.session(for: session.id), "parked exited terminal is reclaimed")
        XCTAssertTrue(try XCTUnwrap(engine.surfaces.first).freed, "native free ran")
    }

    /// T2: polling exists to OBSERVE exits. An exited-but-still-mounted
    /// terminal (nothing reclaims it) must not keep a no-op 0.5 s timer
    /// spinning; a live terminal must keep it.
    func testExitPollTimerStopsWhenAllTerminalsExitedEvenIfMounted() throws {
        let (manager, engine, _, session) = try makeManager()
        defer { engine.shutdown() }

        // Launch started polling for the live terminal.
        XCTAssertNotNil(manager.exitPollTimerForTesting())

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        try manager.mount(terminalID: session.id, paneID: PaneID(), container: container)

        // Observe the exit through the poll path; the terminal STAYS mounted
        // and registered afterwards (mounted surfaces keep scrollback).
        let surface = try XCTUnwrap(manager.surface(for: session.id)?.native as? FakeNativeSurface)
        surface.processExitedFlag = true
        manager.pollProcessExits()

        guard case .exited = manager.session(for: session.id)?.processPhase else {
            return XCTFail("poll must observe the exit")
        }
        XCTAssertNotNil(manager.session(for: session.id), "mounted terminal stays registered")
        XCTAssertNil(
            manager.exitPollTimerForTesting(),
            "no observable terminal remains — the poll timer must stop"
        )
    }

    /// T2 control: a live sibling keeps the timer alive even after another
    /// terminal's exit was observed.
    func testExitPollTimerKeepsRunningWhileAnyTerminalIsLive() throws {
        let (manager, engine, parking, first) = try makeManager()
        defer { engine.shutdown() }

        let second = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        XCTAssertNotNil(manager.exitPollTimerForTesting())

        let surface = try XCTUnwrap(manager.surface(for: first.id)?.native as? FakeNativeSurface)
        surface.processExitedFlag = true
        manager.pollProcessExits()

        guard case .exited = manager.session(for: first.id)?.processPhase else {
            return XCTFail("first exit must be observed")
        }
        guard case .running = manager.session(for: second.id)?.processPhase else {
            return XCTFail("second terminal must stay live")
        }
        XCTAssertNotNil(manager.exitPollTimerForTesting(), "live sibling keeps polling")
        _ = parking
    }

    func testCloseRunsTwoPhaseTeardownAndRemovesRegistryEntry() throws {
        let (manager, engine, _, session) = try makeManager()
        defer { engine.shutdown() }

        try manager.close(terminalID: session.id)
        manager.teardownQueueForTesting().drainForTesting()

        let surface = try XCTUnwrap(engine.surfaces.first)
        XCTAssertTrue(surface.freed, "native free must have run")
        XCTAssertNil(manager.session(for: session.id), "registry entry removed after free")
    }

    func testUnknownTerminalErrors() async throws {
        let (manager, engine, _, _) = try makeManager()
        defer { engine.shutdown() }
        let ghost = TerminalID()

        do {
            _ = try await manager.read(ghost, source: .detection)
            XCTFail()
        } catch {}

        do {
            try await manager.sendSignal(.interrupt, to: ghost)
            XCTFail()
        } catch {}
    }

    // MARK: ticketed launch command quoting (review blocker, stage 4a)

    /// libghostty word-splits the surface command on whitespace outside
    /// double quotes (shlex-style). Reproduces the reviewer probe end to end:
    /// a ticket under a space-containing directory must reach the helper
    /// intact — before the fix the split truncated at "Application Support"
    /// and the helper exited 126 without claiming the ticket.
    func testTicketedLaunchQuotesPathsWithSpacesSoHelperReceivesTicket() throws {
        let engine = FakeEngine()
        let parking = FakeParkingHost()
        let spaceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Application Support \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: spaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: spaceDir) }
        let writer = LaunchTicketWriter(
            directory: spaceDir.appendingPathComponent("runtime/tickets", isDirectory: true)
        )
        let manager = TerminalSessionManager(
            engine: engine, parkingHost: parking, ticketWriter: writer
        )
        defer { engine.shutdown() }

        // Fake helper + marker script BOTH under the space-containing dir:
        // the helper verifies its ticket argument exists, then execs the
        // marker (also under the space dir), which cats the ticket JSON.
        let markerURL = spaceDir.appendingPathComponent("marker.sh")
        try Data("#!/bin/sh\ncat \"$1\"\n".utf8).write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: markerURL.path)
        let launcherURL = spaceDir.appendingPathComponent("fake agentlauncher.sh")
        try Data("#!/bin/sh\ntest -f \"$1\" || exit 3\nexec \"\(markerURL.path)\" \"$1\"\n".utf8)
            .write(to: launcherURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
        let agentID = AgentID()
        _ = try manager.launch(
            workspaceID: WorkspaceID(),
            agentID: agentID,
            spec: LaunchSpec(argv: ["/bin/cat"], environment: [:], workingDirectory: "/tmp"),
            launcherExecutable: launcherURL,
            integrationToken: "test-token",
            controlSocketPath: ""
        )
        _ = parking

        let command = try XCTUnwrap(engine.createdSpecs.first?.command)
        XCTAssertTrue(command.contains(" \""), "both interpolated paths must be quoted: \(command)")

        // Simulate libghostty's shlex-style word split and run the tokens.
        let tokens = shlexSplit(command)
        XCTAssertEqual(tokens.count, 2, "quoted paths must survive the word split: \(command)")
        XCTAssertEqual(tokens[0], launcherURL.path)
        XCTAssertTrue(tokens[1].hasPrefix(writer.directory.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tokens[0])
        process.arguments = Array(tokens.dropFirst())
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0,
                       "helper must claim the ticket under a space path; stderr suppressed")
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains(agentID.rawValue.uuidString), "ticket JSON must arrive intact, got: \(output)")
        XCTAssertTrue(output.contains("test-token"), "marker exec'd and read the real ticket")
    }

    /// Minimal double-quote-aware whitespace splitter (libghostty semantics).
    private func shlexSplit(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            switch ch {
            case "\"": inQuotes.toggle()
            case " ", "\t", "\n":
                if inQuotes {
                    current.append(ch)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default: current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    // MARK: working-activity balance (review finding 5)

    func testActivityTokenBalancedAcrossCloseAndExitPollPaths() throws {
        let engine = FakeEngine()
        let parking = FakeParkingHost()
        let activity = RuntimeActivityManager()
        let manager = TerminalSessionManager(engine: engine, parkingHost: parking, activityManager: activity)
        defer { engine.shutdown() }

        let first = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        let second = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        XCTAssertEqual(activity.activeCount, 2)
        XCTAssertTrue(activity.isActive)

        // Close path releases one holder.
        try manager.close(terminalID: first.id)
        manager.teardownQueueForTesting().drainForTesting()
        XCTAssertEqual(activity.activeCount, 1)
        XCTAssertTrue(activity.isActive)

        // Process-exit poll path releases the other.
        let surface = try XCTUnwrap(manager.surface(for: second.id)?.native as? FakeNativeSurface)
        surface.processExitedFlag = true
        manager.pollProcessExits()
        XCTAssertEqual(activity.activeCount, 0)
        XCTAssertFalse(activity.isActive)

        // Closing an already-exited terminal must not double-decrement.
        try manager.close(terminalID: second.id)
        manager.teardownQueueForTesting().drainForTesting()
        XCTAssertEqual(activity.activeCount, 0)
    }

    // MARK: Round 14 C2

    func testEngineDeliveredChildExitedMirrorsExitExactlyOnceAndPollIsNoOp() throws {
        let engine = FakeEngine()
        let parking = FakeParkingHost()
        let activity = RuntimeActivityManager()
        let manager = TerminalSessionManager(engine: engine, parkingHost: parking, activityManager: activity)
        defer { engine.shutdown() }

        let first = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        let second = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        XCTAssertEqual(activity.activeCount, 2)

        nonisolated(unsafe) var sinkCalls: [TerminalID] = []
        manager.processExitSink = { terminalID, _, _ in sinkCalls.append(terminalID) }

        // 1. Engine-delivered child exit mirrors into the session model.
        engine.eventSink?(GhosttyEvent(
            terminalID: first.id,
            generation: .initial,
            payload: .childExited(exitCode: 7)
        ))
        guard case let .exited(exitCode, signal, userInitiated) =
            manager.session(for: first.id)?.processPhase
        else {
            return XCTFail("engine-delivered exit must flip the phase to exited")
        }
        XCTAssertEqual(exitCode, 7)
        XCTAssertNil(signal)
        XCTAssertFalse(userInitiated)
        XCTAssertEqual(sinkCalls.count, 1, "exit sink fires exactly once for \(sinkCalls)")
        XCTAssertEqual(sinkCalls.first, first.id)
        XCTAssertEqual(activity.activeCount, 1, "activity token released exactly once")

        // 2. Duplicate engine delivery of the IDENTICAL event is a no-op.
        engine.eventSink?(GhosttyEvent(
            terminalID: first.id,
            generation: .initial,
            payload: .childExited(exitCode: 7)
        ))
        XCTAssertEqual(sinkCalls.count, 1, "no double fire on duplicate delivery")
        XCTAssertEqual(activity.activeCount, 1, "no double endWorkingActivity")

        // 3. A later poll observing the same exit is a phase-switch no-op.
        let surface = try XCTUnwrap(manager.surface(for: first.id)?.native as? FakeNativeSurface)
        surface.processExitedFlag = true
        manager.pollProcessExits()
        XCTAssertEqual(sinkCalls.count, 1, "poll must not re-report an already-mirrored exit")
        XCTAssertEqual(activity.activeCount, 1)

        // 4. Stale-generation engine delivery is ignored entirely.
        engine.eventSink?(GhosttyEvent(
            terminalID: second.id,
            generation: SurfaceGeneration(rawValue: 9),
            payload: .childExited(exitCode: 7)
        ))
        XCTAssertEqual(sinkCalls.count, 1)
        guard case .running = manager.session(for: second.id)?.processPhase else {
            return XCTFail("stale generation must not touch the live session")
        }
        XCTAssertEqual(activity.activeCount, 1)

        // The close path is unaffected by all of the above.
        try manager.close(terminalID: second.id)
        manager.teardownQueueForTesting().drainForTesting()
        XCTAssertEqual(activity.activeCount, 0)
    }

    // MARK: Round 18 K1/K2 — sink-after-registration + stamp-once exitAt

    /// K1 (6885f7b law): the engine buffers `.childExited` during
    /// `createSurface` (router `deliver` with sink==nil appends to
    /// pendingPayloads); the manager registers the terminal BEFORE
    /// `activateEventSink()`, so the oldest-first flush finds the registry
    /// entry, mirrors the exit into the session model and fires the sink
    /// exactly once. Reordering sink-before-registration would kill every
    /// instant-exit event on the registry guard — the terminal would show
    /// running forever.
    func testChildExitedBufferedDuringLaunchReachesSessionModelAndExitSinkAfterRegistration() throws {
        let engine = FakeEngine()
        engine.onCreateSurfaceBox = { $0.deliver(.childExited(exitCode: 3)) }
        let parking = FakeParkingHost()
        let activity = RuntimeActivityManager()
        let manager = TerminalSessionManager(engine: engine, parkingHost: parking, activityManager: activity)
        defer { engine.shutdown() }

        nonisolated(unsafe) var sinkCalls: [TerminalID] = []
        manager.processExitSink = { terminalID, _, _ in sinkCalls.append(terminalID) }

        // launchDirect returns AFTER the buffered exit flushed through the
        // freshly registered session (flush happens inside activateEventSink).
        let session = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/true")
        )

        guard case let .exited(exitCode, signal, userInitiated) =
            manager.session(for: session.id)?.processPhase
        else {
            return XCTFail("launch-time-buffered exit must reach the session model")
        }
        XCTAssertEqual(exitCode, 3)
        XCTAssertNil(signal)
        XCTAssertFalse(userInitiated)
        XCTAssertEqual(
            sinkCalls, [session.id],
            "exit sink fires exactly once through the delegate chain, not dropped"
        )
        XCTAssertEqual(activity.activeCount, 0, "the flushed exit releases the activity token")

        // Control: a later poll observing the same exit adds NOTHING
        // (phase-switch no-op after engine delivery).
        let surface = try XCTUnwrap(manager.surface(for: session.id)?.native as? FakeNativeSurface)
        surface.processExitedFlag = true
        manager.pollProcessExits()
        XCTAssertEqual(sinkCalls, [session.id], "poll must not re-report an already-mirrored exit")
    }

    /// K2: the engine-delivered branch stamps `exitAt` INSIDE the same
    /// phase-switch guard that guarantees once-only execution — a duplicate
    /// engine delivery or a later poll must leave it byte-stable.
    func testEngineDeliveredExitStampsExitAtOnceAndDuplicatesDoNotMoveIt() throws {
        let engine = FakeEngine()
        let parking = FakeParkingHost()
        let activity = RuntimeActivityManager()
        let manager = TerminalSessionManager(engine: engine, parkingHost: parking, activityManager: activity)
        defer { engine.shutdown() }

        let first = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        let second = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )

        // Sanity window: the stamp must reflect observation wall-clock.
        let beforeStamp = Date().timeIntervalSince1970
        engine.eventSink?(GhosttyEvent(
            terminalID: first.id,
            generation: .initial,
            payload: .childExited(exitCode: 7)
        ))
        let afterStamp = Date().timeIntervalSince1970
        let t0 = try XCTUnwrap(manager.session(for: first.id)?.exitAt, "engine-delivered exit must stamp exitAt")
        XCTAssertGreaterThanOrEqual(t0, beforeStamp)
        XCTAssertLessThanOrEqual(t0, afterStamp)

        // Duplicate delivery of the IDENTICAL event…
        engine.eventSink?(GhosttyEvent(
            terminalID: first.id,
            generation: .initial,
            payload: .childExited(exitCode: 7)
        ))
        // …and a later poll observing the same exit must both be no-ops.
        let surface = try XCTUnwrap(engine.surfaces.first)
        surface.processExitedFlag = true
        manager.pollProcessExits()

        XCTAssertEqual(
            manager.session(for: first.id)?.exitAt, t0,
            "duplicate observations must not move the operator-visible exit time"
        )
        guard case .exited = manager.session(for: first.id)?.processPhase else {
            return XCTFail("phase must remain exited")
        }
        XCTAssertEqual(activity.activeCount, 1, "only the second terminal still holds its token")
        XCTAssertEqual(second.processPhase, .running(pid: nil, processGroupID: nil))
    }

    // MARK: parked-exit reclamation (PTY master fd leak fix)

    /// A terminal whose process exited while PARKED is invisible — no pane
    /// can show its post-mortem — so the two-phase teardown must run without
    /// waiting for a user close. Before the fix the surface (and the PTY
    /// master fd libghostty holds for it) stayed registered forever.
    func testParkedExitedTerminalIsReclaimedWithoutUserClose() async throws {
        let (manager, engine, _, session) = try makeManager()
        defer { engine.shutdown() }

        engine.eventSink?(GhosttyEvent(
            terminalID: session.id,
            generation: .initial,
            payload: .childExited(exitCode: 0)
        ))
        // The reclaim hops off the delivery as a MainActor Task; yield so
        // it runs, then drain the two-phase teardown synchronously.
        await Task.yield()
        manager.teardownQueueForTesting().drainForTesting()

        let native = try XCTUnwrap(engine.surfaces.first)
        XCTAssertTrue(native.freed, "parked exited surface must be freed without a user close")
        XCTAssertNil(manager.session(for: session.id), "registry entry removed after reclamation")
    }

    /// The counterpart policy bound: a MOUNTED terminal stays for post-mortem
    /// scrollback after its process exits (§3.5 — Close View and Stop Agent
    /// are never the same button); only the user's view close frees it.
    func testMountedExitedTerminalStaysForPostMortemUntilUserClose() throws {
        let (manager, engine, _, session) = try makeManager()
        defer { engine.shutdown() }

        try manager.mount(
            terminalID: session.id,
            paneID: PaneID(),
            container: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        )
        engine.eventSink?(GhosttyEvent(
            terminalID: session.id,
            generation: .initial,
            payload: .childExited(exitCode: 0)
        ))
        manager.teardownQueueForTesting().drainForTesting()

        XCTAssertEqual(manager.allSessions.count, 1, "mounted exit must not auto-close")
        let native = try XCTUnwrap(engine.surfaces.first)
        XCTAssertFalse(native.freed, "mounted surface survives for scrollback")

        try manager.close(terminalID: session.id)
        manager.teardownQueueForTesting().drainForTesting()
        XCTAssertTrue(engine.surfaces.first?.freed ?? false, "user close frees the mounted surface")
        XCTAssertNil(manager.session(for: session.id))
    }

    /// The exit payload rides the sink so consumers never re-read a session
    /// the reclamation may already have removed from the registry.
    func testExitSinkCarriesObservedExitPayload() throws {
        let (manager, engine, _, session) = try makeManager()
        defer { engine.shutdown() }

        nonisolated(unsafe) var observed: [TerminalSessionManager.ExitObservation] = []
        manager.processExitSink = { _, _, observation in observed.append(observation) }

        engine.eventSink?(GhosttyEvent(
            terminalID: session.id,
            generation: .initial,
            payload: .childExited(exitCode: 7)
        ))

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.exitCode, 7)
        XCTAssertNil(observed.first?.signal)
    }

    /// close() over an already-observed exit must not downgrade the phase to
    /// .exiting — the operator-visible record stays "exited(code)".
    func testCloseAfterObservedExitPreservesExitedPhase() throws {
        let (manager, engine, _, session) = try makeManager()
        defer { engine.shutdown() }

        engine.eventSink?(GhosttyEvent(
            terminalID: session.id,
            generation: .initial,
            payload: .childExited(exitCode: 2)
        ))
        try manager.close(terminalID: session.id)

        guard case .exited = manager.session(for: session.id)?.processPhase else {
            return XCTFail("close must not downgrade an observed exit to .exiting")
        }
        manager.teardownQueueForTesting().drainForTesting()
        XCTAssertNil(manager.session(for: session.id))
    }

    /// Regression (2026-08-26 main-thread wedge): a sink that tears its own
    /// terminal down DURING delivery re-entered the callback box's
    /// non-reentrant lock via clearSink and self-deadlocked the main thread
    /// inside ghostty_app_tick (tick → action_cb → child-exit sink →
    /// reclaim → beginTeardown → clearSink). The box lock is recursive now;
    /// this test pins the contract: a synchronous close from inside the
    /// exit sink must complete, not hang.
    func testSinkClosingTerminalDuringDeliveryDoesNotDeadlock() throws {
        let (manager, engine, _, session) = try makeManager()
        defer { engine.shutdown() }

        manager.processExitSink = { [weak manager] terminalID, _, _ in
            try? manager?.close(terminalID: terminalID)
        }

        engine.eventSink?(GhosttyEvent(
            terminalID: session.id,
            generation: .initial,
            payload: .childExited(exitCode: 0)
        ))

        // Delivery returned without wedging; the sink's close ran inline.
        guard case .exited = manager.session(for: session.id)?.processPhase else {
            return XCTFail("phase stays exited after sink-driven close")
        }
        manager.teardownQueueForTesting().drainForTesting()
        XCTAssertNil(manager.session(for: session.id), "sink-driven close tears the terminal down")
        XCTAssertTrue(engine.surfaces.first?.freed ?? false, "native free ran exactly once")
    }
}

extension TerminalSession.Presentation {
    var isMounted: Bool {
        if case .mounted = self {
            return true
        }
        return false
    }
}

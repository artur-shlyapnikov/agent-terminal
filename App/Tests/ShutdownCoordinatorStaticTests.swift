import AgentCore
@testable import AgentTerminal
import AppKit
import XCTest

// Round-3 Suite L (R3-7): the no-refactor-testable pure decisions of the
// §3.15 quit flow — modal-response→choice mapping, live-phase classification,
// and the QuitPreview resumable/unsupported partition. No instance, no root.

@MainActor
final class ShutdownCoordinatorStaticTests: XCTestCase {
    func testQuitSheetResponseMappingAndLiveClassificationPinTheDecisionCore() throws {
        // (a) choice(for:) maps the four sheet buttons by raw response value
        // (1000–1003 as installed by presentQuitSheet); hideWindow is the
        // never-terminate-by-accident catch-all default.
        XCTAssertEqual(
            ShutdownCoordinator.choice(for: NSApplication.ModalResponse(rawValue: 1000)),
            .hideWindow
        )
        XCTAssertEqual(
            ShutdownCoordinator.choice(for: NSApplication.ModalResponse(rawValue: 1001)),
            .quitAndResumeLater
        )
        XCTAssertEqual(
            ShutdownCoordinator.choice(for: NSApplication.ModalResponse(rawValue: 1002)),
            .quitAndStopAgents
        )
        XCTAssertEqual(
            ShutdownCoordinator.choice(for: NSApplication.ModalResponse(rawValue: 1003)),
            .cancel
        )
        // Named/arbitrary responses fall through to hideWindow.
        XCTAssertEqual(
            ShutdownCoordinator.choice(for: .alertFirstButtonReturn),
            .hideWindow
        )
        XCTAssertEqual(
            ShutdownCoordinator.choice(for: NSApplication.ModalResponse(rawValue: 4242)),
            .hideWindow
        )

        // (b) isLive classifies exactly starting/idle/working/waitingForInput/
        // stopping as live.
        XCTAssertTrue(ShutdownCoordinator.isLive(.starting))
        XCTAssertTrue(ShutdownCoordinator.isLive(.idle))
        XCTAssertTrue(ShutdownCoordinator.isLive(.working))
        XCTAssertTrue(ShutdownCoordinator.isLive(.waitingForInput(InputRequestDescriptor(
            kind: .freeText,
            summary: nil,
            source: .integration
        ))))
        XCTAssertTrue(ShutdownCoordinator.isLive(.stopping))
        XCTAssertFalse(ShutdownCoordinator.isLive(.unknown))
        XCTAssertFalse(ShutdownCoordinator.isLive(.stopped(.userRequested)))
        XCTAssertFalse(ShutdownCoordinator.isLive(.failed(FailureDescriptor(reason: "x"))))

        // (c) QuitPreview partitions resumable vs unsupported disjointly and
        // completely, and renders the operator-facing summary.
        let resumableSession = ShutdownCoordinator.QuitSession(
            id: AgentID(),
            displayName: "Claude Task",
            kindName: "claude-code",
            resumable: true,
            reasonText: nil
        )
        let unsupportedSession = ShutdownCoordinator.QuitSession(
            id: AgentID(),
            displayName: "Shell Task",
            kindName: "generic-shell",
            resumable: false,
            reasonText: "no session reference was captured"
        )
        var preview = ShutdownCoordinator.QuitPreview()
        preview.runningAgents = [resumableSession, unsupportedSession]
        preview.liveShellCount = 2

        XCTAssertEqual(preview.resumable, [resumableSession])
        XCTAssertEqual(preview.unsupported, [unsupportedSession])
        XCTAssertTrue(preview.hasRunningWork)
        let summary = try XCTUnwrap(preview.unsupportedSummary)
        XCTAssertTrue(summary.contains("Shell Task"), "summary names the session")
        XCTAssertTrue(summary.contains("generic-shell"), "summary names the kind")
        XCTAssertTrue(summary.contains("no session reference was captured"), "summary gives the reason")

        // Empty preview: nothing running, nothing to list.
        let empty = ShutdownCoordinator.QuitPreview()
        XCTAssertNil(empty.unsupportedSummary)
        XCTAssertFalse(empty.hasRunningWork)
    }
}

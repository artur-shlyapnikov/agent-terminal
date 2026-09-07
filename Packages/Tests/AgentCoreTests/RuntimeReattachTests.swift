@testable import AgentCore
import XCTest

// Restart-reattach behavioral proof (review major M-restart, §3.5 "Surface
// generation changed"):
//
// After the launch pipeline spawns a successor surface, AgentRuntime.reattach
// must re-point the session's single-live-terminal invariant at it so that
//   1. prompt delivery lands on the SUCCESSOR terminal (never the retired one),
//   2. the delivery watchdog confirms via outputRevisionChanged reported
//      against the successor terminal,
//   3. stop (gracefulStop ladder) signals the successor terminal,
// while traffic addressed to the retired terminal keeps failing with
// terminalUnavailable.

final class RuntimeReattachTests: XCTestCase {
    func testReattachRoutesPromptWatchdogAndStopToSuccessorTerminal() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let port = FakeTerminalPort()
        await runtime.setTerminalPort(port)

        let (_, agentID, oldTerminal) = try await runtime.makeRunningAgent(kind: .genericShell)
        await runtime.ingest(integrationEvidence(
            agent: agentID, lifecycle: .idle, sourceID: "hook:test",
            sequence: 1, receivedAt: clock.now
        ))

        // Restart mints generation N+1 and drops old evidence; the app-side
        // pipeline then spawns a NEW terminal and rebinds it.
        try await runtime.restart(agentID)
        let newGeneration = SurfaceGeneration(rawValue: 1)
        let newTerminal = TerminalID()
        try await runtime.reattach(
            agentID: agentID, terminalID: newTerminal, generation: newGeneration
        )

        // The retired terminal is dead: the session's single-terminal
        // invariant now points at the successor, so surface-addressed
        // traffic naming the OLD terminal is rejected.
        do {
            try await runtime.outputRevisionChanged(
                agentID: agentID, terminalID: oldTerminal, revision: 99
            )
            XCTFail("output revision against the retired terminal must throw")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .terminalUnavailable)
        }

        // 1. Prompt delivery flows to the successor terminal.
        let receipt = try await runtime.prompt(agentID, "post-restart", .sendNow)
        XCTAssertEqual(receipt.outcome, .delivered)
        await eventually("prompt delivered on the successor terminal") {
            !port.deliveredTexts.isEmpty &&
                port.deliveredTexts.last?.0 == newTerminal &&
                port.deliveredTexts.last?.1 == "post-restart"
        }

        // 2. Watchdog confirmation through the successor terminal's render —
        //    no unconfirmed event may appear.
        try await runtime.outputRevisionChanged(
            agentID: agentID, terminalID: newTerminal, revision: 7
        )
        let watchArmed = await runtime.deliveryWatchStatus(agentID)
        XCTAssertNotNil(watchArmed, "watch armed at delivery")
        await eventually("watchdog confirmed via output revision on successor") {
            await runtime.deliveryWatchStatus(agentID) == nil
        }
        let unconfirmed = await runtime.timeline(of: agentID).contains { event in
            if case .promptDeliveryUnconfirmed = event.event {
                return true
            }
            return false
        }
        XCTAssertFalse(unconfirmed, "confirmed delivery never records unconfirmed")

        // 3. Stop targets the successor terminal.
        try await runtime.stop(agentID, mode: .interrupt)
        await eventually("interrupt signal sent to the successor terminal") {
            port.sentSignals.last?.0 == newTerminal &&
                port.sentSignals.last?.1 == .interrupt
        }
    }

    func testReattachRejectsUnknownAgent() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        do {
            try await runtime.reattach(
                agentID: AgentID(), terminalID: TerminalID(), generation: .initial
            )
            XCTFail("reattach of an unknown agent must throw")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .agentNotFound)
        }
    }
}

@testable import AgentCore
import XCTest

// §4.8: turn tracking — no false completion. A turn opens on a delivered
// prompt, idle → working without a prompt, or an integration operation start;
// it closes on working → idle, successful exit, or integration completion.
// starting → idle must NEVER create a completion (architecture §3.5).

@MainActor
final class TurnTrackerTests: XCTestCase {
    func testDeliveredPromptOpensTurn() {
        var tracker = TurnTracker()
        XCTAssertTrue(tracker.promptDelivered(commandID: CommandID(), at: instant(5)))
        XCTAssertTrue(tracker.isActive)
    }

    func testSecondPromptDoesNotOpenSecondTurn() {
        var tracker = TurnTracker()
        tracker.promptDelivered(commandID: CommandID(), at: instant(5))
        // The turn is already open; a second delivered prompt must not nest one.
        XCTAssertFalse(tracker.promptDelivered(commandID: CommandID(), at: instant(8)))
        XCTAssertTrue(tracker.isActive)
    }

    func testIdleToWorkingWithoutPromptOpensSpontaneousTurn() {
        var tracker = TurnTracker()
        _ = tracker.observe(from: .idle, to: .working, at: instant(10))
        XCTAssertTrue(tracker.isActive)

        guard let turn = tracker.activeTurn else { return XCTFail("expected an active turn") }
        guard case .spontaneousWork = turn.reason else {
            return XCTFail("expected spontaneousWork, got \(turn.reason)")
        }
    }

    func testWorkingToIdleClosesTurnAsCompletion() {
        var tracker = TurnTracker()
        tracker.workStarted(at: instant(10))
        let closeReason = tracker.observe(from: .working, to: .idle, at: instant(20))
        XCTAssertEqual(closeReason, .becameIdle)
        XCTAssertFalse(tracker.isActive)
    }

    func testStartingToIdleNeverCreatesCompletion() {
        var tracker = TurnTracker()
        // No turn was ever open during startup; starting → idle closes nothing
        // and must not fabricate a completion (§3.5).
        let closeReason = tracker.observe(from: .starting, to: .idle, at: instant(20))
        XCTAssertNil(closeReason)
        XCTAssertFalse(tracker.isActive)
    }

    func testWorkingWithoutOpenTurnToIdleYieldsNothing() {
        var tracker = TurnTracker()
        let closeReason = tracker.observe(from: .working, to: .idle, at: instant(20))
        XCTAssertNil(closeReason)
    }

    func testSuccessfulExitClosesTurn() {
        var tracker = TurnTracker()
        tracker.workStarted(at: instant(10))
        let closeReason = tracker.observe(
            from: .working,
            to: .stopped(.completed),
            at: instant(30)
        )
        XCTAssertEqual(closeReason, .processExitedSuccessfully)
        XCTAssertFalse(tracker.isActive)
    }

    func testIntegrationOperationOpensAndCompletesTurn() {
        var tracker = TurnTracker()
        XCTAssertTrue(tracker.integrationOperationStarted(at: instant(10)))
        XCTAssertTrue(tracker.isActive)
        XCTAssertTrue(tracker.integrationCompleted())
        XCTAssertFalse(tracker.isActive)
    }

    func testIntegrationCompletionWithoutTurnIsIgnored() {
        var tracker = TurnTracker()
        XCTAssertFalse(tracker.integrationCompleted())
    }

    func testResetClearsActiveTurn() {
        var tracker = TurnTracker()
        tracker.workStarted(at: instant(10))
        tracker.reset()
        XCTAssertFalse(tracker.isActive)
    }

    func testAttributionComesFromActiveTurnNotLastClosed() {
        var tracker = TurnTracker()

        // Turn 1 was opened by a delivered prompt.
        tracker.promptDelivered(commandID: CommandID(), at: instant(5))
        _ = tracker.observe(from: .idle, to: .working, at: instant(8))
        _ = tracker.observe(from: .working, to: .idle, at: instant(30))
        XCTAssertFalse(tracker.isActive)

        // Turn 2 is spontaneous work; completion attribution must come from
        // the ACTIVE turn, not leak "prompt" in from the last closed one.
        _ = tracker.observe(from: .idle, to: .working, at: instant(40))
        XCTAssertEqual(tracker.activeTurn?.openedByPrompt, false)
    }

    // MARK: Runtime turn mirror (projection truthfulness)

    func testRuntimeProjectionReportsTurnActiveFromTracker() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent(kind: .claudeCode)

        // No turn yet.
        var projection = await runtime.projection()
        XCTAssertEqual(projection.agents.first?.turnActive, false)

        // Idle → working evidence opens a spontaneous turn; the projection
        // must reflect it through the session mirror.
        await runtime.ingest(screenEvidence(
            agent: made.agent,
            lifecycle: .working,
            receivedAt: instant(10),
            outputRevision: 1
        ))
        projection = await runtime.projection()
        XCTAssertEqual(projection.agents.first?.turnActive, true)

        // Working → idle closes it again.
        await runtime.ingest(screenEvidence(
            agent: made.agent,
            lifecycle: .idle,
            receivedAt: instant(20),
            outputRevision: 2
        ))
        projection = await runtime.projection()
        XCTAssertEqual(projection.agents.first?.turnActive, false)
    }

    // MARK: Round 17 — non-completed terminal edges close plainly (7dfa094)

    /// B1: `.stopped(.userRequested)` routes through the plain `.stopped`
    /// arm to `.becameIdle`; ONLY `.stopped(.completed)` yields
    /// `.processExitedSuccessfully` (§4.8 "no false completion"). A user
    /// stop must never mint a completion event.
    func testUserRequestedStopClosesTurnAsBecameIdleNotCompletion() {
        var tracker = TurnTracker()
        XCTAssertTrue(tracker.workStarted(at: instant(10)))
        let closeReason = tracker.observe(
            from: .working,
            to: .stopped(.userRequested),
            at: instant(30)
        )
        XCTAssertEqual(closeReason, .becameIdle)
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.activeTurn)
    }

    /// B2: ANY non-completed terminal edge is a plain close — failure exits
    /// included — and the closed reason never depends on how the turn
    /// OPENED (prompt vs spontaneous work).
    func testFailedExitAlsoClosesAsBecameIdleAndAttributionStaysWithTheClosedTurn() {
        // Leg 1: prompt-opened turn closes identically (open-reason
        // independence; complements B1's work-opened leg).
        var promptOpened = TurnTracker()
        XCTAssertTrue(promptOpened.promptDelivered(commandID: CommandID(), at: instant(5)))
        XCTAssertEqual(
            promptOpened.observe(from: .working, to: .stopped(.userRequested), at: instant(30)),
            .becameIdle
        )
        XCTAssertFalse(promptOpened.isActive)

        // Leg 2: a failure exit is also a plain close, never a completion.
        var tracker = TurnTracker()
        XCTAssertTrue(tracker.workStarted(at: instant(10)))
        XCTAssertEqual(
            tracker.observe(
                from: .working,
                to: .failed(FailureDescriptor(reason: "crash")),
                at: instant(30)
            ),
            .becameIdle
        )
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.activeTurn)
    }
}

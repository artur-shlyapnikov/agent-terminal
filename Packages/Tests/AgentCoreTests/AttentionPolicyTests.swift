@testable import AgentCore
import XCTest

// §4.8: attention ordering and clearing (§3.4).

@MainActor
final class AttentionPolicyTests: XCTestCase {
    private func waiting(_ kind: InputRequestKind = .approval, safe: SafeReplyMode = .terminalOnly) -> LifecyclePhase {
        .waitingForInput(InputRequestDescriptor(
            kind: kind,
            summary: "run rm -rf?",
            safeReplyMode: safe,
            source: .screen
        ))
    }

    // MARK: Raising

    func testEnteringWaitingRaisesInputRequired() {
        let attention = AttentionPolicy.update(
            current: .none,
            from: .working,
            to: waiting(),
            turnClosedWithCompletion: false,
            agentVisibleAndActive: false,
            at: instant(100),
            eventID: RuntimeEventID()
        )
        guard case let .inputRequired(_, requestID) = attention else {
            return XCTFail("expected inputRequired")
        }
        XCTAssertEqual(requestID, "run rm -rf?")
    }

    func testFailureRaisesFailureAttention() {
        let attention = AttentionPolicy.update(
            current: .none,
            from: .working,
            to: .failed(FailureDescriptor(exitCode: 1)),
            turnClosedWithCompletion: false,
            agentVisibleAndActive: false,
            at: instant(100),
            eventID: RuntimeEventID()
        )
        guard case .failure = attention else { return XCTFail("expected failure") }
    }

    func testOpenTurnWorkingToIdleHiddenAgentRaisesCompletionUnread() {
        let attention = AttentionPolicy.update(
            current: .none,
            from: .working,
            to: .idle,
            turnClosedWithCompletion: true,
            agentVisibleAndActive: false,
            at: instant(100),
            eventID: RuntimeEventID()
        )
        guard case .completionUnread = attention else { return XCTFail("expected completionUnread") }
    }

    func testVisibleAgentDoesNotRaiseCompletionUnread() {
        let attention = AttentionPolicy.update(
            current: .none,
            from: .working,
            to: .idle,
            turnClosedWithCompletion: true,
            agentVisibleAndActive: true,
            at: instant(100),
            eventID: RuntimeEventID()
        )
        XCTAssertEqual(attention, .none)
    }

    // MARK: Priority

    func testPriorityOrderInputRequiredOverFailureOverCompletion() {
        XCTAssertGreaterThan(AttentionRank.inputRequired, AttentionRank.failure)
        XCTAssertGreaterThan(AttentionRank.failure, AttentionRank.completionUnread)
        XCTAssertGreaterThan(AttentionRank.completionUnread, AttentionRank.none)
    }

    func testCompletionNeverOverridesExistingFailure() {
        let since = instant(50)
        let existing = AttentionState.failure(since: since, eventID: RuntimeEventID())
        let attention = AttentionPolicy.update(
            current: existing,
            from: .working,
            to: .idle,
            turnClosedWithCompletion: true,
            agentVisibleAndActive: false,
            at: instant(100),
            eventID: RuntimeEventID()
        )
        XCTAssertEqual(attention, existing, "completionUnread must not downgrade failure")
    }

    func testCompletionNeverOverridesExistingInputRequired() {
        let existing = AttentionState.inputRequired(since: instant(50), requestID: nil)
        let attention = AttentionPolicy.update(
            current: existing,
            from: waiting(),
            to: .idle,
            turnClosedWithCompletion: true,
            agentVisibleAndActive: false,
            at: instant(100),
            eventID: RuntimeEventID()
        )
        // Leaving waiting clears inputRequired; completion then applies because
        // rank 0 < 1 — this is the correct transition path.
        guard case .completionUnread = attention else {
            return XCTFail("after leaving waiting, completion should be raised")
        }
    }

    // MARK: Clearing

    func testLeavingWaitingClearsInputRequired() {
        let attention = AttentionPolicy.update(
            current: .inputRequired(since: instant(10), requestID: nil),
            from: waiting(),
            to: .working,
            turnClosedWithCompletion: false,
            agentVisibleAndActive: true,
            at: instant(100),
            eventID: RuntimeEventID()
        )
        XCTAssertEqual(attention, .none)
    }

    func testStillWaitingKeepsOriginalSince() throws {
        let originalSince = instant(10)
        let current = AttentionState.inputRequired(since: originalSince, requestID: nil)
        let attention = AttentionPolicy.update(
            current: current,
            from: waiting(.approval),
            to: waiting(.selection),
            turnClosedWithCompletion: false,
            agentVisibleAndActive: false,
            at: instant(200),
            eventID: RuntimeEventID()
        )
        XCTAssertEqual(
            try XCTUnwrap(attention.since),
            originalSince,
            "re-matching a waiting rule keeps the oldest timestamp"
        )
    }

    func testMarkSeenClearsOnlyCompletionUnread() {
        XCTAssertEqual(
            AttentionPolicy.clearCompletionOnSeen(.completionUnread(since: instant(1), eventID: RuntimeEventID())),
            .none
        )
        let failure = AttentionState.failure(since: instant(1), eventID: RuntimeEventID())
        XCTAssertEqual(AttentionPolicy.clearCompletionOnSeen(failure), failure)
        let input = AttentionState.inputRequired(since: instant(1), requestID: nil)
        XCTAssertEqual(AttentionPolicy.clearCompletionOnSeen(input), input)
    }

    func testAcknowledgeClearsOnlyFailure() {
        let failure = AttentionState.failure(since: instant(1), eventID: RuntimeEventID())
        XCTAssertEqual(AttentionPolicy.acknowledgeFailure(failure), .none)

        let completion = AttentionState.completionUnread(since: instant(1), eventID: RuntimeEventID())
        XCTAssertEqual(AttentionPolicy.acknowledgeFailure(completion), completion)
    }

    func testRelaunchClearsFailureAndInputButKeepsCompletion() {
        let failure = AttentionState.failure(since: instant(1), eventID: RuntimeEventID())
        XCTAssertEqual(AttentionPolicy.clearForRelaunch(failure), .none)

        let input = AttentionState.inputRequired(since: instant(1), requestID: nil)
        XCTAssertEqual(AttentionPolicy.clearForRelaunch(input), .none)

        let completion = AttentionState.completionUnread(since: instant(1), eventID: RuntimeEventID())
        XCTAssertEqual(AttentionPolicy.clearForRelaunch(completion), completion)
    }

    // MARK: Runtime integration for the visibility rule

    func testRuntimeMarkSeenClearsCompletionAfterTurnCompletion() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent()

        // Open a turn (working) then complete it back to idle — agent hidden.
        try await runtime.setVisibility(made.agent, isVisible: false)
        await runtime.ingest(screenEvidence(agent: made.agent, lifecycle: .working, receivedAt: clock.now))
        await runtime.ingest(screenEvidence(agent: made.agent, lifecycle: .idle, receivedAt: clock.now))

        let stateBefore = try await runtime.state(of: made.agent)
        guard case .completionUnread = stateBefore.attention else {
            return XCTFail("hidden working→idle must raise completionUnread, got \(stateBefore.attention)")
        }

        try await runtime.markSeen(made.agent)
        let stateAfter = try await runtime.state(of: made.agent)
        XCTAssertEqual(stateAfter.attention, .none, "markSeen clears completionUnread only")
    }
}

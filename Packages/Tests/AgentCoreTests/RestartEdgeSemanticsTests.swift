@testable import AgentCore
import Foundation
import XCTest

// Round 6 Suite B: restart-edge semantics that earlier rounds left unpinned —
// the generation-watermark reset in EvidenceLedger, the no-open-turn/no-
// completion law of AgentStateMachine, and the deterministic createdAt-tie
// projection ordering. Reuses the shared TestSupport evidence factories and
// instant() helper (same target); the `state(lifecycle:)` shape mirrors
// AgentStateMachineTests, the session fixture mirrors RuntimeProjectionTests.

@MainActor
final class RestartEdgeSemanticsTests: XCTestCase {
    private let agent = AgentID()

    /// AgentState fixture (AgentStateMachineTests shape).
    private func state(
        lifecycle: LifecyclePhase = .starting,
        process: ProcessPhase = .running(pid: 1, processGroupID: 1),
        authority: StateAuthority = .screen,
        revision: UInt64 = 5
    ) -> AgentState {
        var agentState = AgentState.fresh(at: instant(0))
        agentState.lifecycle = lifecycle
        agentState.process = process
        agentState.authority = authority
        agentState.revision = revision
        return agentState
    }

    /// Minimal AgentSession fixture (RuntimeProjectionTests.makeSession shape)
    /// with explicit id control for UUID tie-breaks.
    private func makeSession(
        id: AgentID,
        displayName: String,
        createdAt: MonotonicInstant
    ) -> AgentSession {
        AgentSession(
            id: id,
            workspaceID: WorkspaceID(),
            kind: .claudeCode,
            displayName: displayName,
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: .claudeCode,
                program: "/usr/local/bin/agent",
                arguments: [],
                workingDirectory: "/tmp",
                environment: [:]
            ),
            state: AgentState.fresh(at: createdAt),
            createdAt: createdAt,
            lastActivityAt: createdAt
        )
    }

    // MARK: R1 — generation change resets the output-revision watermark

    func testGenerationChangeResetsOutputRevisionWatermark() {
        // Explicit generationChanged path.
        var ledger = EvidenceLedger()
        XCTAssertEqual(
            ledger.accept(screenEvidence(
                agent: agent, lifecycle: .working,
                receivedAt: instant(10), outputRevision: 9
            )),
            .accepted, "floor moves to 9"
        )
        // Positive control at generation 1 (mirrors RuntimeOrderingTests).
        XCTAssertEqual(
            ledger.accept(screenEvidence(
                agent: agent, lifecycle: .working,
                receivedAt: instant(11), outputRevision: 8
            )),
            .discardedStaleOutputRevision
        )

        ledger.generationChanged(SurfaceGeneration(rawValue: 2))

        // Revision 1 of the SUCCESSOR generation must pass rule 5 — before
        // the reset this exact observation was discarded as stale forever.
        let successor = screenEvidence(
            agent: agent, lifecycle: .working,
            receivedAt: instant(12), outputRevision: 1,
            generation: SurfaceGeneration(rawValue: 2)
        )
        XCTAssertEqual(ledger.accept(successor), .accepted)
        XCTAssertEqual(ledger.screenObservation?.envelope.outputRevision, 1)

        // AUTO-advance path: an envelope carrying a newer generation triggers
        // the same internal reset without an explicit generationChanged call.
        var autoLedger = EvidenceLedger()
        XCTAssertEqual(
            autoLedger.accept(screenEvidence(
                agent: agent, lifecycle: .working,
                receivedAt: instant(20), outputRevision: 9
            )),
            .accepted
        )
        let advanced = screenEvidence(
            agent: agent, lifecycle: .working,
            receivedAt: instant(21), outputRevision: 1,
            generation: SurfaceGeneration(rawValue: 2)
        )
        XCTAssertEqual(autoLedger.accept(advanced), .accepted)
        XCTAssertEqual(autoLedger.screenObservation?.envelope.outputRevision, 1)
    }

    // MARK: R2 — completion attention requires THIS edge to close an open turn

    func testProcessExitWithoutOpenTurnRaisesNoCompletionAttention() {
        // No open turn anywhere: a clean hidden exit is just an exit.
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .processExited(exitCode: 0, signal: nil, userInitiated: false),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertFalse(
            plan.turnClosedWithCompletion,
            "a turn-less exit must never raise completion attention"
        )
        guard case .stopped(.completed) = plan.newState.lifecycle else {
            return XCTFail("expected stopped(completed), got \(plan.newState.lifecycle)")
        }
        XCTAssertFalse(
            plan.events.contains { event in
                if case .turnCompleted = event {
                    return true
                }
                return false
            },
            "no turnCompleted event may be emitted for a turn-less exit"
        )

        // Contrast arm: ONLY the open turn flips the flag (same arrange,
        // tracker armed via workStarted).
        var openTracker = TurnTracker()
        openTracker.workStarted(at: instant(10))
        let contrast = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .processExited(exitCode: 0, signal: nil, userInitiated: false),
            turnTracker: openTracker,
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertTrue(contrast.turnClosedWithCompletion)
    }

    // MARK: R3 — deterministic projection ordering when createdAt ties

    func testProjectionOrderingIsDeterministicWhenCreatedAtTies() throws {
        // Fixed UUIDs with known string ordering.
        let firstID = try AgentID(rawValue: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")))
        let secondID = try AgentID(rawValue: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")))
        precondition(firstID.rawValue.uuidString < secondID.rawValue.uuidString)

        let tiedAt = instant(5)
        let first = makeSession(id: firstID, displayName: "First", createdAt: tiedAt)
        let second = makeSession(id: secondID, displayName: "Second", createdAt: tiedAt)

        // Both input orders produce IDENTICAL, UUID-ascending summaries.
        for sessions in [[second, first], [first, second]] {
            let projection = RuntimeProjectionBuilder.build(
                sessions: sessions, generatedAt: instant(99)
            )
            XCTAssertEqual(projection.agents.map(\.id), [firstID, secondID])
        }

        // Mixed createdAt still wins first: an earlier session precedes tied
        // ones even when its UUID sorts higher.
        let early = makeSession(id: secondID, displayName: "Early", createdAt: instant(1))
        let mixed = RuntimeProjectionBuilder.build(
            sessions: [first, early], generatedAt: instant(99)
        )
        XCTAssertEqual(mixed.agents.map(\.displayName), ["Early", "First"])
    }
}

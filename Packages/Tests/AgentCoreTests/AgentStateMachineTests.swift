@testable import AgentCore
import XCTest

// §4.8: lifecycle transitions through the pure reducer.

@MainActor
final class AgentStateMachineTests: XCTestCase {
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

    func testExitZeroUserInitiatedBecomesStoppedUserRequested() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .stopping),
            trigger: .processExited(exitCode: 0, signal: nil, userInitiated: true),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        guard case .stopped(.userRequested) = plan.newState.lifecycle else {
            return XCTFail("expected stopped(userRequested), got \(plan.newState.lifecycle)")
        }
        XCTAssertEqual(plan.newState.process, .exited(exitCode: 0, signal: nil, userInitiated: true))
    }

    func testExitZeroNotUserInitiatedWithOpenHiddenTurnRaisesCompletion() {
        var tracker = TurnTracker()
        tracker.workStarted(at: instant(10))
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .processExited(exitCode: 0, signal: nil, userInitiated: false),
            turnTracker: tracker,
            agentVisibleAndActive: false,
            at: instant(100)
        )
        guard case .stopped(.completed) = plan.newState.lifecycle else {
            return XCTFail("expected stopped(completed)")
        }
        XCTAssertTrue(plan.turnClosedWithCompletion)
    }

    func testExitZeroNotUserInitiatedVisibleAgentDoesNotRaiseCompletion() {
        var tracker = TurnTracker()
        tracker.workStarted(at: instant(10))
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .processExited(exitCode: 0, signal: nil, userInitiated: false),
            turnTracker: tracker,
            agentVisibleAndActive: true,
            at: instant(100)
        )
        guard case .stopped(.completed) = plan.newState.lifecycle else {
            return XCTFail("expected stopped(completed)")
        }
        XCTAssertFalse(plan.turnClosedWithCompletion)
    }

    func testNonZeroExitBecomesFailed() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .processExited(exitCode: 1, signal: nil, userInitiated: false),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        guard case let .failed(descriptor) = plan.newState.lifecycle else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(descriptor.exitCode, 1)
    }

    func testSignalExitBecomesFailed() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .processExited(exitCode: nil, signal: 9, userInitiated: true),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        guard case .failed = plan.newState.lifecycle else {
            return XCTFail("expected failed on signal exit")
        }
    }

    /// The exit's CAUSE event must precede the effects it triggers
    /// (stateChanged/turnCompleted) in the persisted timeline.
    func testProcessExitedCauseEventPrecedesItsEffects() {
        var tracker = TurnTracker()
        tracker.workStarted(at: instant(10))
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .processExited(exitCode: 0, signal: nil, userInitiated: false),
            turnTracker: tracker,
            agentVisibleAndActive: false,
            at: instant(100)
        )
        guard case .processExited = plan.events.first else {
            return XCTFail("expected .processExited first, got \(plan.events)")
        }
        XCTAssertTrue(plan.events.dropFirst().contains {
            if case .stateChanged = $0 {
                return true
            }
            return false
        })
    }

    func testInterruptDoesNotChangeLifecycle() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .stopRequested(.interrupt),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.lifecycle, .working)
        XCTAssertTrue(plan.events.contains(.stopCommanded(mode: .interrupt)))
    }

    func testGracefulStopEntersStopping() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .stopRequested(.gracefulStop),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.lifecycle, .stopping)
    }

    func testCloseViewChangesNothing() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .stopRequested(.closeView),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.lifecycle, .working)
        XCTAssertTrue(plan.events.contains(.stopCommanded(mode: .closeView)))
    }

    func testRestartResetsToStartingWithFreshGeneration() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            trigger: .restartRequested(SurfaceGeneration(rawValue: 7)),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.lifecycle, .starting)
        XCTAssertEqual(plan.newState.process, .launching)
        XCTAssertTrue(plan.events.contains(.restartInitiated(generation: SurfaceGeneration(rawValue: 7))))
    }

    func testRestartRequestedResetsAnActiveTurnTracker() {
        var promptOpened = TurnTracker()
        XCTAssertTrue(promptOpened.promptDelivered(commandID: CommandID(), at: instant(10)))
        var workOpened = TurnTracker()
        XCTAssertTrue(workOpened.workStarted(at: instant(10)))
        for tracker in [promptOpened, workOpened] {
            XCTAssertTrue(tracker.isActive)
            let plan = AgentStateMachine.plan(
                current: state(lifecycle: .working, revision: 9),
                trigger: .restartRequested(SurfaceGeneration(rawValue: 7)),
                turnTracker: tracker,
                agentVisibleAndActive: false,
                at: instant(100)
            )
            XCTAssertFalse(plan.turnTracker.isActive)
            XCTAssertNil(plan.turnTracker.activeTurn)
            XCTAssertEqual(plan.newState.lifecycle, .starting)
            XCTAssertTrue(plan.events.contains(.restartInitiated(generation: SurfaceGeneration(rawValue: 7))))
        }
    }

    func testAuthorityLostDropsToUnknownAndRecordsDiagnostics() {
        let plan = AgentStateMachine.plan(
            current: state(authority: .screen),
            trigger: .authorityLost,
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.authority, .unknown)
        XCTAssertEqual(plan.newState.lifecycle, .unknown)
        XCTAssertTrue(plan.events.contains(.authorityLost(previous: .screen)))
    }

    func testLaunchFailedBecomesFailedWithDescriptor() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .starting, process: .launching),
            trigger: .launchFailed("executable not found"),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.process, .launchFailed(errorDescriptor: "executable not found"))
        guard case .failed = plan.newState.lifecycle else {
            return XCTFail("expected failed")
        }
    }

    func testRevisionBumpsByExactlyOnePerTrigger() {
        let plan = AgentStateMachine.plan(
            current: state(revision: 41),
            trigger: .stopRequested(.interrupt),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.revision, 42)
    }

    func testAdoptingScreenEvidenceMovesLifecycleAndAuthority() {
        var tracker = TurnTracker()
        tracker.workStarted(at: instant(10))
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .idle),
            trigger: .surfaceCreated,
            turnTracker: tracker,
            agentVisibleAndActive: false,
            at: instant(20)
        )
        XCTAssertEqual(plan.turnTracker.isActive, true)
        _ = plan

        let adopted = AgentStateMachine.plan(
            current: state(lifecycle: .idle),
            adopting: .working,
            authority: .screen,
            turnTracker: tracker,
            agentVisibleAndActive: false,
            at: instant(30)
        )
        XCTAssertEqual(adopted.newState.lifecycle, .working)
        XCTAssertEqual(adopted.newState.authority, .screen)
    }

    func testAdoptingIdleClosesOpenTurnAndFlagsCompletion() {
        var tracker = TurnTracker()
        tracker.promptDelivered(commandID: CommandID(), at: instant(10))
        tracker.observe(from: .idle, to: .working, at: instant(15))

        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working),
            adopting: .idle,
            authority: .screen,
            turnTracker: tracker,
            agentVisibleAndActive: false,
            at: instant(30)
        )
        XCTAssertTrue(plan.turnClosedWithCompletion)
        XCTAssertTrue(plan.events.contains(.turnCompleted(hadPrompt: true)))
        XCTAssertFalse(plan.turnTracker.isActive)
    }

    func testAdoptingSameLifecycleAndAuthorityIsAFullNoOp() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .working, revision: 9),
            adopting: .working,
            authority: .screen,
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(30)
        )
        // Nothing changed — no revision is minted, no events emitted.
        XCTAssertEqual(plan.newState.revision, 9)
        XCTAssertTrue(plan.events.isEmpty)
    }

    func testAdoptingWithAuthorityOnlyChangeBumpsRevisionAndEmitsStateChanged() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .idle, revision: 9),
            adopting: .idle,
            authority: .integration,
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(30)
        )
        XCTAssertEqual(plan.newState.revision, 10)
        XCTAssertEqual(plan.newState.authority, .integration)
        XCTAssertEqual(plan.events.count, 1)
        if case let .stateChanged(from, to, authority) = plan.events[0] {
            XCTAssertEqual(from, .idle)
            XCTAssertEqual(to, .idle)
            XCTAssertEqual(authority, .integration)
        } else {
            XCTFail("expected stateChanged, got \(plan.events[0])")
        }
    }

    // MARK: Runtime-level stop modes (§3.11) — signals are the port's job

    private func makeRuntime() async throws -> (AgentRuntime, FakeTerminalPort, AgentID, FakeClock) {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent(kind: .claudeCode)
        let port = FakeTerminalPort()
        await runtime.setTerminalPort(port)
        return (runtime, port, made.agent, clock)
    }

    func testRuntimeGracefulStopSendsTerminateThenKillAfterTwoSecondGrace() async throws {
        let (runtime, port, agent, clock) = try await makeRuntime()

        try await runtime.stop(agent, mode: .gracefulStop)
        XCTAssertEqual(port.signalIntents(), [.terminate])
        let stoppingState = try await runtime.state(of: agent)
        XCTAssertEqual(stoppingState.lifecycle, .stopping)

        // Before the grace period expires there must be no SIGKILL.
        clock.advance(by: .seconds(1))
        await eventually("no early kill") { port.signalIntents().count == 1 }

        // Advance past the 2 s grace period; SIGKILL must follow.
        clock.advance(by: .seconds(2))
        await eventually("kill after grace") { port.signalIntents() == [.terminate, .kill] }
    }

    func testRuntimeInterruptSendsOnlyInterruptAndKeepsProcessAlive() async throws {
        let (runtime, port, agent, clock) = try await makeRuntime()

        try await runtime.interrupt(agent)
        XCTAssertEqual(port.signalIntents(), [.interrupt])
        // Interrupt never changes lifecycle (§3.5).
        let interruptedState = try await runtime.state(of: agent)
        XCTAssertEqual(interruptedState.lifecycle, .starting)

        // Time passing must not escalate an interrupt into a kill.
        clock.advance(by: .seconds(10))
        await eventually("interrupt stays interrupt") { port.signalIntents() == [.interrupt] }
    }

    func testRuntimeCloseViewNeverSignals() async throws {
        let (runtime, port, agent, _) = try await makeRuntime()

        try await runtime.stop(agent, mode: .closeView)
        XCTAssertTrue(port.signalIntents().isEmpty)
        // Lifecycle untouched by close view (§3.11).
        let closeViewState = try await runtime.state(of: agent)
        XCTAssertEqual(closeViewState.lifecycle, .starting)
    }

    /// Regression: a stop that cannot reach a live terminal must throw
    /// BEFORE the plan is applied — applying first wedged the agent in
    /// .stopping with stopCommanded persisted, a live process, no grace-kill
    /// backstop, and a phantom stop timeline event.
    func testStopWithoutLiveTerminalThrowsBeforeMutatingState() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent(kind: .claudeCode)

        do {
            try await runtime.stop(made.agent, mode: .gracefulStop)
            XCTFail("expected terminalUnavailable")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .terminalUnavailable)
        }
        let gracefulState = try await runtime.state(of: made.agent)
        XCTAssertEqual(gracefulState.lifecycle, .starting,
                       "a stop that cannot signal must not wedge the agent in .stopping")
        let timeline = await runtime.timeline(of: made.agent)
        XCTAssertFalse(
            timeline.contains { event in
                if case .stopCommanded = event.event {
                    return true
                }
                return false
            },
            "a stop that cannot signal must not leave a phantom stopCommanded event"
        )
        do {
            try await runtime.interrupt(made.agent)
            XCTFail("expected terminalUnavailable")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .terminalUnavailable)
        }
        let interruptedState = try await runtime.state(of: made.agent)
        XCTAssertEqual(interruptedState.lifecycle, .starting,
                       "interrupt without a live terminal must not mutate state either")
    }

    /// Pins the graceful-stop backstop: when the SIGTERM delivery itself
    /// throws, the deferred sweep must still fire SIGKILL past the 2 s grace.
    func testFailedGracefulStopStillArmsTheTwoSecondKillBackstop() async throws {
        let (runtime, _, agent, clock) = try await makeRuntime()
        let port = FailingSignalPort()
        await runtime.setTerminalPort(port)

        do {
            try await runtime.stop(agent, mode: .gracefulStop)
            XCTFail("expected the SIGTERM delivery to fail")
        } catch {}

        clock.advance(by: .seconds(2))
        await eventually("kill swept despite failed terminate") {
            port.recordedIntents() == [.terminate, .kill]
        }
    }

    // MARK: Round 17 — restart-specific authority reset (43dd0cf)

    /// C1: `transitionLifecycle(to:)` no-ops on same-phase, so restarting an
    /// already-`.starting` agent (launch wedged, user hits restart) would
    /// otherwise inherit the dead run's authority; the explicit reset exists
    /// precisely for that no-op leg — WITHOUT any accompanying stateChanged
    /// event (a forced re-emission would churn revisions for every wedge
    /// restart). Reachable ONLY from an already-`.starting` state.
    func testRestartFromAlreadyStartingResetsAuthorityWithoutStateChangedEvent() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .starting, process: .launching, authority: .screen, revision: 5),
            trigger: .restartRequested(SurfaceGeneration(rawValue: 7)),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.authority, .unknown)
        XCTAssertEqual(plan.newState.lifecycle, .starting)
        XCTAssertEqual(plan.newState.process, .launching)
        XCTAssertEqual(
            plan.events,
            [.restartInitiated(generation: SurfaceGeneration(rawValue: 7))],
            "the no-op leg must not emit a stateChanged event"
        )
        XCTAssertEqual(plan.newState.revision, 6, "bump() must run exactly once")
    }

    /// C2: the reset lives INSIDE the restart arm only; gracefulStop
    /// transitions with the incoming authority passed through. A stop command
    /// must not strip screen authority mid-ladder.
    func testGracefulStopFromStartingPreservesAuthorityResetIsRestartSpecific() {
        let plan = AgentStateMachine.plan(
            current: state(lifecycle: .starting, process: .launching, authority: .screen, revision: 5),
            trigger: .stopRequested(.gracefulStop),
            turnTracker: TurnTracker(),
            agentVisibleAndActive: false,
            at: instant(100)
        )
        XCTAssertEqual(plan.newState.lifecycle, .stopping)
        XCTAssertEqual(plan.newState.authority, .screen, "stop must preserve incoming authority")
        XCTAssertTrue(
            plan.events.contains(.stateChanged(from: .starting, to: .stopping, authority: .screen)),
            "events: \(plan.events)"
        )
    }
}

/// Records signal intents but fails every sendSignal — drives the
/// graceful-stop backstop through a failed SIGTERM delivery.
private final class FailingSignalPort: TerminalControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var intents: [SignalIntent] = []

    func recordedIntents() -> [SignalIntent] {
        lock.lock(); defer { lock.unlock() }
        return intents
    }

    func deliverInput(_: TerminalID, text _: String, submit _: Bool) async throws {}
    func sendKeys(_: TerminalID, keys _: [String]) async throws {}
    func read(_: TerminalID, source _: TerminalReadSource) async throws -> TerminalSnapshot? {
        nil
    }

    func sendSignal(_ intent: SignalIntent, to _: TerminalID) async throws {
        lock.withLock { intents.append(intent) }
        throw RuntimeErrors.terminalUnavailable
    }
}

import Foundation

// AgentStateMachine — pure transition reducer (architecture §3.5 table).
//
// Only AgentRuntime applies the plan this produces; the machine itself is a
// stateless function so every edge is directly unit-testable.

public struct StateTransitionPlan: Equatable, Sendable {
    public let newState: AgentState
    public let events: [AgentEvent]
    /// True when an active turn was closed by a completion-bearing edge
    /// (working → idle, or successful exit of a hidden agent).
    public let turnClosedWithCompletion: Bool
    /// Post-transition turn-tracker value.
    public let turnTracker: TurnTracker
}

public enum TransitionTrigger: Equatable, Sendable {
    case surfaceCreated
    case processLaunched(pid: Int32?, processGroupID: Int32?)
    case processExited(exitCode: Int32?, signal: Int32?, userInitiated: Bool)
    case launchFailed(String)
    case stopRequested(StopMode)
    case restartRequested(SurfaceGeneration)
    case authorityLost
}

public enum AgentStateMachine {
    /// Applies one trigger-based edge from the §3.5 table. Bumps the revision
    /// by exactly one per applied change.
    public static func plan(
        current: AgentState,
        trigger: TransitionTrigger,
        turnTracker: TurnTracker,
        agentVisibleAndActive: Bool,
        at instant: MonotonicInstant
    ) -> StateTransitionPlan {
        var next = current
        var events: [AgentEvent] = []
        var tracker = turnTracker
        var turnClosedWithCompletion = false

        func bump() {
            next.revision += 1
            next.observedAt = instant
        }

        func transitionLifecycle(to phase: LifecyclePhase, authority: StateAuthority) {
            let previous = next.lifecycle
            guard previous != phase else { return }
            let hadOpenTurn = tracker.isActive
            // Capture WHO opened the turn BEFORE observe() closes it.
            let openedByPrompt = tracker.activeTurn?.openedByPrompt ?? false
            next.lifecycle = phase
            next.authority = authority
            events.append(.stateChanged(from: previous, to: phase, authority: authority))

            if tracker.observe(from: previous, to: phase, at: instant) != nil {
                events.append(.turnCompleted(hadPrompt: openedByPrompt))
                if case .idle = phase, hadOpenTurn {
                    turnClosedWithCompletion = true
                }
            }
        }

        switch trigger {
        case .surfaceCreated:
            bump()

        case let .processLaunched(pid, pgid):
            next.process = .running(pid: pid, processGroupID: pgid)
            // Lifecycle stays `starting` until real evidence arrives.
            bump()

        case let .processExited(exitCode, signal, userInitiated):
            next.process = .exited(exitCode: exitCode, signal: signal, userInitiated: userInitiated)
            // Cause event precedes its effects (stateChanged/turnCompleted).
            events.append(.processExited(exitCode: exitCode, signal: signal, userInitiated: userInitiated))

            if let code = exitCode, code == 0, signal == nil {
                if userInitiated {
                    transitionLifecycle(to: .stopped(.userRequested), authority: .process)
                } else {
                    // Capture BEFORE transitionLifecycle observes/closes the turn.
                    let hadOpenTurn = tracker.isActive
                    transitionLifecycle(to: .stopped(.completed), authority: .process)
                    // Completion attention only when THIS edge closed an open
                    // turn and the operator was not watching (§3.5).
                    turnClosedWithCompletion =
                        hadOpenTurn && !tracker.isActive && !agentVisibleAndActive
                }
            } else {
                transitionLifecycle(
                    to: .failed(FailureDescriptor(exitCode: exitCode, signal: signal)),
                    authority: .process
                )
            }
            bump()

        case let .launchFailed(descriptor):
            next.process = .launchFailed(errorDescriptor: descriptor)
            transitionLifecycle(to: .failed(FailureDescriptor(reason: descriptor)), authority: .process)
            bump()

        case let .stopRequested(mode):
            switch mode {
            case .interrupt:
                // Interrupt does not change lifecycle — process stays alive.
                events.append(.stopCommanded(mode: .interrupt))
            case .gracefulStop:
                // §3.5: only a live process can still deliver an exit. When
                // the process is already terminal there is nothing to stop —
                // forcing `.stopping` would wedge the agent waiting on an
                // exit that already fired.
                switch next.process {
                case .exited, .launchFailed:
                    break
                default:
                    transitionLifecycle(to: .stopping, authority: next.authority)
                }
                events.append(.stopCommanded(mode: .gracefulStop))
            case .closeView:
                // No signal, no lifecycle change — presentation concern only.
                events.append(.stopCommanded(mode: .closeView))
            }
            bump()

        case let .restartRequested(generation):
            events.append(.restartInitiated(generation: generation))
            // Restart: everything about the old run is gone; no turn
            // survives — a prompt-opened turn must not outlive it.
            tracker.reset()
            next.process = .launching
            transitionLifecycle(to: .starting, authority: .unknown)
            // transitionLifecycle no-ops when lifecycle is already .starting,
            // so the dead run's authority would otherwise survive the restart.
            if next.authority != .unknown {
                next.authority = .unknown
            }
            bump()

        case .authorityLost:
            if next.authority > .unknown {
                events.append(.authorityLost(previous: next.authority))
            }
            next.authority = .unknown
            // §3.5: the lease genuinely is unknown, but a terminal process
            // already reported its final outcome — demoting lifecycle to
            // `.unknown` would destroy that known result. Reset lifecycle
            // only while the process could still report.
            switch next.process {
            case .exited, .launchFailed:
                break
            default:
                transitionLifecycle(to: .unknown, authority: .unknown)
            }
            bump()
        }

        return StateTransitionPlan(
            newState: next,
            events: events,
            turnClosedWithCompletion: turnClosedWithCompletion,
            turnTracker: tracker
        )
    }

    /// Applies adopted evidence (screen/integration lifecycle) to the lifecycle.
    public static func plan(
        current: AgentState,
        adopting lifecycle: LifecyclePhase,
        authority: StateAuthority,
        turnTracker: TurnTracker,
        agentVisibleAndActive _: Bool,
        at instant: MonotonicInstant
    ) -> StateTransitionPlan {
        var next = current
        var events: [AgentEvent] = []
        var tracker = turnTracker
        var turnClosedWithCompletion = false

        let previous = next.lifecycle
        let lifecycleChanged = previous != lifecycle
        let authorityChanged = next.authority != authority
        if lifecycleChanged {
            next.lifecycle = lifecycle
        }
        if authorityChanged {
            next.authority = authority
        }
        // State change is emitted when EITHER axis moved; from/to reflect
        // the actual lifecycle movement (equal when only authority changed).
        if lifecycleChanged || authorityChanged {
            events.append(.stateChanged(from: previous, to: next.lifecycle, authority: next.authority))
            next.revision += 1
        }

        if lifecycleChanged {
            // Capture the open-turn fact BEFORE observe() closes it. The
            // tracker is observed only on real lifecycle transitions.
            let openedByPrompt = tracker.activeTurn?.openedByPrompt ?? false
            if tracker.observe(from: previous, to: lifecycle, at: instant) != nil {
                events.append(.turnCompleted(hadPrompt: openedByPrompt))
                if case .idle = lifecycle {
                    turnClosedWithCompletion = true
                }
            }
        }

        next.observedAt = instant

        return StateTransitionPlan(
            newState: next,
            events: events,
            turnClosedWithCompletion: turnClosedWithCompletion,
            turnTracker: tracker
        )
    }

    /// Opens the turn for a delivered prompt (§3.5 "Prompt accepted").
    public static func openingTurnForPrompt(
        commandID: CommandID,
        tracker: inout TurnTracker,
        at instant: MonotonicInstant
    ) -> Bool {
        tracker.promptDelivered(commandID: commandID, at: instant)
    }
}

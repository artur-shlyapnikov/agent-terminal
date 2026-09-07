import Foundation

// AttentionPolicy (architecture §3.4).
//
// Rules:
// - entering waitingForInput creates inputRequired;
// - unexpected non-zero exit creates failure;
// - an open turn's working → idle creates completionUnread (when the agent
//   was not visible and active);
// - completionUnread clears after 500 ms of visibility in the active app
//   (`markSeen` — the FocusCoordinator owns the 500 ms timer);
// - inputRequired clears only after leaving waitingForInput;
// - failure clears via explicit acknowledge, restart, or a successful relaunch.
//
// Priority: inputRequired > failure > completionUnread.

public struct AttentionPolicy {
    public static let visibilityClearInterval: Duration = .milliseconds(500)

    public init() {}

    /// Computes the new attention from a lifecycle transition.
    public static func update(
        current: AttentionState,
        from previous: LifecyclePhase,
        to next: LifecyclePhase,
        turnClosedWithCompletion: Bool,
        agentVisibleAndActive: Bool,
        at instant: MonotonicInstant,
        eventID: RuntimeEventID
    ) -> AttentionState {
        // Leaving waitingForInput clears inputRequired ONLY; a standing
        // .failure persists until explicit acknowledge/restart/relaunch.
        var result = current
        if isWaiting(previous), !isWaiting(next) {
            if case .inputRequired = result {
                result = .none
            }
        }

        switch next {
        case let .waitingForInput(descriptor):
            if case .inputRequired = result {
                // Still waiting; keep the original `since`.
            } else if result.rank < AttentionRank.failure {
                // A standing .failure persists through the waiting episode:
                // only explicit acknowledge/restart/relaunch clears it (§3.4).
                result = .inputRequired(since: instant, requestID: descriptor.summary)
            }

        case .failed:
            result = .failure(since: instant, eventID: eventID)

        default:
            break
        }

        // Open-turn working → idle raises completionUnread unless the operator
        // was watching. Never overrides inputRequired or failure.
        if turnClosedWithCompletion, next.isIdleLike, !agentVisibleAndActive {
            if result.rank < AttentionRank.completionUnread {
                result = .completionUnread(since: instant, eventID: eventID)
            }
        }

        return result
    }

    static func isWaiting(_ phase: LifecyclePhase) -> Bool {
        if case .waitingForInput = phase {
            return true
        }
        return false
    }

    // MARK: Clearing

    /// `markSeen` after ≥500 ms continuous visibility: clears completionUnread ONLY.
    public static func clearCompletionOnSeen(_ current: AttentionState) -> AttentionState {
        if case .completionUnread = current {
            return .none
        }
        return current
    }

    /// Explicit user acknowledge clears failure only.
    public static func acknowledgeFailure(_ current: AttentionState) -> AttentionState {
        if case .failure = current {
            return .none
        }
        return current
    }

    /// Restart or a successful relaunch clears failure (and never leaves a
    /// stale inputRequired behind).
    public static func clearForRelaunch(_ current: AttentionState) -> AttentionState {
        switch current {
        case .failure, .inputRequired:
            .none
        default:
            current
        }
    }
}

public enum AttentionRank {
    public static let none = 0
    public static let completionUnread = 1
    public static let failure = 2
    public static let inputRequired = 3
}

extension LifecyclePhase {
    /// True for the phase that represents "the agent finished something".
    var isIdleLike: Bool {
        if case .idle = self {
            return true
        }
        return false
    }
}

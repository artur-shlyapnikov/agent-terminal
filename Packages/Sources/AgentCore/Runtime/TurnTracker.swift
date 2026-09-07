import Foundation

/// TurnTracker (architecture §3.5).
///
/// A turn opens when:
/// - a prompt was delivered;
/// - or lifecycle moved idle → working without a prompt;
/// - or a full integration reported the start of an agent operation.
///
/// A turn closes when:
/// - working → idle;
/// - the process exited successfully;
/// - an integration explicitly reported completion.
public struct TurnTracker: Equatable, Sendable {
    public private(set) var activeTurn: ActiveTurn?

    public init() {}

    public var isActive: Bool {
        activeTurn != nil
    }

    // MARK: Open

    @discardableResult
    public mutating func promptDelivered(commandID: CommandID, at instant: MonotonicInstant) -> Bool {
        guard activeTurn == nil else { return false }
        activeTurn = ActiveTurn(openedAt: instant, reason: .promptDelivered(commandID))
        return true
    }

    @discardableResult
    public mutating func workStarted(at instant: MonotonicInstant) -> Bool {
        guard activeTurn == nil else { return false }
        activeTurn = ActiveTurn(openedAt: instant, reason: .spontaneousWork)
        return true
    }

    @discardableResult
    public mutating func integrationOperationStarted(at instant: MonotonicInstant) -> Bool {
        guard activeTurn == nil else { return false }
        activeTurn = ActiveTurn(openedAt: instant, reason: .integrationOperation)
        return true
    }

    // MARK: Close

    /// Applies a lifecycle transition. Returns the close reason when an active
    /// turn was closed by it; nil when nothing closed (including the
    /// starting→idle case, where no turn was ever open).
    @discardableResult
    public mutating func observe(
        from previous: LifecyclePhase,
        to next: LifecyclePhase,
        at instant: MonotonicInstant
    ) -> TurnCloseReason? {
        switch (previous, next) {
        case (_, .idle), (_, .stopped), (_, .failed):
            // working → idle, a process exit, or failure ends the turn.
            guard activeTurn != nil else { return nil }
            let reason: TurnCloseReason = switch next {
            case .idle: .becameIdle
            case .stopped(.completed): .processExitedSuccessfully
            case .stopped: .becameIdle
            default: .becameIdle
            }
            activeTurn = nil
            return reason
        case (_, .working):
            // idle → working without a prompt opens a turn.
            workStarted(at: instant)
            return nil
        default:
            return nil
        }
    }

    /// Integration explicitly reported completion.
    @discardableResult
    public mutating func integrationCompleted() -> Bool {
        guard activeTurn != nil else { return false }
        activeTurn = nil
        return true
    }

    /// Restart: everything about the old run is gone; no turn survives.
    public mutating func reset() {
        activeTurn = nil
    }
}

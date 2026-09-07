import Foundation

// Domain events (architecture §3.3–§3.5). Events carry no prompt text, no
// terminal output and no environment — they are safe to persist and export.

public enum AgentEvent: Equatable, Sendable {
    case stateChanged(from: LifecyclePhase, to: LifecyclePhase, authority: StateAuthority)
    case turnStarted(reason: TurnOpenReason)
    case turnCompleted(hadPrompt: Bool)
    case attentionRaised(kind: AttentionKind)
    case attentionCleared(kind: AttentionKind)
    case promptDelivered(commandID: CommandID)
    case promptDeliveryUnconfirmed(commandID: CommandID)
    case queuedPromptCancelled
    case queuedPromptDeliveryFailed(commandID: CommandID)
    case processExited(exitCode: Int32?, signal: Int32?, userInitiated: Bool)
    case sessionIdentityCaptured(SessionReference)
    case integrationSequenceGap(expected: UInt64, received: UInt64)
    case authorityLost(previous: StateAuthority)
    case stopCommanded(mode: StopMode)
    case restartInitiated(generation: SurfaceGeneration)
    case resumeAttempted(SessionReference)

    public enum AttentionKind: Equatable, Sendable {
        case completionUnread
        case inputRequired
        case failure

        public var rank: Int {
            switch self {
            case .completionUnread: 1
            case .failure: 2
            case .inputRequired: 3
            }
        }
    }
}

/// Process-global monotonic counter backing `TimelineEvent.sequence`. A
/// lock-protected class — no new dependencies, safe from any isolation
/// domain. Sequences are never reused within a process lifetime.
private final class TimelineEventSequence: @unchecked Sendable {
    private static let shared = TimelineEventSequence()

    private let lock = NSLock()
    private var next: UInt64 = 1

    static func next() -> UInt64 {
        shared.advance()
    }

    private func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = next
        next &+= 1
        return value
    }
}

/// A timestamped event as it enters the timeline.
public struct TimelineEvent: Equatable, Sendable {
    public let id: RuntimeEventID
    public let agentID: AgentID
    public let at: MonotonicInstant
    public let event: AgentEvent
    /// Process-global monotonic sequence assigned at construction. Gives the
    /// persistence layer an orderable identity (§3.14 incremental append):
    /// the store records the highest sequence it has persisted per agent and
    /// inserts only the strictly-newer tail of each commit window, instead of
    /// re-inserting the whole ≤1000-event window on every commit.
    ///
    /// Per-process by design: runtime timelines are never restored from disk
    /// (RestoreCoordinator does not repopulate them), so a fresh counter plus
    /// a fresh store-side watermark restart consistently on every launch.
    public let sequence: UInt64

    public init(agentID: AgentID, at: MonotonicInstant, event: AgentEvent) {
        id = RuntimeEventID()
        self.agentID = agentID
        self.at = at
        self.event = event
        sequence = TimelineEventSequence.next()
    }
}

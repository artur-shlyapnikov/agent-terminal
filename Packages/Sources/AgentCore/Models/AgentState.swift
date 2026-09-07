import Foundation

// Orthogonal agent state (architecture §3.4). Process, lifecycle, attention and
// authority are independent axes; only AgentRuntime mutates AgentState (§3.5).

/// Objective state of the underlying OS process.
public enum ProcessPhase: Equatable, Sendable {
    case notStarted
    case launching
    case running(pid: Int32?, processGroupID: Int32?)
    case exiting
    case exited(exitCode: Int32?, signal: Int32?, userInitiated: Bool)
    case launchFailed(errorDescriptor: String)
}

public enum StopReason: Equatable, Sendable {
    /// Exit 0 after a user-initiated stop (`stopping`).
    case userRequested
    /// Exit 0 without a user-initiated stop; the agent finished on its own.
    case completed
}

public struct FailureDescriptor: Equatable, Sendable {
    public var exitCode: Int32?
    public var signal: Int32?
    public var reason: String?

    public init(exitCode: Int32? = nil, signal: Int32? = nil, reason: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
        self.reason = reason
    }
}

/// Operator-facing lifecycle. `done` deliberately does not exist as a durable
/// phase: one turn completing is an event, while the live agent becomes `idle`.
public enum LifecyclePhase: Equatable, Sendable {
    case unknown
    case starting
    case idle
    case working
    indirect case waitingForInput(InputRequestDescriptor)
    case stopping
    case stopped(StopReason)
    case failed(FailureDescriptor)

    public var isTerminal: Bool {
        if case .stopped = self {
            return true
        }
        return false
    }

    /// Coarse bucket used by the detection cadence table (§3.7).
    public var isActive: Bool {
        switch self {
        case .working, .starting, .unknown: true
        default: false
        }
    }
}

/// Presentation/operator attention — never part of lifecycle semantics (§3.4).
public enum AttentionState: Equatable, Sendable {
    case none
    case completionUnread(since: MonotonicInstant, eventID: RuntimeEventID)
    case inputRequired(since: MonotonicInstant, requestID: String?)
    case failure(since: MonotonicInstant, eventID: RuntimeEventID)

    /// Priority order for sidebar grouping: inputRequired > failure > completionUnread.
    public var rank: Int {
        switch self {
        case .none: 0
        case .completionUnread: 1
        case .failure: 2
        case .inputRequired: 3
        }
    }

    public var since: MonotonicInstant? {
        switch self {
        case .none: nil
        case let .completionUnread(since, _): since
        case let .inputRequired(since, _): since
        case let .failure(since, _): since
        }
    }
}

/// Evidence authority precedence: integration > screen > process > unknown (§3.6).
public enum StateAuthority: Equatable, Sendable {
    case unknown
    case process
    case screen
    case integration

    /// Higher wins. Used by the authority resolver.
    public var precedence: Int {
        switch self {
        case .unknown: 0
        case .process: 1
        case .screen: 2
        case .integration: 3
        }
    }
}

extension StateAuthority: Comparable {
    public static func < (lhs: StateAuthority, rhs: StateAuthority) -> Bool {
        lhs.precedence < rhs.precedence
    }
}

/// The full orthogonal state of one agent session.
public struct AgentState: Equatable, Sendable {
    public var process: ProcessPhase
    public var lifecycle: LifecyclePhase
    public var attention: AttentionState
    public var authority: StateAuthority
    /// Monotonic revision; every mutation mints the next value.
    public var revision: UInt64
    /// Local monotonic instant of the last accepted observation that shaped this state.
    public var observedAt: MonotonicInstant

    public init(
        process: ProcessPhase = .notStarted,
        lifecycle: LifecyclePhase = .unknown,
        attention: AttentionState = .none,
        authority: StateAuthority = .unknown,
        revision: UInt64 = 0,
        observedAt: MonotonicInstant
    ) {
        self.process = process
        self.lifecycle = lifecycle
        self.attention = attention
        self.authority = authority
        self.revision = revision
        self.observedAt = observedAt
    }

    public static func fresh(at instant: MonotonicInstant) -> AgentState {
        AgentState(
            process: .notStarted,
            lifecycle: .unknown,
            attention: .none,
            authority: .unknown,
            revision: 0,
            observedAt: instant
        )
    }

    public func with(revision: UInt64, observedAt: MonotonicInstant) -> AgentState {
        var copy = self
        copy.revision = revision
        copy.observedAt = observedAt
        return copy
    }
}

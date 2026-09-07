import Foundation

// AgentSession — the semantic entity (architecture §3.3).
//
// Invariants enforced by construction/encapsulation:
// - an agent has at most one live terminal (`terminalID` is a single optional);
// - an agent may have no visible pane at all (terminal parked);
// - closing a pane never changes lifecycle (parking is presentation-only);
// - session identity is distinct from terminal identity;
// - restart mints a new SurfaceGeneration (owned by AgentRuntime).

public struct AgentSession: Equatable, Sendable {
    public let id: AgentID
    public let workspaceID: WorkspaceID
    public private(set) var terminalID: TerminalID?
    public let kind: AgentKind
    public var displayName: String
    public var taskSummary: String?
    public var cwd: String
    public var launchDescriptor: LaunchDescriptor
    public var resumePolicy: ResumePolicy
    public var sessionReference: SessionReference?
    public var state: AgentState
    /// Generation of the live surface; restart mints a successor (§3.3).
    public var surfaceGeneration: SurfaceGeneration
    /// Last known output revision of the live terminal.
    public var outputRevision: UInt64
    public private(set) var queuedPrompt: QueuedPrompt?
    public private(set) var turn: ActiveTurn?
    public var createdAt: MonotonicInstant
    public var lastActivityAt: MonotonicInstant

    public init(
        id: AgentID = AgentID(),
        workspaceID: WorkspaceID,
        terminalID: TerminalID? = nil,
        kind: AgentKind,
        displayName: String,
        taskSummary: String? = nil,
        cwd: String,
        launchDescriptor: LaunchDescriptor,
        resumePolicy: ResumePolicy = .manual,
        sessionReference: SessionReference? = nil,
        state: AgentState,
        surfaceGeneration: SurfaceGeneration = .initial,
        createdAt: MonotonicInstant,
        lastActivityAt: MonotonicInstant
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.kind = kind
        self.displayName = displayName
        self.taskSummary = taskSummary
        self.cwd = cwd
        self.launchDescriptor = launchDescriptor
        self.resumePolicy = resumePolicy
        self.sessionReference = sessionReference
        self.state = state
        self.surfaceGeneration = surfaceGeneration
        outputRevision = 0
        queuedPrompt = nil
        turn = nil
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }

    // MARK: Encapsulated mutations (runtime-only semantics)

    mutating func attach(terminal id: TerminalID) {
        precondition(terminalID == nil || terminalID == id, "an agent owns at most one live terminal")
        terminalID = id
    }

    mutating func detachTerminal() {
        // Closing a pane parks the terminal; lifecycle is untouched here.
        terminalID = nil
    }

    mutating func setQueuedPrompt(_ prompt: QueuedPrompt?) {
        queuedPrompt = prompt
    }

    mutating func setTurn(_ turn: ActiveTurn?) {
        self.turn = turn
    }
}

/// The single queued prompt (§3.11): at most one per agent, never persisted
/// across app runs, replaced only explicitly.
public struct QueuedPrompt: Equatable, Sendable {
    public let commandID: CommandID
    public let text: String
    public let queuedAt: MonotonicInstant

    public init(commandID: CommandID, text: String, queuedAt: MonotonicInstant) {
        self.commandID = commandID
        self.text = text
        self.queuedAt = queuedAt
    }
}

public enum TurnOpenReason: Equatable, Sendable {
    /// A prompt was actually delivered to the terminal.
    case promptDelivered(CommandID)
    /// Lifecycle moved idle → working without a prompt.
    case spontaneousWork
    /// A full integration reported the start of an agent operation.
    case integrationOperation
}

public enum TurnCloseReason: Equatable, Sendable {
    case becameIdle
    case processExitedSuccessfully
    case integrationCompletion
}

public struct ActiveTurn: Equatable, Sendable {
    public let openedAt: MonotonicInstant
    public let reason: TurnOpenReason

    public var openedByPrompt: Bool {
        if case .promptDelivered = reason {
            return true
        }
        return false
    }

    public init(openedAt: MonotonicInstant, reason: TurnOpenReason) {
        self.openedAt = openedAt
        self.reason = reason
    }
}

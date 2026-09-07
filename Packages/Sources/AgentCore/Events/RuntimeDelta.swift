import Foundation

// Incremental updates for UI and control-plane subscribers (§3.2: the UI
// receives per-agent deltas, never a full model copy).

public struct AgentSummary: Equatable, Sendable {
    public let id: AgentID
    public let workspaceID: WorkspaceID
    public let kind: AgentKind
    public let displayName: String
    public let taskSummary: String?
    public let state: AgentState
    public let hasQueuedPrompt: Bool
    public let turnActive: Bool
    public let hasSessionReference: Bool

    public init(session: AgentSession) {
        id = session.id
        workspaceID = session.workspaceID
        kind = session.kind
        displayName = session.displayName
        taskSummary = session.taskSummary
        state = session.state
        hasQueuedPrompt = session.queuedPrompt != nil
        turnActive = session.turn != nil
        hasSessionReference = session.sessionReference != nil
    }
}

/// Read-only snapshot for UI/API consumers.
public struct RuntimeProjection: Equatable, Sendable {
    public let agents: [AgentSummary]
    public let generatedAt: MonotonicInstant

    public init(agents: [AgentSummary], generatedAt: MonotonicInstant) {
        self.agents = agents
        self.generatedAt = generatedAt
    }
}

public enum RuntimeDelta: Equatable, Sendable {
    case agentChanged(AgentSummary)
    case agentRemoved(AgentID)
    case projectionReplaced(RuntimeProjection)
}

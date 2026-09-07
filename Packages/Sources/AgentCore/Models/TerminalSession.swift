import Foundation

// Terminal session metadata (architecture §3.3/§4.2) — no native pointers
// cross this boundary. A generic shell can own a terminal without an
// AgentSession; parked vs mounted is presentation state, never lifecycle.

public struct TerminalSession: Equatable, Sendable {
    public enum Presentation: Equatable, Sendable {
        case parked
        case mounted(PaneID)
    }

    public let id: TerminalID
    public let workspaceID: WorkspaceID
    public var agentID: AgentID?
    public var cwd: String
    public var surfaceGeneration: SurfaceGeneration
    public var processPhase: ProcessPhase
    /// Wall-clock instant captured when `processPhase` became `.exited`;
    /// nil until then. Persisted as `terminals.last_exit_at` so re-saves of
    /// an already-exited session do not re-stamp the timestamp (§3.14).
    public var exitAt: Double?
    public var processGroupID: Int32?
    public var outputRevision: UInt64
    public var presentation: Presentation

    public init(
        id: TerminalID = TerminalID(),
        workspaceID: WorkspaceID,
        agentID: AgentID? = nil,
        cwd: String,
        surfaceGeneration: SurfaceGeneration = .initial,
        processPhase: ProcessPhase = .notStarted,
        exitAt: Double? = nil,
        processGroupID: Int32? = nil,
        outputRevision: UInt64 = 0,
        presentation: Presentation = .parked
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.agentID = agentID
        self.cwd = cwd
        self.surfaceGeneration = surfaceGeneration
        self.exitAt = exitAt
        self.processPhase = processPhase
        self.processGroupID = processGroupID
        self.outputRevision = outputRevision
        self.presentation = presentation
    }
}

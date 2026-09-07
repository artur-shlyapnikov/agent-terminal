import Foundation

// Persistence port (architecture §3.14 commit ordering). The runtime assigns
// the revision, emits the delta immediately, and hands the durable record to
// the store without ever blocking lifecycle detection on disk I/O.

public struct StateCommit: Sendable {
    public let agentID: AgentID
    public let state: AgentState
    public let events: [TimelineEvent]
    public let sessionReference: SessionReference?
    /// Runtime-owned durable identity (§3.14): everything the store needs
    /// to fabricate the agent row on FIRST sight — id, workspace, kind,
    /// descriptor, resume policy, timestamps. Callers no longer pre-register
    /// a DB row before commits can land. `nil` only for legacy/test commits
    /// that never carried a session.
    public let session: AgentSession?

    public init(
        agentID: AgentID,
        state: AgentState,
        events: [TimelineEvent],
        sessionReference: SessionReference?,
        session: AgentSession? = nil
    ) {
        self.agentID = agentID
        self.state = state
        self.events = events
        self.sessionReference = sessionReference
        self.session = session
    }
}

public protocol StatePersisting: Sendable {
    /// Applies only commits whose revision is not older than what is stored
    /// (§3.14 upsert rule). Failures degrade persistence; they never mutate
    /// runtime state.
    func commit(_ commit: StateCommit) async
}

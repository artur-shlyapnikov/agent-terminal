import Foundation

// Workspace domain model (architecture §3.3). A workspace is the user's
// project — not a container of tabs.

public struct Workspace: Equatable, Sendable {
    public let id: WorkspaceID
    public var name: String
    public var rootPath: String
    public var agentOrder: [AgentID]
    public var layout: LayoutTree
    public var selectedAgentID: AgentID?
    public var createdAt: MonotonicInstant
    public var updatedAt: MonotonicInstant

    public init(
        id: WorkspaceID = WorkspaceID(),
        name: String,
        rootPath: String,
        agentOrder: [AgentID] = [],
        layout: LayoutTree = .empty,
        selectedAgentID: AgentID? = nil,
        createdAt: MonotonicInstant,
        updatedAt: MonotonicInstant
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.agentOrder = agentOrder
        self.layout = layout
        self.selectedAgentID = selectedAgentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

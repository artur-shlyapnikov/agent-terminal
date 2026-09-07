import Foundation

// Built-in adapter registry (architecture §3.10).

public struct AgentCatalog: Sendable {
    private var adaptersByID: [String: any AgentAdapter] = [:]
    private var adaptersByKind: [AgentKind: String] = [:]

    public init(adapters: [any AgentAdapter]) {
        for adapter in adapters {
            adaptersByID[adapter.id] = adapter
            if let kind = adapter.bundledAgentKind {
                adaptersByKind[kind] = adapter.id
            }
        }
    }

    /// The four built-in adapters (§3.10 table).
    public static func standard() -> AgentCatalog {
        AgentCatalog(adapters: [
            ClaudeCodeAdapter(),
            CodexAdapter(),
            OpenCodeAdapter(),
            GenericShellAdapter(),
        ])
    }

    public func adapter(for kind: AgentKind) -> (any AgentAdapter)? {
        guard let id = adaptersByKind[kind] else { return nil }
        return adaptersByID[id]
    }

    public func adapter(id: String) -> (any AgentAdapter)? {
        adaptersByID[id]
    }

    public var allAdapters: [any AgentAdapter] {
        adaptersByID.values.sorted { $0.id < $1.id }
    }
}

/// Adapters declare which AgentKind they serve; used by the catalog index.
public protocol AgentKindAdvertising: AgentAdapter {
    static var agentKind: AgentKind { get }
}

public extension AgentKindAdvertising {
    var bundledAgentKind: AgentKind? {
        Self.agentKind
    }
}

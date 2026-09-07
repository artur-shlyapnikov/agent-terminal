import Foundation

// Agent kinds (architecture §3.10 built-in adapters table).

public enum AgentKind: String, Equatable, Sendable, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case genericShell = "generic-shell"

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .genericShell: "Shell"
        }
    }
}

/// Resume policy persisted per agent (§3.15 quit-and-resume-later).
public enum ResumePolicy: String, Equatable, Sendable, Codable {
    /// Adapter has no session identity; restart means a fresh session.
    case none
    /// Session reference exists but resume is only ever user-initiated.
    case manual
    /// Resume automatically after a clean quit when a valid reference exists.
    case automatic
}

/// Opaque adapter-owned session reference. The domain never inspects the
/// payload — it is captured and replayed verbatim by the adapter that minted it.
public struct SessionReference: Equatable, Sendable, Codable {
    public let agentKind: AgentKind
    public let opaquePayload: String
    public let capturedAtRevision: UInt64

    public init(agentKind: AgentKind, opaquePayload: String, capturedAtRevision: UInt64 = 0) {
        self.agentKind = agentKind
        self.opaquePayload = opaquePayload
        self.capturedAtRevision = capturedAtRevision
    }
}

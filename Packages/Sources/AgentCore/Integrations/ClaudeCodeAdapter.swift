import Foundation

// Claude Code adapter (architecture §3.10):
// lifecycle authority = screen manifest; session identity = hook;
// resume = `claude --resume <id>`.

public struct ClaudeCodeAdapter: AgentKindAdvertising, Sendable {
    public static let staticID = "claude-code"
    public static let agentKind: AgentKind = .claudeCode

    public init() {}

    public var id: String {
        Self.staticID
    }

    public var displayName: String {
        "Claude Code"
    }

    public var capabilities: AgentIntegrationCapability {
        AgentIntegrationCapability(
            sessionIdentity: true,
            // The hook reports identity only — screen stays the authority.
            lifecycle: .none,
            screenFallback: true
        )
    }

    public var executableCandidates: [String] {
        ["claude"]
    }

    public var bundledManifestName: String? {
        "claude-code"
    }

    public func makeLaunchDescriptor(request: AgentLaunchRequest) throws -> LaunchDescriptor {
        LaunchDescriptor(
            agentKind: .claudeCode,
            program: "claude",
            arguments: [],
            workingDirectory: request.workingDirectory
        )
    }

    public func buildLaunchSpec(descriptor: LaunchDescriptor) -> LaunchSpec {
        LaunchSpec(
            argv: [descriptor.program] + descriptor.arguments,
            environment: descriptor.environment,
            workingDirectory: descriptor.workingDirectory
        )
    }

    public func buildResumeSpec(sessionReference: SessionReference) -> ResumeSpec? {
        guard sessionReference.agentKind == .claudeCode else { return nil }
        return ResumeSpec(
            argv: ["claude", "--resume", sessionReference.opaquePayload],
            workingDirectory: ""
        )
    }

    public func integrationInstallPlan() -> IntegrationInstallPlan {
        IntegrationInstallPlan(
            adapterID: id,
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: "~/.claude/settings.json",
                    format: .json,
                    entries: [
                        ManagedConfigEntry(
                            keyPath: ["hooks"],
                            valueJSON: #"{"agentterminal-marker":"\#(IntegrationInstallPlan.namespaceMarker)"}"#,
                            marker: IntegrationInstallPlan.namespaceMarker
                        ),
                    ]
                ),
            ]
        )
    }
}

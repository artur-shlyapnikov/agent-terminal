import Foundation

// Codex adapter (architecture §3.10):
// lifecycle authority = screen manifest; session identity = hook/notification
// integration; resume = `codex resume <id>`.

public struct CodexAdapter: AgentKindAdvertising, Sendable {
    public static let staticID = "codex"
    public static let agentKind: AgentKind = .codex

    public init() {}

    public var id: String {
        Self.staticID
    }

    public var displayName: String {
        "Codex"
    }

    public var capabilities: AgentIntegrationCapability {
        AgentIntegrationCapability(
            sessionIdentity: true,
            lifecycle: .none,
            screenFallback: true
        )
    }

    public var executableCandidates: [String] {
        ["codex"]
    }

    public var bundledManifestName: String? {
        "codex"
    }

    public func makeLaunchDescriptor(request: AgentLaunchRequest) throws -> LaunchDescriptor {
        LaunchDescriptor(
            agentKind: .codex,
            program: "codex",
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
        guard sessionReference.agentKind == .codex else { return nil }
        return ResumeSpec(
            argv: ["codex", "resume", sessionReference.opaquePayload],
            workingDirectory: ""
        )
    }

    public func integrationInstallPlan() -> IntegrationInstallPlan {
        IntegrationInstallPlan(
            adapterID: id,
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: "~/.codex/config.toml",
                    format: .toml,
                    entries: [
                        ManagedConfigEntry(
                            keyPath: ["agentterminal"],
                            valueJSON: #"{ "marker": "\#(IntegrationInstallPlan.namespaceMarker)" }"#,
                            marker: IntegrationInstallPlan.namespaceMarker
                        ),
                    ]
                ),
            ]
        )
    }
}

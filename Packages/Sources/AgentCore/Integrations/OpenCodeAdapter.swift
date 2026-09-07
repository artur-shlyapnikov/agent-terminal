import Foundation

// OpenCode adapter (architecture §3.10):
// full plugin lifecycle authority with screen fallback; session identity =
// plugin; resume = `opencode --session <id>`.

public struct OpenCodeAdapter: AgentKindAdvertising, Sendable {
    public static let staticID = "opencode"
    public static let agentKind: AgentKind = .openCode

    public init() {}

    public var id: String {
        Self.staticID
    }

    public var displayName: String {
        "OpenCode"
    }

    public var capabilities: AgentIntegrationCapability {
        AgentIntegrationCapability(
            sessionIdentity: true,
            // The plugin reports full lifecycle; authority holds until explicit
            // release or process generation end (§3.6 leasePolicy).
            lifecycle: .complete(.explicitRelease),
            screenFallback: true
        )
    }

    public var executableCandidates: [String] {
        ["opencode"]
    }

    public var bundledManifestName: String? {
        "opencode"
    }

    public func makeLaunchDescriptor(request: AgentLaunchRequest) throws -> LaunchDescriptor {
        LaunchDescriptor(
            agentKind: .openCode,
            program: "opencode",
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
        guard sessionReference.agentKind == .openCode else { return nil }
        return ResumeSpec(
            argv: ["opencode", "--session", sessionReference.opaquePayload],
            workingDirectory: ""
        )
    }

    public func integrationInstallPlan() -> IntegrationInstallPlan {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pluginDir = "/Library/Application Support/AgentTerminal/integrations/opencode/lifecycle-plugin.js"
        let valueJSON = #"{ "path": "\#(home + pluginDir)", "marker": "\#(IntegrationInstallPlan.namespaceMarker)" }"#
        return IntegrationInstallPlan(
            adapterID: id,
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: "~/.config/opencode/config.json",
                    format: .json,
                    entries: [
                        ManagedConfigEntry(
                            keyPath: ["plugins", "agentterminal"],
                            // Config consumers do not expand '~' in values,
                            // so the plugin path must be absolute at plan-build
                            // time (JSONSerialization re-encodes the string).
                            valueJSON: valueJSON,
                            marker: IntegrationInstallPlan.namespaceMarker
                        ),
                    ]
                ),
            ]
        )
    }
}

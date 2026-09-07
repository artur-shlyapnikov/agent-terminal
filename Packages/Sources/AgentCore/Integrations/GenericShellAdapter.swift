import Foundation

// Generic Shell adapter (architecture §3.10):
// process-only evidence, no session identity, no resume, no semantic
// automation — queue-until-idle is deliberately unavailable.

public struct GenericShellAdapter: AgentKindAdvertising, Sendable {
    public static let staticID = "generic-shell"
    public static let agentKind: AgentKind = .genericShell

    public init() {}

    public var id: String {
        Self.staticID
    }

    public var displayName: String {
        "Shell"
    }

    public var capabilities: AgentIntegrationCapability {
        AgentIntegrationCapability(
            sessionIdentity: false,
            lifecycle: .none,
            screenFallback: false
        )
    }

    public var executableCandidates: [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"]
        var candidates = ["/bin/zsh", "/bin/bash"]
        if let shell {
            candidates.insert(shell, at: 0)
        }
        return candidates
    }

    public var bundledManifestName: String? {
        nil
    }

    public func makeLaunchDescriptor(request: AgentLaunchRequest) throws -> LaunchDescriptor {
        // detectInstallation validates the candidates; mirror that defense
        // here so a stale or bogus SHELL cannot produce an unlaunchable
        // descriptor (§3.10 launches the shell directly).
        let program = executableCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/bin/bash"
        return LaunchDescriptor(
            agentKind: .genericShell,
            program: program,
            arguments: ["-l"],
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

    public func buildResumeSpec(sessionReference _: SessionReference) -> ResumeSpec? {
        // A new shell is started manually; there is nothing to resume (§3.10).
        nil
    }

    public func integrationInstallPlan() -> IntegrationInstallPlan {
        .empty(adapterID: id)
    }
}

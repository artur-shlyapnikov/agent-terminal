import Foundation

// Persistable, non-secret launch profile (architecture §3.3/§3.9).
//
// The descriptor contains only adapter-owned, non-secret options. Raw user
// environment and arbitrary shell strings are deliberately excluded; the real
// argv/env travel through the one-shot launch ticket instead of the database.

public struct LaunchDescriptor: Equatable, Sendable, Codable {
    public let agentKind: AgentKind
    /// Executable name resolved from PATH, or absolute path.
    public let program: String
    public let arguments: [String]
    public let workingDirectory: String
    /// Adapter-owned, non-secret environment additions only.
    public let environment: [String: String]

    public init(
        agentKind: AgentKind,
        program: String,
        arguments: [String] = [],
        workingDirectory: String,
        environment: [String: String] = [:]
    ) {
        self.agentKind = agentKind
        self.program = program
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// Fully resolved launch material handed to the terminal layer, which writes
/// the launch ticket consumed by `AgentLauncher` (§3.9).
public struct LaunchSpec: Equatable, Sendable, Codable {
    public var argv: [String]
    public var environment: [String: String]
    public var workingDirectory: String

    public init(argv: [String], environment: [String: String] = [:], workingDirectory: String) {
        self.argv = argv
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// Adapter-generated resume command (§3.10): e.g. `claude --resume <id>`.
public struct ResumeSpec: Equatable, Sendable, Codable {
    public var argv: [String]
    public var environment: [String: String]
    public var workingDirectory: String

    public init(argv: [String], environment: [String: String] = [:], workingDirectory: String) {
        self.argv = argv
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// Request the UI makes when creating an agent; the adapter turns it into a
/// concrete `LaunchDescriptor`.
public struct AgentLaunchRequest: Equatable, Sendable {
    public let agentKind: AgentKind
    public let workingDirectory: String
    public let displayName: String
    public let taskSummary: String?

    public init(agentKind: AgentKind, workingDirectory: String, displayName: String, taskSummary: String? = nil) {
        self.agentKind = agentKind
        self.workingDirectory = workingDirectory
        self.displayName = displayName
        self.taskSummary = taskSummary
    }
}

import Foundation

// Typed runtime commands (architecture §3.11).

/// Stop modes are *intents*; the signals themselves (SIGINT/SIGTERM/SIGKILL)
/// are TerminalKit's job. The domain models only the decision.
public enum StopMode: Equatable, Sendable, Codable {
    /// SIGINT / Ctrl-C — the process stays alive.
    case interrupt
    /// SIGTERM process group; 2 s grace period, then SIGKILL.
    case gracefulStop
    /// No signal at all: detach the view, process keeps running.
    case closeView
}

public enum AgentCommand: Equatable, Sendable {
    case prompt(text: String, policy: PromptPolicy)
    case cancelQueuedPrompt
    case interrupt
    case stop(StopMode)
    case restart
    case resume
    case focus
    case sendKeys([String])
}

/// A command with its idempotency identity (§3.16 mutating commands).
public struct RuntimeCommand: Equatable, Sendable {
    public let id: CommandID
    public let agentID: AgentID
    public let command: AgentCommand

    public init(id: CommandID = CommandID(), agentID: AgentID, command: AgentCommand) {
        self.id = id
        self.agentID = agentID
        self.command = command
    }
}

import Foundation

// Prompt policies and receipts (architecture §3.11).

public enum PromptPolicy: Equatable, Sendable, Codable {
    case sendNow
    case queueWhenIdle
    case rejectUnlessIdle

    public var isExplicitSendNow: Bool {
        self == .sendNow
    }
}

public enum PromptOutcome: Equatable, Sendable {
    /// Text was handed to the terminal input path; watchdog armed.
    case delivered
    /// Parked in the single-slot queue until the next validated idle.
    case queued
}

public struct PromptReceipt: Equatable, Sendable {
    public let commandID: CommandID
    public let agentID: AgentID
    public let outcome: PromptOutcome

    public init(commandID: CommandID, agentID: AgentID, outcome: PromptOutcome) {
        self.commandID = commandID
        self.agentID = agentID
        self.outcome = outcome
    }
}

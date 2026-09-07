import Foundation

// PromptQueue (architecture §3.11): exactly one queued prompt per agent,
// replaced only with an explicit replace, cancellable, never persisted across
// app runs.

public struct PromptQueue {
    public private(set) var queued: QueuedPrompt?

    public init() {}

    public var isEmpty: Bool {
        queued == nil
    }

    /// Enqueues a prompt. Throws `queuedPromptAlreadyExists` unless the caller
    /// explicitly authorizes replacement of the previous prompt.
    public mutating func enqueue(
        _ prompt: QueuedPrompt,
        replacingExisting explicitlyAuthorized: Bool = false
    ) throws {
        if queued != nil, !explicitlyAuthorized {
            throw RuntimeErrors.queuedPromptAlreadyExists
        }
        queued = prompt
    }

    @discardableResult
    public mutating func cancel() -> Bool {
        guard queued != nil else { return false }
        queued = nil
        return true
    }

    /// Takes the queued prompt for delivery (next validated idle). Leaves the
    /// queue empty.
    @discardableResult
    public mutating func take() -> QueuedPrompt? {
        let prompt = queued
        queued = nil
        return prompt
    }
}

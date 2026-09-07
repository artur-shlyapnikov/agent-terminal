import Foundation

// RuntimeErrors enum — exactly the §3.11 set.

public enum RuntimeErrors: Error, Equatable, Sendable {
    case agentNotFound
    case terminalUnavailable
    case invalidLifecycle
    case waitingForTerminalInput
    case queuedPromptAlreadyExists
    case semanticStateUnavailable
    case resumeUnsupported
    case resumeReferenceMissing
    case launchFailed
    case promptDeliveryUnconfirmed
    case timeout
    case persistenceDegraded
}

extension RuntimeErrors: CustomStringConvertible {
    public var description: String {
        switch self {
        case .agentNotFound: "agentNotFound"
        case .terminalUnavailable: "terminalUnavailable"
        case .invalidLifecycle: "invalidLifecycle"
        case .waitingForTerminalInput: "waitingForTerminalInput"
        case .queuedPromptAlreadyExists: "queuedPromptAlreadyExists"
        case .semanticStateUnavailable: "semanticStateUnavailable"
        case .resumeUnsupported: "resumeUnsupported"
        case .resumeReferenceMissing: "resumeReferenceMissing"
        case .launchFailed: "launchFailed"
        case .promptDeliveryUnconfirmed: "promptDeliveryUnconfirmed"
        case .timeout: "timeout"
        case .persistenceDegraded: "persistenceDegraded"
        }
    }
}

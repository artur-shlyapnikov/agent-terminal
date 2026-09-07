import AgentCore
import Foundation

// Stable control-protocol error codes (architecture §3.16, §4.5).
//
// Wire contract: an error response is
//   {"requestID":…, "ok":false, "error":{"code":"…","message":"…"}}
// Codes are part of the v1 wire contract and never renamed. The message is
// human-facing and may change freely; clients must branch on `code` only.
// Runtime internals (paths, errno strings, stack context) are NEVER leaked —
// every failure maps into this closed set.

public enum ControlErrorCode: String, CaseIterable, Sendable, Codable {
    // Protocol-level failures.
    case badRequest
    case unsupportedProtocolVersion
    case unknownMethod
    case payloadTooLarge
    case cancelled
    /// A request with this commandID is already executing on another
    /// connection; retry to obtain the idempotency-cached result (§3.16).
    case commandInFlight

    // Hook/launcher authentication (§3.16 hook authentication).
    case unauthorized
    case staleGeneration

    // Runtime command failures — 1:1 with the §3.11 taxonomy.
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

    /// Catch-all; the only code whose message is generic by design.
    case internalError
}

/// The single error type thrown inside the router; rendered as a structured
/// error response at the connection boundary.
public struct ControlFailure: Error, Equatable, Sendable {
    public let code: ControlErrorCode
    public let message: String

    public init(code: ControlErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public static func badRequest(_ message: String) -> ControlFailure {
        ControlFailure(code: .badRequest, message: message)
    }
}

/// Deterministic mapping from the AgentCore runtime error taxonomy onto the
/// stable protocol codes. Unknown non-runtime errors collapse to
/// `.internalError` with a sanitized message.
public func mapRuntimeError(_ error: any Error) -> ControlFailure {
    if let failure = error as? ControlFailure {
        return failure
    }
    guard let runtimeError = error as? RuntimeErrors else {
        return ControlFailure(code: .internalError, message: "internal error")
    }
    switch runtimeError {
    case .agentNotFound: return .init(code: .agentNotFound, message: "agent not found")
    case .terminalUnavailable: return .init(code: .terminalUnavailable, message: "terminal unavailable")
    case .invalidLifecycle: return .init(code: .invalidLifecycle, message: "command invalid for current lifecycle")
    case .waitingForTerminalInput: return .init(
            code: .waitingForTerminalInput,
            message: "agent is waiting for terminal input"
        )
    case .queuedPromptAlreadyExists: return .init(
            code: .queuedPromptAlreadyExists,
            message: "a queued prompt already exists"
        )
    case .semanticStateUnavailable: return .init(
            code: .semanticStateUnavailable,
            message: "requested read source is unavailable"
        )
    case .resumeUnsupported: return .init(
            code: .resumeUnsupported,
            message: "resume is unsupported for this agent kind"
        )
    case .resumeReferenceMissing: return .init(
            code: .resumeReferenceMissing,
            message: "no session reference captured for resume"
        )
    case .launchFailed: return .init(code: .launchFailed, message: "launch failed")
    case .promptDeliveryUnconfirmed: return .init(
            code: .promptDeliveryUnconfirmed,
            message: "prompt delivery was not confirmed"
        )
    case .timeout: return .init(code: .timeout, message: "operation timed out")
    case .persistenceDegraded: return .init(code: .persistenceDegraded, message: "persistence degraded")
    }
}

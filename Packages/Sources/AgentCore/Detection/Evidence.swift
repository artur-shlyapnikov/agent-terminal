import Foundation

// Typed evidence and the observation envelope (architecture §3.6).

public enum EvidenceSource: Equatable, Sendable, Codable {
    case integration
    case screen
    case process

    public var authority: StateAuthority {
        switch self {
        case .integration: .integration
        case .screen: .screen
        case .process: .process
        }
    }
}

/// Every observation travels with this envelope. Ordering rules (§3.6):
/// - observations from an older surfaceGeneration are discarded;
/// - hook reports with seq <= lastAcceptedSeq are duplicates/stale;
/// - observedAt is NEVER used for ordering (external clocks are untrusted);
/// - sequence gaps are accepted but logged as diagnostics;
/// - a late screen result whose outputRevision already changed is dropped;
/// - duplicate reports are acknowledged without creating an event.
public struct ObservationEnvelope: Equatable, Sendable {
    public let agentID: AgentID
    public let terminalID: TerminalID?
    public let surfaceGeneration: SurfaceGeneration
    /// Stable identifier of the concrete source ("hook:claude-code", "screen", …).
    public let sourceID: String
    public let sourceKind: EvidenceSource
    public let sequence: UInt64?
    public let outputRevision: UInt64?
    /// External clock reading — recorded for diagnostics only.
    public let observedAt: MonotonicInstant
    /// Local monotonic receipt time — the only trusted ordering input.
    public let receivedAt: MonotonicInstant

    public init(
        agentID: AgentID,
        terminalID: TerminalID?,
        surfaceGeneration: SurfaceGeneration,
        sourceID: String,
        sourceKind: EvidenceSource,
        sequence: UInt64? = nil,
        outputRevision: UInt64? = nil,
        observedAt: MonotonicInstant,
        receivedAt: MonotonicInstant
    ) {
        self.agentID = agentID
        self.terminalID = terminalID
        self.surfaceGeneration = surfaceGeneration
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.sequence = sequence
        self.outputRevision = outputRevision
        self.observedAt = observedAt
        self.receivedAt = receivedAt
    }
}

/// What the process inspector found for the foreground process.
public struct ProcessEvidencePayload: Equatable, Sendable {
    public var executablePath: String?
    public var executableName: String?
    public var pid: Int32?
    public var matchesForegroundExecutables: Bool

    public init(
        executablePath: String? = nil,
        executableName: String? = nil,
        pid: Int32? = nil,
        matchesForegroundExecutables: Bool = false
    ) {
        self.executablePath = executablePath
        self.executableName = executableName
        self.pid = pid
        self.matchesForegroundExecutables = matchesForegroundExecutables
    }
}

/// Result of screen rule evaluation before hysteresis (§3.7).
public struct ScreenEvidencePayload: Equatable, Sendable {
    public var matchedRuleID: String?
    public var resultingLifecycle: LifecyclePhase
    /// Rule IDs that agreed on the result.
    public var supportingRules: [String]
    /// Equal-priority rules that conflicted — the reason for `unknown`.
    public var conflictingRules: [String]

    public init(
        matchedRuleID: String?,
        resultingLifecycle: LifecyclePhase,
        supportingRules: [String],
        conflictingRules: [String]
    ) {
        self.matchedRuleID = matchedRuleID
        self.resultingLifecycle = resultingLifecycle
        self.supportingRules = supportingRules
        self.conflictingRules = conflictingRules
    }

    public static func unknown(reason conflict: [String]) -> ScreenEvidencePayload {
        ScreenEvidencePayload(
            matchedRuleID: nil,
            resultingLifecycle: .unknown,
            supportingRules: [],
            conflictingRules: conflict
        )
    }
}

/// Operation markers reported by full-lifecycle integrations (e.g. OpenCode).
public enum IntegrationOperation: Equatable, Sendable {
    case started(operationID: String)
    case completed(operationID: String)
}

public enum EvidencePayload: Equatable, Sendable {
    /// Complete lifecycle report from a full integration plugin.
    case integrationLifecycle(LifecyclePhase)
    case integrationOperation(IntegrationOperation)
    case sessionIdentity(SessionReference)
    /// Screen rule evaluation outcome.
    case screen(ScreenEvidencePayload)
    /// Process-only fallback observation.
    case process(ProcessEvidencePayload)
}

public struct Evidence: Equatable, Sendable {
    public let envelope: ObservationEnvelope
    public let payload: EvidencePayload

    public init(envelope: ObservationEnvelope, payload: EvidencePayload) {
        self.envelope = envelope
        self.payload = payload
    }

    public var authority: StateAuthority {
        envelope.sourceKind.authority
    }
}

/// Outcome of feeding one observation through the ordering rules.
public enum AcceptanceDecision: Equatable, Sendable {
    case accepted
    /// Duplicate/stale report: acknowledged to the sender, no event created.
    case acknowledgedDuplicate
    case discardedStaleGeneration
    case discardedStaleOutputRevision
    /// Accepted, but a sequence gap was recorded as diagnostics.
    case acceptedWithSequenceGap(expectedNext: UInt64)
}

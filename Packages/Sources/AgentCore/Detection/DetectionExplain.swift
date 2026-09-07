import Foundation

// DetectionExplain payload (architecture §3.6).
//
// The Inspector shows this to the operator. There is deliberately NO numeric
// confidence: a made-up percentage creates false precision. Ambiguity is
// expressed structurally (conflicting rules, fallback reason).

public enum ExplainAuthority: Equatable, Sendable {
    case integration
    case screen
    case process
    case unknown

    public init(_ authority: StateAuthority) {
        switch authority {
        case .integration: self = .integration
        case .screen: self = .screen
        case .process: self = .process
        case .unknown: self = .unknown
        }
    }
}

public struct DetectionExplain: Equatable, Sendable {
    /// Which source won authority for the resolved state.
    public var authority: ExplainAuthority

    // Adapter identity.
    public var adapterID: String?
    public var adapterVersion: String?

    // Process identity.
    public var executablePath: String?
    public var executableVersion: String?

    // Manifest identity and the rule that produced a screen result.
    public var manifestID: String?
    public var manifestVersion: Int?
    public var matchedRuleID: String?
    /// Equal-priority rules that disagreed — why the result is `unknown`.
    public var conflictingRuleIDs: [String]

    // Snapshot identity for screen results.
    public var snapshotRevision: UInt64?
    public var snapshotHash: String?

    // Integration identity for hook/plugin results.
    public var integrationSourceID: String?
    public var integrationSequence: UInt64?

    /// Why a lower-authority source was used instead of the preferred one.
    public var fallbackReason: String?

    /// Age of the accepted observation at resolution time (monotonic).
    public var observationAge: Duration?

    public init(
        authority: ExplainAuthority,
        adapterID: String? = nil,
        adapterVersion: String? = nil,
        executablePath: String? = nil,
        executableVersion: String? = nil,
        manifestID: String? = nil,
        manifestVersion: Int? = nil,
        matchedRuleID: String? = nil,
        conflictingRuleIDs: [String] = [],
        snapshotRevision: UInt64? = nil,
        snapshotHash: String? = nil,
        integrationSourceID: String? = nil,
        integrationSequence: UInt64? = nil,
        fallbackReason: String? = nil,
        observationAge: Duration? = nil
    ) {
        self.authority = authority
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.executablePath = executablePath
        self.executableVersion = executableVersion
        self.manifestID = manifestID
        self.manifestVersion = manifestVersion
        self.matchedRuleID = matchedRuleID
        self.conflictingRuleIDs = conflictingRuleIDs
        self.snapshotRevision = snapshotRevision
        self.snapshotHash = snapshotHash
        self.integrationSourceID = integrationSourceID
        self.integrationSequence = integrationSequence
        self.fallbackReason = fallbackReason
        self.observationAge = observationAge
    }

    /// Builds an explain payload from a screen evaluation.
    public static func screen(
        result: ScreenEvidencePayload,
        manifest: ScreenManifest,
        revision: UInt64,
        age: Duration?
    ) -> DetectionExplain {
        DetectionExplain(
            authority: result.conflictingRules.isEmpty && result.matchedRuleID != nil ? .screen : .unknown,
            manifestID: manifest.agentKind.rawValue,
            manifestVersion: manifest.manifestVersion,
            matchedRuleID: result.matchedRuleID,
            conflictingRuleIDs: result.conflictingRules,
            snapshotRevision: revision,
            fallbackReason: result.conflictingRules.isEmpty ? nil : "equal-priority rule conflict",
            observationAge: age
        )
    }
}

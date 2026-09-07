import Foundation

// EvidenceLedger: holds the last valid observation per source and applies the
// observation-envelope ordering rules (architecture §3.6).

public struct EvidenceLedger {
    /// Diagnostics entries (sequence gaps, discards) for the Inspector.
    public struct Diagnostic: Equatable, Sendable {
        public let message: String
        public let at: MonotonicInstant
    }

    private(set) var currentGeneration: SurfaceGeneration = .initial
    private(set) var currentOutputRevision: UInt64 = 0

    private(set) var integrationObservations: [String: Evidence] = [:]
    private(set) var lastAcceptedSequences: [String: UInt64] = [:]
    private(set) var screenObservation: Evidence?
    private(set) var processObservation: Evidence?
    private(set) var sessionReference: SessionReference?

    private(set) var diagnostics: [Diagnostic] = []

    /// Diagnostics are a bounded ring for the Inspector: keep the most
    /// recent `maxDiagnostics` entries (§3.6).
    private static let maxDiagnostics = 64

    private mutating func appendDiagnostic(_ diagnostic: Diagnostic) {
        diagnostics.append(diagnostic)
        if diagnostics.count > Self.maxDiagnostics {
            diagnostics.removeFirst(diagnostics.count - Self.maxDiagnostics)
        }
    }

    public init() {}

    public var allObservations: [Evidence] {
        Array(integrationObservations.values) + [screenObservation, processObservation].compactMap { $0 }
    }

    /// The runtime calls this on every render event so late screen results can
    /// be recognized as stale.
    public mutating func outputRevisionChanged(_ revision: UInt64) {
        currentOutputRevision = max(currentOutputRevision, revision)
    }

    /// Restart/resume minted a new generation: drop every observation. The
    /// output-revision watermark restarts with it — observations of the new
    /// generation are judged against its own revisions only (§3.6).
    public mutating func generationChanged(_ generation: SurfaceGeneration) {
        currentGeneration = generation
        currentOutputRevision = 0
        integrationObservations.removeAll()
        lastAcceptedSequences.removeAll()
        screenObservation = nil
        processObservation = nil
        diagnostics.removeAll()
        // Session reference survives restart until a new launch succeeds
        // (crash-recovery rule §3.15: old ref kept until confirmed new start).
    }

    /// Applies ordering rules and stores the observation when accepted.
    @discardableResult
    public mutating func accept(_ evidence: Evidence) -> AcceptanceDecision {
        let envelope = evidence.envelope

        // Rule 1: observations from an older surfaceGeneration are discarded.
        guard envelope.surfaceGeneration >= currentGeneration else {
            return .discardedStaleGeneration
        }
        if envelope.surfaceGeneration > currentGeneration {
            generationChanged(envelope.surfaceGeneration)
        }

        switch evidence.payload {
        case .screen:
            // Rule 5: a late screen result is dropped if outputRevision moved on.
            if let observedRevision = envelope.outputRevision, observedRevision < currentOutputRevision {
                return .discardedStaleOutputRevision
            }
            if let observedRevision = envelope.outputRevision {
                currentOutputRevision = max(currentOutputRevision, observedRevision)
            }
            screenObservation = evidence
            return .accepted

        case .integrationLifecycle, .integrationOperation, .sessionIdentity:
            let sourceID = envelope.sourceID
            // Capture the identity reference but do not commit it yet: a
            // stale duplicate below must NOT roll sessionReference back.
            var identityReference: SessionReference?
            if case let .sessionIdentity(reference) = evidence.payload {
                identityReference = reference
            }

            // Rule 2: seq <= lastAcceptedSeq is duplicate/stale — acknowledge
            // without creating a new event.
            if let sequence = envelope.sequence, let accepted = lastAcceptedSequences[sourceID] {
                if sequence <= accepted {
                    return .acknowledgedDuplicate
                }
                // Rule 4: gaps are accepted but logged.
                var decision = AcceptanceDecision.accepted
                if sequence > accepted + 1 {
                    appendDiagnostic(
                        Diagnostic(
                            message: "sequence gap from \(sourceID): expected \(accepted + 1), received \(sequence)",
                            at: envelope.receivedAt
                        )
                    )
                    decision = .acceptedWithSequenceGap(expectedNext: accepted + 1)
                }
                lastAcceptedSequences[sourceID] = sequence
                integrationObservations[sourceID] = evidence
                if let reference = identityReference {
                    sessionReference = reference
                }
                return decision
            }
            if let sequence = envelope.sequence {
                lastAcceptedSequences[sourceID] = sequence
            }
            integrationObservations[sourceID] = evidence
            if let reference = identityReference {
                sessionReference = reference
            }
            return .accepted

        case .process:
            processObservation = evidence
            return .accepted
        }
    }

    /// Authority lost (e.g. hook stopped reporting while process alive):
    /// integration evidence expires, diagnostics record the loss.
    public mutating func expireIntegration(sourceID: String, at instant: MonotonicInstant) {
        integrationObservations[sourceID] = nil
        appendDiagnostic(Diagnostic(message: "integration \(sourceID) expired", at: instant))
    }
}

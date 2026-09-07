import Foundation

// Authority resolution (architecture §3.6): integration > screen > process >
// unknown. A session-identity hook never becomes lifecycle authority.

public enum StateAuthorityResolver {
    /// Picks the highest-precedence lifecycle-bearing evidence currently in the
    /// ledger. `nil` when nothing lifecycle-bearing is available.
    public static func resolve(in ledger: EvidenceLedger) -> Evidence? {
        var candidates: [Evidence] = []

        // Full-lifecycle integrations only; identity-only hooks are excluded
        // from lifecycle authority by design.
        for evidence in ledger.integrationObservations.values {
            if case .integrationLifecycle = evidence.payload {
                candidates.append(evidence)
            }
        }
        if let screen = ledger.screenObservation, case .screen = screen.payload {
            candidates.append(screen)
        }
        if let process = ledger.processObservation, case .process = process.payload {
            candidates.append(process)
        }

        guard !candidates.isEmpty else { return nil }

        // Highest authority wins; ties break by newest local receipt time.
        // (observedAt is never used — external clocks are untrusted.)
        return candidates.max { lhs, rhs in
            if lhs.authority != rhs.authority {
                return lhs.authority < rhs.authority
            }
            return lhs.envelope.receivedAt < rhs.envelope.receivedAt
        }
    }

    /// The effective authority label for the current ledger, even when no
    /// lifecycle-bearing evidence exists (→ .unknown).
    public static func effectiveAuthority(in ledger: EvidenceLedger) -> StateAuthority {
        resolve(in: ledger)?.authority ?? .unknown
    }
}

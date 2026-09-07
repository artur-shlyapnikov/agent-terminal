import Foundation

// Screen detection engine (architecture §3.5 flicker protection, §3.7
// algorithm steps 9–11). Actor-owned per-agent evaluation state; rule matching
// itself is pure (`ScreenManifestEvaluator`).
//
// Flicker protection constants:
// - waitingForInput needs the SAME rule matched on two snapshots at least
//   `waitingConfirmationInterval` (150 ms) apart with no newer output
//   revision in between;
// - idle after working needs `idleStabilizationInterval` (400 ms) of stable
//   screen with no new output revision;
// - integration and process events are applied immediately by the runtime —
//   they never pass through this engine;
// - equal-priority conflicting screen rules yield unknown (pure evaluator).

public actor ScreenDetectionEngine {
    public struct Configuration: Sendable {
        public var waitingConfirmationInterval: Duration = .milliseconds(150)
        public var idleStabilizationInterval: Duration = .milliseconds(400)

        public init(
            waitingConfirmationInterval: Duration = .milliseconds(150),
            idleStabilizationInterval: Duration = .milliseconds(400)
        ) {
            self.waitingConfirmationInterval = waitingConfirmationInterval
            self.idleStabilizationInterval = idleStabilizationInterval
        }
    }

    struct AgentDetectionState {
        var lastWaitingMatch: [String: (firstSeen: MonotonicInstant, revision: UInt64)] = [:]
        var idleCandidate: (firstSeen: MonotonicInstant, revision: UInt64)?
    }

    private let clock: FakeClock
    private let configuration: Configuration
    private var agents: [AgentID: AgentDetectionState] = [:]

    public init(clock: FakeClock, configuration: Configuration = Configuration()) {
        self.clock = clock
        self.configuration = configuration
    }

    /// Context for one evaluation.
    public struct EvaluationContext: Sendable {
        public let agentID: AgentID
        public let currentLifecycle: LifecyclePhase
        public let manifest: ScreenManifest

        public init(agentID: AgentID, currentLifecycle: LifecyclePhase, manifest: ScreenManifest) {
            self.agentID = agentID
            self.currentLifecycle = currentLifecycle
            self.manifest = manifest
        }
    }

    /// Evaluates a normalized snapshot against the manifest and applies
    /// hysteresis. Returns nil while a stability window is still open.
    ///
    /// The snapshot text must already be normalized by the terminal layer
    /// (last N rows ≤ 32 / 16 KiB, CRLF normalized, trailing spaces stripped,
    /// independent of scroll position — §3.7 step 4). The runtime re-validates
    /// generation and outputRevision on arrival (§3.7 step 11).
    public func evaluate(_ snapshot: TerminalSnapshot, context: EvaluationContext) -> ScreenEvidencePayload? {
        var state = agents[context.agentID] ?? AgentDetectionState()
        defer { agents[context.agentID] = state }
        let raw = ScreenManifestEvaluator.evaluate(manifest: context.manifest, snapshotText: snapshot.text)
        let now = clock.now

        // Rule conflict → unknown immediately; no hysteresis can fix ambiguity.
        if !raw.conflictingRules.isEmpty {
            state.lastWaitingMatch.removeAll()
            state.idleCandidate = nil
            return .unknown(reason: raw.conflictingRules)
        }

        switch raw.resultingLifecycle {
        case let .waitingForInput(descriptor):
            guard let ruleID = raw.matchedRuleID else { return raw }
            if stabilityRequirement(of: raw, manifest: context.manifest) == .none {
                // Emit on the first matching snapshot; no confirmation pair.
                state.lastWaitingMatch[ruleID] = nil
                _ = descriptor
                return raw
            }
            if let candidate = state.lastWaitingMatch[ruleID],
               candidate.revision == snapshot.outputRevision
            {
                if now - candidate.firstSeen >= stabilityWindow(
                    of: raw,
                    manifest: context.manifest,
                    fallback: configuration.waitingConfirmationInterval
                ) {
                    state.lastWaitingMatch[ruleID] = nil
                    return raw
                }
                // Same confirmation window still open.
                return nil
            } else {
                // First sighting (or a newer output revision arrived since):
                // record/restart the pair and wait for another match on the
                // same revision ≥ window later. Continuous redraws (e.g.
                // spinner frames) must not confirm a persistently visible
                // match by elapsed wall time alone.
                state.lastWaitingMatch[ruleID] = (now, snapshot.outputRevision)
                _ = descriptor
                return nil
            }

        case .idle where isWorkingToIdle(context.currentLifecycle):
            // idle-after-working: require a stable screen with no newer output
            // revision than when the candidate first appeared. The window comes
            // from the winning idle rule itself, independent of the previous
            // phase (§3.7 step 9).
            if stabilityRequirement(of: raw, manifest: context.manifest) == .none {
                // Emit on the first matching snapshot; no stabilization wait.
                state.idleCandidate = nil
                return raw
            }
            let window = stabilityWindow(
                of: raw,
                manifest: context.manifest,
                fallback: configuration.idleStabilizationInterval
            )
            if let candidate = state.idleCandidate, candidate.revision == snapshot.outputRevision {
                if now - candidate.firstSeen >= window {
                    state.idleCandidate = nil
                    return raw
                }
                return nil
            } else {
                state.idleCandidate = (now, snapshot.outputRevision)
                return nil
            }

        default:
            // Everything else emits immediately.
            state.lastWaitingMatch.removeAll()
            state.idleCandidate = nil
            return raw
        }
    }

    private func isWorkingToIdle(_ current: LifecyclePhase) -> Bool {
        if case .working = current {
            return true
        }
        return false
    }

    /// §3.7 step 9 + the `stabilityRequirement` rule field: the winning rule's
    /// declared window governs its hysteresis. Rules without a declaration keep
    /// the legacy constants — bundled manifests declare exactly those values,
    /// so their behavior is unchanged.
    private func stabilityWindow(
        of payload: ScreenEvidencePayload,
        manifest: ScreenManifest,
        fallback: Duration
    ) -> Duration {
        guard let ruleID = payload.matchedRuleID,
              let rule = manifest.rules.first(where: { $0.id == ruleID }),
              case let .stable(window) = rule.stabilityRequirement else { return fallback }
        return window
    }

    private func stabilityRequirement(
        of payload: ScreenEvidencePayload,
        manifest: ScreenManifest
    ) -> StabilityRequirement {
        guard let ruleID = payload.matchedRuleID,
              let rule = manifest.rules.first(where: { $0.id == ruleID }) else { return .unspecified }
        return rule.stabilityRequirement
    }

    /// Restart/resume minted a new generation: forget all hysteresis.
    public func invalidate(agentID: AgentID) {
        agents[agentID] = nil
    }
}

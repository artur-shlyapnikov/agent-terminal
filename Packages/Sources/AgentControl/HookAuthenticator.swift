import AgentCore
import Foundation

// Per-process-generation scoped hook token validation (architecture §3.16).
//
// Model:
// - when the app launches a process generation it mints a random token, hands
//   it to the child through the ephemeral launch environment (ticket env
//   `AGENT_TERMINAL_TOKEN`), and registers it here;
// - integration.report / integration.release and launcher.started/failed
//   reports must present the token for the CURRENT generation of the agent;
// - restart invalidates the old token (the app registers the new generation's
//   token; reports from the superseded generation are `staleGeneration`);
// - a wrong token is `unauthorized`; no fallback interpretation.
//
// Sequence ordering follows §3.6: a report whose `seq <= lastAcceptedSeq` for
// its (agentID, source) is a duplicate — acknowledged with ok:true and NO new
// event. Gaps are accepted but flagged in diagnostics.
//
// Threat-model boundary: this protects against accidental cross-agent or
// stale-generation reports only. It is NOT a defense against a malicious
// process running as the same Unix user — the app threat model is a trusted
// local user (§3.16).

public actor HookAuthenticator {
    public enum Verdict: Equatable, Sendable {
        /// Report accepted; caller must forward it to the runtime.
        case accept(sequence: UInt64?)
        /// Duplicate/stale sequence per §3.6 — ack without creating an event.
        case duplicate(lastAcceptedSequence: UInt64)
        /// Structured rejection.
        case reject(ControlFailure)
    }

    struct GenerationEntry {
        let token: String
        let surfaceGeneration: SurfaceGeneration
    }

    private var generations: [AgentID: GenerationEntry] = [:]
    /// Last accepted source sequence per (agentID, sourceID).
    private var lastAcceptedSequence: [AgentID: [String: UInt64]] = [:]
    /// Integration sources whose lease was explicitly released, scoped per
    /// agent so a new generation registration can clear stale entries. Sources
    /// released without a known agentID stay in `releasedOrphanSources`
    /// permanently (no owner to re-register them).
    private var releasedSources: [AgentID: Set<String>] = [:]
    private var releasedOrphanSources: Set<String> = []

    public init() {}

    // MARK: Registry (called by the app composition root / stage 8 wiring)

    /// Registers the scoped token minted for one process generation.
    public func register(
        agentID: AgentID,
        surfaceGeneration: SurfaceGeneration,
        token: String
    ) {
        generations[agentID] = GenerationEntry(token: token, surfaceGeneration: surfaceGeneration)
        // A fresh generation starts a fresh sequence space (§3.6); without
        // this, stale sequences from the superseded generation would make
        // the new generation's early reports classify as duplicates.
        lastAcceptedSequence[agentID] = nil
        // A new generation implicitly re-registers integration sources, so
        // previously released sources of this agent are no longer stale.
        releasedSources[agentID] = nil
    }

    /// Invalidates the current generation (restart path). Reports from any
    /// generation after this are rejected until a new one is registered.
    public func invalidate(agentID: AgentID) {
        generations[agentID] = nil
        lastAcceptedSequence[agentID] = nil
    }

    /// Releases an integration lease (`integration.release`). Later reports
    /// from that source are rejected as stale until re-registered implicitly
    /// by a new generation registration.
    public func release(sourceID: String, agentID: AgentID?) {
        if let agentID {
            releasedSources[agentID, default: []].insert(sourceID)
            lastAcceptedSequence[agentID]?[sourceID] = nil
        } else {
            // No owning agent: nothing will ever re-register it.
            releasedOrphanSources.insert(sourceID)
        }
    }

    public func isRegistered(agentID: AgentID) -> Bool {
        generations[agentID] != nil
    }

    public func hasReleased(sourceID: String, agentID: AgentID?) -> Bool {
        if let agentID {
            return releasedSources[agentID]?.contains(sourceID) == true
                || releasedOrphanSources.contains(sourceID)
        }
        return releasedOrphanSources.contains(sourceID)
    }

    // MARK: Validation

    /// Validates a report carrying (token, surfaceGeneration) and performs
    /// §3.6 duplicate-sequence handling on success.
    public func validateReport(
        agentID: AgentID,
        surfaceGeneration: SurfaceGeneration,
        sourceID: String,
        sequence: UInt64?,
        token: String
    ) -> Verdict {
        guard let entry = generations[agentID] else {
            return .reject(ControlFailure(
                code: .unauthorized,
                message: "no registered process generation for agent"
            ))
        }
        guard entry.token == token else {
            return .reject(ControlFailure(code: .unauthorized, message: "hook token mismatch"))
        }
        // The registered generation is authoritative; anything else is stale.
        guard entry.surfaceGeneration == surfaceGeneration else {
            return .reject(ControlFailure(
                code: .staleGeneration,
                message: "report from superseded surface generation #\(surfaceGeneration.rawValue)"
            ))
        }
        if hasReleased(sourceID: sourceID, agentID: agentID) {
            return .reject(ControlFailure(
                code: .staleGeneration,
                message: "integration source already released"
            ))
        }

        guard let sequence else { return .accept(sequence: nil) }
        if let last = lastAcceptedSequence[agentID]?[sourceID], sequence <= last {
            return .duplicate(lastAcceptedSequence: last)
        }
        lastAcceptedSequence[agentID, default: [String: UInt64]()][sourceID] = sequence
        return .accept(sequence: sequence)
    }

    /// Diagnostics helper for §3.6 sequence-gap logging at report sites.
    public func expectedNextSequence(agentID: AgentID, sourceID: String) -> UInt64? {
        lastAcceptedSequence[agentID]?[sourceID].map { $0 + 1 }
    }
}

import Foundation

// Foreground executable / process tree contract (architecture §3.6/§4.2).
//
// AgentCore defines only the port; the libproc-backed implementation arrives
// in TerminalKit (`MacProcessInspector`). The runtime uses it to build
// ProcessEvidence — the lowest-authority fallback.

public protocol ProcessInspector: Sendable {
    /// Inspects the foreground process of the agent's terminal session and
    /// computes `matchesForegroundExecutables` for real against the manifest
    /// candidate list owned by the stage-7 engine (§3.6). Returns nil-derived
    /// data gracefully when the process is gone.
    func inspect(
        terminalID: TerminalID,
        pid: Int32?,
        foregroundExecutableCandidates: [String]
    ) async throws -> ProcessEvidencePayload
}

public extension ProcessInspector {
    /// Convenience for callers without the manifest list: no candidates means
    /// the match flag is always false (the semantic belongs to the engine).
    func inspect(terminalID: TerminalID, pid: Int32?) async throws -> ProcessEvidencePayload {
        try await inspect(terminalID: terminalID, pid: pid, foregroundExecutableCandidates: [])
    }
}

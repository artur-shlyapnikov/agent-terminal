import AgentCore
import Darwin
import Foundation

// libproc/sysctl implementation of AgentCore.ProcessInspector (architecture
// §3.6/§4.2): the process-evidence fallback used when screen rules and hooks
// are inconclusive. Degrades gracefully to nil-derived payloads.

public struct MacProcessInspector: ProcessInspector {
    public init() {}

    public func inspect(
        terminalID _: TerminalID,
        pid: Int32?,
        foregroundExecutableCandidates: [String]
    ) async throws -> ProcessEvidencePayload {
        guard let pid, pid > 0 else {
            return ProcessEvidencePayload()
        }

        // proc_pidpath first: a successful read implies liveness, and taking
        // the path from the same instant as the liveness decision avoids
        // attributing another process's executable to a reused PID. Fall back
        // to signal 0 only when the path is unreadable: EPERM means alive but
        // owned by another user, anything else (e.g. ESRCH) means gone.
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        guard length > 0 else {
            switch kill(pid, 0) {
            case 0:
                break
            default:
                guard errno == EPERM else {
                    return ProcessEvidencePayload(pid: pid)
                }
            }
            // Alive but path unreadable — still valid liveness evidence.
            return ProcessEvidencePayload(
                executablePath: nil,
                executableName: nil,
                pid: pid,
                matchesForegroundExecutables: false
            )
        }
        let path = String(cString: pathBuffer)
        let name = URL(fileURLWithPath: path).lastPathComponent
        // Real match against the manifest's candidate list (case-insensitive;
        // candidates may be bare names like "claude" or absolute paths).
        // Case-folding here is presentation-level tolerance; the semantic
        // decision stays with the stage-7 engine, which owns the manifest.
        let loweredCandidates = foregroundExecutableCandidates.map { $0.lowercased() }
        let matches = loweredCandidates.contains { $0 == name.lowercased() || $0 == path.lowercased() }
        return ProcessEvidencePayload(
            executablePath: path,
            executableName: name,
            pid: pid,
            matchesForegroundExecutables: matches
        )
    }
}

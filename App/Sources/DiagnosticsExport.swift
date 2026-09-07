import AgentCore
import AgentStore
import CommonCrypto
import Foundation
import GhosttyBridge
import SQLite3

// Diagnostic export (architecture §3.22).
//
// The bundle contains ONLY content-free material:
//   app/Ghostty versions, adapter versions, manifest hashes, state-transition
//   timelines (event descriptions — never prompt text or terminal output),
//   authority/ledger diagnostics, database schema version, integration install
//   fingerprints and REDACTED log lines.
//
// Redaction law (DoD #14): prompt, environment and terminal output must be
// absent from diagnostics. `DiagnosticRedactor` scrubs env-style assignments
// for sensitive keys and quoted payload fragments at RECORD time and again at
// RENDER time; the unit suite proves hostile strings cannot survive.

// MARK: - Redaction (pure, unit-tested)

enum DiagnosticRedactor {
    /// Env/log keys whose VALUES never belong in a diagnostic bundle.
    static let sensitiveKeyPatterns: [String] = [
        "TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY",
        "PRIVATE_KEY", "SESSION", "COOKIE", "CREDENTIAL", "PROMPT",
    ]

    /// True when the key looks sensitive (`ATERM_TOKEN`, `MY_API_KEY=…`).
    static func isSensitive(key: String) -> Bool {
        let upper = key.uppercased()
        return sensitiveKeyPatterns.contains { upper.contains($0) }
    }

    /// Scrubs one log line:
    ///  * quoted `KEY="multi word value"` assignments with sensitive keys lose
    ///    the whole value (a space-splitting token pass cannot see them);
    ///  * `KEY=value` / `KEY: value` assignments with sensitive keys lose the value;
    ///  * anything after an explicit "prompt:"/"output:" marker is dropped;
    ///  * bracketed-paste and heredoc-looking payloads are truncated.
    static func sanitize(_ line: String) -> String {
        var result = line

        // Drop explicit prompt/output payload sections entirely.
        for marker in ["prompt:", "prompt =", "output:", "output ="] {
            if let range = result.range(of: marker, options: .caseInsensitive) {
                result = String(result[result.startIndex ..< range.lowerBound]) + "\(marker) <redacted>"
            }
        }

        // Quoted-value pre-pass: `KEY="secret words here"` splits into
        // `KEY="secret` and `words here"` on spaces, so the token loop below
        // only catches the first fragment. Replace the ENTIRE quoted span
        // (double- or single-quoted) for every sensitive key up front; because
        // this replaces the whole span, nothing of a quoted secret survives
        // for the token loop or render() to miss.
        let quotedPattern =
            "\\b(?i:(\\w*(?:" + sensitiveKeyPatterns.joined(separator: "|") + ")\\w*))\\s*=\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*')"
        if let quoted = try? NSRegularExpression(pattern: quotedPattern) {
            result = quoted.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex ..< result.endIndex, in: result),
                withTemplate: "$1=<redacted>"
            )
        }
        // Unterminated quote: a truncated log line can cut a quoted value
        // before its closing quote; treat the rest of the line as the value
        // (same end-of-line law as the colon pass below).
        let unterminatedPattern =
            "\\b(?i:(\\w*(?:" + sensitiveKeyPatterns.joined(separator: "|") + ")\\w*))\\s*=\\s*[\"'][^\"']*$"
        if let unterminated = try? NSRegularExpression(pattern: unterminatedPattern) {
            result = unterminated.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex ..< result.endIndex, in: result),
                withTemplate: "$1=<redacted>"
            )
        }
        // KEY: value scrubbing (log-style). The value runs to end of line:
        // colon-form payloads are free text, so a token-scoped pass would
        // leak the tail (mirrors the prompt:/output: marker truncation).
        let colonPattern =
            "\\b(?i:(\\w*(?:" + sensitiveKeyPatterns.joined(separator: "|") + ")\\w*))\\s*:\\s*.*$"
        if let colon = try? NSRegularExpression(pattern: colonPattern) {
            result = colon.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex ..< result.endIndex, in: result),
                withTemplate: "$1: <redacted>"
            )
        }
        // KEY=value scrubbing (shell-export style).
        for pair in result.split(separator: " ", omittingEmptySubsequences: false) {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            let key = String(pair[pair.startIndex ..< eq])
            if isSensitive(key: key) {
                let replacement = key + "=<redacted>"
                result = result.replacingOccurrences(of: String(pair), with: replacement)
            }
        }
        return result
    }

    /// Whole-document safety net: refuses to render any line still carrying a
    /// sensitive assignment after sanitization. Values ALREADY scrubbed to
    /// `<redacted>` survive — the placeholder itself carries no secret.
    static func render(lines: [String]) -> [String] {
        lines.map(sanitize).filter { line in
            !line.split(separator: " ").contains { word in
                guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
                let value = word[word.index(after: eq)...]
                guard value != "<redacted>" else { return false }
                return isSensitive(key: String(word[word.startIndex ..< eq]))
            }
        }
        // Note: quoted sensitive values were already fully replaced by the
        // pre-pass in sanitize(); the word filter above remains a sufficient
        // backstop for unquoted values, which never contain spaces.
    }
}

// MARK: - Log ring (in-memory, redacted at record time)

/// Bounded ring of app-level diagnostic lines. Fed explicitly by lifecycle
/// sites (composition root, repair flow); NEVER fed prompts or output.
@MainActor
final class DiagnosticsLogRing {
    static let shared = DiagnosticsLogRing()
    private(set) var lines: [String] = []
    private let capacity = 500

    func record(_ line: String) {
        lines.append(DiagnosticRedactor.sanitize("[\(Self.timestamp())] \(line)"))
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    nonisolated static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

// MARK: - Bundle assembly

struct DiagnosticsSnapshot {
    struct AdapterRow {
        let id: String
        let displayName: String
        let installedPath: String?
        let versionText: String?
    }

    var generatedAt: Date = .init()
    var appVersion: String
    var ghosttyDescription: String
    var bridgeABIVersion: UInt32
    var adapters: [AdapterRow]
    var manifestHashes: [String: String] // manifest name → sha256
    var schemaVersion: String?
    var fingerprints: [ManagedEntryFingerprint]
    var agents: [AgentSummary]
    var timelineLines: [AgentID: [String]] // per-agent §3.22 transition lines
    var logLines: [String]
}

/// Pure renderer — unit-tested WITHOUT AppKit or the runtime.
enum DiagnosticBundleBuilder {
    static func render(_ snapshot: DiagnosticsSnapshot) -> String {
        var out: [String] = []
        out.append("AgentTerminal Diagnostic Bundle")
        out.append("generated: \(DiagnosticsLogRing.timestamp()) (redacted per architecture §3.22)")
        out.append("")
        out.append("== Versions ==")
        out.append("app: \(snapshot.appVersion)")
        out.append("ghostty: \(snapshot.ghosttyDescription)")
        out.append("ghostty bridge ABI: \(snapshot.bridgeABIVersion)")
        out.append("")
        out.append("== Adapters ==")
        if snapshot.adapters.isEmpty {
            out.append("(none)")
        }
        for adapter in snapshot.adapters {
            out
                .append(
                    "\(adapter.id) (\(adapter.displayName)): path=\(adapter.installedPath ?? "not found") version=\(adapter.versionText ?? "?")"
                )
        }
        out.append("")
        out.append("== Detection manifests (sha256) ==")
        if snapshot.manifestHashes.isEmpty {
            out.append("(none)")
        }
        for (name, hash) in snapshot.manifestHashes.sorted(by: { $0.key < $1.key }) {
            out.append("\(name): \(hash)")
        }
        out.append("")
        out.append("== Store ==")
        out.append("schema version: \(snapshot.schemaVersion ?? "unavailable")")
        out.append("")
        out.append("== Integration install fingerprints ==")
        if snapshot.fingerprints.isEmpty {
            out.append("(no managed entries recorded)")
        }
        for fingerprint in snapshot.fingerprints {
            // Managed CONTENT is AgentTerminal-generated boilerplate; only the
            // location identity belongs here.
            out.append(
                "\(fingerprint.adapterID) @ \(fingerprint.targetPath) "
                    + "keys=\(fingerprint.entryKeyPath.joined(separator: "/")) "
                    + "marker-present=\(!fingerprint.marker.isEmpty)"
            )
        }
        out.append("")
        out.append("== Agents & state transitions (no prompt/output content) ==")
        if snapshot.agents.isEmpty {
            out.append("(no agents this run)")
        }
        for agent in snapshot.agents {
            out
                .append(
                    "- \(agent.displayName) [\(agent.kind.rawValue)] lifecycle=\(agent.state.lifecycle) attention=\(agent.state.attention)"
                )
            for line in snapshot.timelineLines[agent.id] ?? [] {
                out.append("    \(line)")
            }
        }
        out.append("")
        out.append("== Redacted logs ==")
        out.append(contentsOf: DiagnosticRedactor.render(lines: snapshot.logLines))
        out.append("")
        return out.joined(separator: "\n")
    }
}

// MARK: - Exporter (composition-root wired)

@MainActor
final class DiagnosticExporter {
    weak var root: AppCompositionRoot?
    /// Install fingerprints source — the composition root's recording, the
    /// same instance the installer writes through (stage-16 will swap in the
    /// AgentStore-backed recording).
    var recording: IntegrationInstallRecording?

    init(root: AppCompositionRoot?, recording: IntegrationInstallRecording? = nil) {
        self.root = root
        self.recording = recording
    }

    /// Gathers the live snapshot. Never throws — degraded inputs degrade the
    /// section text instead (§3.22 observability must survive degradation).
    func gatherSnapshot() async -> DiagnosticsSnapshot {
        let root = root
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // Stage-16 item C: the pinned commit is bundled as a resource, so a
        // shipped .app reports it without any repo checkout on the machine.
        let pinnedCommit = (Bundle.main.url(forResource: "commit", withExtension: "txt"))
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "unknown (commit.txt resource missing)"
        let ghosttyDescription =
            "vendored libghostty, pinned commit \(pinnedCommit); config: \(AppCompositionRoot.makeGhosttyConfig())"

        var adapters: [DiagnosticsSnapshot.AdapterRow] = []
        let catalog = AgentCatalog.standard()
        for adapter in catalog.allAdapters {
            var path: String?
            var version: String?
            if case let .installed(p, detected) = await adapter.detectInstallation() {
                path = p
                if let detected {
                    version = detected
                } else {
                    version = await adapter.detectVersion(executablePath: p)
                }
            }
            adapters.append(.init(
                id: adapter.id, displayName: adapter.displayName,
                installedPath: path, versionText: version
            ))
        }

        var schemaVersion: String?
        if let database = root?.database {
            schemaVersion = Self.readSchemaVersion(databaseURL: database.databaseURL)
                .map { "agentstore-v\($0)" } ?? "unknown"
        }

        let runtimeAgents: [AgentSummary] = if let root {
            await root.runtime.projection().agents
        } else {
            []
        }
        var timelines: [AgentID: [String]] = [:]
        for agent in runtimeAgents {
            let events = await root?.runtime.timeline(of: agent.id) ?? []
            timelines[agent.id] = events.map { event in
                "\(AgentEventText.describe(event.event)) — \(AgentEventText.ageText(from: event.at, to: AgentEventText.nowInstant()))"
            }
        }

        return DiagnosticsSnapshot(
            appVersion: "\(appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))",
            ghosttyDescription: ghosttyDescription,
            bridgeABIVersion: agt_bridge_abi_version(),
            adapters: adapters,
            manifestHashes: Self.manifestHashes(),
            schemaVersion: schemaVersion,
            fingerprints: Self.allFingerprints(recording: recording, catalog: catalog),
            agents: runtimeAgents,
            timelineLines: timelines,
            logLines: DiagnosticsLogRing.shared.lines
        )
    }

    /// Writes the bundle to the user-chosen file; returns nil on success or an
    /// actionable message.
    func export(to url: URL) async -> String? {
        let snapshot = await gatherSnapshot()
        let text = DiagnosticBundleBuilder.render(snapshot)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            DiagnosticsLogRing.shared.record("diagnostic bundle exported to \(url.lastPathComponent)")
            return nil
        } catch {
            return "Could not write the diagnostic bundle: \(error)"
        }
    }

    static func allFingerprints(
        recording: IntegrationInstallRecording?, catalog: AgentCatalog
    ) -> [ManagedEntryFingerprint] {
        guard let recording else { return [] }
        return catalog.allAdapters.flatMap { recording.fingerprints(adapterID: $0.id) }
    }

    /// Reads the highest applied `agentstore-vN` migration directly from the
    /// SQLite file (read-only) without importing GRDB into the app target.
    static func readSchemaVersion(databaseURL: URL) -> UInt64? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT identifier FROM grdb_migrations", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var versions: [UInt64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let cString = sqlite3_column_text(statement, 0)
            guard let cString else { continue }
            let identifier = String(cString: cString)
            let prefix = "agentstore-v"
            if identifier.hasPrefix(prefix), let v = UInt64(identifier.dropFirst(prefix.count)) {
                versions.append(v)
            }
        }
        return versions.max()
    }

    /// sha256 over every bundled detection manifest TOML inside the AgentCore
    /// resource bundle (§3.22 manifest hashes).
    static func manifestHashes() -> [String: String] {
        var hashes: [String: String] = [:]
        let bundleURL = Bundle.main.url(forResource: "AgentTerminal_AgentCore", withExtension: "bundle")
            ?? Bundle.main.resourceURL?.appendingPathComponent("AgentTerminal_AgentCore.bundle")
        guard let bundleURL,
              let detectionURL = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil)?
              .compactMap({ $0 as? URL })
              .first(where: { $0.lastPathComponent == "Detection" })
        else {
            return hashes
        }
        let names = ["claude-code", "codex", "opencode"]
        for name in names {
            let fileURL = detectionURL.appendingPathComponent("\(name).toml")
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            hashes[name] = Self.sha256(data)
        }
        return hashes
    }

    static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

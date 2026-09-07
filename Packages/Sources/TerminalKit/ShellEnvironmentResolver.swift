import AgentCore
import Foundation

// Login environment resolver (architecture §3.9): one shot per app run, via
// the user's own login shell with a 3 s timeout. Filtering rules:
//   - DYLD_* stripped (injection defense);
//   - AGENT_TERMINAL_* keys from the app override any login-shell values;
//   - PATH, locale and SSH_AUTH_SOCK are preserved from the login shell;
//   - on failure/timeout a safe fallback PATH is used.
//
// Secrets never logged: no value of the resolved environment is ever printed,
// and `description`/`debugDescription` are redacted.

public struct ShellEnvironmentResolver: Sendable {
    public struct Configuration: Sendable {
        /// Full argv of the environment probe. Defaults to
        /// `$SHELL -l -c "/usr/bin/env -0"`. Tests inject e.g.
        /// ["/usr/bin/env", "-0"] to run without a login shell.
        public var command: [String]
        public var timeoutSeconds: Double
        public var fallbackPATH: String
        /// Overrides the process environment as the "app side" baseline
        /// (AGENT_TERMINAL_* overrides, locale fallbacks). Tests inject a
        /// deterministic baseline here.
        public var baseEnvironment: [String: String]?

        public init(
            command: [String]? = nil,
            timeoutSeconds: Double = 3,
            fallbackPATH: String = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            baseEnvironment: [String: String]? = nil
        ) {
            if let command {
                self.command = command
            } else {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                self.command = [shell, "-l", "-c", "/usr/bin/env -0"]
            }
            self.timeoutSeconds = timeoutSeconds
            self.fallbackPATH = fallbackPATH
            self.baseEnvironment = baseEnvironment
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Resolves the login environment with no overlays.
    public func resolve() -> [String: String] {
        resolve(overlays: [:])
    }

    /// Resolves the login environment and applies `overlays` on top (after the
    /// AGENT_TERMINAL_* override rule), so adapter-owned additions win.
    public func resolve(overlays: [String: String]) -> [String: String] {
        let base = configuration.baseEnvironment ?? ProcessInfo.processInfo.environment
        // AGENT_TERMINAL_* keys from the app override any login-shell values,
        // so carry them as overlays (below the caller's, per resolve's docs).
        let effectiveOverlays = base.filter { $0.key.hasPrefix("AGENT_TERMINAL_") }
            .merging(overlays) { _, overlay in overlay }
        if let login = runProbe() {
            var merged = login
            merged["PATH"] = login["PATH"] ?? base["PATH"] ?? configuration.fallbackPATH
            // Preserve locale + agent socket from the login environment even
            // when the probe omitted them.
            for key in ["LANG", "LC_ALL", "SSH_AUTH_SOCK"] where merged[key] == nil {
                merged[key] = base[key]
            }
            return applyRules(merged, overlays: effectiveOverlays)
        }

        // Degraded mode: current process env with a safe fallback PATH.
        var fallback = base
        fallback["PATH"] = configuration.fallbackPATH
        return applyRules(fallback, overlays: effectiveOverlays)
    }

    /// Strips DYLD_*, removes inherited AGENT_TERMINAL_* from the probed
    /// environment, then applies app-provided AGENT_TERMINAL_* + overlays.
    private func applyRules(_ environment: [String: String], overlays: [String: String]) -> [String: String] {
        var result = environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("AGENT_TERMINAL_")
        }
        for (key, value) in overlays where !key.hasPrefix("DYLD_") {
            result[key] = value
        }
        return result
    }

    // MARK: probe execution

    private func runProbe() -> [String: String]? {
        guard !configuration.command.isEmpty else { return nil }

        // Bounded probe via AgentCore's managed runner: event-driven output
        // collection, deadline escalation to SIGKILL, and bounded EOF grace,
        // so a grandchild holding stdout (ssh-agent & co.) cannot wedge
        // resolution past the configured timeout.
        let outcome = try? ManagedChildProcess.run(
            executableURL: URL(fileURLWithPath: configuration.command[0]),
            arguments: Array(configuration.command.dropFirst()),
            deadline: configuration.timeoutSeconds
        )
        guard let outcome, outcome.terminationStatus == 0, !outcome.deadlineFired else {
            return nil
        }
        return Self.parseNulSeparated(outcome.stdout)
    }

    static func parseNulSeparated(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for entry in data.split(separator: 0) where !entry.isEmpty {
            guard let equalsIndex = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: entry[..<equalsIndex], as: UTF8.self)
            let value = String(decoding: entry[entry.index(after: equalsIndex)...], as: UTF8.self)
            result[key] = value
        }
        return result
    }
}

extension ShellEnvironmentResolver: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ShellEnvironmentResolver(command: redacted)"
    }

    public var debugDescription: String {
        description
    }
}

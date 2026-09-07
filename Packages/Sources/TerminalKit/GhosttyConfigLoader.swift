import AgentCore
import Foundation

// App-specific Ghostty configuration (architecture §3.8): the app loads ONLY
// its own config at ~/Library/Application Support/AgentTerminal/ghostty/config,
// never the user's global Ghostty files. This excludes structural keybindings
// and other host-app settings; the file is meant for visual-only keys:
//
//   font-family, font-size, colors/theme, cursor-style/-blink,
//   ligatures, scrollback-limit, shell-integration visual options.
//
// Structural application shortcuts are owned by the App target, not here.

@MainActor public final class GhosttyConfigLoader {
    /// Default per-app config location.
    public static func defaultPath() -> URL {
        AppPaths.applicationSupport()
            .appendingPathComponent("AgentTerminal/ghostty/config")
    }

    public let path: URL

    /// - Parameter path: overrides the default config location (tests).
    public init(path: URL? = nil) {
        self.path = path ?? Self.defaultPath()
    }

    /// Creates the parent directory when missing so users have a discoverable
    /// place for visual customization. Never writes a config file itself.
    public func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// Returns the config path when the file exists; otherwise nil so the
    /// engine boots on library defaults instead of failing.
    ///
    /// NOTE (ADR-0002 finding 5): some config keys (e.g. `scrollback-limit`)
    /// were observed to suppress SHOW_CHILD_EXITED action delivery. That does
    /// not affect this loader — process exit is polled regardless — but it is
    /// why exit codes remain best-effort.
    public func existingConfigPath() -> String? {
        FileManager.default.fileExists(atPath: path.path) ? path.path : nil
    }
}

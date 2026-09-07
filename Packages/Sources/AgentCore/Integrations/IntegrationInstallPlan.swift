import Foundation

// Declarative integration install plan (architecture §3.17).
//
// The installer NEVER overwrites a user config wholesale: it reads the
// existing file, builds this plan, shows the diff, backs up, writes to temp,
// validates, atomically renames and records managed fingerprints. Uninstall
// removes only entries whose marker matches ours.

public enum ConfigFileFormat: String, Equatable, Sendable, Codable {
    case json
    case toml
    case javaScript = "javascript"
}

public struct ManagedConfigEntry: Equatable, Sendable, Codable {
    /// JSON-pointer-style path into the target document, e.g. ["hooks","stop"].
    public let keyPath: [String]
    /// Serialized value to merge at that path.
    public let valueJSON: String
    /// Namespace marker proving AgentTerminal owns the entry.
    public let marker: String

    public init(keyPath: [String], valueJSON: String, marker: String) {
        self.keyPath = keyPath
        self.valueJSON = valueJSON
        self.marker = marker
    }
}

public struct IntegrationFileEdit: Equatable, Sendable, Codable {
    /// Path template; "~" expands to the user home at install time.
    public let targetPathTemplate: String
    public let format: ConfigFileFormat
    public let entries: [ManagedConfigEntry]

    public init(targetPathTemplate: String, format: ConfigFileFormat, entries: [ManagedConfigEntry]) {
        self.targetPathTemplate = targetPathTemplate
        self.format = format
        self.entries = entries
    }
}

public struct IntegrationInstallPlan: Equatable, Sendable, Codable {
    public static let namespaceMarker = "com.agentterminal.managed"

    public let adapterID: String
    public let files: [IntegrationFileEdit]

    public init(adapterID: String, files: [IntegrationFileEdit]) {
        self.adapterID = adapterID
        self.files = files
    }

    public static func empty(adapterID: String) -> IntegrationInstallPlan {
        IntegrationInstallPlan(adapterID: adapterID, files: [])
    }
}

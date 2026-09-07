import Foundation

// Runtime-facing terminal port (architecture §2.3/§3.10). AgentCore never
// touches libghostty; it only states *what* must happen. Signal intents are
// modeled as decisions — the actual POSIX signals belong to TerminalKit.

public struct TerminalSnapshot: Equatable, Sendable {
    /// Normalized screen text: last rows, CRLF normalized, trailing spaces
    /// stripped, independent of the user's scroll position (§3.7).
    public var text: String
    public var outputRevision: UInt64
    public var generation: SurfaceGeneration

    public init(text: String, outputRevision: UInt64, generation: SurfaceGeneration) {
        self.text = text
        self.outputRevision = outputRevision
        self.generation = generation
    }
}

public enum TerminalReadSource: String, Sendable {
    /// The current viewport (user-facing `agent.read visible`).
    case visible
    /// The live bottom screen used by the detector.
    case detection
}

public enum SignalIntent: String, Sendable, Codable {
    /// SIGINT / Ctrl-C.
    case interrupt
    /// SIGTERM to the process group.
    case terminate
    /// SIGKILL after the 2 s graceful-stop grace period expired.
    case kill
}

public protocol TerminalControlling: Sendable {
    /// Delivers prompt text via the bracketed-paste-compatible input path and,
    /// when `submit` is true, follows with Return (§3.11 watchdog steps 2–3).
    func deliverInput(_ terminalID: TerminalID, text: String, submit: Bool) async throws

    func sendKeys(_ terminalID: TerminalID, keys: [String]) async throws

    /// Sends a signal intent to the process group of the terminal.
    func sendSignal(_ intent: SignalIntent, to terminalID: TerminalID) async throws

    func read(_ terminalID: TerminalID, source: TerminalReadSource) async throws -> TerminalSnapshot?
}

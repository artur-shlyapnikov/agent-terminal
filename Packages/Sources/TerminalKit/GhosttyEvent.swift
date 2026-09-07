import AgentCore
import Foundation

// Typed callback events (architecture §3.18 step 4): the bridge translates a
// libghostty action into owned plain-C data; this layer turns that into a
// Sendable value that can safely cross a task hop onto the main actor.
//
// Child-exit policy note (ADR-0002 finding 5): `.childExited` is an
// OPPORTUNISTIC accelerator. Delivery of SHOW_CHILD_EXITED was suppressed in
// multi-surface runs, so process-exit evidence is gathered primarily by
// polling the surface (`TerminalSessionManager.process-exit poller`); this
// event merely accelerates detection when it does arrive. Exit codes from any
// path are best-effort on Darwin.

public struct GhosttyProgressState: Equatable, Sendable {
    public enum Value: Sendable, Equatable {
        case remove
        case set
        case error
        case indeterminate
        case pause
    }

    public let value: Value
    /// -1 when no percentage was reported, otherwise 0...100.
    public let percent: Int8

    public init(value: Value, percent: Int8) {
        self.value = value
        self.percent = percent
    }
}

public enum TerminalURLKind: Equatable, Sendable {
    case unknown
    case text
    case html
    case osc8
}

public enum GhosttyMouseShape: Equatable, Sendable {
    case unknown
    case text
    case pointer
    case progress
    case wait
    case crosshair
    case other(Int32)
}

/// A single terminal observation delivered from the engine onto the main
/// actor, already tagged with the owning terminal identity and generation.
public struct GhosttyEvent: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        /// Renderer produced new output — bumps outputRevision (§3.7).
        case render
        case title(String)
        case pwd(String)
        /// Opportunistic child-exit accelerator (see file header).
        case childExited(exitCode: UInt32)
        case commandFinished(exitCode: Int16, durationNanoseconds: UInt64)
        case progress(GhosttyProgressState)
        case bell
        case selectionChanged
        case notification(title: String, body: String)
        case openURL(kind: TerminalURLKind, url: String)
        case mouseShape(GhosttyMouseShape)
        /// App-targeted close request; structural decisions belong to the app.
        case closeWindowRequested(processAlive: Bool)
    }

    /// nil for app-targeted events (e.g. close-window requests).
    public let terminalID: TerminalID?
    /// Generation captured at delivery; consumers re-validate against their
    /// registry before acting (§3.18 step 6).
    public let generation: SurfaceGeneration?
    public let payload: Payload

    public init(
        terminalID: TerminalID?,
        generation: SurfaceGeneration?,
        payload: Payload
    ) {
        self.terminalID = terminalID
        self.generation = generation
        self.payload = payload
    }
}

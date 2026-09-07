import AgentCore
import AppKit
import GhosttyBridge

// Internal terminal abstraction (architecture §4.3): every concrete libghostty
// interaction lives behind these two protocols so TerminalSessionManager and
// friends are testable against fakes with zero ghostty involvement.
//
// Isolation model (§3.18): engines/surfaces are @MainActor-owned; the only
// cross-thread surface is SurfaceCallbackBox (GhosttyCallbackRouter.swift).

/// Modifiers mirroring the bridge's AGTMods* bit values.
public struct KeyModifiers: OptionSet, Sendable, Equatable, Hashable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let numericPad = KeyModifiers(rawValue: 1 << 5)
}

public enum KeyEventAction: Int32, Sendable {
    case release = 0
    case press = 1
    case repeatKey = 2
}

/// A single hardware-style key event (bridge AGTKeyEvent mirror). `text` is
/// encoded synchronously during send; no pointer escapes.
public struct GhosttyKeyEvent: Sendable, Equatable {
    public var action: KeyEventAction
    public var modifiers: KeyModifiers
    public var consumedModifiers: KeyModifiers
    /// macOS virtual keycode (what libghostty expects on this platform).
    public var keycode: UInt32
    public var text: String?
    public var unshiftedCodepoint: UInt32
    public var composing: Bool

    public init(
        action: KeyEventAction,
        modifiers: KeyModifiers = [],
        consumedModifiers: KeyModifiers = [],
        keycode: UInt32,
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0,
        composing: Bool = false
    ) {
        self.action = action
        self.modifiers = modifiers
        self.consumedModifiers = consumedModifiers
        self.keycode = keycode
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
        self.composing = composing
    }
}

public enum MouseButtonState: Int32, Sendable {
    case release = 0
    case press = 1
}

public enum MouseButton: Int32, Sendable {
    case unknown = 0
    case left = 1
    case right = 2
    case middle = 3
    case four = 4
    case five = 5
}

/// Launch material for one surface (§3.9). `command` is an exact argv string
/// word-split and exec'd by libghostty WITHOUT shell interpolation.
public struct TerminalLaunchSpec: Sendable, Equatable {
    var workingDirectory: String
    var command: String?
    var environment: [String: String]
    var initialInput: String?
    var waitAfterCommand: Bool
    var fontSize: Float?

    public init(
        workingDirectory: String,
        command: String? = nil,
        environment: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        fontSize: Float? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.fontSize = fontSize
    }
}

/// One live native surface handle owned by an engine implementation.
/// All methods run on the main actor; `performFree()` is the two-phase
/// teardown phase-2 entry point and MUST be main-thread (ADR-0002).
@MainActor public protocol NativeTerminalSurface: AnyObject {
    func setFocus(_ focused: Bool)
    func setOccluded(_ occluded: Bool)
    func resize(widthPixels: UInt32, heightPixels: UInt32, scaleFactor: Double)
    /// IME-style text commit (arbitrary Unicode incl. newlines).
    func sendText(_ text: String)
    @discardableResult
    func sendKey(_ key: GhosttyKeyEvent) -> Bool
    func sendPreedit(_ text: String?)
    @discardableResult
    func mouseButton(state: MouseButtonState, button: MouseButton, modifiers: KeyModifiers) -> Bool
    func mousePosition(x: Double, y: Double, modifiers: KeyModifiers)
    func mouseScroll(dx: Double, dy: Double, packedModifiers: Int32)

    /// Poll-based child-exit evidence — PRIMARY lifecycle signal (ADR-0002
    /// finding 5); the SHOW_CHILD_EXITED action is opportunistic only.
    func isProcessExited() -> Bool
    /// Foreground child pid, 0 when unknown/exited.
    func foregroundPID() -> UInt64
    func gridSize() -> (columns: UInt32, rows: UInt32)?
    /// Live active screen including scrollback; independent of user scroll.
    func readScreen() -> String?
    /// What the user currently sees (viewport).
    func readViewport() -> String?
    /// Native free; consumes the handle. Called exactly once, on the main thread.
    func performFree()
}

/// Engine abstraction over the process-global libghostty runtime.
/// Implemented by GhosttyEngine (real) and FakeEngine (tests).
@MainActor public protocol TerminalEngine: AnyObject {
    /// Sink for surface-targeted and app-targeted typed events.
    var eventSink: (@MainActor (GhosttyEvent) -> Void)? { get set }
    /// Drives pending work; called repeatedly from the main loop.
    func tick()
    /// Creates a native surface rendering into `view`. `box` receives the
    /// surface-targeted callbacks and must stay alive until performFree.
    func createSurface(
        view: NSView,
        spec: TerminalLaunchSpec,
        box: SurfaceCallbackBox
    ) throws -> any NativeTerminalSurface
    /// Shuts the runtime down; all surfaces must already be freed.
    func shutdown()
}

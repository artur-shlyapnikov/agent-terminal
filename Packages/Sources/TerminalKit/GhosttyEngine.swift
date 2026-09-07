import AgentCore
import AppKit
import GhosttyBridge

// Global app/config/runtime owner (architecture §3.8). @MainActor singleton
// per process; created only by the AppCompositionRoot (or tests/spikes).
//
// Tick strategy: wake-gated — libghostty is driven by ghostty_app_tick only
// when a wakeup (render-ready signal from any thread) is pending, coalesced
// through the WakeupFlag; a 120 Hz main-runloop timer polls the flag (cheap
// consume) and doubles as a ~1 Hz forced heartbeat for tick-needs libghostty
// never signals.

/// Wakeup flag safe to set from any thread.
final class WakeupFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    /// Returns true when a wakeup was pending (and consumes it).
    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let had = value
        value = false
        return had
    }
}

@MainActor public final class GhosttyEngine: TerminalEngine {
    public var eventSink: (@MainActor (GhosttyEvent) -> Void)?

    let router = GhosttyCallbackRouter()
    var clipboardBridge: ClipboardBridge?

    private let nativeRuntime: UnsafeMutableRawPointer
    private var tickTimer: Timer?
    /// Set by shutdown(); ticks after teardown would hit the freed runtime.
    private var isShutdown = false

    /// Live surfaces created by this engine. An engine released with zero
    /// live surfaces can safely free the native runtime from deinit (the
    /// abandoned-engine case: leaving g_active_runtime set would make every
    /// later agt_bridge_runtime_create fail for the whole process).
    private var liveSurfaceCount = 0
    private let wakeup = WakeupFlag()
    public private(set) var tickCount = 0
    /// Reentrancy guard: a nested wakeup raised DURING a tick sets the
    /// WakeupFlag and is deferred to the next timer fire instead of
    /// recursing through ghostty from inside a tick.
    private var ticking = false

    public static func globalInit() throws {
        guard agt_bridge_global_init() == AGTStatusOK else {
            throw TerminalEngineError.bridgeInitializationFailed
        }
    }

    public convenience init() throws {
        try self.init(configLoader: GhosttyConfigLoader(), clipboardBridge: ClipboardBridge())
    }

    public convenience init(configLoader: GhosttyConfigLoader) throws {
        try self.init(configLoader: configLoader, clipboardBridge: ClipboardBridge())
    }

    public init(configLoader: GhosttyConfigLoader, clipboardBridge: ClipboardBridge) throws {
        try Self.globalInit()
        self.clipboardBridge = clipboardBridge

        var callbacks = AGTRuntimeCallbacks()
        router.installCallbacks(into: &callbacks)

        // ADR-0002 finding 2: userdata must be installed before app creation;
        // the bridge copies the callback struct before ghostty_app_new.
        var runtimeOut: UnsafeMutableRawPointer?
        let configPath = configLoader.existingConfigPath()
        let status = agt_bridge_runtime_create(configPath, &callbacks, &runtimeOut)
        guard status == AGTStatusOK, let runtimeOut else {
            throw TerminalEngineError.runtimeCreationFailed(status: Int(status.rawValue))
        }
        nativeRuntime = runtimeOut

        router.delegate = self
        router.clipboardReadPolicy = clipboardBridge.readPolicyClosure
        startTicking()
    }

    deinit {
        // Surfaces must have been torn down first (§3.8 teardown ordering);
        // shutdown() performs the actual free. The tick timer, however, must
        // not outlive the engine: RunLoop.main retains its timers, so an
        // owner that drops the engine without shutdown() (real: tests that
        // never call shutdown) would leave a 120 Hz no-op timer firing
        // forever. Invalidate via the main queue — safe from any thread.
        // Timer is main-thread confined (created on and added to RunLoop.main);
        // deinit may run off-main, so the reference crosses into the main-queue
        // closure as nonisolated(unsafe) and invalidate() runs on the main
        // thread. No other accessor survives deinit entry, so the transfer is
        // sound despite Timer not being Sendable.
        nonisolated(unsafe) let timer = tickTimer
        DispatchQueue.main.async {
            timer?.invalidate()
        }
        // An abandoned surfaceless engine must not leak g_active_runtime:
        // the bridge rejects every later runtime_create while it stays set,
        // permanently breaking engine creation for the process. Surfaces
        // still alive at deinit keep the runtime alive with them (freeing
        // under live native handles would dangle them) — the residual
        // limitation is deliberate.
        let surfacesLive = liveSurfaceCount > 0
        if !isShutdown, !surfacesLive {
            isShutdown = true
            agt_bridge_runtime_free(nativeRuntime)
        }
    }

    // MARK: configuration diagnostics

    public var diagnosticCount: UInt32 {
        // Diagnostics live in the native runtime; report none after teardown.
        guard !isShutdown else { return 0 }
        return agt_bridge_runtime_diagnostic_count(nativeRuntime)
    }

    public func diagnostic(at index: UInt32) -> String? {
        guard !isShutdown else { return nil }
        guard let message = agt_bridge_runtime_diagnostic(nativeRuntime, index) else {
            return nil
        }
        defer { agt_bridge_string_free(message) }
        return String(cString: message)
    }

    // MARK: ticking

    private func startTicking() {
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Called from the wakeup trampoline (already on the main actor via
    /// performOnMain). Sets the flag and ticks synchronously — no second
    /// async hop: native callbacks during a tick usually land on main, so
    /// the extra DispatchQueue.main.async only added latency.
    func engineWantsTick() {
        wakeup.set()
        tickIfNeeded()
    }

    /// Runs on the main actor from two places only: engineWantsTick() and
    /// the 120 Hz timer. Ticks the runtime only when a wakeup is actually
    /// pending; otherwise it is a cheap flag poll plus the ~1 Hz heartbeat.
    ///
    /// engineWantsTick() runs synchronously and tick() is public: all can
    /// land after shutdown(), so never touch the freed runtime.
    private func tickIfNeeded() {
        guard !isShutdown, !ticking else { return }
        guard wakeup.consume() else {
            // Heartbeat safety net: with no wakeup pending, force one real
            // tick per second so an unknown tick-need that never raised a
            // wakeup still gets served eventually.
            tickCount += 1
            if tickCount % 120 == 0 {
                print("[UIX-DEBUG] heartbeat tick #\(tickCount)")
                agt_bridge_runtime_tick(nativeRuntime)
            }
            return
        }
        ticking = true
        defer { ticking = false }
        agt_bridge_runtime_tick(nativeRuntime)
        tickCount += 1
    }

    public func tick() {
        tickIfNeeded()
    }

    // MARK: surfaces

    public func createSurface(
        view: NSView,
        spec: TerminalLaunchSpec,
        box: SurfaceCallbackBox
    ) throws -> any NativeTerminalSurface {
        // Never touch the freed native runtime after shutdown().
        guard !isShutdown else { throw TerminalEngineError.runtimeShutdown }
        view.wantsLayer = true

        // The bridge copies every string during create, but the C call itself
        // borrows them; strdup/free gives unambiguous lifetime.
        let workingDirectoryC: UnsafeMutablePointer<CChar>? = strdup(spec.workingDirectory)
        let commandC: UnsafeMutablePointer<CChar>? = spec.command.flatMap { strdup($0) }
        let initialInputC: UnsafeMutablePointer<CChar>? = spec.initialInput.flatMap { strdup($0) }
        // Key/value are strdup'd together as one pair so allocation can never
        // desync the pairing (or shift the envVars index map); any strdup
        // failure aborts the whole surface creation.
        let sortedEnv = spec.environment.sorted { $0.key < $1.key }
        let envPairs: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] =
            sortedEnv.compactMap { pair in
                let keyC = strdup(pair.key)
                let valueC = strdup(pair.value)
                guard let key = keyC, let value = valueC else {
                    // Free whichever half of this pair succeeded; the defer
                    // below frees all previously completed pairs.
                    keyC.map { free($0) }
                    valueC.map { free($0) }
                    return nil
                }
                return (key, value)
            }
        defer {
            free(workingDirectoryC)
            commandC.map { free($0) }
            initialInputC.map { free($0) }
            envPairs.forEach { free($0.0); free($0.1) }
        }
        guard envPairs.count == sortedEnv.count else {
            throw TerminalEngineError.environmentAllocationFailed
        }

        var envVars: [AGTEnvVar] = envPairs.map { AGTEnvVar(key: $0.0, value: $0.1) }

        var config = AGTSurfaceConfig()
        config.nsview = Unmanaged.passUnretained(view).toOpaque()
        config.working_directory = UnsafePointer(workingDirectoryC)
        config.command = commandC.map { UnsafePointer($0) }
        config.env_var_count = envVars.count
        config.initial_input = initialInputC.map { UnsafePointer($0) }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        config.scale_factor = Double(scale)
        config.font_size = spec.fontSize ?? 0
        config.wait_after_command = spec.waitAfterCommand
        config.userdata = Unmanaged.passUnretained(box).toOpaque()

        var surfaceOut: UnsafeMutableRawPointer?
        var status: AGTStatusCode
        if envVars.isEmpty {
            config.env_vars = nil
            status = agt_bridge_surface_create(nativeRuntime, &config, &surfaceOut)
        } else {
            status = envVars.withUnsafeMutableBufferPointer { buffer in
                config.env_vars = buffer.baseAddress.map { UnsafePointer($0) }
                return agt_bridge_surface_create(nativeRuntime, &config, &surfaceOut)
            }
        }
        guard status == AGTStatusOK, let surfaceOut else {
            throw TerminalEngineError.surfaceCreationFailed(status: Int(status.rawValue))
        }
        let handle = GhosttySurfaceHandle(pointer: surfaceOut)
        liveSurfaceCount += 1
        handle.onFree = { [weak self] in self?.liveSurfaceCount -= 1 }
        return handle
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        tickTimer?.invalidate()
        tickTimer = nil
        agt_bridge_runtime_free(nativeRuntime)
    }
}

public enum TerminalEngineError: Error, Equatable {
    case bridgeInitializationFailed
    case runtimeCreationFailed(status: Int)
    case surfaceCreationFailed(status: Int)
    case environmentAllocationFailed
    case runtimeShutdown
}

// MARK: - Native handle over one bridge surface

/// Thin main-actor wrapper translating NativeTerminalSurface calls into
/// bridge calls. Owns the bridge surface handle until performFree.
@MainActor final class GhosttySurfaceHandle: NativeTerminalSurface {
    private let pointer: UnsafeMutableRawPointer
    /// Invoked exactly once when the native surface is freed.
    var onFree: (() -> Void)?
    private(set) var freed = false

    init(pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }

    private var isLive: Bool {
        !freed
    }

    func setFocus(_ focused: Bool) {
        guard isLive else { return }
        agt_bridge_surface_set_focus(pointer, focused)
    }

    func setOccluded(_ occluded: Bool) {
        guard isLive else { return }
        agt_bridge_surface_set_occlusion(pointer, occluded)
    }

    func resize(widthPixels: UInt32, heightPixels: UInt32, scaleFactor: Double) {
        guard isLive else { return }
        agt_bridge_surface_set_content_scale(pointer, scaleFactor)
        agt_bridge_surface_set_size(
            pointer,
            UInt32(max(1, widthPixels)),
            UInt32(max(1, heightPixels))
        )
    }

    func sendText(_ text: String) {
        guard isLive else { return }
        text.utf8CString.withUnsafeBufferPointer { buffer in
            // utf8CString is NUL-terminated; pass the exact byte count so no
            // terminator reaches the terminal.
            let length = buffer.count - 1
            guard length > 0, let base = buffer.baseAddress else { return }
            agt_bridge_surface_send_text(pointer, base, length)
        }
    }

    @discardableResult
    func sendKey(_ key: GhosttyKeyEvent) -> Bool {
        guard isLive else { return false }
        // The text pointer lives inside a by-value C struct: pin its storage
        // for the call duration (spike lesson — Swift string bridging into a
        // by-value struct is not lifetime-guaranteed).
        let textStorage: UnsafeMutablePointer<CChar>? = key.text.flatMap { strdup($0) }
        defer { textStorage.map { free($0) } }

        var native = AGTKeyEvent()
        native.action = key.action.rawValue
        native.mods = key.modifiers.rawValue
        native.consumed_mods = key.consumedModifiers.rawValue
        native.keycode = key.keycode
        native.text = textStorage.map { UnsafePointer($0) }
        native.unshifted_codepoint = key.unshiftedCodepoint
        native.composing = key.composing
        return agt_bridge_surface_send_key(pointer, &native)
    }

    func sendPreedit(_ text: String?) {
        guard isLive else { return }
        let storage: UnsafeMutablePointer<CChar>? = text.flatMap { strdup($0) }
        defer { storage.map { free($0) } }
        let length: Int = storage == nil ? 0 : Int(strlen(storage!))

        let preeditPtr: UnsafePointer<CChar>? = storage.map { UnsafePointer($0) }
        agt_bridge_surface_send_preedit(pointer, preeditPtr, length)
    }

    @discardableResult
    func mouseButton(state: MouseButtonState, button: MouseButton, modifiers: KeyModifiers) -> Bool {
        guard isLive else { return false }
        return agt_bridge_surface_mouse_button(pointer, state.rawValue, button.rawValue, modifiers.rawValue)
    }

    func mousePosition(x: Double, y: Double, modifiers: KeyModifiers) {
        guard isLive else { return }
        agt_bridge_surface_mouse_pos(pointer, x, y, modifiers.rawValue)
    }

    func mouseScroll(dx: Double, dy: Double, packedModifiers: Int32) {
        guard isLive else { return }
        agt_bridge_surface_mouse_scroll(pointer, dx, dy, packedModifiers)
    }

    func isProcessExited() -> Bool {
        guard isLive else { return true }
        return agt_bridge_surface_process_exited(pointer)
    }

    func foregroundPID() -> UInt64 {
        guard isLive else { return 0 }
        return agt_bridge_surface_foreground_pid(pointer)
    }

    func gridSize() -> (columns: UInt32, rows: UInt32)? {
        var columns: UInt32 = 0
        var rows: UInt32 = 0
        guard isLive else { return nil }
        agt_bridge_surface_grid_size(pointer, &columns, &rows)
        return columns > 0 ? (columns, rows) : nil
    }

    func readScreen() -> String? {
        readRegion { agt_bridge_surface_read_screen(pointer, $0, $1) }
    }

    func readViewport() -> String? {
        readRegion { agt_bridge_surface_read_viewport(pointer, $0, $1) }
    }

    private func readRegion(
        _ reader: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<Int>) -> AGTStatusCode
    ) -> String? {
        guard isLive else { return nil }
        var textOut: UnsafeMutablePointer<CChar>?
        var lengthOut = 0
        guard reader(&textOut, &lengthOut) == AGTStatusOK, let textOut else { return nil }
        defer { agt_bridge_string_free(textOut) }
        // Decode exactly `lengthOut` bytes: the bridge contract says the
        // length EXCLUDES the terminator but the payload itself may contain
        // embedded NULs — String(cString:) would truncate silently.
        return Self.decodeBridgeText(textOut, length: lengthOut)
    }

    /// Internal so the bridge-level decode contract is unit-testable without
    /// a live libghostty surface.
    static func decodeBridgeText(_ base: UnsafePointer<CChar>, length: Int) -> String {
        String(decoding: UnsafeRawBufferPointer(start: base, count: max(0, length)), as: UTF8.self)
    }

    /// Teardown phase 2 (main thread enforced by the teardown queue).
    func performFree() {
        guard !freed else { return }
        freed = true
        agt_bridge_surface_free(pointer)
        onFree?()
    }
}

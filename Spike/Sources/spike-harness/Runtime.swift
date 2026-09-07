import AppKit
import CGhostty
import Foundation

// MARK: - Recorded runtime events

struct RecordedAction {
    var tag: ghostty_action_tag_e
    var surface: UnsafeMutableRawPointer?
    var childExitCode: Int32?
    var text: String?
}

// MARK: - Wakeup flag (thread-safe)

final class WakeupFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
    @discardableResult
    func clear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let v = value
        value = false
        return v
    }
}

// MARK: - Surface context box (generation-guard style)

/// Retained by the registry for the whole lifetime of a surface. The
/// `userdata` handed to libghostty points at an *unretained* box.
/// Teardown policy under test: remove from registry BEFORE native free,
/// drop the retained box only after free returns (two-phase teardown).
final class SurfaceBox {
    let id: Int
    weak var runtime: GhosttyRuntime?
    var closing = false

    init(id: Int, runtime: GhosttyRuntime) {
        self.id = id
        self.runtime = runtime
    }
}

// MARK: - SpikeSurface

final class SpikeSurface {
    let native: UnsafeMutableRawPointer
    let box: SurfaceBox
    unowned let runtime: GhosttyRuntime
    private(set) var view: NSView

    // Storage that must outlive the native surface (C pointers into it).
    private let workingDirNS: NSString
    private let commandNS: NSString?
    private let inputNS: NSString?
    private let envKeyNS: [NSString]
    private let envValNS: [NSString]

    var rawPtr: UnsafeMutableRawPointer { UnsafeMutableRawPointer(native) }

    init(runtime: GhosttyRuntime,
         view: NSView,
         command: String?,
         initialInput: String?,
         env: [String: String],
         workingDirectory: String,
         waitAfterCommand: Bool) throws {
        self.runtime = runtime
        self.view = view
        self.box = SurfaceBox(id: runtime.nextSurfaceID(), runtime: runtime)

        workingDirNS = workingDirectory as NSString
        commandNS = command as NSString?
        inputNS = initialInput as NSString?
        envKeyNS = env.keys.sorted().map { $0 as NSString }
        envValNS = env.keys.sorted().map { env[$0]! as NSString }

        view.wantsLayer = true

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(box).toOpaque()
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        cfg.scale_factor = Double(scale)
        cfg.working_directory = workingDirNS.utf8String!
        if let c = commandNS?.utf8String { cfg.command = c }
        cfg.wait_after_command = waitAfterCommand
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        if !envKeyNS.isEmpty {
            var pairs: [ghostty_env_var_s] = []
            for i in 0..<envKeyNS.count {
                pairs.append(ghostty_env_var_s(key: envKeyNS[i].utf8String!,
                                               value: envValNS[i].utf8String!))
            }
            cfg.env_vars = UnsafeMutablePointer(mutating: pairs)
            cfg.env_var_count = pairs.count
        }
        if let i = inputNS?.utf8String { cfg.initial_input = i }

        guard let surf = ghostty_surface_new(runtime.app, &cfg) else {
            throw RuntimeError.surfaceCreationFailed
        }
        native = surf

        runtime.register(self)
        layoutSurface()
    }

    func layoutSurface() {
        guard let win = view.window else { return }
        let scale = win.backingScaleFactor
        let px = UInt32(max(1, view.frame.size.width * scale))
        let py = UInt32(max(1, view.frame.size.height * scale))
        ghostty_surface_set_content_scale(native, Double(scale), Double(scale))
        ghostty_surface_set_size(native, px, py)
    }

    // MARK: state probes

    var foregroundPID: pid_t { pid_t(ghostty_surface_foreground_pid(native)) }
    var processExited: Bool { ghostty_surface_process_exited(native) }

    var sizeInfo: (columns: Int, rows: Int) {
        let s = ghostty_surface_size(native)
        return (Int(s.columns), Int(s.rows))
    }

    // MARK: reading

    static func readText(_ surf: UnsafeMutableRawPointer, tag: ghostty_point_tag_e) -> String? {
        var sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surf, sel, &out), out.text != nil else { return nil }
        defer { ghostty_surface_free_text(surf, &out) }
        let data = Data(bytes: out.text!, count: Int(out.text_len))
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func read(tag: ghostty_point_tag_e) -> String? {
        SpikeSurface.readText(native, tag: tag)
    }

    // MARK: input

    func sendText(_ text: String) {
        ghostty_surface_text(native, text, uintptr_t(text.utf8.count))
    }

    /// Diagnostics: return values of the last ghostty_surface_key calls
    /// (true = ghostty consumed/encoded the key).
    private(set) var keyReturns: [Bool] = []

    func resetKeyReturns() {
        keyReturns.removeAll()
    }

    /// Sends a hardware key press+release through ghostty_surface_key.
    /// IMPORTANT: the text pointer lives inside a by-value C struct, so the
    /// backing storage must be pinned with utf8CString for the call duration
    /// (Swift string-to-pointer bridging is not guaranteed there).
    func sendKey(keycode: UInt32, text: String, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
        let press = text.utf8CString.withUnsafeBufferPointer { buf -> Bool in
            ghostty_surface_key(native, ghostty_input_key_s(
                action: GHOSTTY_ACTION_PRESS,
                mods: mods,
                consumed_mods: GHOSTTY_MODS_NONE,
                keycode: keycode,
                text: buf.baseAddress,
                unshifted_codepoint: buf.count > 1 ? UInt32(buf[0]) : 0,
                composing: false))
        }
        let release = "\u{0}".utf8CString.withUnsafeBufferPointer { _ -> Bool in
            ghostty_surface_key(native, ghostty_input_key_s(
                action: GHOSTTY_ACTION_RELEASE,
                mods: mods,
                consumed_mods: GHOSTTY_MODS_NONE,
                keycode: keycode,
                text: nil,
                unshifted_codepoint: 0,
                composing: false))
        }
        keyReturns.append(press)
        keyReturns.append(release)
    }

    func scroll(deltaY: Double, times: Int) {
        for _ in 0..<times {
            // C signature is (surface, x, y, mods): vertical delta is y.
            ghostty_surface_mouse_scroll(native, 0, deltaY, ghostty_input_scroll_mods_t(0))
        }
    }

    func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(native, focused)
    }

    func setOccluded(_ occluded: Bool) {
        ghostty_surface_set_occlusion(native, occluded)
    }

    /// Two-phase teardown per ADR-0002 policy:
    /// 1. generation-guard off callbacks, remove from registry
    /// 2. native free on the calling (main) thread
    /// 3. release the callback box only after free returns.
    func freeOnMainThread() {
        guard !box.closing else { return }
        box.closing = true
        runtime.unregister(self)          // phase 1: drop callbacks by identity
        ghostty_surface_free(native)      // phase 2: confirmed main-thread context
        // phase 3: `box` reference dies with self
    }
}

enum RuntimeError: Error {
    case surfaceCreationFailed
}

// MARK: - Footprint sampling

enum Footprint {
    static func current() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MiB", Double(bytes) / 1048576.0)
    }
}

// MARK: - GhosttyRuntime

final class GhosttyRuntime {
    let app: UnsafeMutableRawPointer
    let wakeup = WakeupFlag()
    private(set) var tickCount = 0
    private(set) var wakeupsReceived = 0
    private(set) var actions: [RecordedAction] = []
    private(set) var closeRequests: [(surface: UnsafeMutableRawPointer?, processAlive: Bool)] = []

    private var surfaces: [UnsafeMutableRawPointer: SpikeSurface] = [:]
    private var nextID = 1
    private var tickTimer: DispatchSourceTimer?

    /// libghostty clones the runtime config inside ghostty_app_new, so the
    /// userdata pointer must be valid BEFORE app creation. We route all
    /// callbacks through a stable box that is wired to `self` post-init.
    final class CallbackBox {
        weak var rt: GhosttyRuntime?
    }

    private static let callbackBox = CallbackBox()

    /// C callback trampolines must outlive the app; stored statically.
    private static var runtimeConfig: ghostty_runtime_config_s = {
        var rc = ghostty_runtime_config_s()
        rc.supports_selection_clipboard = false
        rc.userdata = Unmanaged.passRetained(callbackBox).toOpaque()
        rc.wakeup_cb = { ud in
            guard let ud, let rt = Unmanaged<CallbackBox>.fromOpaque(ud).takeUnretainedValue().rt else { return }
            rt.wakeup.set()
            DispatchQueue.main.async { rt.tickIfWakeup() }
        }
        rc.action_cb = { _, target, action in
            GhosttyRuntime.handleAction(target: target, action: action)
            return true
        }
        rc.read_clipboard_cb = { _, _, _ in false }
        rc.confirm_read_clipboard_cb = { _, _, _, _ in }
        rc.write_clipboard_cb = { _, _, _, _, _ in }
        rc.close_surface_cb = { ud, processAlive in
            guard let ud, let rt = Unmanaged<CallbackBox>.fromOpaque(ud).takeUnretainedValue().rt else { return }
            rt.recordClose(nil, processAlive)
        }
        return rc
    }()

    private static var didInit = false

    init(configPath: String?) throws {
        if !GhosttyRuntime.didInit {
            var argv = [UnsafeMutablePointer<CChar>?](repeating: nil, count: 1)
            let rc = ghostty_init(0, nil)
            precondition(rc == GHOSTTY_SUCCESS, "ghostty_init failed")
            GhosttyRuntime.didInit = true
        }
        let config = ghostty_config_new()
        if let configPath {
            ghostty_config_load_file(config, configPath)
        }
        ghostty_config_finalize(config)
        let diags = ghostty_config_diagnostics_count(config)
        if diags > 0 {
            for i in 0..<diags {
                let d = ghostty_config_get_diagnostic(config, i)
                print("[config-diagnostic] \(String(cString: d.message))")
            }
        }

        guard let a = ghostty_app_new(&Self.runtimeConfig, config) else {
            throw RuntimeError.surfaceCreationFailed
        }
        app = a
        Self.callbackBox.rt = self
        startTicking()
    }

    deinit {
        stopTicking()
        ghostty_app_free(app)
    }

    // MARK: registry / ids

    func nextSurfaceID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    func register(_ s: SpikeSurface) {
        surfaces[s.rawPtr] = s
    }

    /// Phase 1 of teardown: identity-keyed callback suppression.
    func unregister(_ s: SpikeSurface) {
        surfaces.removeValue(forKey: s.rawPtr)
    }

    func surface(forRaw ptr: UnsafeMutableRawPointer?) -> SpikeSurface? {
        guard let ptr else { return nil }
        return surfaces[ptr]
    }

    var liveSurfaces: [SpikeSurface] { Array(surfaces.values.sorted { $0.box.id < $1.box.id }) }

    // MARK: events

    fileprivate func recordClose(_ surface: UnsafeMutableRawPointer?, _ processAlive: Bool) {
        if Thread.isMainThread {
            closeRequests.append((surface, processAlive))
        } else {
            DispatchQueue.main.async { self.closeRequests.append((surface, processAlive)) }
        }
    }

    nonisolated static func handleAction(target: ghostty_target_s, action: ghostty_action_s) {
        // Copy everything we need out of the payload immediately; the
        // payload is only valid during this callback.
        var rec = RecordedAction(tag: action.tag, surface: nil, childExitCode: nil, text: nil)
        if target.tag == GHOSTTY_TARGET_SURFACE {
            rec.surface = target.target.surface
        }
        switch action.tag {
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            rec.childExitCode = Int32(action.action.child_exited.exit_code)
        case GHOSTTY_ACTION_SET_TITLE:
            rec.text = action.action.set_title.title.map { String(cString: $0) }
        case GHOSTTY_ACTION_PWD:
            rec.text = action.action.pwd.pwd.map { String(cString: $0) }
        default:
            break
        }
        DispatchQueue.main.async {
            // Delivered to whichever runtime owns the app; there is exactly
            // one per process in the spike, found via the live surfaces' box.
            GhosttyRuntime.shared?.actions.append(rec)
        }
    }

    static weak var shared: GhosttyRuntime?

    // MARK: ticking

    private func startTicking() {
        GhosttyRuntime.shared = self
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            ghostty_app_tick(self.app)
            self.tickCount += 1
            if self.wakeup.clear() {
                self.wakeupsReceived += 1
            }
        }
        timer.resume()
        tickTimer = timer
    }

    func stopTicking() {
        tickTimer?.cancel()
        tickTimer = nil
    }

    func tickIfWakeup() {
        guard wakeup.isSet else { return }
        ghostty_app_tick(app)
        tickCount += 1
        if wakeup.clear() { wakeupsReceived += 1 }
    }

    // MARK: surface factory

    func makeSurface(view: NSView,
                     command: String?,
                     initialInput: String? = nil,
                     env: [String: String] = [:],
                     workingDirectory: String = "/tmp",
                     waitAfterCommand: Bool = false) throws -> SpikeSurface {
        try SpikeSurface(runtime: self,
                         view: view,
                         command: command,
                         initialInput: initialInput,
                         env: env,
                         workingDirectory: workingDirectory,
                         waitAfterCommand: waitAfterCommand)
    }

    // MARK: waiting helpers (must be called from the main thread; pumps runloop)

    @discardableResult
    func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.05,
                   _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
        }
        return condition()
    }

    func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func actionsFor(_ surface: SpikeSurface) -> [RecordedAction] {
        actions.filter { $0.surface == surface.rawPtr }
    }

    @discardableResult
    func waitForAction(_ surface: SpikeSurface, tag: ghostty_action_tag_e,
                       timeout: TimeInterval) -> RecordedAction? {
        waitUntil(timeout: timeout) { !self.actionsFor(surface).filter { $0.tag == tag }.isEmpty }
        return actionsFor(surface).first { $0.tag == tag }
    }
}

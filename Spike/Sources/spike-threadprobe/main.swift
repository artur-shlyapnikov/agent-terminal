import AppKit
import CGhostty

// ---------------------------------------------------------------------------
// spike-threadprobe: isolated experiment for plan §6.0 item 13.
//
// Creates one live ghostty surface, then dispatches ghostty_surface_free on a
// background queue while main-thread ticking is paused. Reports:
//   stdout "FREE_DISPATCHED"  -> free call was entered off-main
//   exit 42                   -> survived: free returned, post-free ticks stable
//   crash signal              -> crashed during/after off-main free
// ---------------------------------------------------------------------------

final class ProbeToken {} // stable userdata identity for runtime callbacks

var probeApp: UnsafeMutableRawPointer?
var probeSurface: UnsafeMutableRawPointer?
var probeView: NSView!
var probeWindow: NSWindow!
var tickTimer: DispatchSourceTimer?
var wakeups = 0
let freed = DispatchSemaphore(value: 0)

var mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "free"
var cmdStorage = mode == "exit" ? "/bin/sh /tmp/spike-exit-helper.sh" : "/bin/sleep 60"
var wdStorage = "/tmp"
var waitAfter = mode == "exit"
var seenTags: [UInt32] = []
var ticks = 0

func cstr(_ s: String) -> UnsafePointer<CChar> { (s as NSString).utf8String! }

var runtimeConfig: ghostty_runtime_config_s = {
    var rc = ghostty_runtime_config_s()
    rc.supports_selection_clipboard = false
    rc.userdata = Unmanaged.passRetained(ProbeToken()).toOpaque()
    rc.wakeup_cb = { ud in
        wakeups += 1
        if ProcessInfo.processInfo.environment["DOUBLE_TICK"] == "1" {
            DispatchQueue.main.async { if let a = probeApp { ghostty_app_tick(a) } }
        }
    }
    rc.action_cb = { _, _, action in
        seenTags.append(action.tag.rawValue)
        return true
    }
    rc.read_clipboard_cb = { _, _, _ in false }
    rc.confirm_read_clipboard_cb = { _, _, _, _ in }
    rc.write_clipboard_cb = { _, _, _, _, _ in }
    rc.close_surface_cb = { _, _ in }
    return rc
}()

func makeConfig() -> UnsafeMutableRawPointer? {
    let path = "/tmp/spike-probe-cfg"
    try? "font-size = 13\nscrollback-limit = 4194304".write(toFile: path, atomically: true, encoding: .utf8)
    var config = ghostty_config_new()
    ghostty_config_load_file(config, path)
    ghostty_config_finalize(config)
    return config
}

func startTicking() {
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now(), repeating: .milliseconds(8))
    t.setEventHandler { if let a = probeApp { ghostty_app_tick(a); ticks += 1; if wakeups > 0 { wakeups -= 1 } } }
    t.resume()
    tickTimer = t
}

func settle(_ t: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: t)) }

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

print("init:", terminator: "")
fflush(stdout)
let initRC = ghostty_init(0, nil)
print(" rc=\(initRC)", terminator: "")
fflush(stdout)

guard var cfgPtr = makeConfig(), let a = ghostty_app_new(&runtimeConfig, cfgPtr) else { exit(51) }
probeApp = a

probeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                       styleMask: [.titled], backing: .buffered, defer: false)
probeWindow.isReleasedWhenClosed = false
probeWindow.orderOut(nil)
probeView = NSView(frame: probeWindow.contentView!.bounds)
probeView.wantsLayer = true
probeWindow.contentView!.addSubview(probeView)

var sCfg = ghostty_surface_config_new()
sCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
sCfg.platform.macos.nsview = Unmanaged.passUnretained(probeView).toOpaque()
if mode == "exit" {
    try? "#!/bin/sh\nsleep 1\nexit 7\n".write(toFile: "/tmp/spike-exit-helper.sh",
                                              atomically: true, encoding: .utf8)
}
sCfg.working_directory = cstr(wdStorage)
sCfg.command = cstr(cmdStorage)
sCfg.wait_after_command = waitAfter
guard let s = ghostty_surface_new(probeApp!, &sCfg) else { exit(52) }
probeSurface = s

startTicking()

let deadline = Date().addingTimeInterval(10)
while ghostty_surface_foreground_pid(s) == 0 && Date() < deadline { settle(0.05) }
guard ghostty_surface_foreground_pid(s) != 0 else {
    print("PROBE_NO_PROCESS")
    exit(53)
}

if mode == "exit" || mode == "app" || mode == "appsync" {
    func runExitPoll(_ s: UnsafeMutableRawPointer) {
        var observedExit = false
        let dl = Date().addingTimeInterval(20)
        while Date() < dl {
            settle(0.2)
            let pid = ghostty_surface_foreground_pid(s)
            let exited = ghostty_surface_process_exited(s)
            print("pid=\(pid) exited=\(exited) ticks=\(ticks) tags=\(seenTags)")
            fflush(stdout)
            if exited {
                observedExit = true
                break
            }
        }
        print(observedExit ? "EXIT_OBSERVED" : "EXIT_NEVER_OBSERVED")
        exit(observedExit ? 44 : 45)
    }
    if mode == "exit" {
        runExitPoll(s)
    } else if mode == "appsync" {
        // applicationDidFinishLaunching runs as a runloop notification
        // callout, NOT inside a dispatch-queue drain.
        let runner = ProbeAppRunner(surface: s, poll: runExitPoll, syncKick: true)
        NSApp.delegate = runner
        NSApp.run()
    } else {
        // Replicate the harness: NSApplication.run active, all work nested
        // inside a main-queue drain kicked off at launch.
        let runner = ProbeAppRunner(surface: s, poll: runExitPoll)
        NSApp.delegate = runner
        NSApp.run()
    }
}
settle(0.3)

DispatchQueue.global(qos: .userInitiated).async {
    print("FREE_DISPATCHED", terminator: "")
    fflush(stdout)
    ghostty_surface_free(s) // EXPERIMENT: undocumented threading context
    freed.signal()
}

_ = freed.wait(timeout: .now() + 5)

// Resume ticking; late corruption (UAF in callbacks) would surface here.
startTicking()
settle(2.0)

print(" PROBE_SURVIVED")
fflush(stdout)
exit(42)

// Harness-replica delegate: kicks the poll from inside a main-queue drain,
// mirroring the spike-harness applicationDidFinishLaunching structure.
final class ProbeAppRunner: NSObject, NSApplicationDelegate {
    let surface: UnsafeMutableRawPointer
    let poll: (UnsafeMutableRawPointer) -> Void
    var syncKick = false
    init(surface: UnsafeMutableRawPointer, poll: @escaping (UnsafeMutableRawPointer) -> Void, syncKick: Bool = false) {
        self.surface = surface
        self.poll = poll
        self.syncKick = syncKick
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if syncKick {
            self.poll(self.surface)
        } else {
            DispatchQueue.main.async { self.poll(self.surface) }
        }
    }
}

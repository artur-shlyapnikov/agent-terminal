import AgentCore
import AppKit
import TerminalKit

// Diagnostic harness: replicates the verified stage-3 spike launch path inside
// the App target to isolate the ghostty/Metal draw crash. Enabled with
// ATERM_MINIMAL=1.

// Temp config dir of the harness run, removed at process end.
private var harnessCfgDirPendingRemoval: String?
private func removeHarnessCfgDir() {
    if let path = harnessCfgDirPendingRemoval {
        try? FileManager.default.removeItem(atPath: path)
    }
}

@MainActor
final class MinimalHarness {
    func run() async {
        let cfgDir = NSTemporaryDirectory() + "aterm-minimal-\(getpid())"
        try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
        harnessCfgDirPendingRemoval = cfgDir
        atexit(removeHarnessCfgDir)
        try? "font-size = 13".write(toFile: cfgDir + "/config", atomically: true, encoding: .utf8)

        do {
            try GhosttyEngine.globalInit()
            let engine =
                try GhosttyEngine(configLoader: GhosttyConfigLoader(path: URL(fileURLWithPath: cfgDir + "/config")))
            let parking = TerminalParkingHost()
            let manager = TerminalSessionManager(engine: engine, parkingHost: parking, inputBracketedPaste: false)
            await launch(manager: manager)
        } catch {
            print("[MINIMAL] failed: \(error)")
            exit(44)
        }
    }

    /// Synchronous on purpose: this @MainActor harness blocks main to pump
    /// AppKit events; `RunLoop.run(until:)`'s noasync flag guards the
    /// cooperative pool, not this call site.
    private func pumpMainRunloop(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
    }

    private func launch(manager: TerminalSessionManager) async {
        do {
            let session = try manager.launchDirect(
                workspaceID: WorkspaceID(),
                spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/sh",
                                         environment: ["PS1": "$ "])
            )

            // Visible plain window, no split view / composer / status item.
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            window.contentView = container
            window.makeKeyAndOrderFront(nil)
            try manager.mount(terminalID: session.id, paneID: PaneID(), container: container)

            var pid: UInt64 = 0
            let deadline = Date().addingTimeInterval(10)
            while pid == 0, Date() < deadline {
                pumpMainRunloop(0.05)
                pid = manager.foregroundPID(for: session.id) ?? 0
            }
            print("[MINIMAL] alive pid=\(pid)")
        } catch {
            print("[MINIMAL] launch failed: \(error)")
            exit(45)
        }
    }
}

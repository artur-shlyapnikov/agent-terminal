import AppKit
import Foundation
import AgentCore
import TerminalKit

// ---------------------------------------------------------------------------
// Stage-3 live verification (plan §6.3 item 3: terminal lifecycle without
// AgentRuntime). Exercises the REAL TerminalKit types end-to-end over the
// pinned libghostty:
//
//   1. engine bootstrap + parking host
//   2. /bin/sh surface launched through TerminalSessionManager.launchDirect
//   3. `echo atk-marker-$((1+1))` delivered via TerminalControlling.deliverInput
//      (bracketed-paste gateway + Return)
//   4. detection-grade SCREEN snapshot contains `atk-marker-2`
//   5. park/mount reparent cycles — 100 cycles (risk register §5.1 criterion;
//      the stage-0 spike ran 20)
//   6. 20 sequential create/free teardown cycles through TerminalTeardownQueue
//
// Non-interactive: drives everything from tasks inside the NSApplication
// runloop, prints results, exits 0/1.
// ---------------------------------------------------------------------------

@main
final class SpikeApp: NSObject, NSApplicationDelegate {
    static var runner: Runner!

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0) // line-buffered: survive hard kills
        let app = NSApplication.shared
        let delegate = SpikeApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        print("spike-terminalkit: entering runloop")
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.runner = Runner()
        Task { @MainActor in
            let code = await Self.runner.runAll()
            print("DONE exit=\(code)")
            exit(Int32(code))
        }
    }
}

@MainActor
final class Runner {
    private var failures: [String] = []
    private var checks = 0

    private func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        checks += 1
        let status = condition ? "PASS" : "FAIL"
        print("[\(status)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !condition {
            failures.append(name)
        }
    }

    /// Yields to the main runloop while polling an async condition; engine
    /// ticking continues because we're inside NSApplication.run.
    private func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.05,
                           _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) && Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return await condition()
    }

    func runAll() async -> Int {
        // -- 0. bootstrap ---------------------------------------------------
        let scratchDir = NSTemporaryDirectory() + "spike-terminalkit-\(getpid())"
        try? FileManager.default.createDirectory(
            atPath: scratchDir, withIntermediateDirectories: true)
        let cfgPath = scratchDir + "/config"
        // Minimal app config; deliberately no scrollback-limit (ADR-0002 finding 5).
        try? "font-size = 13".write(toFile: cfgPath, atomically: true, encoding: .utf8)

        guard let engine = try? GhosttyEngine(
            configLoader: GhosttyConfigLoader(path: URL(fileURLWithPath: cfgPath))) else {
            print("FATAL: engine bootstrap failed")
            return 1
        }
        check("engine bootstrap", true, "tick timer running")

        let parkingHost = TerminalParkingHost()
        // Raw /bin/sh cannot consume bracketed-paste escapes.
        let manager = TerminalSessionManager(
            engine: engine,
            parkingHost: parkingHost,
            inputBracketedPaste: false)

        // -- 1. shell surface launch ---------------------------------------
        let session: TerminalSession
        do {
            session = try manager.launchDirect(
                workspaceID: WorkspaceID(),
                spec: TerminalLaunchSpec(
                    workingDirectory: "/tmp",
                    command: "/bin/sh",
                    environment: ["PS1": "$ "]))
        } catch {
            print("FATAL: launch failed: \(error)")
            return 1
        }
        check("surface launch via manager", true,
              "terminal=\(session.id.rawValue.uuidString.prefix(8))")

        let terminalID = session.id
        var surfacePID: UInt64 = 0
        let pidOK = await waitUntil(timeout: 10) { [weak manager] in
            surfacePID = manager?.surface(for: terminalID)?.foregroundPID() ?? 0
            return surfacePID > 0
        }
        check("foreground child alive", pidOK, "pid=\(surfacePID)")

        // -- 2. type the marker command through the input port --------------
        do {
            try await manager.deliverInput(
                terminalID,
                text: "echo atk-marker-$((1+1))",
                submit: true)
            check("deliverInput via TerminalControlling", true, "bracketed-paste + Return")
        } catch {
            check("deliverInput via TerminalControlling", false, "\(error)")
        }

        // -- 3. SCREEN-space detection snapshot contains atk-marker-2 -------
        var markerText = ""
        let markerFound = await waitUntil(timeout: 15) { [weak manager] in
            guard let snapshot = try? await manager?.read(terminalID, source: TerminalReadSource.detection) else { return false }
            markerText = snapshot.text
            return markerText.contains("atk-marker-2")
        }
        check("SCREEN snapshot has atk-marker-2", markerFound && markerText.contains("atk-marker-2"))
        if markerFound {
            let markerLine = markerText.split(separator: "\n")
                .first(where: { $0.contains("atk-marker-2") }) ?? ""
            check("child shell evaluated the arithmetic", !markerLine.contains("$((1+1))"),
                  "line: \(markerLine.trimmingCharacters(in: .whitespaces))")
        }

        // Viewport read should also work (visible source).
        let viewport = try? await manager.read(terminalID, source: TerminalReadSource.visible)
        check("viewport read non-nil", viewport != nil)

        // -- 4. 100 park/mount reparent cycles ------------------------------
        // Real reparenting between the hidden parking window and a second
        // host window (kept unordered-out for headless operation).
        let mountWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        mountWindow.isReleasedWhenClosed = false
        mountWindow.orderOut(nil)
        let mountContainer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        mountWindow.contentView = mountContainer
        let paneID = PaneID()

        var cycleFailures = 0
        let generationBefore = manager.session(for: terminalID)?.surfaceGeneration
        let cycleStart = Date()
        for cycle in 0..<100 {
            do {
                try manager.mount(terminalID: terminalID, paneID: paneID, container: mountContainer)
                try manager.park(terminalID: terminalID)
            } catch {
                cycleFailures += 1
                print("  cycle \(cycle): \(error)")
            }
        }
        let cycleSeconds = Date().timeIntervalSince(cycleStart)
        let generationUnchanged =
            manager.session(for: terminalID)?.surfaceGeneration == generationBefore &&
            generationBefore == SurfaceGeneration.initial
        check("100 park/mount cycles clean", cycleFailures == 0,
              String(format: "%.1fs total (%.0fms/cycle)", cycleSeconds, cycleSeconds * 10))
        check("generation unchanged across 100 cycles", generationUnchanged)

        // Output still flows after 200 reparents.
        let stillAlive = await waitUntil(timeout: 10) { [weak manager] in
            guard let snapshot = try? await manager?.read(terminalID, source: TerminalReadSource.detection) else {
                return false
            }
            return snapshot.text.contains("atk-marker-2")
        }
        check("output readable after 100 cycles", stillAlive)

        // -- 5. 20 create/free teardown cycles ------------------------------
        var cycleResults: [Bool] = []
        for cycle in 0..<20 {
            // Lingering child: instant-exit children vanish before libghostty's
            // Darwin pid watcher engages (ADR-0002 finding 6 / RESULTS check 3).
            let scriptPath = "\(scratchDir)/cycle-\(cycle).sh"
            try? "#!/bin/sh\necho cycle-\(cycle)\nsleep 0.3\nexit 0\n"
                .write(toFile: scriptPath, atomically: true, encoding: .utf8)
            guard let cycleSession = try? manager.launchDirect(
                workspaceID: WorkspaceID(),
                spec: TerminalLaunchSpec(
                    workingDirectory: "/tmp",
                    command: "/bin/sh \(scriptPath)",
                    waitAfterCommand: true)) else {
                cycleResults.append(false)
                continue
            }
            let started = await waitUntil(timeout: 5) { [weak manager] in
                (manager?.surface(for: cycleSession.id)?.foregroundPID() ?? 0) > 0
            }
            try? manager.close(terminalID: cycleSession.id)
            // Teardown queue frees on subsequent main-runloop hops.
            let freedAndRemoved = await waitUntil(timeout: 10) { [weak manager] in
                manager?.session(for: cycleSession.id) == nil &&
                manager?.surface(for: cycleSession.id) == nil
            }
            cycleResults.append(started && freedAndRemoved)
        }
        let cleanCycles = cycleResults.filter { $0 }.count
        check("20 create/free cycles clean", cleanCycles == 20, "\(cleanCycles)/20")

        // -- 6. shutdown of the primary terminal ----------------------------
        try? manager.close(terminalID: terminalID)
        _ = await waitUntil(timeout: 15) { [weak manager] in
            manager?.session(for: terminalID) == nil
        }
        check("primary terminal torn down", manager.session(for: terminalID) == nil)

        engine.shutdown()
        check("engine shutdown", true)

        print("---")
        print("checks=\(checks) failures=\(failures.count)")
        if !failures.isEmpty {
            print("failed: " + failures.joined(separator: ", "))
        }
        return failures.isEmpty ? 0 : 1
    }
}

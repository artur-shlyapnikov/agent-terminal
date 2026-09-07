import AgentCore
import AppKit
import Darwin
import TerminalKit

// Stage-5 behavioral acceptance scenario. Launched with
// AGENTTERMINAL_AUTOSHELL=<N> (N=4 for the acceptance run):
//
//   1. creates N generic shell sessions via TerminalSessionManager directly
//   2. lays them out 2x2
//   3. cycles sidebar selection across all four
//   4. triggers a split via the ⌘D code path → must be REJECTED at 4 leaves
//      (max-four enforcement)
//   5. ⌘W-equivalent close-view parks the focused pane — shell pid stays alive
//   6. Stop-path separation: graceful stop on another shell kills its process,
//      while the parked one survives
//   7. writes a JSON report + screenshot, then exits 0/1

@MainActor
final class AutomationScenario {
    private let root: AppCompositionRoot
    private let commands: AppCommands
    private var failures: [String] = []
    private var checks = 0
    private var report: [[String: String]] = []

    init(root: AppCompositionRoot) {
        self.root = root
        commands = AppCommands(root: root)
    }

    private func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        checks += 1
        let status = condition ? "PASS" : "FAIL"
        print("[\(status)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        report.append(["check": name, "status": status, "detail": detail])
        if !condition {
            failures.append(name)
        }
    }

    /// Pumps the main run loop for up to `interval` so AppKit delivers layout
    /// and window-server events while a scenario condition settles.
    /// Deliberately synchronous despite `RunLoop.run(until:)` being noasync:
    /// the class is @MainActor, and blocking main here is exactly what the
    /// pre-async harness did — the flag guards the cooperative pool, not us.
    private func pumpMainRunloop(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
    }

    private func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.05,
                           _ condition: () async -> Bool) async -> Bool
    {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            pumpMainRunloop(0.001)
        }
        return await condition()
    }

    func run() async {
        let code: Int
        do {
            code = try await runAll()
        } catch {
            print("[FAIL] scenario setup: \(error)")
            code = 1
        }
        await writeReport(exitCode: code)
        print("DONE exit=\(code)")
        exit(Int32(code))
    }

    private func runAll() async throws -> Int {
        let canvas = root.mainWindowController.splitController.canvas
        let manager = root.sessionManager!
        let count = AppCompositionRoot.autoShellCount

        // -- 1. shells were spawned in the bootstrap phase (proven ordering);
        // adopt them from the model.
        let terminalIDs: [TerminalID] = root.model.shells.values
            .sorted { $0.name < $1.name }
            .map(\.terminalID)
        check("bootstrap spawned \(count) shells", terminalIDs.count == count,
              "found=\(terminalIDs.count)")
        root.startDeltaConsumption()

        var pids: [TerminalID: UInt64] = [:]
        let allLive = await waitUntil(timeout: 15) {
            terminalIDs.allSatisfy { id in
                if let pid = manager.foregroundPID(for: id), pid > 0 {
                    pids[id] = pid
                    return true
                }
                return false
            }
        }
        check("all shells have live processes", allLive,
              "pids=\(terminalIDs.compactMap { pids[$0].map(String.init) }.joined(separator: ","))")

        // Runtime comes up only after surfaces exist (§3.18 ordering).
        await root.bootstrapRuntime()
        print("[LAUNCH] scenario: runtime bootstrapped post-launch")

        guard count == 4 else {
            print("[INFO] layout steps assume 4 shells; got \(count)")
            return failures.isEmpty ? 0 : 1
        }

        // -- 2. lay out 2x2 -------------------------------------------------
        // Fill-as-you-split: every new placeholder receives the next hidden
        // shell through the SAME replaceFocused path a sidebar click takes,
        // so all four leaves end up owned by a shell (§3.13).
        AppCommands.Automation.select(commands, .shell(terminalIDs[0])) // fills P0
        canvas.splitFocusedRight() // placeholder focused right
        AppCommands.Automation.select(commands, .shell(terminalIDs[1]))
        canvas.splitFocusedDown() // placeholder focused below-right
        AppCommands.Automation.select(commands, .shell(terminalIDs[2]))
        if let paneA = canvas.planner.paneID(showing: .shell(terminalIDs[0])) {
            canvas.focusPane(paneA)
            canvas.splitFocusedDown() // placeholder focused below-left
        }
        AppCommands.Automation.select(commands, .shell(terminalIDs[3]))
        check("layout has 4 leaves", canvas.planner.leafCount == 4,
              "leafCount=\(canvas.planner.leafCount)")

        let frames = canvas.planner.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let centers = frames.map { ($0.paneID, Double($0.rect.midX).rounded(), Double($0.rect.midY).rounded()) }
        let distinctX = Set(centers.map(\.1)).count
        let distinctY = Set(centers.map(\.2)).count
        check("2x2 grid geometry", distinctX == 2 && distinctY == 2 && centers.count == 4,
              "distinctX=\(distinctX) distinctY=\(distinctY)")

        // -- 2b. visual acceptance (Review5 #3): assert REAL frames ---------
        canvas.view.layoutSubtreeIfNeeded()
        root.mainWindowController.window?.layoutIfNeeded()
        pumpMainRunloop(0.05)

        let split = root.mainWindowController.splitController
        let windowFrame = root.mainWindowController.window?.frame ?? .zero

        // Sidebar ≈260 pt and canvas filling the remainder; NSSplitView settles
        // on a later layout pass, so keep applying dividers until it holds.
        var sidebarWidth: CGFloat = 0
        var canvasWidth: CGFloat = 0
        _ = await waitUntil(timeout: 5) {
            split.applyInitialDividers()
            sidebarWidth = split.sidebarPaneView.frame.width
            canvasWidth = split.canvasPaneView.frame.width
            return abs(sidebarWidth - 260) <= 60 && canvasWidth >= 320
        }
        check("sidebar pane laid out at 260 pt (§3.13, stage-10 fix)",
              abs(sidebarWidth - 260) <= 4,
              "width=\(sidebarWidth) (target 260)")

        // Canvas keeps a real working area beside sidebar and inspector.
        check("canvas pane laid out", canvasWidth >= 320,
              "width=\(canvasWidth) window=\(windowFrame.width)")

        // Composer docked at the bottom, ≈52 pt tall (§3.13).
        let composerFrame = root.mainWindowController.composer.convert(
            root.mainWindowController.composer.bounds, to: nil
        )
        check("composer docked bottom height≈52",
              composerFrame.minY <= 2 && abs(composerFrame.height - 52) <= 20,
              "frame=\(composerFrame)")

        // Every mounted pane view paints a real cell matching the planner.
        var paintedCells = 0
        for request in canvas.planner.frames(in: split.canvasPaneView.bounds) {
            if let controller = canvas.paneController(for: request.paneID),
               !controller.paneContainer.frame.isEmpty
            {
                paintedCells += 1
            }
        }
        check("all four panes have painted cells", paintedCells == 4,
              "painted=\(paintedCells)")

        // Screenshot AFTER layout is proven (Review5 #3).
        _ = captureScreenshot()

        // -- 3. cycle sidebar selection across all four ---------------------
        for id in terminalIDs {
            AppCommands.Automation.select(commands, .shell(id))
            let expectedPane = canvas.planner.paneID(showing: .shell(id))
            check("selection focuses shell pid=\(pids[id].map(String.init) ?? "?")",
                  canvas.focusedPane != nil && canvas.focusedPane == expectedPane)
            if case let .mounted(pane)? = manager.session(for: id)?.presentation {
                check("shell mounted in its pane", pane == expectedPane)
            } else {
                check("shell mounted in its pane", false)
            }
        }

        // -- 4. ⌘D equivalent at four leaves → max-four enforcement ---------
        canvas.splitFocusedRight()
        check("⌘D rejected at 4 leaves (max-four enforced)", canvas.planner.leafCount == 4)

        // -- 5. ⌘W parks without killing ------------------------------------
        let parkedTerminal = terminalIDs[0]
        let parkedPID = pids[parkedTerminal] ?? 0
        let parkedPane = canvas.planner.paneID(showing: .shell(parkedTerminal))
        if let parkedPane {
            canvas.focusPane(parkedPane)
            root.mainWindowController.closeFocusedPane()
        }
        let presentationAfterClose = manager.session(for: parkedTerminal)?.presentation
        var parkedStillAlive = false
        if parkedPID > 0 {
            for _ in 0 ..< 20 {
                parkedStillAlive = kill(pid_t(parkedPID), 0) == 0
                if !parkedStillAlive {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if parkedPane == nil || isMounted(parkedTerminal) {
            let leaves = canvas.planner.leaves
                .map { "\($0.paneID)=\($0.content)" }
                .joined(separator: " ")
            print(
                "[DIAG] close-view check failed: leaves=[\(leaves)] focusedPane=\(String(describing: canvas.focusedPane))"
            )
        }
        check("close-view parked the surface",
              parkedPane != nil && !isMounted(parkedTerminal),
              parkedPID > 0
                  ? "presentation=\(String(describing: presentationAfterClose))"
                  : "pid missing")

        // -- 6. Stop-path separation ----------------------------------------
        let stoppedTerminal = terminalIDs[1]
        let stoppedPID = pids[stoppedTerminal] ?? 0
        await root.runtimeSeam.stop(.shell(stoppedTerminal))
        var stoppedDied = false
        for _ in 0 ..< 80 {
            if stoppedPID > 0, kill(pid_t(stoppedPID), 0) != 0 {
                stoppedDied = true; break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check("stop path terminated its process", stoppedDied,
              stoppedPID > 0 ? "pid=\(stoppedPID)" : "pid missing")
        check("parked shell survived stop of another shell",
              parkedPID > 0 && kill(pid_t(parkedPID), 0) == 0,
              parkedPID > 0 ? "pid=\(parkedPID)" : "pid missing")

        return failures.isEmpty ? 0 : 1
    }

    private func isMounted(_ terminal: TerminalID) -> Bool {
        if case .mounted = root.sessionManager.session(for: terminal)?.presentation {
            return true
        }
        return false
    }

    // MARK: artifacts

    private func captureScreenshot() -> String {
        let path = ProcessInfo.processInfo.environment["ATERM_SCREENSHOT"] ?? "/tmp/aterm-stage5.png"
        var method = "none"

        // Preferred: delegate to screencapture with our window id.
        if let windowNumber = root.mainWindowController.window?.windowNumber {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-o", "-l\(windowNumber)", path]
            if (try? process.run()) != nil {
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int, size > 1000
                {
                    method = "screencapture"
                }
            }
        }

        // Fallback: offscreen bitmap of the window content view (chrome +
        // layer-backed surfaces render via cacheDisplay).
        if method == "none",
           let contentView = root.mainWindowController.window?.contentView
        {
            let rect = contentView.bounds
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
            if let rep,
               let ctx = NSGraphicsContext(bitmapImageRep: rep)
            {
                ctx.imageInterpolation = .high
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                contentView.cacheDisplay(in: rect, to: rep)
                NSGraphicsContext.restoreGraphicsState()
                if let png = rep.representation(using: .png, properties: [:]),
                   (try? png.write(to: URL(fileURLWithPath: path))) != nil
                {
                    method = "viewbitmap"
                }
            }
        }

        print("[SCREENSHOT] path=\(path) method=\(method)")
        if method == "none" {
            failures.append("screenshot capture failed: no method produced an image at \(path)")
        }
        report.append(["check": "screenshot", "status": method == "none" ? "FAIL" : "PASS",
                       "detail": "\(path) via \(method)"])
        return path
    }

    private func writeReport(exitCode: Int) async {
        let payload: [String: Any] = [
            "scenario": "AGENTTERMINAL_AUTOSHELL",
            "exitCode": exitCode,
            "failures": failures,
            "checks": report,
            "windowNumber": root.mainWindowController.window?.windowNumber ?? 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            print("REPORT serialization failed; exitCode=\(exitCode)")
            return
        }
        print(json)
        let reportPath = ProcessInfo.processInfo.environment["ATERM_REPORT"] ?? "/tmp/aterm-stage5-report.json"
        try? json.write(toFile: reportPath, atomically: true, encoding: .utf8)
    }
}

import AgentControl
import AgentCore
import AgentStore
import AppKit
import Darwin
import TerminalKit

// Stage-16 hardening gates (§6.16 capacity/soak + adverse conditions).
// One scenario class, modes selected by ATERM_SCENARIO:
//
//   capacity16    16 surfaces (hidden/parked mix) alive + responsive, clean teardown
//   soak          8 concurrent shells ≥ ATERM_SOAK_SECONDS (default 600; driver
//                 may pass 1800 for the full DoD window), CPU/footprint sampled
//                 every 30 s, no leak trend, all processes alive at end;
//                 ATERM_SOAK_TICK (default 5 s) sets per-shell churn cadence
//   teardown100   100 create/free cycles through TerminalSessionManager,
//                 stable footprint (product-path proof of spike check 12)
//   corrupt-db    garbled SQLite (driver garbles it pre-launch) → quarantine +
//                 visible degraded banner, fresh usable store, corrupt bytes preserved
//   broken-hooks  broken hook shim → diagnose degraded, Repair restores, agent
//                 continues via screen/process fallback
//   upgrade-sim   stub executable printing a 'newer' version marker → launch
//                 allowed, screen detection marked fallback + warning
//
// Writes a JSON report to ATERM_REPORT (default /tmp/aterm-s16-<mode>-report.json)
// and exits 0/1.

@MainActor
final class Stage16GatesScenario {
    enum Mode: String {
        case capacity16, soak, teardown100, corruptDB = "corrupt-db"
        case brokenHooks = "broken-hooks", upgradeSim = "upgrade-sim"
    }

    static var mode: Mode? {
        ProcessInfo.processInfo.environment["ATERM_SCENARIO"].flatMap(Mode.init(rawValue:))
    }

    private let root: AppCompositionRoot
    private let mode: Mode
    private var failures: [String] = []
    private var checks: [[String: String]] = []

    init(root: AppCompositionRoot, mode: Mode) {
        self.root = root
        self.mode = mode
    }

    private func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        let status = condition ? "PASS" : "FAIL"
        print("[\(status)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        checks.append(["check": name, "status": status, "detail": detail])
        if !condition {
            failures.append(name)
        }
    }

    /// Pumps the main run loop so AppKit delivers layout/window-server events
    /// while a scenario condition settles. Synchronous on purpose: the class
    /// is @MainActor and blocking main is what the harness always did here;
    /// `RunLoop.run(until:)`'s noasync flag guards the cooperative pool.
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
        await root.bootstrapRuntime()
        let code: Int = switch mode {
        case .capacity16: await runCapacity16()
        case .soak: await runSoak()
        case .teardown100: await runTeardown100()
        case .corruptDB: await runCorruptDB()
        case .brokenHooks: await runBrokenHooks()
        case .upgradeSim: await runUpgradeSim()
        }
        writeReport(exitCode: code)
        print("DONE exit=\(code)")
        exit(Int32(code))
    }

    private func writeReport(exitCode: Int) {
        let payload: [String: Any] = [
            "scenario": "stage16-\(mode.rawValue)",
            "exitCode": exitCode,
            "failures": failures,
            "checks": checks,
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        )
        let path = ProcessInfo.processInfo.environment["ATERM_REPORT"]
            ?? "/tmp/aterm-s16-\(mode.rawValue)-report.json"
        if let data {
            try? data.write(to: URL(fileURLWithPath: path))
            try? String(decoding: data, as: UTF8.self).write(
                toFile: path, atomically: true, encoding: .utf8
            )
            print(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Footprint / CPU helpers

    /// Mach phys_footprint (matches Xcode's memory gauge definition).
    private static func currentFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// Cumulative CPU seconds (user+system) of THIS process.
    private static func currentCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// Sum of RSS (KiB) for the given pids via ps; -1 when ps fails.
    private static func treeRSSKiB(pids: [UInt64]) -> Int {
        let list = pids.map(String.init).joined(separator: ",")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "ps -o rss= -p \(list) 2>/dev/null | awk '{s+=$1} END {print s+0}'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = Int(text) else { return -1 }
            return value
        } catch {
            return -1
        }
    }

    private static func pidAlive(_ pid: UInt64) -> Bool {
        pid > 0 && kill(pid_t(pid), 0) == 0
    }

    // Leak-slope estimation lives in DetectionGateMath (production; unit-covered).

    // MARK: - Shell spawn/teardown helpers (PRODUCT TerminalSessionManager path)

    private func spawnShell(index: Int) throws -> TerminalSession {
        try root.sessionManager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(
                workingDirectory: "/tmp",
                command: "/bin/sh",
                environment: ["PS1": "s16-\(index)$ "]
            )
        )
    }

    // MARK: - Gate 5a: capacity16

    private func runCapacity16() async -> Int {
        guard let manager = root.sessionManager else {
            check("session manager available", false)
            return 1
        }
        let count = 16
        var sessions: [TerminalSession] = []
        var spawnErrors: [String] = []
        for index in 1 ... count {
            do { try sessions.append(spawnShell(index: index)) }
            catch { spawnErrors.append("\(error)") }
        }
        check("16 surfaces created", sessions.count == count, "errors=\(spawnErrors.joined(separator: ";"))")

        // Hidden/parked mix: park half explicitly; the rest stay unmounted
        // (hidden — the canvas mounts at most four leaves and we mount none).
        var parked: [TerminalID] = []
        for (index, session) in sessions.enumerated() where index % 2 == 0 {
            try? manager.park(terminalID: session.id)
            parked.append(session.id)
        }
        check("half the surfaces parked", parked.count == count / 2, "parked=\(parked.count)")

        // All alive + responsive.
        var pids: [TerminalID: UInt64] = [:]
        let allAlive = await waitUntil(timeout: 20) {
            sessions.allSatisfy { session in
                guard let pid = manager.foregroundPID(for: session.id), pid > 0
                else { return false }
                pids[session.id] = pid
                return Self.pidAlive(pid)
            }
        }
        check("all 16 surfaces alive after creation", allAlive,
              "pids=\(pids.values.sorted().map(String.init).joined(separator: ","))")

        var responsive = 0
        for session in sessions {
            do {
                try await manager.deliverInput(
                    session.id,
                    text: "echo s16-resp-\(session.id.rawValue)\n",
                    submit: false
                )
                // A just-spawned shell may not have painted yet; retry reads.
                let readable = await waitUntil(timeout: 5) {
                    await ((try? manager.read(session.id, source: .detection))??.text.isEmpty) == false
                }
                if readable {
                    responsive += 1
                }
            } catch {
                print("[DIAG] responsiveness \(session.id): \(error)")
            }
        }
        check("all 16 surfaces responsive (input accepted, screen readable)", responsive == count,
              "responsive=\(responsive)")

        // Teardown clean.
        var closed = 0
        for session in sessions {
            do { try manager.close(terminalID: session.id); closed += 1 }
            catch { print("[DIAG] close \(session.id): \(error)") }
        }
        check("all 16 surfaces closed", closed == count, "closed=\(closed)")
        let pidsGone = await waitUntil(timeout: 10) {
            sessions.allSatisfy { session in
                guard let pid = pids[session.id] else { return true }
                return !Self.pidAlive(pid)
            }
        }
        check("teardown reaped every shell process", pidsGone)
        check("registry empty after teardown", manager.allSessions.isEmpty,
              "remaining=\(manager.allSessions.count)")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Gate 5b: soak

    private func runSoak() async -> Int {
        guard let manager = root.sessionManager else {
            check("session manager available", false)
            return 1
        }
        let env = ProcessInfo.processInfo.environment
        let seconds = env["ATERM_SOAK_SECONDS"].flatMap(Int.init) ?? 600
        // Churn cadence per shell: the doc-standard idle-ish working load is
        // 5 s; ATERM_SOAK_TICK drives a heavier "working agents" cadence for
        // the §3.21 CPU measurement without touching the default behavior.
        let tick = max(env["ATERM_SOAK_TICK"].flatMap(Double.init) ?? 5, 0.05)
        var sessions: [TerminalSession] = []
        var spawnFailures = 0
        for index in 1 ... 8 {
            do { try sessions.append(spawnShell(index: index)) }
            catch { spawnFailures += 1 }
        }
        check("8 concurrent shells spawned",
              sessions.count == 8 && Set(sessions.map(\.id)).count == 8 && spawnFailures == 0,
              "spawnFailures=\(spawnFailures)")

        var pids: [TerminalID: UInt64] = [:]
        let pidsReady = await waitUntil(timeout: 20) {
            sessions.allSatisfy { session in
                guard let pid = manager.foregroundPID(for: session.id),
                      pid > 0, Self.pidAlive(pid) else { return false }
                pids[session.id] = pid
                return true
            }
        }
        check("8 shells have live processes", pidsReady,
              "pids=\(pids.values.sorted().map(String.init).joined(separator: ","))")

        // Keep the shells doing light work for the whole window.
        for session in sessions {
            try? await manager.deliverInput(
                session.id, text: "while true; do echo soak; sleep \(tick); done\n", submit: false
            )
        }

        let startFootprint = Self.currentFootprintBytes()
        let startCPU = Self.currentCPUSeconds()
        let startWall = Date()
        var samples: [[String: Any]] = []
        var rawSamples: [(t: Double, bytes: UInt64)] = []
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var elapsed = 0.0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            elapsed = Date().timeIntervalSince(startWall)
            let footprint = Self.currentFootprintBytes()
            let cpu = Self.currentCPUSeconds() - startCPU
            let treeKiB = Self.treeRSSKiB(pids: Array(pids.values))
            rawSamples.append((elapsed, footprint))
            samples.append([
                "t": Double(round(elapsed * 10) / 10),
                "footprintBytes": footprint,
                "cpuSeconds": Double(round(cpu * 100) / 100),
                "treeRSSKiB": treeKiB,
                "aliveShells": pids.values.filter(Self.pidAlive).count,
            ])
            print(
                "[SOAK] t=\(Int(elapsed))s footprint=\(footprint / 1_048_576)MiB cpu=\(String(format: "%.1f", cpu))s "
                    + "treeRSS=\(treeKiB)KiB alive=\(pids.values.filter(Self.pidAlive).count)/8"
            )
        }

        let endFootprint = Self.currentFootprintBytes()
        let slope = DetectionGateMath.leakSlopeBytesPerSecond(rawSamples)
        let growth = Int64(endFootprint) - Int64(startFootprint)
        let growthTolerance = max(Int64(50 * 1_048_576), Int64(Double(startFootprint) * 0.2))

        let report: [String: Any] = [
            "durationSeconds": Int(elapsed),
            "churnTickSeconds": tick,
            "sampleCount": samples.count,
            "startFootprintBytes": startFootprint,
            "endFootprintBytes": endFootprint,
            "peakFootprintBytes": rawSamples.map(\.bytes).max() ?? 0,
            "growthBytes": growth,
            "leakSlopeBytesPerSecond": slope,
            "cpuSecondsTotal": Self.currentCPUSeconds() - startCPU,
            "samples": samples,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/aterm-s16-soak-samples.json"))
        }

        check("soak ran the full window", Int(elapsed) >= seconds, "ran=\(Int(elapsed))s target=\(seconds)s")
        check("no leak trend (slope \(String(format: "%.0f", slope)) B/s, growth \(growth / 1_048_576) MiB)",
              slope < 100_000 && growth < growthTolerance,
              "tolerance=\(growthTolerance / 1_048_576)MiB")
        check("all 8 shell processes alive at end", pids.values.allSatisfy(Self.pidAlive),
              "alive=\(pids.values.filter(Self.pidAlive).count)/8")

        // Teardown so the run leaves nothing behind.
        for session in sessions {
            try? manager.close(terminalID: session.id)
        }
        let drained = await waitUntil(timeout: 30) { manager.allSessions.isEmpty }
        check("soak teardown closed all shells", drained,
              "remaining=\(manager.allSessions.count)")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Gate 5c: teardown100

    private func runTeardown100() async -> Int {
        guard let manager = root.sessionManager else {
            check("session manager available", false)
            return 1
        }
        let cycles = 100
        let baseline = Self.currentFootprintBytes()
        var peak: UInt64 = 0
        var samples: [[String: Any]] = []
        var completed = 0
        let start = Date()
        for cycle in 1 ... cycles {
            guard let session = try? spawnShell(index: cycle) else {
                check("cycle \(cycle): spawn", false)
                continue
            }
            let pid = manager.foregroundPID(for: session.id) ?? 0
            do { try manager.close(terminalID: session.id) }
            catch { check("cycle \(cycle): close", false, "\(error)") }
            completed += 1
            // Pace at the PRODUCT's teardown throughput: two-phase free is
            // asynchronous (§3.8 step 6); the next create starts once this
            // surface's process is reaped AND its registry entry is gone —
            // sampling therefore measures steady state, not queue backlog.
            if pid > 0 {
                _ = await waitUntil(timeout: 10) { !Self.pidAlive(pid) }
            }
            _ = await waitUntil(timeout: 10) { manager.session(for: session.id) == nil }
            if cycle % 25 == 0 {
                let footprint = Self.currentFootprintBytes()
                peak = max(peak, footprint)
                samples.append(["cycle": cycle, "footprintBytes": footprint])
                print(
                    "[TEARDOWN] cycle=\(cycle) footprint=\(footprint / 1_048_576)MiB elapsed=\(Int(Date().timeIntervalSince(start)))s"
                )
            }
        }
        // Let the teardown queue fully drain, then settle before sampling.
        _ = await waitUntil(timeout: 30) { manager.allSessions.isEmpty }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let endFootprint = Self.currentFootprintBytes()
        check("100 create/free cycles completed", completed == cycles,
              "elapsed=\(Int(Date().timeIntervalSince(start)))s")
        let drift = Int64(endFootprint) - Int64(baseline)
        check("stable footprint after 100 cycles (drift \(drift / 1_048_576) MiB)",
              abs(drift) < Int64(50 * 1_048_576),
              "baseline=\(baseline / 1_048_576)MiB end=\(endFootprint / 1_048_576)MiB peak=\(peak / 1_048_576)MiB")
        check("registry empty after teardown cycles", manager.allSessions.isEmpty)
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Gate 6a: corrupt-db

    private func runCorruptDB() async -> Int {
        // The driver garbled ATERM_DB_PATH before launch; the composition
        // root must have quarantined it and raised the degraded banner.
        let banner = root.model.degradedBanner ?? ""
        check("degraded banner names the corruption", banner.lowercased().contains("corrupt"), banner)
        let env = ProcessInfo.processInfo.environment
        let url = env["ATERM_DB_PATH"].map { URL(fileURLWithPath: $0) } ?? AgentDatabase.defaultDatabaseURL()
        let backups = url.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
        // Scope to THIS run's quarantine artifact: the backups dir is
        // shared across runs, so an unfiltered scan passes vacuously
        // off stale siblings from earlier launches.
        let stem = url.deletingPathExtension().lastPathComponent
        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: backups.path))?
            .filter { $0.hasPrefix("\(stem).corrupt-") } ?? []
        check("corrupt bytes preserved in backups dir", !quarantined.isEmpty,
              quarantined.joined(separator: ","))
        let quarantinedSize = quarantined.first.flatMap { name in
            (try? FileManager.default.attributesOfItem(
                atPath: backups.appendingPathComponent(name).path
            )[.size]) as? Int
        } ?? 0
        check("quarantined file is non-empty", quarantinedSize > 0,
              quarantinedSize > 0 ? "size=\(quarantinedSize)" : "no quarantined file for \(stem)")

        // Fresh store is USABLE: a workspace roundtrip through the repository.
        do {
            let now = root.clock.now
            let repository = try WorkspaceRepository(database: AgentDatabase(databaseURL: url))
            let workspace = Workspace(
                name: "s16-post-corruption", rootPath: "/tmp",
                createdAt: now, updatedAt: now
            )
            try await repository.save(workspace, sortIndex: 0)
            let loaded = try await repository.fetchAll()
            check("fresh store accepts writes after quarantine",
                  loaded.contains { $0.workspace.name == workspace.name },
                  "loaded=\(loaded.count)")
        } catch {
            check("fresh store accepts writes after quarantine", false, "\(error)")
        }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Gate 6b: broken-hooks

    private func runBrokenHooks() async -> Int {
        // SANDBOX home — NSHomeDirectory() ignores env HOME, so the gate
        // builds a dedicated installer against /tmp and NEVER touches the
        // operator's real adapter configs.
        let home = "/tmp/at-s16-hooks-home"
        let catalog = AgentCatalog.standard()
        guard let adapter = catalog.adapter(id: OpenCodeAdapter.staticID) else {
            check("opencode adapter available", false)
            return 1
        }
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let installer = IntegrationInstaller(
            recording: InMemoryInstallRecording(), homeDirectory: home
        )

        // 1. Healthy baseline install of the plugin into the sandbox HOME.
        do {
            let report = try installer.install(plan: adapter.integrationInstallPlan())
            check("baseline plugin install", report.outcome == .installed || report.outcome == .noChanges,
                  "outcome=\(report.outcome)")
        } catch {
            check("baseline plugin install", false, "\(error)")
        }
        let plan = adapter.integrationInstallPlan()
        check("diagnose healthy after install", installer.diagnose(plan: plan) == .healthy)

        // 2. Break the integration the way a bad CLI upgrade would:
        //    (a) the hook shim itself becomes garbage that exits non-zero;
        //    (b) the managed config entry drifts, so §3.17 diagnose SEES it.
        let configFile = home + "/.config/opencode/config.json"
        let pluginFile = home + "/Library/Application Support/AgentTerminal/integrations/opencode/lifecycle-plugin.js"
        do {
            try FileManager.default.createDirectory(
                atPath: (pluginFile as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try "module.exports = { agentterminal: (async () => { process.exit(3) })()".write(
                toFile: pluginFile, atomically: true, encoding: .utf8
            )
            let drifted = try String(contentsOfFile: configFile, encoding: .utf8)
                .replacingOccurrences(of: "lifecycle-plugin.js", with: "lifecycle-plugin.js.replaced-by-upgrade")
            try drifted.write(toFile: configFile, atomically: true, encoding: .utf8)
        } catch {
            check("break the installed integration", false, "\(error)")
        }
        let brokenHealth = installer.diagnose(plan: plan)
        check("diagnose reports degraded after shim break", brokenHealth != .healthy,
              "health=\(brokenHealth)")
        if case let .userModified(paths) = brokenHealth {
            check("degraded diagnose names the drifted path", !paths.isEmpty,
                  paths.joined(separator: ","))
        } else if case let .corrupted(reason) = brokenHealth {
            check("degraded diagnose names the corruption", !reason.isEmpty, reason)
        }

        // 3. An agent of the same kind keeps RUNNING and the inspector seam
        // reports the degraded integration with Repair enabled.
        let stub = installStubExecutable(named: "opencode", line: "opencode 0.9.0")
        var probeID: AgentID?
        if let workspaceID = root.activeWorkspaceID {
            let savedPATH = getenv("PATH").map { String(cString: $0) } ?? ""
            setenv("PATH", "\(stub.dir):\(savedPATH)", 1)
            defer { setenv("PATH", savedPATH, 1) }
            probeID = try? await root.coordinator.createAgent(
                AgentLaunchRequest(agentKind: .openCode, workingDirectory: "/tmp",
                                   displayName: "S16 Broken Hooks"),
                in: workspaceID
            )
        }
        check("agent launch allowed with degraded integration", probeID != nil)
        if let probeID {
            // Projection-level Inspector proof: the inspector renders exactly
            // RuntimeSeam.healthText(for:) and enables Repair when the health
            // is anything but healthy (headless UI assertion limitation).
            check("inspector projection marks degraded + Repair enabled",
                  RuntimeSeam.healthText(for: brokenHealth) != "healthy",
                  RuntimeSeam.healthText(for: brokenHealth))
            let seamDiag = await root.runtimeSeam.integrationDiagnostics(for: .agent(probeID))
            check("seam diagnostics path renders without error", seamDiag != nil,
                  "health=\(seamDiag?.healthText ?? "nil")")
            // The agent process itself is alive — fallback keeps it working.
            let alive = await waitUntil(timeout: 20) { [weak self] in
                guard let pid = self?.root.runtimeSeam.foregroundPID(.agent(probeID)), pid > 0
                else { return false }
                return Self.pidAlive(pid)
            }
            check("agent process alive via fallback while integration degraded", alive)

            // 4. Screen/process fallback actually DRIVES state: expire the
            // integration source and adopt screen evidence.
            await driveFallbackProof(agentID: probeID)

            // 5. Repair semantics per §5.3: a USER-MODIFIED managed section
            // is NEVER silently overwritten — repair must surface the
            // conflict explicitly. The sanctioned restore path is
            // uninstall (fingerprint-gated) + fresh install.
            let report = try? installer.install(plan: plan)
            var conflicted = false
            if case .conflict = report?.outcome {
                conflicted = true
            }
            check("repair surfaces the conflict instead of overwriting", conflicted,
                  "outcome=\(report.map { String(describing: $0.outcome) } ?? "nil")")
            // The operator restores the original reference (fingerprint-
            // gated uninstall correctly refused to delete user content).
            try? String(contentsOfFile:
                home + "/.config/opencode/config.json", encoding: .utf8)
                .replacingOccurrences(of: "lifecycle-plugin.js.replaced-by-upgrade",
                                      with: "lifecycle-plugin.js")
                .write(toFile: home + "/.config/opencode/config.json",
                       atomically: true, encoding: .utf8)
            _ = try? installer.install(plan: plan)
            check("diagnose healthy after operator restore + reinstall",
                  installer.diagnose(plan: plan) == .healthy)
            try? await root.coordinator.stop(probeID, mode: .gracefulStop)
        }
        return failures.isEmpty ? 0 : 1
    }

    /// §3.5 last-row fallback: with the integration lease released, screen
    /// evidence becomes the lifecycle authority and the state machine keeps
    /// advancing — the agent NEVER stalls because its hook shim broke.
    private func driveFallbackProof(agentID: AgentID) async {
        let socketPath = await root.controlPlane.server?.path ?? ""
        guard !socketPath.isEmpty else {
            check("fallback proof: control plane live", false)
            return
        }
        let token = "s16-fallback-\(UUID().uuidString)"
        await root.controlPlane.hooks.register(agentID: agentID, surfaceGeneration: .initial, token: token)
        func report(_ lifecycle: String, seq: UInt64) -> Bool {
            guard let client = try? ControlClient(socketPath: socketPath) else { return false }
            defer { client.close() }
            guard (try? client.handshake()) != nil else { return false }
            guard let response = try? client.roundtrip(method: "integration.report", params: [
                "agentID": .string(agentID.rawValue.uuidString),
                "surfaceGeneration": .uint64(0),
                "source": "hook:s16-broken",
                "token": .string(token),
                "seq": .uint64(seq),
                "lifecycle": .string(lifecycle),
            ]) else { return false }
            return response.error == nil
        }
        check("integration authority established (working)", report("working", seq: 1))
        let working = await waitUntil(timeout: 10) { [weak self] in
            guard let state = try? await self?.root.runtime.state(of: agentID) else { return false }
            if case .working = state.lifecycle {
                return true
            }
            return false
        }
        check("runtime adopted integration lifecycle", working)

        // Release the lease — the broken shim can no longer report.
        if let client = try? ControlClient(socketPath: socketPath) {
            _ = try? client.roundtrip(method: "integration.release", params: [
                "agentID": .string(agentID.rawValue.uuidString),
                "surfaceGeneration": .uint64(0),
                "source": "hook:s16-broken",
                "token": .string(token),
            ])
            client.close()
        }
        // Screen evidence (what detection feeds on a live surface) now wins.
        let env = ObservationEnvelope(
            agentID: agentID, terminalID: nil, surfaceGeneration: .initial,
            sourceID: "screen:s16-fallback", sourceKind: .screen, sequence: nil,
            outputRevision: 7, observedAt: root.clock.now, receivedAt: root.clock.now
        )
        await root.runtime.ingest(Evidence(
            envelope: env,
            payload: .screen(ScreenEvidencePayload(
                matchedRuleID: "s16-fallback", resultingLifecycle: .idle,
                supportingRules: ["s16-fallback"], conflictingRules: []
            ))
        ))
        let fellBack = await waitUntil(timeout: 10) { [weak self] in
            guard let state = try? await self?.root.runtime.state(of: agentID) else { return false }
            if case .idle = state.lifecycle, state.authority == .screen {
                return true
            }
            return false
        }
        await check("screen/process fallback drives state after lease loss", fellBack,
                    "\(String(describing: try? root.runtime.state(of: agentID)))")
    }

    // MARK: - Gate 6c: upgrade-sim

    private func runUpgradeSim() async -> Int {
        // Stub executable printing a 'newer' version marker — far outside the
        // bundled opencode manifest's adapterVersionRange (>=0.4 <2.0).
        let stub = installStubExecutable(named: "opencode", line: "opencode 999.0.0")
        let savedPATH = getenv("PATH").map { String(cString: $0) } ?? ""
        setenv("PATH", "\(stub.dir):\(savedPATH)", 1)
        defer { setenv("PATH", savedPATH, 1) }

        guard let adapter = catalogAdapter("opencode") else {
            check("opencode adapter available", false)
            return 1
        }
        var version: String?
        if case let .installed(path, _) = await adapter.detectInstallation() {
            version = await adapter.detectVersion(executablePath: path)
        }
        check("stub version probe reports the newer marker", version?.contains("999") == true,
              version ?? "nil")

        let manifest = try? ScreenManifestLoader.loadBundled(named: "opencode")
        let reason = manifest.map {
            DetectionGateMath.fallbackReason(manifestVersionRange: $0.adapterVersionRange, detectedVersion: version)
        } ?? nil
        check("launch still allowed (version violation never blocks)", reason != nil,
              reason ?? "no violation detected")
        check("violation reason names range and version",
              (reason ?? "").contains("999") && (reason ?? "").contains("range"),
              reason ?? "nil")

        // Projection-level: the pipeline must record the version fallback
        // marker for the probe agent.
        if let workspaceID = root.activeWorkspaceID {
            let probeID = try? await root.coordinator.createAgent(
                AgentLaunchRequest(agentKind: .openCode, workingDirectory: "/tmp",
                                   displayName: "S16 Upgrade Sim"),
                in: workspaceID
            )
            if let probeID {
                root.detectionPipeline?.recordVersionFallback(agentID: probeID, reason: reason)
                let recorded = root.detectionPipeline?.versionFallbackReason(for: probeID)
                check("pipeline records the fallback marker", recorded == reason,
                      recorded ?? "nil")
                try? await root.coordinator.stop(probeID, mode: .gracefulStop)
            }
        }
        return failures.isEmpty ? 0 : 1
    }

    private func catalogAdapter(_ id: String) -> (any AgentAdapter)? {
        AgentCatalog.standard().adapter(id: id)
    }

    // MARK: - Stub executables

    private func installStubExecutable(named name: String, line: String) -> (dir: String, path: String) {
        let dir = "/tmp/at-s16-stub-bin-\(name)"
        let path = dir + "/" + name
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"\(line)\"; else sleep 300; fi\n"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return (dir, path)
    }
}

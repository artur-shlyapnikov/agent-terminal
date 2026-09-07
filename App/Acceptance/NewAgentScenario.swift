import AgentControl
import AgentCore
import AppKit
import Darwin
import TerminalKit

// Stage-15 acceptance scenario (ATERM_SCENARIO=new-agent): proves the §4.6
// New Agent sheet end-to-end WITHOUT UI automation — the same model and the
// same pipeline entry points ⌘N uses:
//
//   1. the sheet MODEL produces a validated request for an installed adapter;
//   2. creating with a MISSING CLI yields the §6.6 actionable error and does
//      NOT touch the runtime (no zombie starting session);
//   3. with a STUB executable on PATH, Create launches through the REAL
//      ticketed pipeline (AgentLauncher) and the agent reaches `starting`
//      with a live process.
//
// Writes a JSON report and exits 0/1.

@MainActor
final class NewAgentScenario {
    private let root: AppCompositionRoot
    private var failures: [String] = []
    private var checks: [[String: String]] = []

    init(root: AppCompositionRoot) {
        self.root = root
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
        let code: Int
        do {
            code = try await runAll()
        } catch {
            print("[FAIL] scenario setup: \(error)")
            code = 1
        }
        writeReport(exitCode: failures.isEmpty ? code : 1)
        print("DONE exit=\(failures.isEmpty ? code : 1)")
        exit(Int32(failures.isEmpty ? code : 1))
    }

    private func runAll() async throws -> Int {
        await root.bootstrapRuntime()
        guard let workspaceID = root.activeWorkspaceID else {
            check("workspace bootstrapped", false)
            return 1
        }
        check("workspace bootstrapped", true)

        let agentCountBefore = await runtimeAgentCount()

        // -- 1. sheet model produces a validated request ----------------------
        let model = NewAgentSheetModel()
        let shellOption = model.options.first { $0.kind == .genericShell }
        check("sheet lists adapters including shell", shellOption != nil,
              model.options.map(\.displayName).joined(separator: ", "))

        // Invalid input → actionable validation errors.
        if case .success = model.validate(kind: .genericShell, displayName: "   ",
                                          taskSummary: "", workingDirectory: "/tmp")
        {
            check("empty name rejected", false)
        } else {
            check("empty name rejected", true)
        }
        if case let .failure(error) = model.validate(
            kind: .genericShell, displayName: "x", taskSummary: "",
            workingDirectory: "/nonexistent-folder-xyz"
        ) {
            check("missing folder rejected with actionable copy",
                  !error.actionableMessage.isEmpty, error.actionableMessage)
        } else {
            check("missing folder rejected with actionable copy", false)
        }

        switch model.validate(kind: .genericShell, displayName: "Scenario Shell",
                              taskSummary: "stage-15 new-agent",
                              workingDirectory: "/tmp")
        {
        case let .success(request):
            check("validated request produced",
                  request.agentKind == .genericShell && request.displayName == "Scenario Shell"
                      && request.workingDirectory == "/tmp" && request.taskSummary != nil,
                  "\(request)")
            await check("no runtime mutation during validation",
                        runtimeAgentCount() == agentCountBefore)
        case let .failure(error):
            check("validated request produced", false, error.actionableMessage)
        }

        // Install detection populates the picker labels.
        await model.refreshInstallStatus()
        let shellRow = model.options.first { $0.kind == .genericShell }
        check("install detection marks shell installed", shellRow?.installed == true,
              shellRow?.executablePath ?? "nil")

        // -- 2. missing CLI → actionable error, zero runtime mutation --------
        // Injected resolver seam (the sheet's own seam) reports absence; the
        // PIPELINE gate is exercised against the real PATH scan below by
        // pointing PATH at an empty directory via setenv.
        let emptyResolverModel = NewAgentSheetModel { kind in
            kind == .claudeCode ? nil : AgentExecutionCoordinator.resolveExecutable(for: kind)
        }
        if case let .failure(error) = emptyResolverModel.validate(
            kind: .claudeCode, displayName: "Missing CLI Probe",
            taskSummary: "", workingDirectory: "/tmp"
        ) {
            check("sheet flags missing CLI",
                  error == .missingExecutable(.claudeCode), error.actionableMessage)
            check("missing-CLI message is actionable (install hint)",
                  error.actionableMessage.contains("npm install"),
                  error.actionableMessage)
        } else {
            check("sheet flags missing CLI", false)
        }

        let savedPATH = getenv("PATH").map { String(cString: $0) } ?? ""
        let emptyDir = "/tmp/at-s15-empty-path"
        try? FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyDir) }
        setenv("PATH", emptyDir, 1)
        defer { setenv("PATH", savedPATH, 1) }

        do {
            _ = try await root.coordinator.createAgent(
                AgentLaunchRequest(agentKind: .claudeCode,
                                   workingDirectory: "/tmp",
                                   displayName: "Missing CLI Probe"),
                in: workspaceID
            )
            check("pipeline rejects missing CLI", false)
        } catch let failure as ControlFailure {
            check("pipeline rejects missing CLI",
                  failure.message.contains("not found") && failure.message.contains("npm install"),
                  failure.message)
        } catch {
            check("pipeline rejects missing CLI", false, "\(error)")
        }
        setenv("PATH", savedPATH, 1)

        let countAfterGate = await runtimeAgentCount()
        check("§6.6 gate leaves runtime untouched",
              countAfterGate == agentCountBefore,
              "agents before=\(agentCountBefore) after=\(countAfterGate)")

        // -- 3. stub executable → real ticketed launch reaches starting ------
        let stubDir = "/tmp/at-s15-stub-bin"
        let stubPath = stubDir + "/opencode"
        try? FileManager.default.createDirectory(atPath: stubDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stubDir) }
        let script = "#!/bin/sh\nexec sleep 120\n"
        try? script.write(toFile: stubPath, atomically: true, encoding: .utf8)
        chmod(stubPath, 0o755)

        // Sheet model resolves through the SAME seam ⌘N uses; the stub dir is
        // prepended to PATH so both the model AND the pipeline find it.
        setenv("PATH", "\(stubDir):\(savedPATH)", 1)
        defer { setenv("PATH", savedPATH, 1) }

        let stubModel = NewAgentSheetModel() // default resolver reads getenv PATH
        switch stubModel.validate(kind: .openCode, displayName: "Stub OpenCode",
                                  taskSummary: "ticketed launch proof",
                                  workingDirectory: "/tmp")
        {
        case .success:
            check("stub executable satisfies sheet validation", true)
        case let .failure(error):
            check("stub executable satisfies sheet validation", false, error.actionableMessage)
        }

        var probeID: AgentID?
        do {
            probeID = try await root.coordinator.createAgent(
                AgentLaunchRequest(agentKind: .openCode,
                                   workingDirectory: "/tmp",
                                   displayName: "Stub OpenCode"),
                in: workspaceID
            )
            check("create through ticketed pipeline succeeds", probeID != nil)
        } catch {
            check("create through ticketed pipeline succeeds", false, "\(error)")
        }

        if let probeID {
            root.commands.select(.agent(probeID)) // mount so ghostty renders
            let summary = await state(of: probeID)
            var startingReached = false
            if let summary, case .starting = summary.state.lifecycle {
                startingReached = true
            }
            check("agent reaches starting", startingReached,
                  summary.map { "\($0.state.lifecycle)" } ?? "missing")

            let pidAlive: () async -> Bool = { [weak self] in
                guard let self, let pid = foregroundPID(of: probeID) else { return false }
                return kill(pid_t(pid), 0) == 0
            }
            await check("stub process launched through ticket", waitUntil(timeout: 20) { await pidAlive() })

            // Cleanup: stop the probe so the run leaves nothing behind.
            try? await root.coordinator.stop(probeID, mode: .gracefulStop)
        }

        return 0
    }

    // MARK: - helpers

    private func runtimeAgentCount() async -> Int {
        await root.runtime.projection().agents.count
    }

    private func state(of agentID: AgentID) async -> AgentSummary? {
        await root.runtime.projection().agents.first { $0.id == agentID }
    }

    private func foregroundPID(of agentID: AgentID) -> UInt64? {
        guard let terminalID = root.registry.binding(for: agentID)?.terminalID else { return nil }
        let pid = root.sessionManager.foregroundPID(for: terminalID) ?? 0
        return pid > 0 ? pid : nil
    }

    private func writeReport(exitCode: Int) {
        let payload: [String: Any] = [
            "scenario": "ATERM_SCENARIO=new-agent",
            "exitCode": exitCode,
            "failures": failures,
            "checks": checks,
        ]
        let path = ProcessInfo.processInfo.environment["ATERM_REPORT"]
            ?? "/tmp/aterm-new-agent-report.json"
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            print("REPORT serialization failed")
            return
        }
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        print("[REPORT] path=\(path)")
    }
}

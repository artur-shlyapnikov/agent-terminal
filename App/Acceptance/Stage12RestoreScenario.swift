import AgentControl
import AgentCore
import AgentStore
import AppKit
import Darwin

// Stage-12 live verification (§3.15). Driven by ATERM_SCENARIO:
//
//   quit-resume-later — fake-agent shells + an openCode-kind agent with a
//                       captured session reference; programmatic
//                       Quit-and-Resume-Later: processes die, ONLY the
//                       resumable row gets resume_requested=1, app run clean,
//                       layout flushed. Report carries the persisted ids.
//   clean-restore     — second process on the same DB: RestoreCoordinator's
//                       plan is executed by bootstrapRuntime; the resumed
//                       agent runs the adapter-generated command through the
//                       real ticketed launch; flag cleared after confirmed
//                       launch; shells NOT relaunched.
//   crash-setup       — same population, then exit(9) WITHOUT cleanup.
//   crash-recovery    — second process after the crash: NO auto-starts,
//                       Recovery Center lists every previously-running agent;
//                       Archive / Start Fresh / Resume driven through the
//                       REAL controller actions.

@MainActor
final class Stage12RestoreScenario {
    enum Mode: String {
        case quitResumeLater = "quit-resume-later"
        case cleanRestore = "clean-restore"
        case crashSetup = "crash-setup"
        case crashRecovery = "crash-recovery"
        case quitStopClears = "quit-stop-clears"
    }

    static var mode: Mode? {
        ProcessInfo.processInfo.environment["ATERM_SCENARIO"].flatMap(Mode.init(rawValue:))
    }

    private let root: AppCompositionRoot
    private let mode: Mode
    private var failures: [String] = []
    private var checks: [[String: String]] = []
    private(set) var createdIDs: [String] = []
    private(set) var resumableID = ""

    init(root: AppCompositionRoot) {
        self.root = root
        mode = Self.mode ?? .quitResumeLater
    }

    // MARK: plumbing

    private func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        checks.append(["name": name, "ok": condition ? "1" : "0", "detail": detail])
        if !condition {
            failures.append(name)
        }
        print("[S12-\(mode.rawValue)] \(condition ? "PASS" : "FAIL") \(name) \(detail)")
    }

    private func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.05,
                           _ condition: () async -> Bool) async -> Bool
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return await condition()
    }

    private func scalar(_ sql: String) async -> String? {
        guard let db = root.database else { return nil }
        return try? await db.pool.read { try String.fetchOne($0, sql: sql) }
    }

    private func pid(of terminalID: TerminalID) -> UInt64? {
        root.sessionManager.foregroundPID(for: terminalID)
    }

    private func pidAlive(_ pid: UInt64) -> Bool {
        kill(pid_t(pid), 0) == 0
    }

    private func setTerminal(_ agentID: AgentID, _ terminalID: TerminalID) async {
        guard let database = root.database else { return }
        try? await database.pool.write { db in
            try db.execute(
                sql: "UPDATE agents SET terminal_id = ? WHERE id = ?",
                arguments: [terminalID.rawValue.uuidString, agentID.rawValue.uuidString]
            )
        }
    }

    /// Registers/refreshes the store row for a runtime-created session so
    /// DatabaseWriter snapshot commits can land on it (§3.14 upsert rule).
    private func registerStoreRow(
        id: AgentID, workspace: WorkspaceID, terminal: TerminalID?,
        kind: AgentKind, name: String
    ) async throws {
        guard let repository = root.agentRepository else { return }
        let now = root.clock.now
        let session = AgentSession(
            id: id,
            workspaceID: workspace,
            terminalID: nil,
            kind: kind,
            displayName: name,
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: kind, program: "/bin/true", workingDirectory: "/tmp"
            ),
            state: AgentState(
                process: .running(pid: nil, processGroupID: nil),
                lifecycle: .starting,
                attention: .none,
                authority: .process,
                revision: 0,
                observedAt: now
            ),
            createdAt: now,
            lastActivityAt: now
        )
        try await repository.register(session)
        if terminal != nil {
            await setTerminal(id, terminal!)
        }
    }

    func run() async {
        let code: Int
        do {
            switch mode {
            case .quitResumeLater:
                try await runQuitResumeLater(crashAtEnd: false)
            case .crashSetup:
                try await runQuitResumeLater(crashAtEnd: true)
            case .cleanRestore:
                try await runCleanRestore()
            case .crashRecovery:
                try await runCrashRecovery()
            case .quitStopClears:
                try await runQuitStopClears()
            }
            code = failures.isEmpty ? 0 : 1
        } catch {
            print("[S12-FAIL] scenario error: \(error)")
            code = 1
        }
        writeReport(exitCode: code)
        print("DONE mode=\(mode.rawValue) exit=\(code)")
        if mode == .crashSetup, failures.isEmpty {
            exit(9) // THE CRASH: no cleanup, no run-row close (§3.15)
        }
        exit(Int32(code))
    }

    // MARK: shared population builder

    /// AppDelegate's ATERM_SCENARIO branch already bootstrapped the runtime
    /// (control-plane start is not idempotent); this only builds agents.
    private func buildPopulation() async throws {
        guard let workspace = root.activeWorkspaceID else {
            check("workspace available", false)
            throw CancellationError()
        }
        // FK bridge: the runtime workspace is in-memory only; persist the row
        // so agents.workspace_id resolves.
        try? await root.workspaceRepository?.save(
            Workspace(id: workspace, name: "Default", rootPath: NSHomeDirectory(),
                      createdAt: root.clock.now, updatedAt: root.clock.now),
            sortIndex: 0
        )

        // Two fake-agent shells through the REAL pipeline.
        for name in ["Shell One", "Shell Two"] {
            let id = try await root.coordinator.createAgent(
                AgentLaunchRequest(
                    agentKind: .genericShell,
                    workingDirectory: "/tmp",
                    displayName: name
                ),
                in: workspace
            )
            createdIDs.append(id.rawValue.uuidString)
            if let bound = root.registry.binding(for: id) {
                do {
                    try await registerStoreRow(
                        id: id, workspace: workspace, terminal: bound.terminalID,
                        kind: .genericShell, name: name
                    )
                } catch {
                    print("[S12-DBG] register \(name) failed: \(error)")
                }
            }
        }
        // openCode-kind agent on a DEDICATED host surface: a pipeline shell
        // ("OpenCode Host") provides the real pty; its persisted row is then
        // REPLACED by the openCode row because agents.terminal_id is UNIQUE.
        let hostID = try await root.coordinator.createAgent(
            AgentLaunchRequest(
                agentKind: .genericShell,
                workingDirectory: "/tmp",
                displayName: "OpenCode Host"
            ),
            in: workspace
        )
        guard let hostTerminal = root.registry.binding(for: hostID)?.terminalID else {
            check("host surface for opencode-kind agent", false)
            throw CancellationError()
        }
        let cID = try await root.runtime.createAgent(
            AgentLaunchRequest(
                agentKind: .openCode,
                workingDirectory: "/tmp",
                displayName: "Fake OpenCode"
            ),
            in: workspace
        )
        try await root.runtime.surfaceCreated(
            agentID: cID, terminalID: hostTerminal,
            generation: .initial, pid: nil, processGroupID: nil
        )
        createdIDs.append(cID.rawValue.uuidString)
        resumableID = cID.rawValue.uuidString

        if let database = root.database {
            try? await database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM agents WHERE id = ?",
                    arguments: [hostID.rawValue.uuidString]
                )
            }
        }
        do {
            try await registerStoreRow(
                id: cID, workspace: workspace, terminal: hostTerminal,
                kind: .openCode, name: "Fake OpenCode"
            )
        } catch {
            print("[S12-DBG] register Fake OpenCode failed: \(error)")
        }

        // Capture the session identity through the runtime evidence path.
        let reference = SessionReference(agentKind: .openCode, opaquePayload: "scenario-session-42")
        let envelope = ObservationEnvelope(
            agentID: cID,
            terminalID: hostTerminal,
            surfaceGeneration: .initial,
            sourceID: "hook:scenario",
            sourceKind: .integration,
            sequence: 1,
            outputRevision: 1,
            observedAt: root.clock.now,
            receivedAt: root.clock.now
        )
        await root.runtime.ingest(Evidence(envelope: envelope, payload: .sessionIdentity(reference)))

        // Packages gap bridge: ledger references never reach StateCommit, so
        // persist the reference explicitly (stage-16 hardening item).
        var refPersisted = false
        for _ in 0 ..< 10 {
            if let repository = root.agentRepository,
               let existing = try? await repository.find(cID),
               let captured = await root.runtime.capturedSessionReference(of: cID)
            {
                var updated = existing
                updated.sessionReference = captured
                do { try await repository.save(updated); refPersisted = true }
                catch { print("[S12-DBG] ref save failed: \(error)") }
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        check("reference bridge applied", refPersisted)
        await check("session reference persisted",
                    waitUntil(timeout: 10) {
                        await self.scalar(
                            "SELECT session_ref_json IS NOT NULL FROM agents WHERE id='\(resumableID)'"
                        ) == "1"
                    },
                    "agents=" + (scalar("SELECT COUNT(*) FROM agents") ?? "?"))
        await check("three agent rows persisted",
                    scalar("SELECT COUNT(*) FROM agents") == "3")
    }

    private func runQuitResumeLater(crashAtEnd: Bool) async throws {
        try await buildPopulation()

        let pids = Array(Set(root.model.agentTerminal.values.compactMap { pid(of: $0) }))
        check("agent processes launched", pids.count >= 3, "pids=\(pids)")

        if crashAtEnd {
            check("unclosed run left behind", root.currentRunID != nil)
            return // report written, then exit(9)
        }

        // Seed a REAL persisted layout (clean-restore step-3 input): select
        // the resumable agent into the canvas so the snapshot flushed at
        // quit carries an agent leaf + selection under the stable key.
        if let resumable = UUID(uuidString: resumableID) {
            root.commands.select(.agent(AgentID(rawValue: resumable)))
            root.persistLayoutSnapshot()
            try? await Task.sleep(nanoseconds: 600_000_000) // debounce window
        }
        let preview = await root.shutdownCoordinator.makePreview()
        check("preview marks exactly one resumable",
              preview.resumable.count == 1 && preview.resumable.first?.id.rawValue.uuidString == resumableID,
              "resumable=\(preview.resumable.map(\.displayName))")
        check("preview lists unsupported sessions",
              preview.unsupported.count == 3 &&
                  preview.unsupported.allSatisfy { $0.reasonText != nil },
              preview.unsupportedSummary ?? "none")

        let proceed = await root.shutdownCoordinator.performQuit(.quitAndResumeLater)
        check("quit-and-resume-later proceeds to terminate", proceed)

        await check("processes terminated",
                    waitUntil(timeout: 12) { pids.allSatisfy { !self.pidAlive($0) } },
                    "alive=\(pids.filter { self.pidAlive($0) }.count)")

        await check("resume_requested set ONLY for resumable",
                    waitUntil(timeout: 5) {
                        let flagged = await self.scalar(
                            "SELECT COUNT(*) FROM agents WHERE resume_requested = 1"
                        ) ?? "0"
                        let mine = await self.scalar(
                            "SELECT resume_requested FROM agents WHERE id='\(self.resumableID)'"
                        ) ?? "?"
                        return flagged == "1" && mine == "1"
                    })

        let lastRun = await scalar(
            "SELECT termination_kind FROM app_runs ORDER BY id DESC LIMIT 1"
        )
        check("app run marked clean", lastRun == "clean", String(describing: lastRun))

        let layouts = await scalar("SELECT COUNT(*) FROM layouts") ?? "0"
        check("layout flushed on quit", Int(layouts) ?? 0 >= 1, "rows=\(layouts)")
    }

    private func runCleanRestore() async throws {
        guard let oldResumeID = UUID(uuidString: ProcessInfo.processInfo.environment["ATERM_RESUME_AGENT_ID"] ?? "")
        else {
            check("resume id passed via env", false)
            return
        }
        let oldShellIDs = Set((ProcessInfo.processInfo.environment["ATERM_SHELL_AGENT_IDS"] ?? "")
            .split(separator: ",").map(String.init))
        guard !oldShellIDs.isEmpty else {
            check("shell ids provided via env", false)
            return
        }

        check("restore produced a clean plan",
              root.restorePlan != nil && !root.recoveryPending,
              String(describing: root.restorePlan))

        let mapped = await waitUntil(timeout: 30) {
            self.root.resumedMappings[AgentID(rawValue: oldResumeID)] != nil
        }
        check("resume executed and mapped", mapped,
              String(describing: root.resumedMappings))
        let newAgentID = root.resumedMappings[AgentID(rawValue: oldResumeID)]

        if let newAgentID {
            _ = await waitUntil(timeout: 20) { self.root.registry.binding(for: newAgentID) != nil }
            if let terminal = root.registry.binding(for: newAgentID)?.terminalID,
               let processPID = pid(of: terminal)
            {
                await check("resumed process alive (adapter command ran)",
                            waitUntil(timeout: 15) { self.pidAlive(processPID) },
                            "pid=\(processPID)")
            } else {
                check("resumed process alive (adapter command ran)", false, "no pid")
            }
        }

        // Final fix (review #3): the superseded row is archived once the new
        // launch is confirmed — it can never resurface as a recovery
        // candidate after a later crash.
        await check("superseded row archived once launch confirmed",
                    waitUntil(timeout: 5) {
                        await self.scalar(
                            "SELECT archived_at IS NOT NULL FROM agents WHERE id='\(oldResumeID.uuidString)'"
                        ) == "1"
                    })

        // Final fix (review #2): clean-restore step 3 — the persisted pane
        // structure came back and the resumed agent remounted under its
        // mapped live id with the persisted selection.
        if let newAgentID {
            let canvas = root.mainWindowController.splitController.canvas
            await check("layout restore remounted resumed agent with persisted selection",
                        waitUntil(timeout: 5) {
                            if case let .agent(live)? = canvas.focusedContent {
                                return live == newAgentID
                            }
                            return false
                        },
                        String(describing: canvas.focusedContent))
        }

        await check("flag cleared after confirmed launch",
                    waitUntil(timeout: 5) {
                        await self.scalar(
                            "SELECT resume_requested FROM agents WHERE id='\(oldResumeID.uuidString)'"
                        ) == "0"
                    })

        let list = oldShellIDs.map { "'\($0)'" }.joined(separator: ",")
        let unflagged = await scalar(
            "SELECT COUNT(*) FROM agents WHERE id IN (\(list)) AND resume_requested = 0"
        )
        check("shells not marked nor relaunched",
              unflagged == "\(oldShellIDs.count)",
              unflagged ?? "query failed")
        await check("exactly one runtime session exists (no shell auto-start)",
                    root.runtime.projection().agents.count == 1,
                    "count=\(root.runtime.projection().agents.count)")
    }

    /// Final fix (review #4): 'Quit and Stop Agents' must disarm any stale
    /// resume_requested so the next launch never auto-executes a superseded
    /// intent.
    private func runQuitStopClears() async throws {
        try await buildPopulation()

        // A failed resume cycle left the flag armed (launch never confirmed).
        let staleID = resumableID
        if let database = root.database {
            try? await database.pool.write { db in
                try db.execute(
                    sql: "UPDATE agents SET resume_requested = 1 WHERE id = ?",
                    arguments: [staleID]
                )
            }
        }
        await check("stale flag armed before quit",
                    scalar(
                        "SELECT COUNT(*) FROM agents WHERE resume_requested = 1"
                    ) == "1")

        let proceed = await root.shutdownCoordinator.performQuit(.quitAndStopAgents)
        check("quit-and-stop proceeds to terminate", proceed)

        await check("stale resume flags cleared by quit-and-stop",
                    waitUntil(timeout: 8) {
                        await self.scalar(
                            "SELECT COUNT(*) FROM agents WHERE resume_requested = 1"
                        ) == "0"
                    })
    }

    private func runCrashRecovery() async throws {
        guard case let .crashRecovery(recovery)? = root.restorePlan else {
            check("crash recovery plan generated", false, String(describing: root.restorePlan))
            return
        }
        check("recovery candidates listed", recovery.candidates.count == 3,
              recovery.candidates.map(\.displayName).debugDescription)
        check("nothing auto-started",
              root.model.agents.isEmpty && root.registry.bindings.isEmpty,
              "agents=\(root.model.agents.count)")

        let claudeLike = recovery.candidates.first { $0.canResume }
        check("resumable candidate keeps preserved reference",
              claudeLike?.sessionReference?.opaquePayload == "scenario-session-42")
        check("start-fresh-only candidates reported",
              recovery.candidates.filter { !$0.canResume }.count == 2)

        // Drive the REAL Recovery Center actions.
        root.presentRecoveryCenter()
        guard let center = root.recoveryCenter else {
            check("recovery center presented", false)
            return
        }

        let ids = recovery.candidates
        var archivedID: AgentID?

        // 1. Archive the first start-fresh-only candidate.
        if let candidate = ids.first(where: { !$0.canResume }) {
            archivedID = candidate.agentID
            center.archiveClicked(button(candidate.agentID))
            await check("archive sets archived_at",
                        waitUntil(timeout: 5) {
                            await self.scalar(
                                "SELECT archived_at IS NOT NULL FROM agents WHERE id='\(candidate.agentID.rawValue.uuidString)'"
                            ) ==
                                "1"
                        })
        }

        // 2. Start Fresh for the other.
        if let candidate = ids.first(where: { !$0.canResume && $0.agentID != archivedID }) {
            center.startFreshClicked(button(candidate.agentID))
            await check("start fresh launches a new session",
                        waitUntil(timeout: 25) { await self.root.runtime.projection().agents.count == 1 },
                        "count=\(root.runtime.projection().agents.count)")
        }

        // 3. Resume the supported one; the OLD reference stays in the row.
        if let candidate = claudeLike {
            let refBefore = await scalar(
                "SELECT session_ref_json FROM agents WHERE id='\(candidate.agentID.rawValue.uuidString)'"
            )
            center.resumeClicked(button(candidate.agentID))
            await check("resume launches through the pipeline",
                        waitUntil(timeout: 30) { await self.root.runtime.projection().agents.count == 2 },
                        "count=\(root.runtime.projection().agents.count)")
            let refAfter = await scalar(
                "SELECT session_ref_json FROM agents WHERE id='\(candidate.agentID.rawValue.uuidString)'"
            )
            check("old session reference preserved across recovery", refBefore == refAfter && refAfter != nil)
        }

        await check("recovery center closed after all resolved",
                    waitUntil(timeout: 5) { self.root.recoveryCenter == nil })
    }

    private func button(_ id: AgentID) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.identifier = NSUserInterfaceItemIdentifier(id.rawValue.uuidString)
        return b
    }

    // MARK: report

    private func writeReport(exitCode: Int) {
        let payload: [String: Any] = [
            "scenario": "ATERM_SCENARIO=\(mode.rawValue)",
            "exitCode": exitCode,
            "failures": failures,
            "checks": checks,
            "createdIDs": createdIDs,
            "resumableID": resumableID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            print("REPORT serialization failed; exitCode=\(exitCode)")
            return
        }
        print(json)
        let base = ProcessInfo.processInfo.environment["ATERM_REPORT"] ?? "/tmp/aterm-stage12-report.json"
        try? json.write(toFile: base + "-\(mode.rawValue).json", atomically: true, encoding: .utf8)
    }
}

import AgentControl
import AgentCore
import AgentStore
import AppKit
import TerminalKit

// Sole service construction site (architecture §4.6). Everything the shell
// needs is built here exactly once and handed down; no other file constructs
// TerminalKit/AgentCore services.
//
// Stage 8 replaces the placeholder seam driving with the real stack:
//   FakeClock + RealtimeClockDriver (wall-clock domain timing)
//   AgentRuntime ← TerminalControlling(TerminalSessionManager)
//               ← StatePersisting(DatabaseWriter, degradation-safe §3.12A)
//               ← DetectionScheduler/ScreenDetectionEngine (bundled manifests)
//   ControlServer stack at the DEFAULT socket (hooks/idempotency/broker)
// The EventStreamBroker owns the ONLY runtime.deltaStream() subscription;
// UI deltas flow through a broker subscription (§3.2).

@MainActor
final class AppCompositionRoot {
    // Two-phase initialization (constructed vs adopted terminal stack):
    // assigned exactly once inside commonInit before any read.
    private(set) var engine: GhosttyEngine!
    private(set) var parkingHost: TerminalParkingHost!
    private(set) var sessionManager: TerminalSessionManager!

    // Stage-8 real stack.
    private(set) var clock: FakeClock!
    private(set) var clockDriver: RealtimeClockDriver!
    private(set) var runtime: AgentRuntime!
    private(set) var registry: AgentTerminalRegistry!
    private(set) var detectionPipeline: DetectionPipeline!
    private(set) var coordinator: AgentExecutionCoordinator!
    private(set) var controlPlane: ControlPlaneComposer!
    private(set) var persistenceWriter: DatabaseWriter?

    private(set) var runtimeSeam: RuntimeSeam!
    private(set) var promptCoordinator: PromptCoordinator!
    private(set) var model: AppModel!
    private(set) var focusCoordinator: FocusCoordinator!
    private(set) var mainWindowController: MainWindowController!
    private(set) var statusItem: StatusItemController!
    /// Retained menu/shortcut controller — Review5 #1: menu items hold weak
    /// targets, so this MUST be owned for the app's lifetime.
    private(set) var commands: AppCommands!
    /// Stage-10 (§3.13): UN notifications with §3.13 suppression + click
    /// navigation. Retained here — the only construction site.
    private(set) var notificationCoordinator: NotificationCoordinator!
    /// §4.6 "Integration Setup…" observer token — kept so the registration
    /// is removable in deinit instead of living for the app lifetime by
    /// accident.
    private var integrationSettingsObserver: NSObjectProtocol?

    deinit {
        if let integrationSettingsObserver {
            NotificationCenter.default.removeObserver(integrationSettingsObserver)
        }
    }

    /// §3.17 diagnostics/Repair (review item 6): the sole IntegrationInstaller
    /// for the app's lifetime, read through RuntimeSeam by the inspector.
    private(set) var integrationInstaller: IntegrationInstaller!
    /// Retained install-recording backing the installer; AgentStore-backed
    /// (stage-16 item A) so diagnose() reflects persisted installs across runs.
    private(set) var installRecording: PersistentInstallRecording!
    /// §3.22 redacted diagnostic bundle export.
    private(set) var diagnosticExporter: DiagnosticExporter!
    /// §4.6 first-run onboarding. Set by the app delegate BEFORE
    /// bootstrapRuntime so no implicit Default workspace is created while the
    /// operator picks their first folder.
    var onboardingPending = false
    private var onboarder: OnboardingController?

    /// Stage-12 restore/shutdown stack (§3.15).
    private(set) var database: AgentStore.AgentDatabase?
    /// The ONE workspace identity for this run: the active workspace's
    /// persisted ID, registered verbatim in the runtime (§3.14). Runtime,
    /// store rows, layout keys and control-plane listings all use it.
    private(set) var activeWorkspaceID: WorkspaceID?
    private(set) var agentRepository: AgentStore.AgentRepository?
    private(set) var appRunRepository: AppRunRepository?
    private(set) var layoutRepository: LayoutRepository?
    private(set) var workspaceRepository: WorkspaceRepository?
    private(set) var restoreCoordinator: RestoreCoordinator?
    private(set) var shutdownCoordinator: ShutdownCoordinator!
    private(set) var currentRunID: Int64?
    private(set) var restorePlan: RestorePlan?
    private(set) var recoveryCenter: RecoveryCenterController?
    private(set) var recoveryPending = false
    /// persisted agent id → live runtime agent id after a successful resume.
    private(set) var resumedMappings: [AgentID: AgentID] = [:]
    private var restorePrepared = false
    private var resumesExecuted = false
    private var layoutRestored = false
    /// Automation entry (stage-5 acceptance): AGENTTERMINAL_AUTOSHELL=<N>.
    static var autoShellCount: Int {
        guard let raw = ProcessInfo.processInfo.environment["AGENTTERMINAL_AUTOSHELL"],
              let n = Int(raw), n > 0 else { return 0 }
        return n
    }

    /// Stage-8 agent-lifecycle scenario entry: AGENTTERMINAL_AUTOAGENT=1.
    static var autoAgentScenario: Bool {
        ProcessInfo.processInfo.environment["AGENTTERMINAL_AUTOAGENT"] == "1"
    }

    // MARK: ghostty config (Review5 note): Application Support by default,

    // hermetic override via ATERM_GHOSTTY_CONFIG_DIR for automation runs.

    static func makeGhosttyConfig() -> String {
        let fm = FileManager.default
        let dir: String = if let override = ProcessInfo.processInfo.environment["ATERM_GHOSTTY_CONFIG_DIR"] {
            override
        } else {
            AppPaths.applicationSupport()
                .appendingPathComponent("AgentTerminal/ghostty", isDirectory: true).path
        }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/config"
        if !fm.fileExists(atPath: path) {
            try? "font-size = 13".write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    /// Locates the AgentLauncher helper: app bundle first, then explicit env
    /// override, then known development build locations.
    static func locateLauncherExecutable() -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["ATERM_LAUNCHER_PATH"],
           fm.isExecutableFile(atPath: p)
        {
            return URL(fileURLWithPath: p)
        }
        if let exe = Bundle.main.executableURL {
            for candidate in ["Helpers/AgentLauncher", "AgentLauncher"] {
                let url = exe.deletingLastPathComponent().appendingPathComponent(candidate)
                if fm.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        // Development fallbacks relative to the repository root.
        let root = (#file as NSString).deletingLastPathComponent // App/Sources
        let repo = (root as NSString).deletingLastPathComponent // App/
        let repoParent = (repo as NSString).deletingLastPathComponent // repo root
        let devCandidates = [
            repoParent + "/App/build/Debug/AgentLauncher",
            repoParent + "/Packages/.build-runtime-wiring/debug/agentlauncher",
        ]
        for candidate in devCandidates where fm.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Persistence identity row registration happens through this repository.
    private func makeAgentRepository() -> AgentRepository? {
        database.map { AgentRepository(database: $0) }
    }

    init() throws {
        try GhosttyEngine.globalInit()
        print("[LAUNCH] init: engine+parking+manager")
        let engine = try GhosttyEngine(
            configLoader: GhosttyConfigLoader(path: URL(fileURLWithPath: Self.makeGhosttyConfig()))
        )
        let parkingHost = TerminalParkingHost()
        // Raw shells choke on bracketed paste; agents re-enable per launch.
        let sessionManager = TerminalSessionManager(
            engine: engine,
            parkingHost: parkingHost,
            ticketWriter: LaunchTicketWriter(),
            environmentResolver: ShellEnvironmentResolver(),
            inputBracketedPaste: false
        )
        commonInit(engine: engine, parkingHost: parkingHost,
                   sessionManager: sessionManager, shells: [])
    }

    init(adopting stack: AdoptedTerminalStack) {
        let shells = stack.sessions.enumerated().map { index, session in
            AppModel.ShellInfo(terminalID: session.id, name: "Shell \(index + 1)", cwd: session.cwd)
        }
        commonInit(
            engine: stack.engine,
            parkingHost: stack.parkingHost,
            sessionManager: stack.sessionManager,
            shells: shells
        )
    }

    private func commonInit(engine: GhosttyEngine,
                            parkingHost: TerminalParkingHost,
                            sessionManager: TerminalSessionManager,
                            shells: [AppModel.ShellInfo])
    {
        self.engine = engine
        self.parkingHost = parkingHost
        self.sessionManager = sessionManager

        // Domain clock driven by real monotonic time (watchdogs, grace
        // periods, detection cadence all run wall-clock in production).
        clock = FakeClock()
        clockDriver = RealtimeClockDriver(clock: clock)

        runtime = AgentRuntime(clock: clock)
        print("[LAUNCH] adopt: runtime")

        registry = AgentTerminalRegistry()
        model = AppModel()
        model.nowProvider = { [weak self] in self?.clock.now ?? .zero }
        for shell in shells {
            model.add(shell: shell)
        }
        // Persistence (§3.14): failure to open degrades to a banner, never to
        // a dead runtime (§3.12A). ATERM_DB_PATH hermetically redirects the
        // store for automation runs.
        do {
            let url = ProcessInfo.processInfo.environment["ATERM_DB_PATH"]
                .map { URL(fileURLWithPath: $0) } ?? AgentDatabase.defaultDatabaseURL()
            // Stage-16 gate 6a: a corrupt store is quarantined (never
            // deleted) and replaced with a fresh one; the operator SEES the
            // quarantine via the persistent banner — never silent.
            let (database, quarantined) = try AgentDatabase.openWithCorruptionQuarantine(
                databaseURL: url
            )
            self.database = database
            if let quarantined {
                print("[LAUNCH] corrupt database quarantined at \(quarantined.path)")
                DiagnosticsLogRing.shared.record(
                    "corrupt database quarantined at \(quarantined.path); fresh store created"
                )
                model.setDegradedBanner(
                    "Database was corrupted and has been preserved at " +
                        "\(quarantined.path). A fresh store was created; " +
                        "restore from backup if needed.",
                    sticky: true
                )
            }
            let writer = DatabaseWriter(transactor: PoolTransactor(pool: database.pool))
            persistenceWriter = writer
            // Stage-12 repositories (§3.15/§4.4).
            agentRepository = AgentRepository(database: database)
            appRunRepository = AppRunRepository(database: database)
            layoutRepository = LayoutRepository(transactor: PoolTransactor(pool: database.pool))
            workspaceRepository = WorkspaceRepository(database: database)
            // §5.2: corrupt workspace-layout quarantine surfaces through the
            // package's corruption sink into the diagnostics ring.
            WorkspaceCorruptionNotice.shared.install { line in
                Task { @MainActor in
                    DiagnosticsLogRing.shared.record(line)
                }
            }
            restoreCoordinator = RestoreCoordinator(database: database)
        } catch {
            print("[LAUNCH] persistence unavailable, degrading: \(error)")
            model.setDegradedBanner("Persistence unavailable — \(error)")
        }

        // Screen-evidence pipeline FIRST: the coordinator owns it (suspend on
        // user stop, invalidate on generation cutover) — no registry global.
        detectionPipeline = DetectionPipeline(
            clock: clock,
            registry: registry,
            sessionManager: sessionManager,
            runtime: runtime
        )

        let controlHooks = HookAuthenticator()
        let pipeline = AgentExecutionCoordinator(
            runtime: runtime,
            clock: clock,
            sessionManager: sessionManager,
            registry: registry,
            model: model,
            hooks: controlHooks,
            agentRepository: makeAgentRepository(),
            launcherExecutable: Self.locateLauncherExecutable(),
            controlSocketPath: UnixSocketServer.defaultPath(),
            detectionPipeline: detectionPipeline
        )
        coordinator = pipeline
        // Control-plane lifecycle operations go through the coordinator:
        // creates spawn the FULL launch flow (surface + persistence + hook
        // token), stops classify user intent and compensate suspensions —
        // bare runtime calls would strand "starting" sessions or misclassify
        // exits (agentctl-created zombie agents, historically).
        controlPlane = ControlPlaneComposer(
            runtime: runtime,
            hooks: controlHooks,
            launchAgent: { [weak pipeline] request, workspaceID in
                guard let pipeline else {
                    throw ControlFailure(code: .internalError, message: "launch coordinator unavailable")
                }
                return try await pipeline.createAgent(request, in: workspaceID)
            },
            stopAgent: { [weak pipeline] agentID, mode in
                guard let pipeline else {
                    throw ControlFailure(code: .internalError, message: "launch coordinator unavailable")
                }
                try await pipeline.stop(agentID, mode: mode)
            },
            focusAgent: { [weak self, runtime] agentID in
                // Full focus semantics: runtime visibility + the SAME
                // selection path a sidebar click takes (select → mount).
                guard let runtime else { return }
                try await runtime.focus(agentID)
                guard let self else { return }
                await focusAgentInUI(agentID)
            }
        )

        runtimeSeam = RuntimeSeam(
            runtime: runtime, sessionManager: sessionManager, model: model
        )
        runtimeSeam.coordinator = coordinator
        // Agent teardown: when the model drops an agent, the seam's per-item
        // visibility bookkeeping (pending/finished Task handles) must go too.
        model.onAgentRemoved = { [weak runtimeSeam] agentID in
            runtimeSeam?.clearVisibilityState(for: .agent(agentID))
        }

        // Stage-9 (§3.9/§3.11): when-ready initial prompts + watchdog surfacing.
        promptCoordinator = PromptCoordinator(runtime: runtime, clock: clock, model: model)
        coordinator.promptCoordinator = promptCoordinator
        runtimeSeam.promptCoordinator = promptCoordinator

        focusCoordinator = FocusCoordinator(seam: runtimeSeam, model: model)
        let canvas = AgentCanvasController(
            sessionManager: sessionManager,
            model: model,
            seam: runtimeSeam,
            focusCoordinator: focusCoordinator
        )
        mainWindowController = MainWindowController(
            canvas: canvas,
            model: model,
            seam: runtimeSeam,
            focusCoordinator: focusCoordinator
        )
        statusItem = StatusItemController(
            model: model,
            createItem: Self.autoShellCount == 0,
            root: self
        )
        // Review5 #1: retained HERE — menu items target this weakly.
        commands = AppCommands(root: self, installMenu: Self.autoShellCount == 0)
        print("[LAUNCH] adopt: window built")

        // Stage-12 shutdown coordinator (§3.15). The layout flush seam keeps
        // the debounced writer behind a closure so quit ordering stays explicit.
        shutdownCoordinator = ShutdownCoordinator(root: self) { [weak self] in
            guard let layoutRepository = self?.layoutRepository else { return }
            try await layoutRepository.flushNow()
        }

        // §3.17 diagnostics/Repair (review item 6): one installer for the
        // app's lifetime, handed to the seam the inspector reads through.
        // Stage-16 item A: recording persists through AgentStore's
        // IntegrationRepository so diagnose() survives relaunch.
        installRecording = PersistentInstallRecording(
            repository: database.map { IntegrationRepository(database: $0) }
        )
        integrationInstaller = IntegrationInstaller(
            recording: installRecording,
            homeDirectory: NSHomeDirectory()
        )
        runtimeSeam.integrationInstaller = integrationInstaller
        // §3.22: redacted diagnostic export over the same services.
        diagnosticExporter = DiagnosticExporter(root: self, recording: installRecording)
        notificationCoordinator = NotificationCoordinator(model: model)
        notificationCoordinator.navigate = { [weak self] agentID in
            guard let self else { return }
            mainWindowController.showAndKey()
            commands.select(.agent(agentID))
        }
        // §4.6 onboarding "Integration Setup…" entry point → Settings window.
        integrationSettingsObserver = NotificationCenter.default.addObserver(
            forName: .atermOpenIntegrationSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                SettingsWindowController.present(root: self)
            }
        }
        notificationCoordinator.isAgentVisible = { [weak self] agentID in
            guard let self, let terminal = model.agentTerminal[agentID] else { return false }
            if case .mounted = self.sessionManager.session(for: terminal)?.presentation {
                return true
            }
            return false
        }
        notificationCoordinator.isPaneFocused = { [weak self] agentID in
            self?.mainWindowController.splitController.canvas.focusedContent == .agent(agentID)
        }

        // §3.9 bottom: an initial prompt whose validated idle never arrived
        // within 30 s is NEVER blind-sent — the text returns as a draft.
        promptCoordinator.onInitialPromptTimeout = { [weak self] agentID, text in
            // The draft belongs to the currently focused agent only; never
            // clobber the visible draft if the user switched agents.
            guard let self,
                  mainWindowController.splitController.canvas.focusedContent == .agent(agentID) else { return }
            mainWindowController.composer.restoreDraft(text)
        }

        wire()
        if Self.autoShellCount == 0 {
            consumeDeltas()
        }
    }

    func startDeltaConsumption() {
        consumeDeltas()
    }

    /// Async half of bootstrapping — actor-isolated runtime calls. Called only
    /// AFTER surfaces exist (§3.18 ordering).
    func bootstrapRuntime() async {
        // Quit latched before bootstrap even started: spawn NOTHING (the
        // ordering law forbids new work after the quit ladder begins) and
        // open no run row that nobody would close.
        guard !shutdownCoordinator.isTerminating else {
            print("[LAUNCH] quit during bootstrap: skipping startup entirely")
            return
        }
        // Stage-12 (§3.15) FIRST: unclosed-run detection + the fresh app_runs
        // row MUST precede any surface or agent activity.
        await prepareRestoreIfNeeded()

        // prepareRestoreIfNeeded bails when quit raced its await; nothing
        // below may run against a tearing-down stack.
        guard !shutdownCoordinator.isTerminating else { return }

        if activeWorkspaceID == nil, !onboardingPending {
            await adoptWorkspaces()
        }
        if activeWorkspaceID == nil, onboardingPending {
            print("[LAUNCH] first run: workspace creation deferred to onboarding")
        }
        await runtime.setTerminalPort(sessionManager)
        if let writer = persistenceWriter {
            await runtime.setPersistence(writer)
        }
        let socketDir = (UnixSocketServer.defaultPath() as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
        await controlPlane.start()
        if let error = controlPlane.startError {
            print("[LAUNCH] control plane failed to start: \(error)")
            model.setDegradedBanner("Control plane unavailable — \(error)")
        } else {
            let boundPath = await controlPlane.server?.path
            print("[LAUNCH] control plane live at \(boundPath ?? "?")")
        }
        detectionPipeline.exitReporter = { [weak coordinator] terminalID, generation in
            guard let coordinator else { return }
            try await coordinator.handleProcessExit(terminalID: terminalID, generation: generation)
        }
        detectionPipeline.start()
        monitorPersistenceHealth()

        // §3.15 clean restore steps 7–8: fresh surfaces running the
        // adapter-generated resume commands. Crash plans NEVER reach here.
        await executePendingResumes()

        // Stage-10 (§3.13): notifications only in interactive runs — the
        // authorization prompt must never surface under automation.
        if Self.autoShellCount == 0, !Self.autoAgentScenario {
            Task { await notificationCoordinator.activate() }
        }

        // Clean-restore step 3 (§3.14/§3.15): the canvas is rebuilt from the
        // layout persisted under the STABLE workspace key, so the operator
        // finds the same pane structure (and selection) across launches.
        // Only actually-live agents remount; everything else degrades to a
        // placeholder.
        await restorePersistedLayout()
    }

    private func prepareRestoreIfNeeded() async {
        guard !restorePrepared else { return }
        restorePrepared = true
        guard let restoreCoordinator else { return }
        // W2/S3: quit latched BEFORE the restore await — do not open this
        // process's app_runs row at all, so finishShutdown's nil-currentRunID
        // skip cannot strand an open row for the next launch to misread as a
        // crash.
        guard !shutdownCoordinator.isTerminating else {
            print("[LAUNCH] quit during bootstrap: restore coordination skipped")
            return
        }
        do {
            let plan = try await restoreCoordinator.prepareStartup()
            // prepareStartup opened THIS process's run row inside its own
            // transaction. A quit that raced the await above means the
            // teardown may already have passed its endRun step (which skips
            // while currentRunID is still nil). Close the just-opened row
            // HERE and keep currentRunID nil, so exactly one closer exists
            // under every interleaving:
            //   • latch set before prepareStartup → no row opened;
            //   • latch set during prepareStartup → closed here;
            //   • latch set after this point → currentRunID is published
            //     (no await between the check below and the assignment), so
            //     finishShutdown's own endRun closes it.
            if shutdownCoordinator.isTerminating {
                print("[LAUNCH] quit during bootstrap: closing run row \(plan.currentRunID)")
                do {
                    try await appRunRepository?.endRun(plan.currentRunID, kind: .clean)
                } catch {
                    DiagnosticsLogRing.shared.record(
                        "quit-raced bootstrap run-row close failed for \(plan.currentRunID): \(error)"
                    )
                }
                return
            }
            restorePlan = plan
            print("[RESTORE] plan decided: \(plan)")
            currentRunID = plan.currentRunID
            if case .crashRecovery = plan {
                recoveryPending = true
            }
            if case let .clean(clean) = plan {
                if !clean.unsupported.isEmpty {
                    print("[RESTORE] unsupported sessions reported at startup: " +
                        clean.unsupported.map { "\($0.displayName): \($0.reasonText)" }.joined(separator: "; "))
                }
                // Corrupt reference blobs are data corruption (§3.15), not an
                // adapter report: surface them loudly. The run row closed
                // clean, so a full Recovery Center plan would misreport
                // unclosed runs — banner + log is the honest surface.
                if !clean.crashCandidates.isEmpty {
                    print("[RESTORE] corrupt session references at startup: " +
                        clean.crashCandidates.map { "\($0.displayName)" }.joined(separator: "; "))
                    model.setDegradedBanner(
                        "Restore found \(clean.crashCandidates.count) corrupt session reference(s) — see log"
                    )
                }
            }
        } catch {
            print("[LAUNCH] restore coordination failed, degrading: \(error)")
            model.setDegradedBanner("Restore check failed — \(error)")
        }
    }

    private func executePendingResumes() async {
        guard !resumesExecuted else { return }
        resumesExecuted = true
        guard case let .clean(clean)? = restorePlan, !clean.resumes.isEmpty else { return }
        // Each resume launches in ITS OWN persisted workspace — the runtime
        // holds every persisted row, so per-action identities are live.
        for action in clean.resumes {
            do {
                let newID = try await coordinator.executeResume(action, in: action.workspaceID)
                resumedMappings[action.persistedAgentID] = newID
                print("[RESTORE] resumed \(action.displayName) → \(newID.rawValue.uuidString.prefix(8))")
            } catch {
                // Old session reference preserved; flag stays set for a later
                // successful launch (§3.15).
                print("[RESTORE] resume FAILED for \(action.displayName): \(error)")
                model.setDegradedBanner("Resume failed — \(action.displayName): \(error)")
            }
        }
    }

    /// ONE durable identity (§3.14): persisted workspace rows are opened in
    /// the runtime under their OWN ids — the runtime mints nothing. A first
    /// run without onboarding persists ONE Default workspace and registers
    /// the exact same instance, so runtime sessions, agent rows, layout keys
    /// and control-plane listings share a single WorkspaceID from birth.
    private func adoptWorkspaces() async {
        guard activeWorkspaceID == nil else { return }
        if let repository = workspaceRepository {
            var workspaces = await ((try? repository.fetchAll()) ?? []).map(\.workspace)
            if workspaces.isEmpty {
                let workspace = Workspace(
                    name: "Default", rootPath: NSHomeDirectory(),
                    createdAt: clock.now, updatedAt: clock.now
                )
                do {
                    try await repository.save(workspace, sortIndex: 0)
                } catch {
                    DiagnosticsLogRing.shared.record("workspace persist failed: \(error)")
                }
                workspaces = [workspace]
            }
            for workspace in workspaces {
                await runtime.openWorkspace(workspace)
            }
            activeWorkspaceID = workspaces.first?.id
        } else {
            // Persistence degraded (§3.12A): the run still needs an identity
            // for launches; nothing is durably anchored this run.
            activeWorkspaceID = await runtime.createWorkspace(
                name: "Default", rootPath: NSHomeDirectory()
            )
        }
        print("[LAUNCH] active workspace \(activeWorkspaceID?.rawValue.uuidString.prefix(8) ?? "nil")")
    }

    /// Debounced layout capture (§3.14): every model change snapshots the
    /// canvas tree + selection under THE workspace identity (layout travels
    /// with its workspace row — no separate anchor key exists anymore).
    func persistLayoutSnapshot() {
        guard let layoutRepository, let key = activeWorkspaceID else { return }
        let canvas = mainWindowController.splitController.canvas
        var selected: AgentID?
        if case let .agent(id) = canvas.focusedContent {
            selected = id
        }
        let tree = canvas.planner.tree
        Task { await layoutRepository.store(workspaceID: key, tree: tree, selectedAgentID: selected) }
    }

    /// Clean-restore step 3 (§3.15): load the persisted canvas layout under
    /// the stable workspace key and rebuild the tree with its original pane
    /// structure. Leaf contents are re-bound to THIS run's reality: resumed
    /// agents remount through their persisted→live id mapping, dead shells
    /// and non-resumed agents degrade to placeholders. Nothing persisted →
    /// the default empty canvas stays.
    private func restorePersistedLayout() async {
        guard !layoutRestored else { return }
        layoutRestored = true
        guard let layoutRepository,
              let key = activeWorkspaceID,
              let restored = try? await layoutRepository.load(workspaceID: key) else { return }
        let mappedTree = Self.liveTree(
            from: restored.tree,
            resumedMappings: resumedMappings,
            liveAgentTerminals: model.agentTerminal
        )
        // A tree whose every leaf degraded to a placeholder has no operator
        // value: it just replays the dead session's split geometry as N
        // identical "Empty pane" panes (reads as a rendering bug). Structure
        // is only worth preserving when something actually remounts into it,
        // so keep the default single empty canvas instead.
        guard mappedTree.leaves.contains(where: {
            if case .agent = $0.content {
                return true
            }; return false
        })
        else {
            print("[RESTORE] layout had no live agents - keeping default empty canvas")
            return
        }
        let mappedSelection = Self.liveSelection(
            restored.selectedAgentID,
            resumedMappings: resumedMappings,
            tree: mappedTree
        )
        mainWindowController.splitController.canvas.applyRestored(
            tree: mappedTree, selectedAgentID: mappedSelection
        )
    }

    /// Pure re-bind of a restored leaf content to the live process (unit-
    /// tested): agent ids resolve through the resume mapping when one exists
    /// and must reference a LIVE terminal; raw shells never survive a
    /// relaunch (TerminalIDs are minted per process).
    static func liveTree(
        from restored: LayoutTree,
        resumedMappings: [AgentID: AgentID],
        liveAgentTerminals: [AgentID: TerminalID]
    ) -> LayoutTree {
        func mapping(_ node: LayoutTree.Node) -> LayoutTree.Node {
            switch node {
            case let .leaf(pane, content):
                switch content {
                case let .agent(id):
                    let live = resumedMappings[id] ?? id
                    if liveAgentTerminals[live] != nil {
                        return .leaf(pane, .agent(live))
                    }
                    return .leaf(pane, .placeholder)
                case .terminal:
                    return .leaf(pane, .placeholder)
                case .placeholder:
                    return node
                }
            case let .split(axis, ratio, first, second):
                return .split(axis, ratio, mapping(first), mapping(second))
            }
        }
        return LayoutTree(root: mapping(restored.rootNode))
    }

    /// Pure selection re-bind: the persisted selection follows its resume
    /// mapping and only survives when it is actually visible in the live
    /// tree.
    static func liveSelection(
        _ selected: AgentID?,
        resumedMappings: [AgentID: AgentID],
        tree: LayoutTree
    ) -> AgentID? {
        guard let selected else { return nil }
        let live = resumedMappings[selected] ?? selected
        return tree.contains(agent: live) ? live : nil
    }

    /// Presents the Recovery Center INSTEAD of keying the normal window
    /// content when the previous run terminated uncleanly (§3.15).
    /// Returns false when nothing was presented: either the plan is not a
    /// crash-recovery plan, or it crashed with ZERO running agents — nothing
    /// needs an operator decision, so presenting a buttonless window would
    /// deadlock launch. Clears `recoveryPending` in every not-presented path
    /// so reopen/quit routing falls back to the normal window.
    @discardableResult
    func presentRecoveryCenter() -> Bool {
        if case let .crashRecovery(recovery)? = restorePlan {
            guard !recovery.candidates.isEmpty else {
                // Crash with zero running agents: nothing to decide, and the
                // Center renders buttonless — presenting would deadlock launch.
                print("[RESTORE] crash recovery plan has no candidates - skipping Recovery Center")
                recoveryPending = false
                return false
            }
            let controller = RecoveryCenterController(plan: recovery, root: self)
            recoveryCenter = controller
            controller.present()
            return true
        }
        recoveryPending = false
        return false
    }

    /// Recovery Center resolved its last candidate: hand control back to the
    /// normal shell (§3.15).
    func recoveryCenterDidFinish() {
        recoveryCenter = nil
        mainWindowController.showAndKey()
        focusCoordinator.start()
    }

    /// Control-plane focus → sidebar-click-equivalent selection (§3.16):
    /// selects the agent in the canvas, mounting its surface pane.
    func focusAgentInUI(_ agentID: AgentID) {
        mainWindowController?.splitController.canvas
            .sidebarClicked(item: .agent(agentID), kind: .plain)
    }

    /// §3.12F/§3.15: dock-icon reopen routes to the key UI of the moment —
    /// the main window normally, but the Recovery Center while a crash
    /// recovery is still pending (the main window stays parked behind it).
    func reopenPrimaryUI() {
        if recoveryPending {
            recoveryCenter?.bringToFront()
        } else {
            mainWindowController.showAndKey()
        }
    }

    // MARK: - Stage-15 onboarding (§4.6) + workspace opening (§3.13)

    /// §4.6 first-run condition: persistence available AND no workspace rows.
    /// Scenario/automation runs never onboard (the app delegate guards).
    func shouldShowOnboarding() async -> Bool {
        guard let repository = workspaceRepository else { return false }
        let stored = await (try? repository.fetchAll()) ?? []
        return stored.isEmpty && !onboardingPending
    }

    func presentOnboarding() {
        onboardingPending = true
        let controller = OnboardingController()
        controller.onboardingDelegate = self
        onboarder = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Creates the first workspace from the operator-chosen folder, then hands
    /// control to the normal shell (mirrors recoveryCenterDidFinish ordering).
    private func completeOnboarding(rootPath: String) async {
        onboarder = nil
        let name = URL(fileURLWithPath: rootPath).lastPathComponent.isEmpty
            ? "Default" : URL(fileURLWithPath: rootPath).lastPathComponent
        let now = clock.now
        // ONE identity from birth: persist the workspace, then register the
        // SAME instance in the runtime — no runtime-side re-minting, no
        // mirror, no separate layout anchor.
        let live = Workspace(name: name, rootPath: rootPath,
                             createdAt: now, updatedAt: now)
        do {
            try await workspaceRepository?.save(live, sortIndex: 0)
        } catch {
            DiagnosticsLogRing.shared.record("onboarding workspace persist failed: \(error)")
        }
        await runtime.openWorkspace(live)
        activeWorkspaceID = live.id
        onboardingPending = false
        mainWindowController.showAndKey()
        focusCoordinator.start()
    }

    /// §3.13 "Open Workspace" palette/menu action: registers a new workspace
    /// row and points NEW launches at it. Existing agents stay where they are.
    func openWorkspace(rootPath: String) async {
        let name = URL(fileURLWithPath: rootPath).lastPathComponent
        let now = clock.now
        let resolvedName = name.isEmpty ? "Workspace" : name
        let live = Workspace(name: resolvedName, rootPath: rootPath,
                             createdAt: now, updatedAt: now)
        do {
            try await workspaceRepository?.save(live, sortIndex: nextSortIndex())
        } catch {
            DiagnosticsLogRing.shared.record("workspace persist failed: \(error)")
        }
        await runtime.openWorkspace(live)
        activeWorkspaceID = live.id
        DiagnosticsLogRing.shared.record("opened workspace \(resolvedName) → active for new agents")
    }

    /// Sidebar position for a newly opened workspace (after every row).
    private func nextSortIndex() async -> Int {
        await (((try? workspaceRepository?.fetchAll()) ?? []).map(\.sortIndex).max() ?? -1) + 1
    }

    private func wire() {
        model.onChange = { [weak self] in
            guard let self else { return }
            statusItem.refresh()
            mainWindowController.refreshChrome()
            notificationCoordinator.modelDidChange()
            persistLayoutSnapshot()
        }
        sessionManager.appEventSink = { [weak self] event in
            switch event.payload {
            case .closeWindowRequested:
                // Surface-initiated close requests park through the same path as ⌘W.
                self?.mainWindowController.closeViewForTerminal(event.terminalID)
            case let .openURL(_, url):
                // Runtime-level URL opens (now that the callback router is
                // wired) reach the consumer here; malformed strings are ignored.
                if let url = URL(string: url) {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
        // Exit-poll sink → coordinator (stale generations dropped there AND
        // in the runtime ledger — belt and suspenders per §3.6).
        sessionManager.processExitSink = { [weak coordinator] terminalID, generation, observation in
            // Fire-and-forget from the manager's poll loop; failures release
            // the exactly-once gate inside the coordinator so a later
            // detection tick re-drives the transition.
            guard let coordinator else { return }
            Task {
                try? await coordinator.handleProcessExit(
                    terminalID: terminalID, generation: generation,
                    observation: observation
                )
            }
        }
    }

    /// Persistence-degraded banner (§3.14 step 8). Health changes NEVER touch
    /// the runtime itself (§3.12A).
    private func monitorPersistenceHealth() {
        guard let writer = persistenceWriter else { return }
        Task { @MainActor [weak self] in
            let updates = await writer.healthUpdates()
            for await health in updates {
                self?.model.apply(persistenceHealth: health)
            }
        }
    }

    /// UI projection consumption (§3.2): per-agent summaries through the
    /// broker's fan-out — the raw runtime.deltaStream() has exactly ONE
    /// consumer (the broker pump).
    private func consumeDeltas() {
        Task { @MainActor [weak self] in
            var backoff: Duration = .milliseconds(500)
            while !Task.isCancelled, let self {
                let broker = controlPlane.broker
                let stream = await broker.subscribe(agentID: nil)
                do {
                    for try await summary in stream {
                        guard !Task.isCancelled else { return }
                        model.upsert(agent: summary)
                        detectionPipeline.lifecycleChanged(summary: summary)
                        // Healthy delivery: transient-error backoff no
                        // longer applies to much-later resubscriptions.
                        backoff = .milliseconds(500)
                    }
                    // Normal stream end (broker shutdown): do not resubscribe.
                    return
                } catch {
                    DiagnosticsLogRing.shared.record(
                        "broker stream error; resubscribing in \(backoff): \(error)"
                    )
                    if Task.isCancelled {
                        return
                    }
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(8))
                }
            }
        }
    }

    func shutdown() async {
        focusCoordinator.stop()
        detectionPipeline.stop()
        clockDriver.stop()
        // Await (not fire-and-forget): the process must not exit before the
        // socket is unlinked and in-flight requests drain.
        if let server = controlPlane.server {
            await server.stop()
        }
    }
}

/// §4.6: onboarding completion hands the chosen folder back to the root.
extension AppCompositionRoot: OnboardingDelegate {
    func onboardingDidFinish(rootPath: String) {
        Task { await completeOnboarding(rootPath: rootPath) }
    }
}

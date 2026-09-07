import AgentControl
import AgentCore
import AgentStore
import Foundation
import TerminalKit

// Agent execution coordinator (§3.12 flows C/D): the ONE deep module owning
// the agent lifecycle saga — create, restart, stop, resume and process-exit
// classification. Every agent surface is created HERE and nowhere else.
//
// Ordering invariant preserved from stage 5 (§3.18): surface creation is pure
// synchronous AppKit/TerminalKit work on the main actor. The only runtime
// round-trips happen strictly BEFORE (createAgent) or strictly AFTER
// (surfaceCreated) the spawn — never interleaved with it.
//
// Ticketed launch (§3.9): ONE scoped integration token is minted per process
// generation, registered with the HookAuthenticator AND carried inside the
// LaunchTicket together with the live control socket path, so hook reports
// authenticate against exactly the generation that minted them.
//
// Ownership consolidated here (previously spread across the composition
// root, RuntimeSeam and a weak global): launch/restart transaction ordering,
// terminal generation cutover, hook token lifetime, user-stop intent,
// exactly-once exit admission, detection suspend/invalidate, agent↔terminal
// binding metadata and compensating cleanup.

@MainActor
final class AgentExecutionCoordinator {
    private let runtime: AgentRuntime
    private let clock: FakeClock
    private let sessionManager: TerminalSessionManager
    private let registry: AgentTerminalRegistry
    private let model: AppModel
    private let hooks: HookAuthenticator
    /// Screen-evidence pipeline: suspended for user stops, invalidated on
    /// generation cutover. Owned here — no registry global.
    private let detectionPipeline: DetectionPipeline?
    /// Exactly-once admission for process-exit reports from BOTH paths
    /// (session-manager sink AND detection reporter).
    private let exitGate = ProcessExitGate()
    private let agentRepository: AgentRepository?
    /// Absolute path of the AgentLauncher helper executable (nil when the
    /// helper cannot be located — creation then fails with a clear error).
    private let launcherExecutable: URL?
    /// Path of the running UnixSocketServer (tickets must point at it).
    private let controlSocketPath: String
    /// Catalog matching the runtime's standard set, used to rebuild launch
    /// descriptors for relaunches (the runtime owns the originals).
    private let catalog = AgentCatalog.standard()

    // Workspace identity note: callers pass the workspace explicitly; the
    // runtime registered it under its persisted ID, so launch, persistence
    // row and layout share ONE WorkspaceID — no anchor translation here.

    /// Live integration token per agent (diagnostics + control-plane flows).
    private(set) var activeTokens: [AgentID: String] = [:]

    /// Stage-9: owns when-ready initial-prompt delivery (§3.9). Weak — the
    /// composition root owns the coordinator.
    weak var promptCoordinator: PromptCoordinator?

    /// Original creation request per agent — the restart relaunch input.
    private var launchRequests: [AgentID: AgentLaunchRequest] = [:]
    /// Creation-time workspace per agent — restart must respawn in the
    /// workspace the agent was created in, not whichever workspace is
    /// active at restart time (the runtime session never moves).
    private var launchWorkspaces: [AgentID: WorkspaceID] = [:]
    /// Agents whose exit the USER commanded (gracefulStop), consulted by the
    /// exit sink to distinguish stopped(userRequested) from completed.
    private(set) var userStoppedAgents: Set<AgentID> = []
    /// In-flight superseded-surface retire ladders keyed by terminalID, so
    /// the quit path can drain them instead of orphaning a mid-ladder Task
    /// (which would leave the superseded process never SIGKILLed).
    private var pendingRetires: [TerminalID: Task<Void, Never>] = [:]

    init(runtime: AgentRuntime,
         clock: FakeClock,
         sessionManager: TerminalSessionManager,
         registry: AgentTerminalRegistry,
         model: AppModel,
         hooks: HookAuthenticator,
         agentRepository: AgentRepository?,
         launcherExecutable: URL?,
         controlSocketPath: String,
         detectionPipeline: DetectionPipeline? = nil)
    {
        self.runtime = runtime
        self.clock = clock
        self.sessionManager = sessionManager
        self.registry = registry
        self.model = model
        self.hooks = hooks
        self.agentRepository = agentRepository
        self.launcherExecutable = launcherExecutable
        self.controlSocketPath = controlSocketPath
        self.detectionPipeline = detectionPipeline
    }

    // MARK: - Creation (§3.5 rows 1–2)

    func createAgent(
        _ request: AgentLaunchRequest,
        in workspaceID: WorkspaceID,
        initialPrompt: String? = nil
    ) async throws -> AgentID {
        // §6.6 gate FIRST: a missing CLI must yield an actionable error
        // WITHOUT any runtime mutation (no zombie starting session).
        guard Self.resolveExecutable(for: request.agentKind) != nil else {
            throw ControlFailure(
                code: .launchFailed,
                message: Self.missingExecutableMessage(for: request.agentKind)
            )
        }
        // §6.6 preflight: hoist every remaining DETERMINISTIC failure of the
        // spawn tail (helper missing / adapter refusal / unresolvable argv[0])
        // so a doomed launch throws BEFORE runtime.createAgent strands a
        // fresh "starting" session + persistence row.
        try preflightLaunch(kind: request.agentKind, request: request)
        // 1. Runtime creates the session (starting/launching). Its FIRST
        //    persistence commit carries the full session identity, so the
        //    writer fabricates the durable row itself — no caller-side DB
        //    registration ordering (§3.14 self-sufficient commit).
        let agentID = try await runtime.createAgent(request, in: workspaceID)

        // 2. Mint ONE scoped token for the INITIAL generation: registered
        //    with the authenticator and minted into the ticket.
        let token = Self.mintToken()
        activeTokens[agentID] = token
        await hooks.register(agentID: agentID, surfaceGeneration: .initial, token: token)

        // 3. Surface spawn — synchronous, no runtime round-trip inside.
        let terminalID: TerminalID
        do {
            terminalID = try spawnSurface(
                agentID: agentID, workspaceID: workspaceID,
                request: request, generation: .initial,
                integrationToken: token
            )
        } catch {
            // Residual failure AFTER runtime/token mutations: drop the scoped
            // token so nothing stays half-registered, fail the session
            // through the runtime's launchFailed semantic command (no
            // "starting" zombie), then surface the error.
            await hooks.invalidate(agentID: agentID)
            activeTokens[agentID] = nil
            try? await runtime.launchFailed(agentID: agentID, reason: "\(error)")
            throw error
        }

        // 4. Report success back into the runtime (§3.5 row 2).
        try await runtime.surfaceCreated(
            agentID: agentID,
            terminalID: terminalID,
            generation: .initial,
            pid: nil,
            processGroupID: nil
        )

        launchRequests[agentID] = request
        launchWorkspaces[agentID] = workspaceID
        // 5. When-ready initial prompt (§3.9 bottom): delivered at the first
        //    VALIDATED idle; 30 s timeout returns it to the composer draft.
        //    The text is never persisted or logged — it lives only inside the
        //    coordinator until delivery or timeout.
        if let initialPrompt, !initialPrompt.isEmpty {
            promptCoordinator?.scheduleInitialPrompt(agentID: agentID, text: initialPrompt)
        }
        return agentID
    }

    // MARK: - Restart (§3.5 row "Surface generation changed")

    /// One restart per agent at a time: overlapping restarts would both read
    /// the same pre-restart binding, spawn duplicate successors, and orphan
    /// the first (its token invalidated, its rebind overwritten) — a live
    /// process with no binding. Later callers coalesce onto the in-flight
    /// restart's result.
    private var inFlightRestarts: [AgentID: Task<Void, Error>] = [:]

    func restartAgent(_ agentID: AgentID) async throws {
        if let existing = inFlightRestarts[agentID] {
            return try await existing.value
        }
        // The map entry is cleared by the TASK BODY's defer, not by the
        // first awaiter: between task completion and the awaiter's
        // resumption other MainActor work can interleave, and a caller
        // arriving in that window would coalesce onto the COMPLETED task
        // and replay its success instead of starting a fresh restart.
        // The body is MainActor-isolated, so the clear strictly precedes
        // completion and every awaiter resumption. (The pipeline is an
        // app-lifetime object; the weak-self bail-out is unreachable in
        // practice but keeps the closure from extending teardown.)
        let task = Task { [weak self] () throws in
            guard let self else { return }
            defer { self.inFlightRestarts[agentID] = nil }
            try await self.performRestart(agentID)
        }
        inFlightRestarts[agentID] = task
        return try await task.value
    }

    /// Allocates the NEW surface generation; every observation of the old
    /// generation is dropped by runtime + authenticator from the moment the
    /// runtime transition applies.
    private func performRestart(_ agentID: AgentID) async throws {
        guard let binding = registry.binding(for: agentID),
              let request = launchRequests[agentID],
              let workspace = launchWorkspaces[agentID]
        else {
            // Raw shells / unknown bindings carry no relaunch semantics; the
            // bare runtime transition still records the intent.
            try await runtime.restart(agentID)
            return
        }

        let newGeneration = binding.nextGeneration
        let oldTerminalID = binding.terminalID

        // §6.6 preflight FIRST: the retire ladder below is irreversible, so
        // every deterministic spawn failure must throw BEFORE runtime.restart
        // tears down the old surface with no successor able to bind.
        try preflightLaunch(kind: request.agentKind, request: request)
        // 1. Runtime transition first: ledgers drop ALL old-generation evidence.
        try await runtime.restart(agentID)

        // 2. Old token dies; reports from the old generation are rejected stale.
        await hooks.invalidate(agentID: agentID)

        // 3. Screen hysteresis forgets everything about the agent.
        detectionPipeline?.generationInvalidated(agentID: agentID)

        // 4. Retire the old surface (graceful ladder, then teardown).
        retire(terminalID: oldTerminalID)

        // 5. Fresh scoped token for the successor generation — registered AND
        //    minted into the new ticket so reports authenticate.
        let token = Self.mintToken()
        activeTokens[agentID] = token
        await hooks.register(agentID: agentID, surfaceGeneration: newGeneration, token: token)

        // 6. Spawn the successor surface — same ordering discipline as creation.
        let newTerminalID: TerminalID
        do {
            newTerminalID = try spawnSurface(
                agentID: agentID, workspaceID: workspace,
                request: request, generation: newGeneration,
                integrationToken: token
            )
        } catch {
            // Preflight removed the deterministic failures; this is residual.
            // The retire ladder cannot be rolled back — best-effort: drop the
            // freshly minted token (nothing re-registers it) and rethrow the
            // original error.
            await hooks.invalidate(agentID: agentID)
            activeTokens[agentID] = nil
            throw error
        }

        // 7. Bind the successor terminal EVERYWHERE: the runtime learns the
        //    new single-live-terminal binding (reattach — review M-restart),
        //    then the shell registry follows. From here prompt/stop/read/
        //    sendKeys/watchdog traffic flows against the successor surface.
        do {
            try await runtime.reattach(
                agentID: agentID,
                terminalID: newTerminalID,
                generation: newGeneration
            )
        } catch {
            // Residual reattach failure (e.g. session desync): the freshly
            // spawned successor would stay alive yet unbound while the
            // registry still routes traffic to the retired terminal. Tear it
            // down through the same §3.11 ladder used for superseded
            // surfaces, drop the successor token (nothing binds it), and
            // drop the registry binding — no binding may reference a
            // retired terminal; the agent row stays, unbound, until a
            // later launch/restart binds a live surface again. Rethrow.
            retire(terminalID: newTerminalID)
            registry.remove(agentID: agentID)
            await hooks.invalidate(agentID: agentID)
            activeTokens[agentID] = nil
            throw error
        }
        registry.rebind(
            agentID: agentID,
            newTerminalID: newTerminalID,
            generation: newGeneration
        )
    }

    /// §3.9 ticket law: execve requires ABSOLUTE argv[0]. Adapter resume
    /// specs use bare names ("claude"), so resolve against PATH here.
    nonisolated static func resolveExecutable(_ name: String) -> String? {
        guard !name.contains("/") else { return name }
        // getenv (NOT ProcessInfo) so in-process setenv from scenarios is
        // honored when probing stub executables.
        let searchPath = getenv("PATH").map { String(cString: $0) }
            ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Stage-15 (§4.6 New Agent sheet / stage-6 gap): scans an adapter's
    /// `executableCandidates` against PATH and returns the first hit as an
    /// ABSOLUTE path, or nil when nothing exists. Generic shells always
    /// resolve (their candidates are absolute).
    private nonisolated static let resolutionCatalog = AgentCatalog.standard()

    /// Static variant for form-model validation seams (no pipeline instance).
    nonisolated static func resolveExecutable(for kind: AgentKind) -> String? {
        guard let adapter = resolutionCatalog.adapter(for: kind) else { return nil }
        for candidate in adapter.executableCandidates {
            if let resolved = resolveExecutable(candidate) {
                return resolved
            }
        }
        return nil
    }

    /// §6.6 acceptance gate: a missing CLI yields an ACTIONABLE error — what
    /// is missing, how to install it — never a bare failure.
    nonisolated static func missingExecutableMessage(for kind: AgentKind) -> String {
        switch kind {
        case .claudeCode:
            "Claude Code CLI not found on PATH. Install it with `npm install -g @anthropic-ai/claude-code` (or `brew install claude`), then try again."
        case .codex:
            "Codex CLI not found on PATH. Install it with `npm install -g @openai/codex`, then try again."
        case .openCode:
            "OpenCode CLI not found on PATH. Install it from https://opencode.ai/docs/installation, then try again."
        case .genericShell:
            "No shell found (looked for $SHELL, /bin/zsh, /bin/bash)."
        }
    }

    /// Executes one validated resume action produced by RestoreCoordinator:
    /// creates the runtime session, spawns a fresh surface running the
    /// ADAPTER-GENERATED resume command through the same ticketed pipeline,
    /// then clears the persisted `resume_requested` flag on the ORIGINAL
    /// agents row after the confirmed launch.
    func executeResume(
        _ action: RestoreResumeAction,
        in workspaceID: WorkspaceID
    ) async throws -> AgentID {
        guard let adapter = catalog.adapter(for: action.kind),
              var spec = adapter.buildResumeSpec(sessionReference: action.sessionReference)
        else {
            throw ControlFailure(
                code: .internalError,
                message: "resume unsupported for \(action.kind.rawValue)"
            )
        }
        // The create path (NewAgentSheet validation) refuses an empty
        // working directory; resume must too — a ticketed launch with cwd ""
        // is rejected by the launcher (exit 126) only AFTER createAgent has
        // minted a phantom 'starting' row and the original resume intent was
        // archived. Fail deterministically BEFORE any runtime mutation.
        guard !action.cwd.isEmpty else {
            throw ControlFailure(
                code: .launchFailed,
                message: "resume requires a working directory"
            )
        }
        if !action.cwd.isEmpty {
            spec.workingDirectory = action.cwd
        }
        if let first = spec.argv.first, !first.hasPrefix("/") {
            spec.argv[0] = Self.resolveExecutable(first) ?? first
        }

        let request = AgentLaunchRequest(
            agentKind: action.kind,
            workingDirectory: action.cwd,
            displayName: action.displayName,
            taskSummary: "resumed session"
        )
        // §6.6 preflight: fail deterministically (helper, adapter, argv[0]
        // resolution) BEFORE runtime.createAgent mints a phantom session row.
        try preflightLaunch(kind: action.kind, request: request, resumeArgv: spec.argv)
        let agentID = try await runtime.createAgent(request, in: workspaceID)
        // (Persistence needs no caller-side registration — see createAgent.)

        let token = Self.mintToken()
        activeTokens[agentID] = token
        await hooks.register(agentID: agentID, surfaceGeneration: .initial, token: token)

        // Minimal compile fix (stage-10): the ticketed launcher takes a
        // LaunchSpec; the adapter's ResumeSpec carries identical material.
        let launchSpec = LaunchSpec(
            argv: spec.argv,
            environment: spec.environment,
            workingDirectory: spec.workingDirectory
        )
        let terminalID: TerminalID
        do {
            terminalID = try bindAndSpawn(
                agentID: agentID, workspaceID: workspaceID, spec: launchSpec,
                kind: action.kind, displayName: action.displayName,
                cwd: action.cwd, generation: .initial, integrationToken: token
            )
        } catch {
            // Same residual-failure compensation as createAgent: drop the
            // token, fail the session through launchFailed (no "starting"
            // zombie), then rethrow.
            await hooks.invalidate(agentID: agentID)
            activeTokens[agentID] = nil
            try? await runtime.launchFailed(agentID: agentID, reason: "\(error)")
            throw error
        }
        try await runtime.surfaceCreated(
            agentID: agentID, terminalID: terminalID,
            generation: .initial, pid: nil, processGroupID: nil
        )
        launchRequests[agentID] = request
        launchWorkspaces[agentID] = workspaceID

        // §3.15 step 9 — only AFTER a confirmed launch: the superseded row
        // is archived (archived_at set, dead terminal_id detached) so it can
        // never resurface as a previously-running recovery candidate, and
        // its resume intent is consumed.
        do {
            try await agentRepository?.setResumeRequested(false, agentID: action.persistedAgentID)
        } catch {
            DiagnosticsLogRing.shared.record(
                "resume epilogue: consume resume_requested failed for \(action.persistedAgentID): \(error)"
            )
        }
        do {
            try await agentRepository?.archive(action.persistedAgentID)
        } catch {
            DiagnosticsLogRing.shared.record(
                "resume epilogue: archive failed for \(action.persistedAgentID): \(error)"
            )
        }
        return agentID
    }

    // MARK: - Interactive resume

    /// One interactive resume per agent at a time: overlapping resumes would
    /// both read the same pre-resume session reference and spawn DUPLICATE
    /// successor agents (the exact hazard the restart coalescing documents).
    /// Later callers coalesce onto the in-flight resume's result.
    private var inFlightResumes: [AgentID: Task<AgentID, Error>] = [:]

    /// Interactive resume (§3.12 flow C): the operator relaunches an
    /// already-mounted exited agent from the inspector/sidebar/palette.
    /// `RuntimeSeam.resume` keeps `runtime.resume`'s validation +
    /// `.resumeAttempted` timeline semantics; THIS performs the actual
    /// relaunch through executeResume's validated, ticketed pipeline. The
    /// superseded persisted row is the agent's OWN row — executeResume's
    /// epilogue archives it, so the consumed session reference can never
    /// resurface as a previously-running recovery candidate (§3.15).
    func executeInteractiveResume(of agentID: AgentID) async throws -> AgentID {
        if let existing = inFlightResumes[agentID] {
            return try await existing.value
        }
        // Same clear-by-the-task-body discipline as inFlightRestarts: the
        // body is MainActor-isolated, so the clear strictly precedes
        // completion and no awaiter coalesces onto a COMPLETED task.
        let task = Task { [weak self] () throws -> AgentID in
            guard let self else {
                throw ControlFailure(
                    code: .internalError,
                    message: "coordinator released during interactive resume"
                )
            }
            defer { self.inFlightResumes[agentID] = nil }
            return try await self.performInteractiveResume(agentID)
        }
        inFlightResumes[agentID] = task
        return try await task.value
    }

    /// Gathers the same inputs the restore path persists into
    /// RestoreResumeAction from the LIVE runtime session, then reuses
    /// executeResume verbatim (preflight, ticketed spawn, §3.15 epilogue).
    private func performInteractiveResume(_ agentID: AgentID) async throws -> AgentID {
        guard let descriptor = await runtime.launchDescriptor(of: agentID) else {
            throw ControlFailure(
                code: .internalError,
                message: "resume target \(agentID) has no runtime session"
            )
        }
        // Unsupported kinds (generic shell → buildResumeSpec nil) fail in
        // runtime.resume's validation or inside executeResume — never as a
        // silent no-op.
        guard let reference = await runtime.capturedSessionReference(of: agentID) else {
            throw ControlFailure(
                code: .internalError,
                message: "no session reference captured for \(descriptor.agentKind.rawValue)"
            )
        }
        guard let workspaceID = launchWorkspaces[agentID] else {
            throw ControlFailure(
                code: .internalError,
                message: "resume target \(agentID) has no known workspace"
            )
        }
        let original = launchRequests[agentID]
        let action = RestoreResumeAction(
            persistedAgentID: agentID,
            workspaceID: workspaceID,
            kind: descriptor.agentKind,
            displayName: model.agents[agentID]?.displayName
                ?? original?.displayName
                ?? descriptor.program,
            // The recorded CREATION-time working directory is authoritative;
            // the AppModel cwd mirror is a UI projection that can lag.
            cwd: original?.workingDirectory ?? model.agentCwd[agentID] ?? "",
            sessionReference: reference,
            // executeResume rebuilds the spec from the adapter via the
            // session reference; this stub argv is never used.
            resumeSpec: ResumeSpec(argv: [], workingDirectory: "")
        )
        return try await executeResume(action, in: workspaceID)
    }

    /// Marks `agentID` as user-stop-commanded so a subsequent clean exit maps
    /// to stopped(userRequested) instead of stopped(completed) (§3.5).
    func markUserStop(_ agentID: AgentID) {
        userStoppedAgents.insert(agentID)
        // From here the lifecycle belongs to the stop ladder — silence the
        // screen pipeline so no in-flight adoption regresses the state.
        detectionPipeline?.suspend(agentID: agentID)
    }

    func clearUserStop(_ agentID: AgentID) {
        userStoppedAgents.remove(agentID)
    }

    func isUserStopped(_ agentID: AgentID) -> Bool {
        userStoppedAgents.contains(agentID)
    }

    /// §3.17 inspector diagnostics: why screen detection demoted this
    /// agent's adapter to fallback (nil when never demoted).
    func versionFallbackReason(for agentID: AgentID) -> String? {
        detectionPipeline?.versionFallbackReason(for: agentID)
    }

    /// User-commanded stop (§3.11 stop modes): the FULL semantic operation,
    /// not a bare runtime call. gracefulStop marks user intent (a clean exit
    /// under the ladder maps to stopped(userRequested)) and silences the
    /// screen pipeline for the ladder's duration; interrupt passes through
    /// unmarked. On a stop that failed BEFORE any signal was sent, the
    /// suspension and the intent flag are compensated away — otherwise the
    /// agent would stay screen-blind and its eventual spontaneous exit would
    /// misclassify as user-requested.
    func stop(_ agentID: AgentID, mode: StopMode) async throws {
        let marksUserStop = (mode == .gracefulStop)
        if marksUserStop {
            markUserStop(agentID)
        }
        do {
            try await runtime.stop(agentID, mode: mode)
        } catch {
            if marksUserStop {
                clearUserStop(agentID)
                do {
                    let state = try await runtime.state(of: agentID)
                    if state.lifecycle.isTerminal == false {
                        detectionPipeline?.unsuspend(agentID: agentID)
                        DiagnosticsLogRing.shared.record(
                            "stop failed for live agent \(agentID); screen detection re-enabled: \(error)"
                        )
                        return
                    }
                } catch {
                    // agentNotFound — the agent is gone; state untouched.
                }
            }
            DiagnosticsLogRing.shared.record("stop failed for \(agentID): \(error)")
            throw error
        }
    }

    // MARK: - Process-exit ingestion (§3.5 exit rows; ADR-0002 primary signal)

    /// TerminalSessionManager observed a running→exited transition. Only the
    /// CURRENT generation of a bound agent reaches the runtime (§3.5 row
    /// "Surface generation changed": old-generation observations are inert).
    func handleProcessExit(
        terminalID: TerminalID,
        generation: SurfaceGeneration,
        observation: TerminalSessionManager.ExitObservation? = nil
    ) async throws {
        // Exactly-once exit reporting: whichever path (sink or detector)
        // observes the transition first admits it; the duplicate is dropped
        // here instead of double-driving the state machine.
        guard exitGate.admit(terminalID) else { return }
        guard let agentID = registry.agentID(for: terminalID),
              let binding = registry.binding(for: agentID),
              binding.surfaceGeneration == generation
        else {
            return // stale/superseded surface — silently dropped
        }
        var exitCode: Int32?
        var signal: Int32?
        if let observation {
            // Payload captured at the manager's observation point; the
            // session may already be reclaimed (parked-exit teardown).
            exitCode = observation.exitCode
            signal = observation.signal
        } else if case let .exited(code, sig, _) = sessionManager.session(for: terminalID)?.processPhase
            ?? .running(pid: nil, processGroupID: nil)
        {
            exitCode = code
            signal = sig
        }
        let userInitiated = isUserStopped(agentID)
        // §3.5 'Exit 0, user stop' row: when the USER commanded the stop and
        // the process died under our terminate/kill ladder, the observable
        // outcome IS a successful user-requested stop; libghostty's raw wait
        // status (signal death → 128+n) must not corrupt the lifecycle into
        // failed(). Raw status stays visible in the terminal itself.
        if userInitiated {
            exitCode = 0
            signal = nil
        }
        do {
            try await runtime.processExited(
                agentID: agentID,
                exitCode: exitCode,
                signal: signal,
                userInitiated: userInitiated
            )
        } catch {
            // Release the exactly-once slot so a later poll re-reports
            // the transition instead of losing it permanently. Rethrow so
            // the detection-pipeline reporter keeps its id unmarked and
            // retries on its next tick.
            exitGate.release(terminalID)
            DiagnosticsLogRing.shared.record(
                "process-exit report failed for \(agentID): \(error)"
            )
            throw error
        }
        // Consume the user-stop flag only AFTER the report succeeded: on a
        // transient failure the gate slot is released and the retry must
        // still classify the exit as user-initiated (§3.5).
        if userInitiated {
            clearUserStop(agentID)
        }
    }

    // MARK: - Internals

    /// §6.6/§3.9 launch preflight: resolves every DETERMINISTIC failure of
    /// the spawn tail (spawnSurface/bindAndSpawn) BEFORE any runtime,
    /// persistence, or token mutation — a doomed launch must never strand a
    /// freshly created "starting" session. Covers: AgentLauncher-helper
    /// availability, adapter lookup/refusal (descriptor construction), and
    /// PATH resolution of a bare argv[0]. Pass `resumeArgv` to validate an
    /// adapter-generated resume command instead of a launch descriptor.
    /// NOT covered (residual, compensated by the do/catch around each
    /// spawn): ghostty surface creation, ticket writing, working-directory
    /// exec validity — none are deterministically checkable here (the
    /// ticket writer lives privately inside TerminalSessionManager).
    private func preflightLaunch(
        kind: AgentKind,
        request: AgentLaunchRequest,
        resumeArgv: [String]? = nil
    ) throws {
        guard launcherExecutable != nil else {
            throw ControlFailure(
                code: .launchFailed,
                message: "AgentLauncher helper not found; cannot spawn surface"
            )
        }
        guard let adapter = catalog.adapter(for: kind) else {
            throw ControlFailure(
                code: .internalError,
                message: "no adapter for agent kind \(kind)"
            )
        }
        let argv: [String]
        if let resumeArgv {
            argv = resumeArgv
        } else {
            // Adapter refusal is deterministic — surface it up front.
            let descriptor = try adapter.makeLaunchDescriptor(request: request)
            argv = adapter.buildLaunchSpec(descriptor: descriptor).argv
        }
        // Mirror spawnSurface's §3.9 ticket law exactly: a bare argv[0] must
        // resolve on PATH, else fail with the actionable §6.6 error.
        if let first = argv.first, !first.hasPrefix("/"),
           Self.resolveExecutable(first) == nil
        {
            throw ControlFailure(
                code: .launchFailed,
                message: Self.missingExecutableMessage(for: kind)
            )
        }
    }

    private func spawnSurface(
        agentID: AgentID,
        workspaceID: WorkspaceID,
        request: AgentLaunchRequest,
        generation: SurfaceGeneration,
        integrationToken: String
    ) throws -> TerminalID {
        guard let adapter = catalog.adapter(for: request.agentKind) else {
            throw ControlFailure(
                code: .internalError,
                message: "no adapter for agent kind \(request.agentKind)"
            )
        }
        let descriptor = try adapter.makeLaunchDescriptor(request: request)
        var spec = adapter.buildLaunchSpec(descriptor: descriptor)
        // §3.9 ticket law: execve requires ABSOLUTE argv[0]. Adapter launch
        // descriptors use bare names ("claude"); resolve BEFORE the ticket is
        // written and fail with the §6.6 actionable error when missing.
        if let first = spec.argv.first, !first.hasPrefix("/") {
            guard let resolved = Self.resolveExecutable(first) else {
                throw ControlFailure(
                    code: .launchFailed,
                    message: Self.missingExecutableMessage(for: request.agentKind)
                )
            }
            spec.argv[0] = resolved
        }
        // Deterministic shell prompt for generic shells: the bundled-free
        // shell manifest recognizes "aterm$" at the line end as idle (§3.7).
        if request.agentKind == .genericShell {
            spec.environment["PS1"] = "aterm$ "
            spec.environment["PROMPT"] = "aterm$ "
        }
        return try bindAndSpawn(
            agentID: agentID, workspaceID: workspaceID, spec: spec,
            kind: request.agentKind, displayName: request.displayName,
            cwd: request.workingDirectory, generation: generation,
            integrationToken: integrationToken
        )
    }

    /// Shared tail of every surface creation: ticketed launch + registry
    /// binding + UI association. Synchronous AppKit/TerminalKit work only.
    private func bindAndSpawn(
        agentID: AgentID,
        workspaceID: WorkspaceID,
        spec: LaunchSpec,
        kind: AgentKind,
        displayName: String,
        cwd: String,
        generation: SurfaceGeneration,
        integrationToken: String
    ) throws -> TerminalID {
        // Minimal compile fix (stage-10): the inherited mid-flight edit left
        // this optional unguarded; ticketed launch requires a real helper.
        guard let launcherExecutable else {
            throw ControlFailure(
                code: .launchFailed,
                message: "AgentLauncher helper not found; cannot spawn surface"
            )
        }
        let session = try sessionManager.launch(
            workspaceID: workspaceID,
            agentID: agentID,
            spec: spec,
            launcherExecutable: launcherExecutable,
            integrationToken: integrationToken,
            controlSocketPath: controlSocketPath,
            surfaceGeneration: generation
        )

        registry.bind(
            agentID: agentID,
            to: AgentBinding(
                terminalID: session.id,
                surfaceGeneration: generation,
                kind: kind,
                displayName: displayName,
                cwd: cwd
            )
        )
        model.associate(terminal: session.id, cwd: cwd, for: agentID)
        return session.id
    }

    private func retire(terminalID: TerminalID) {
        let task = Task { @MainActor [weak self, sessionManager] in
            defer { self?.pendingRetires[terminalID] = nil }
            try? await sessionManager.sendSignal(.terminate, to: terminalID)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try? await sessionManager.sendSignal(.kill, to: terminalID)
            try? sessionManager.close(terminalID: terminalID)
        }
        pendingRetires[terminalID] = task
    }

    /// Awaits every in-flight retire ladder; ShutdownCoordinator calls this
    /// during quit so no superseded process outlives engine teardown.
    func awaitPendingRetires() async {
        for task in Array(pendingRetires.values) {
            await task.value
        }
    }

    private static func mintToken() -> String {
        UUID().uuidString
    }
}

/// Exactly-once admission gate for process-exit reports (review dedup item).
/// Both reporting paths — the TerminalSessionManager sink and the
/// DetectionPipeline poller — funnel through one shared instance owned by
/// AgentExecutionCoordinator, so a terminal's running→exited transition
/// drives the runtime state machine exactly once no matter which path
/// observed it first. Unit-testable.
@MainActor
final class ProcessExitGate {
    private var admitted: Set<TerminalID> = []

    /// Returns true the FIRST time a terminal is seen, false afterwards.
    func admit(_ terminalID: TerminalID) -> Bool {
        admitted.insert(terminalID).inserted
    }

    /// Releases a previously admitted terminal so a failed report can be
    /// re-admitted (and re-driven) by a later poll.
    func release(_ terminalID: TerminalID) {
        admitted.remove(terminalID)
    }
}

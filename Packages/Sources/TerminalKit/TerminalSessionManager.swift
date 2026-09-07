import AgentCore
import AppKit
import Foundation

// Surface registry and terminal port (architecture §3.8/§3.11): launch via
// LaunchTicketWriter + parking window, mount/park bookkeeping, input delivery,
// process-group signals, snapshots, and the poll-based child-exit watcher.
//
// Conforms to AgentCore.TerminalControlling — the runtime's only view of the
// terminal subsystem.

@MainActor public final class TerminalSessionManager: TerminalControlling {
    struct ManagedTerminal {
        var session: TerminalSession
        var surface: GhosttySurface?
        /// Working-activity token is released at most once per terminal,
        /// whichever path gets there first (close / signal / exit poll).
        var activityTokenReleased = false
    }

    private var terminals: [TerminalID: ManagedTerminal] = [:]

    private let engine: any TerminalEngine
    private let parkingHost: any TerminalParkingHosting
    private let mountCoordinator: TerminalMountCoordinator
    private let teardownQueue: TerminalTeardownQueue
    /// nil in fake-based setups that never exec a helper (tests/spike shell).
    private let ticketWriter: LaunchTicketWriter?
    private let environmentResolver: ShellEnvironmentResolver?
    private let activityManager: RuntimeActivityManager?
    /// Bracketed-paste prompt delivery (§3.11). On by default — agents enable
    /// bracketed paste — but raw shells choke on the escape sequences, so
    /// composition roots may turn it off for plain-terminal sessions.
    public var inputBracketedPaste: Bool

    /// Exit payload captured at the observation point (poll or engine event)
    /// and carried by `processExitSink`, so consumers never re-read a session
    /// that a concurrent teardown may already have removed from the registry.
    public struct ExitObservation: Sendable {
        public let exitCode: Int32?
        public let signal: Int32?

        public init(exitCode: Int32?, signal: Int32?) {
            self.exitCode = exitCode
            self.signal = signal
        }
    }

    /// Fired when a running→exited transition is observed.
    public var processExitSink: (@MainActor (TerminalID, SurfaceGeneration, ExitObservation) -> Void)?
    /// Fired for engine-level events (close-window requests etc.).
    public var appEventSink: (@MainActor (GhosttyEvent) -> Void)?

    public init(
        engine: any TerminalEngine,
        parkingHost: any TerminalParkingHosting,
        ticketWriter: LaunchTicketWriter? = nil,
        environmentResolver: ShellEnvironmentResolver? = nil,
        activityManager: RuntimeActivityManager? = nil,
        inputBracketedPaste: Bool = true
    ) {
        self.engine = engine
        self.inputBracketedPaste = inputBracketedPaste
        self.parkingHost = parkingHost
        mountCoordinator = TerminalMountCoordinator(parkingHost: parkingHost)
        teardownQueue = TerminalTeardownQueue()
        self.ticketWriter = ticketWriter
        self.environmentResolver = environmentResolver
        self.activityManager = activityManager
        engine.eventSink = { [weak self] event in
            self?.handleEngineEvent(event)
        }
    }

    // MARK: registry access

    public func session(for terminalID: TerminalID) -> TerminalSession? {
        terminals[terminalID]?.session
    }

    public var allSessions: [TerminalSession] {
        terminals.values.map(\.session)
    }

    // MARK: launching

    /// Direct launch (exact argv through the surface config; no ticket). Used
    /// for plain shells and by the spike.
    @discardableResult
    public func launchDirect(
        workspaceID: WorkspaceID,
        agentID: AgentID? = nil,
        spec: TerminalLaunchSpec
    ) throws -> TerminalSession {
        try launchSurface(workspaceID: workspaceID, agentID: agentID, spec: spec)
    }

    /// Ticketed launch (§3.9): writes a one-shot 0600 ticket and launches the
    /// fixed `AgentLauncher` executable with it as the only argument.
    @discardableResult
    public func launch(
        workspaceID: WorkspaceID,
        agentID: AgentID,
        spec: LaunchSpec,
        launcherExecutable: URL,
        integrationToken: String,
        controlSocketPath: String,
        surfaceGeneration: SurfaceGeneration = .initial
    ) throws -> TerminalSession {
        guard let ticketWriter else {
            throw TerminalKitError.launchTicketWriterUnavailable
        }
        let resolvedEnvironment = resolveEnvironment(spec.environment)
        let terminalIDForTicket = TerminalID()
        let ticket = LaunchTicket.make(
            agentID: agentID.rawValue,
            terminalID: terminalIDForTicket.rawValue,
            surfaceGeneration: surfaceGeneration.rawValue,
            cwd: spec.workingDirectory,
            argv: spec.argv,
            environment: resolvedEnvironment,
            integrationToken: integrationToken,
            controlSocketPath: controlSocketPath,
            now: Date().timeIntervalSince1970
        )
        let ticketURL = try ticketWriter.write(ticket)

        // libghostty word-splits `command` on whitespace WITHOUT shell
        // interpolation (§3.9): both interpolated paths must carry their own
        // double quotes, else any space (default tickets live under
        // "Application Support") truncates argv before the helper parses it.
        let command = "\"\(launcherExecutable.path)\" \"\(ticketURL.path)\""
        do {
            return try launchSurface(
                workspaceID: workspaceID,
                agentID: agentID,
                spec: TerminalLaunchSpec(
                    workingDirectory: spec.workingDirectory,
                    command: command,
                    environment: resolvedEnvironment
                ),
                generation: surfaceGeneration,
                ticketTerminalID: terminalIDForTicket
            )
        } catch {
            // Surface never came up; don't leak the ticket file on disk.
            ticketWriter.cancel(at: ticketURL)
            throw error
        }
    }

    private func launchSurface(
        workspaceID: WorkspaceID,
        agentID: AgentID?,
        spec: TerminalLaunchSpec,
        generation: SurfaceGeneration = .initial,
        ticketTerminalID: TerminalID? = nil
    ) throws -> TerminalSession {
        let terminalID = ticketTerminalID ?? TerminalID()
        let surface = try GhosttySurface(
            engine: engine,
            terminalID: terminalID,
            generation: generation,
            spec: spec,
            onViewCreated: { [parkingHost] view in
                // Born inside the parking window (§3.8); occlusion flips on
                // once the coordinator parks it explicitly.
                parkingHost.park(view)
            }
        )
        surface.delegate = self
        // Born-parked surfaces (§3.8) start occluded; mount() remains the
        // sole point that clears occlusion.
        surface.native.setOccluded(true)

        let session = TerminalSession(
            id: terminalID,
            workspaceID: workspaceID,
            agentID: agentID,
            cwd: spec.workingDirectory,
            surfaceGeneration: generation,
            processPhase: .running(pid: nil, processGroupID: nil),
            outputRevision: 0,
            presentation: .parked
        )
        terminals[terminalID] = ManagedTerminal(session: session, surface: surface)
        activityManager?.beginWorkingActivity()
        startExitPollingIfNeeded()
        // Install the sink only after the delegate is wired: setSink flushes
        // payloads buffered during engine.createSurface (an instantly-exiting
        // command's .childExited must be observed by the manager).
        surface.activateEventSink()
        return session
    }

    /// Immutable snapshot of the terminal-level facts consumers need about
    /// a live surface. This — NOT the raw GhosttySurface — is the terminal
    /// port's contract: libghostty lifecycle stays an implementation detail.
    public struct ProcessStatus: Sendable {
        public let generation: SurfaceGeneration
        public let isClosing: Bool
        public let processExited: Bool
        public let foregroundPID: UInt64
    }

    /// Terminal-level status snapshot (nil for unknown/closed terminals).
    public func processStatus(for terminalID: TerminalID) -> ProcessStatus? {
        guard let managed = terminals[terminalID], let surface = managed.surface else { return nil }
        return ProcessStatus(
            generation: surface.generation,
            isClosing: surface.isClosing,
            processExited: surface.processExited,
            foregroundPID: surface.foregroundPID()
        )
    }

    /// Foreground child PID of the terminal's shell (0 when not alive).
    public func foregroundPID(for terminalID: TerminalID) -> UInt64? {
        terminals[terminalID]?.surface?.foregroundPID()
    }

    /// The live surface object for a terminal (nil when closed/closed-pending).
    /// INTERNAL by design: app consumers go through processStatus /
    /// foregroundPID(for:) / focusInput; only this module (mount coordinator,
    /// teardown, tests) touches the raw libghostty surface.
    func surface(for terminalID: TerminalID) -> GhosttySurface? {
        terminals[terminalID]?.surface
    }

    /// Semantic focus operation (§3.4): makes the terminal's surface view
    /// the window's first responder. Returns false when the terminal is
    /// unknown or already closing — callers then demote focus themselves.
    @discardableResult
    public func focusInput(terminalID: TerminalID) -> Bool {
        guard let managed = terminals[terminalID], let surface = managed.surface,
              !surface.isClosing else { return false }
        surface.view.window?.makeFirstResponder(surface.view)
        return true
    }

    /// Test hook: direct access to the teardown queue for deterministic
    /// draining in fake-based suites.
    func teardownQueueForTesting() -> TerminalTeardownQueue {
        teardownQueue
    }

    /// Test-only hook: exposes the child-exit poll timer so suites can assert
    /// idle/liveness without waiting on real runloop ticks.
    func exitPollTimerForTesting() -> Timer? {
        exitPollTimer
    }

    private func resolveEnvironment(_ additions: [String: String]) -> [String: String] {
        guard let resolver = environmentResolver else { return additions }
        return resolver.resolve(overlays: additions)
    }

    // MARK: presentation

    public func mount(terminalID: TerminalID, paneID: PaneID, container: NSView) throws {
        guard var managed = terminals[terminalID], let surface = managed.surface else {
            throw TerminalKitError.unknownTerminal(terminalID)
        }
        try mountCoordinator.mount(surface, into: container, paneID: paneID)
        managed.session.presentation = .mounted(paneID)
        terminals[terminalID] = managed
    }

    public func park(terminalID: TerminalID) throws {
        guard var managed = terminals[terminalID], let surface = managed.surface else {
            throw TerminalKitError.unknownTerminal(terminalID)
        }
        mountCoordinator.park(surface)
        managed.session.presentation = .parked
        terminals[terminalID] = managed
    }

    // MARK: teardown

    /// Closes a terminal: parks (if mounted), enqueues two-phase teardown and
    /// removes the registry entry once the native free returned.
    public func close(terminalID: TerminalID) throws {
        guard var managed = terminals[terminalID], let surface = managed.surface else {
            throw TerminalKitError.unknownTerminal(terminalID)
        }
        if case .mounted = managed.session.presentation {
            mountCoordinator.park(surface)
        }
        // Release the working-activity token at most once per terminal
        // lifecycle: close(), sendSignal(.terminate/.kill) and the exit poll
        // can all reach a terminal in a terminal-bound phase; the latch makes
        // the release idempotent across re-entry (e.g. terminate then close).
        switch managed.session.processPhase {
        case .running, .exiting:
            if !managed.activityTokenReleased {
                managed.activityTokenReleased = true
                activityManager?.endWorkingActivity()
            }
        case .notStarted, .launching, .exited, .launchFailed:
            break
        }
        teardownQueue.enqueue(surface) { [weak self] in
            // Registry removal strictly after native free (§3.8 step 6).
            self?.terminals[terminalID] = nil
            self?.stopExitPollingIfIdle()
        }
        switch managed.session.processPhase {
        case .exited: break // keep the observed exit; .exiting would misreport
        default: managed.session.processPhase = .exiting
        }
        terminals[terminalID] = managed
    }

    // MARK: child-exit polling (PRIMARY lifecycle signal, ADR-0002 finding 5)

    private var exitPollTimer: Timer?

    private func startExitPollingIfNeeded() {
        guard exitPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollProcessExits()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        exitPollTimer = timer
    }

    deinit {
        // The timer closure only weakly captures self, but RunLoop.main
        // retains the repeating timer itself even after the manager's last
        // reference drops — it would fire forever into a nil weak self.
        // Invalidate via the main queue — safe from any thread. Timer is
        // main-thread confined, so the reference crosses into the @Sendable
        // closure as nonisolated(unsafe); no other accessor survives deinit
        // entry, making the transfer sound despite Timer not being Sendable.
        nonisolated(unsafe) let timer = exitPollTimer
        DispatchQueue.main.async {
            timer?.invalidate()
        }
    }

    /// Polling exists to OBSERVE exits: a terminal whose process phase is
    /// `.exited`/`.launchFailed`/`.notStarted` has nothing left to observe,
    /// and a surface already closing rejects poll observation too. Only
    /// running/exiting terminals on non-closing surfaces keep the timer alive.
    private func stopExitPollingIfIdle() {
        let hasObservableTerminals = terminals.values.contains { managed in
            switch managed.session.processPhase {
            case .running, .exiting:
                managed.surface?.isClosing == false
            case .notStarted, .launching, .exited, .launchFailed:
                false
            }
        }
        if !hasObservableTerminals, let timer = exitPollTimer {
            timer.invalidate()
            exitPollTimer = nil
        }
    }

    /// One polling pass; also callable directly from tests.
    public func pollProcessExits() {
        for id in Array(terminals.keys) {
            pollProcessExit(for: id)
        }
        // Exited-but-still-mounted terminals must not keep a no-op 0.5 s
        // timer spinning: once nothing observable remains, stop polling.
        // Exit-code pickup happens inside this pass (pollProcessExit), so
        // stopping afterwards cannot delay observation.
        stopExitPollingIfIdle()
    }

    private func pollProcessExit(for terminalID: TerminalID) {
        guard var managed = terminals[terminalID],
              let surface = managed.surface else { return }
        switch managed.session.processPhase {
        case .running, .exiting: break
        default: return
        }
        guard surface.pollProcessExit() else { return }
        let observation = ExitObservation(
            exitCode: surface.lastReportedExitCode.map(Int32.init),
            signal: nil
        )
        managed.session.processPhase = .exited(
            exitCode: observation.exitCode,
            signal: observation.signal,
            userInitiated: false
        )
        managed.session.exitAt = Date().timeIntervalSince1970
        if !managed.activityTokenReleased {
            managed.activityTokenReleased = true
            activityManager?.endWorkingActivity()
        }
        terminals[terminalID] = managed
        processExitSink?(terminalID, surface.generation, observation)
        reclaimExitedTerminalIfParked(terminalID)
    }

    /// Reclamation policy: a terminal whose process exited while PARKED is
    /// invisible (no pane shows it), so its surface — and the PTY master fd
    /// libghostty holds for it — has no post-mortem viewer. Tearing it down
    /// immediately bounds fd/memory growth across agent churn (a parked
    /// exited surface otherwise leaks its master until process exit).
    /// Mounted terminals stay for scrollback until the user closes the view
    /// (§3.5: Close View and Stop Agent are never the same button).
    ///
    /// MUST NOT run inline: the child-exit engine event arrives through
    /// `SurfaceCallbackBox.deliverLocked`, which holds the box's
    /// non-reentrant NSLock while the sink runs, and `close()` →
    /// `beginTeardown()` → `clearSink()` takes that same lock — an inline
    /// call self-deadlocks the main thread inside `ghostty_app_tick`
    /// (sampled 2026-08-26). The Task hops out of the delivery; the guards
    /// re-validate because the world may have moved on by then.
    private func reclaimExitedTerminalIfParked(_ terminalID: TerminalID) {
        Task { @MainActor [weak self] in
            guard let self,
                  let managed = terminals[terminalID],
                  case .exited = managed.session.processPhase,
                  case .parked = managed.session.presentation else { return }
            try? close(terminalID: terminalID)
        }
    }

    // MARK: engine events

    private func handleEngineEvent(_ event: GhosttyEvent) {
        guard let terminalID = event.terminalID else {
            appEventSink?(event)
            return
        }
        guard var managed = terminals[terminalID],
              let surface = managed.surface,
              surface.generation == event.generation
        else {
            return // late/stale observation from another generation (§3.18)
        }
        // Local state already applied inside GhosttySurface.handle; mirror the
        // bits the TerminalSession model owns.
        switch event.payload {
        case .render:
            managed.session.outputRevision = surface.outputRevision
            terminals[terminalID] = managed
        case let .childExited(code):
            // Idempotent observation: GhosttySurface.handle already recorded
            // processExited locally; mirror it into the session model and fire
            // the sink exactly once. A later poll observing the same exit is
            // a no-op via the phase switch in pollProcessExit(for:).
            switch managed.session.processPhase {
            case .running, .exiting:
                let observation = ExitObservation(
                    exitCode: Int32(bitPattern: code),
                    signal: nil
                )
                managed.session.processPhase = .exited(
                    exitCode: observation.exitCode,
                    signal: observation.signal,
                    userInitiated: false
                )
                managed.session.exitAt = Date().timeIntervalSince1970
                if !managed.activityTokenReleased {
                    managed.activityTokenReleased = true
                    activityManager?.endWorkingActivity()
                }
                terminals[terminalID] = managed
                processExitSink?(terminalID, surface.generation, observation)
                reclaimExitedTerminalIfParked(terminalID)
            default:
                break // already observed (close path or poll won the race)
            }
            // The engine-delivered exit mirrors the poll's observation; the
            // same idle rule applies — nothing left to observe, stop polling.
            stopExitPollingIfIdle()
        default:
            break
        }
    }

    // MARK: TerminalControlling port

    public func deliverInput(_ terminalID: TerminalID, text: String, submit: Bool) async throws {
        guard let managed = terminals[terminalID], let surface = managed.surface else {
            throw TerminalKitError.unknownTerminal(terminalID)
        }
        guard !surface.isClosing else {
            throw TerminalKitError.surfaceClosing(terminalID: terminalID)
        }
        let gateway = TerminalInputGateway(
            target: surface.native,
            bracketedPaste: inputBracketedPaste
        )
        gateway.sendPrompt(text, submit: submit)
    }

    public func sendKeys(_ terminalID: TerminalID, keys: [String]) async throws {
        guard let managed = terminals[terminalID], let surface = managed.surface else {
            throw TerminalKitError.unknownTerminal(terminalID)
        }
        guard !surface.isClosing else {
            throw TerminalKitError.surfaceClosing(terminalID: terminalID)
        }
        let gateway = TerminalInputGateway(target: surface.native)
        gateway.sendKeys(keys)
    }

    public func sendSignal(_ intent: SignalIntent, to terminalID: TerminalID) async throws {
        guard var managed = terminals[terminalID], let surface = managed.surface else {
            throw TerminalKitError.unknownTerminal(terminalID)
        }
        guard !surface.isClosing else {
            throw TerminalKitError.surfaceClosing(terminalID: terminalID)
        }
        // Process-group signal (§3.11 stop modes): target the foreground
        // child's process group so interactive children (and their own
        // children) receive the signal.
        let pid = pid_t(surface.foregroundPID())
        guard pid > 0 else {
            throw TerminalKitError.signalDeliveryFailed(intent: intent.rawValue, status: -1)
        }
        let group = Darwin.getpgid(pid)
        let pgid: pid_t = group > 0 ? group : pid
        let signal: Int32 = switch intent {
        case .interrupt: SIGINT
        case .terminate: SIGTERM
        case .kill: SIGKILL
        }
        if kill(pgid, signal) != 0 {
            // Fall back to the pid itself when the group vanished mid-flight.
            if errno != ESRCH || kill(pid, signal) != 0 {
                throw TerminalKitError.signalDeliveryFailed(intent: intent.rawValue, status: errno)
            }
        }

        if intent != .interrupt {
            // Terminating the process ends its working activity; the latch
            // keeps a later close() or exit poll from releasing again.
            if !managed.activityTokenReleased {
                managed.activityTokenReleased = true
                activityManager?.endWorkingActivity()
            }
            managed.session.processPhase = .exiting
            terminals[terminalID] = managed
        }
    }

    public func read(_ terminalID: TerminalID, source: TerminalReadSource) async throws -> TerminalSnapshot? {
        guard let managed = terminals[terminalID], let surface = managed.surface else {
            throw TerminalKitError.unknownTerminal(terminalID)
        }
        return surface.snapshot(source: source)
    }
}

extension GhosttySurface: TerminalTeardownTarget {}

extension TerminalSessionManager: GhosttySurfaceDelegate {
    public func surface(_: GhosttySurface, didProduceEvent event: GhosttyEvent) {
        handleEngineEvent(event)
    }
}

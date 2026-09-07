import AgentCore
import AppKit
import TerminalKit

// Stage-8/9/10 wiring seam. The shell never touches AgentRuntime's actor
// surface directly; every mutation flows through this protocol so later
// stages (store, control plane, notifications) can substitute implementations
// without touching UI code.

enum SidebarItem: Hashable {
    case agent(AgentID)
    case shell(TerminalID)

    var sortKey: String {
        switch self {
        case let .agent(id): "a-\(id.rawValue.uuidString)"
        case let .shell(id): "s-\(id.rawValue.uuidString)"
        }
    }
}

@MainActor
protocol PromptRouting: AnyObject {
    /// `commandID` is the client-side idempotency key (stage-9): retries with
    /// the same key replay the original receipt instead of re-delivering.
    @discardableResult
    func send(_ item: SidebarItem, text: String, policy: PromptPolicy, commandID: CommandID?) async -> PromptSendOutcome
    func cancelQueuedPrompt(_ item: SidebarItem) async
}

/// Outcome of one prompt dispatch through the seam. A `.failed` result MUST
/// surface in the UI together with the kept/restored draft text — a rejected
/// prompt never disappears print-only.
enum PromptSendOutcome {
    case accepted
    case failed(reason: String)
}

extension PromptRouting {
    @discardableResult
    func send(_ item: SidebarItem, text: String, policy: PromptPolicy) async -> PromptSendOutcome {
        await send(item, text: text, policy: policy, commandID: nil)
    }
}

extension RuntimeSeam: PromptRouting {
    @discardableResult
    func send(_ item: SidebarItem, text: String, policy: PromptPolicy,
              commandID: CommandID?) async -> PromptSendOutcome
    {
        switch item {
        case let .agent(id):
            do {
                let receipt = try await runtime.prompt(id, text, policy, commandID: commandID)
                if case .delivered = receipt.outcome {
                    promptCoordinator?.surfaceDeliveryOutcome(agentID: id, commandID: receipt.commandID)
                }
                return .accepted
            } catch {
                // §3.11: rejected policies surface as state/timeline evidence;
                // the composer never silently re-routes a blocked send. The
                // failure is returned so the UI keeps the draft and shows why.
                DiagnosticsLogRing.shared.record("prompt rejected for \(id): \(error)")
                return .failed(reason: Self.rejectionText(for: error))
            }
        case let .shell(terminalID):
            // Plain shells take the raw input path. Failures are surfaced the
            // same way — `try?` used to swallow them and lose the draft.
            do {
                try await sessionManager.deliverInput(terminalID, text: text + "\n", submit: true)
                return .accepted
            } catch {
                DiagnosticsLogRing.shared.record("shell input failed for \(terminalID): \(error)")
                return .failed(reason: String(describing: error))
            }
        }
    }

    /// The rejection reason is shown verbatim in the composer's inline error,
    /// so §3.11 cases render as human phrases instead of raw enum names.
    private static func rejectionText(for error: Error) -> String {
        guard let rejection = error as? RuntimeErrors else {
            return error.localizedDescription
        }
        switch rejection {
        case .agentNotFound:
            return NSLocalizedString("the agent is no longer available",
                                     comment: "Prompt rejection reason")
        case .terminalUnavailable:
            return NSLocalizedString("the terminal is not connected",
                                     comment: "Prompt rejection reason")
        case .invalidLifecycle:
            return NSLocalizedString("the agent's current state rejects this delivery",
                                     comment: "Prompt rejection reason")
        case .waitingForTerminalInput:
            return NSLocalizedString("the agent is waiting for input in its terminal",
                                     comment: "Prompt rejection reason")
        case .queuedPromptAlreadyExists:
            return NSLocalizedString("a queued prompt is already waiting",
                                     comment: "Prompt rejection reason")
        case .semanticStateUnavailable:
            return NSLocalizedString("the agent's state is not readable yet",
                                     comment: "Prompt rejection reason")
        case .resumeUnsupported, .resumeReferenceMissing:
            return NSLocalizedString("this session cannot be resumed",
                                     comment: "Prompt rejection reason")
        case .launchFailed:
            return NSLocalizedString("the agent failed to launch",
                                     comment: "Prompt rejection reason")
        case .promptDeliveryUnconfirmed:
            return NSLocalizedString("delivery could not be confirmed",
                                     comment: "Prompt rejection reason")
        case .timeout:
            return NSLocalizedString("the operation timed out",
                                     comment: "Prompt rejection reason")
        case .persistenceDegraded:
            return NSLocalizedString("persistence is degraded",
                                     comment: "Prompt rejection reason")
        }
    }

    func cancelQueuedPrompt(_ item: SidebarItem) async {
        guard case let .agent(id) = item else { return }
        try? await runtime.cancelQueuedPrompt(id)
    }
}

@MainActor
protocol AgentActionRouting: AnyObject {
    func stop(_ item: SidebarItem) async
    func interrupt(_ item: SidebarItem) async
    func restart(_ item: SidebarItem) async
    func resume(_ item: SidebarItem) async
    func markSeen(_ item: SidebarItem) async
    func acknowledgeFailure(_ item: SidebarItem) async
    func setVisible(_ item: SidebarItem, _ visible: Bool)
    func focusRuntime(_ item: SidebarItem) async
    func timelineLines(for agent: AgentID, limit: Int?) async -> [String]
    func foregroundPID(_ item: SidebarItem) -> UInt64?
    func cwd(of item: SidebarItem) -> String?
}

/// Default implementation backed by the real runtime actor + session manager.
@MainActor
final class RuntimeSeam: AgentActionRouting {
    let runtime: AgentRuntime
    /// Set by the composition root; owns ticketed relaunches.
    let sessionManager: TerminalSessionManager
    /// Identity wrapper so a finished visibility task can drop its own map
    /// entry: Task is not Equatable, so the body compares the stored box.
    /// Invariant: visibilityTasks holds only IN-FLIGHT visibility tasks;
    /// completed handles are removed by the task body itself (or superseded).
    private final class VisibilityTaskBox {
        let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }
    }

    /// §3.4: unstructured task submission order is not guaranteed; keep the
    /// latest task per item so rapid hide/show toggles converge on the last
    /// requested visibility instead of racing.
    private var visibilityTasks: [SidebarItem: VisibilityTaskBox] = [:]
    /// Latest requested visibility per item, recorded synchronously in
    /// setVisible so any superseded in-flight task can re-apply the newest
    /// value as a compensation when it resumes out of order.
    private var desiredVisibility: [SidebarItem: Bool] = [:]
    /// Set by the composition root; arms watchdog-outcome surfacing after a
    /// successful sendNow delivery (stage-9 §3.11).
    weak var promptCoordinator: PromptCoordinator?
    /// Integration diagnostics (review item: §3.17 Repair flow consumer).
    /// Set by the composition root — the sole construction site.
    var integrationInstaller: IntegrationInstaller?
    private let catalog = AgentCatalog.standard()

    /// Inspector-facing integration diagnostics for one agent.
    struct IntegrationDiagnostics: Equatable {
        let program: String
        let resolvedPath: String?
        let version: String?
        let healthText: String
        let canRepair: Bool
    }

    /// Lifecycle owner for agent-scoped operations (stop/restart). Optional:
    /// harness seams without a coordinator stay silent no-ops by design.
    var coordinator: AgentExecutionCoordinator?
    private let model: AppModel

    init(runtime: AgentRuntime, sessionManager: TerminalSessionManager, model: AppModel) {
        self.runtime = runtime
        self.sessionManager = sessionManager
        self.model = model
    }

    func stop(_ item: SidebarItem) async {
        switch item {
        case let .agent(id):
            // The coordinator owns the FULL semantic stop: user-intent
            // marking, detection suspension and failure compensation.
            do {
                try await coordinator?.stop(id, mode: .gracefulStop)
            } catch {
                // The coordinator already recorded the failure and applied
                // its compensation; nothing further for the seam to do.
            }
        case let .shell(terminalID):
            // Plain shells are not runtime sessions; mirror the runtime's
            // gracefulStop ladder (SIGTERM → 2 s grace → SIGKILL, §3.11).
            // Interactive /bin/sh ignores bare SIGTERM.
            do {
                try await sessionManager.sendSignal(.terminate, to: terminalID)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await sessionManager.sendSignal(.kill, to: terminalID)
            } catch {
                DiagnosticsLogRing.shared.record("shell stop failed for \(terminalID): \(error)")
            }
        }
    }

    func interrupt(_ item: SidebarItem) async {
        switch item {
        case let .agent(id):
            do {
                try await runtime.interrupt(id)
            } catch {
                DiagnosticsLogRing.shared.record("runtime interrupt failed for \(id): \(error)")
            }
        case let .shell(terminalID):
            do {
                try await sessionManager.sendSignal(.interrupt, to: terminalID)
            } catch {
                DiagnosticsLogRing.shared.record("shell interrupt failed for \(terminalID): \(error)")
            }
        }
    }

    func restart(_ item: SidebarItem) async {
        guard case let .agent(id) = item else { return } // shells have no restart semantics
        do {
            try await coordinator?.restartAgent(id)
        } catch {
            DiagnosticsLogRing.shared.record("restart failed for \(id): \(error)")
        }
    }

    func resume(_ item: SidebarItem) async {
        guard case let .agent(id) = item else { return }
        do {
            // Validation + the `.resumeAttempted` timeline event (§3.15):
            // unchanged runtime semantics. Unsupported kinds and missing
            // references throw BEFORE any relaunch attempt.
            try await runtime.resume(id)
        } catch {
            DiagnosticsLogRing.shared.record("resume failed for \(id): \(error)")
            return
        }
        // The bare runtime transition never relaunched anything; the actual
        // relaunch flows through the coordinator's ticketed pipeline
        // (executeResume). Without a coordinator (harness seams) this stays
        // a validated no-op by design, like stop/restart.
        do {
            _ = try await coordinator?.executeInteractiveResume(of: id)
        } catch {
            DiagnosticsLogRing.shared.record("resume relaunch failed for \(id): \(error)")
        }
    }

    func markSeen(_ item: SidebarItem) async {
        guard case let .agent(id) = item else { return }
        do {
            try await runtime.markSeen(id)
        } catch {
            DiagnosticsLogRing.shared.record("mark seen failed for \(id): \(error)")
        }
    }

    /// §3.4: explicit operator acknowledge clears ONLY failure attention.
    func acknowledgeFailure(_ item: SidebarItem) async {
        guard case let .agent(id) = item else { return }
        do {
            try await runtime.acknowledgeFailure(id)
        } catch {
            DiagnosticsLogRing.shared.record("acknowledge failure failed for \(id): \(error)")
        }
    }

    func setVisible(_ item: SidebarItem, _ visible: Bool) {
        guard case let .agent(id) = item else { return }
        // Record the request BEFORE any await point so it is visible to
        // every concurrently in-flight task for this item.
        desiredVisibility[item] = visible
        visibilityTasks[item]?.task.cancel()
        // The task body needs the box for identity comparison, and the box
        // needs the task; the body only runs after both are initialized.
        var box: VisibilityTaskBox!
        box = VisibilityTaskBox(task: Task {
            defer {
                // Drop our own handle unless superseded by a newer task;
                // keeps the map holding only in-flight tasks.
                if visibilityTasks[item] === box {
                    visibilityTasks[item] = nil
                }
            }
            guard !box.task.isCancelled else { return }
            do {
                try await self.runtime.setVisibility(id, isVisible: visible)
            } catch {
                DiagnosticsLogRing.shared.record("set visibility failed for \(id): \(error)")
            }
            // Application order is not guaranteed: a task suspended inside
            // setVisibility can resume AFTER a newer task already finished,
            // leaving a stale value applied last. Re-issue the newest
            // requested value; every superseded task applies the SAME
            // latest value, so any interleaving converges.
            if visibilityTasks[item] !== box, let latest = desiredVisibility[item] {
                try? await self.runtime.setVisibility(id, isVisible: latest)
            }
        })
        visibilityTasks[item] = box
    }

    /// Drops the per-item visibility bookkeeping when an agent leaves the
    /// model; finished Task handles must not accumulate for removed agents.
    func clearVisibilityState(for item: SidebarItem) {
        visibilityTasks[item]?.task.cancel()
        visibilityTasks[item] = nil
    }

    func focusRuntime(_ item: SidebarItem) async {
        guard case let .agent(id) = item else { return }
        do {
            try await runtime.focus(id)
        } catch {
            DiagnosticsLogRing.shared.record("focus runtime failed for \(id): \(error)")
        }
    }

    func timelineLines(for agent: AgentID, limit: Int?) async -> [String] {
        let events = await runtime.timeline(of: agent)
        guard !events.isEmpty else { return [] }
        // Format only the requested tail: the inspector renders the last
        // few transitions while the full history can run to 1000 events.
        let bounded = limit.map(events.suffix) ?? events[...]
        return bounded.map { event in
            "\(AgentEventText.describe(event.event)) — \(AgentEventText.ageText(from: event.at, to: AgentEventText.nowInstant()))"
        }
    }

    func isProcessAlive(_ item: SidebarItem) -> Bool {
        guard let pid = foregroundPID(item), pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    func foregroundPID(_ item: SidebarItem) -> UInt64? {
        let terminalID: TerminalID = switch item {
        case let .agent(id): model.agentTerminal[id] ?? .init()
        case let .shell(id): id
        }
        return sessionManager.foregroundPID(for: terminalID)
    }

    /// §3.17 inspector diagnostics: why (if ever) screen detection fell back
    /// for this agent's adapter version. Routed through the coordinator's
    /// owned pipeline — no registry global.
    func versionFallbackReason(for agentID: AgentID) -> String? {
        coordinator?.versionFallbackReason(for: agentID)
    }

    // MARK: Integration diagnostics (§3.17 — review item 6)

    func launchDescriptor(of item: SidebarItem) async -> LaunchDescriptor? {
        guard case let .agent(id) = item else { return nil }
        return await runtime.launchDescriptor(of: id)
    }

    /// Executable/version + install-plan health for the inspector. Never
    /// throws: degraded integrations degrade the TEXT, not the call.
    func integrationDiagnostics(for item: SidebarItem) async -> IntegrationDiagnostics? {
        // The probe fans out into a PATH scan, a version probe and an
        // install-plan diagnose, yet the inspector refreshes on every model
        // tick while an agent stays selected. Serve a short-TTL cache:
        // identical results within the window, bounded staleness for
        // out-of-band changes (e.g. a manual reinstall), and repairIntegration
        // drops the entry outright so post-repair health re-probes at once.
        if let cached = diagnosticsCache[item],
           ContinuousClock.now - cached.at < Self.diagnosticsTTL
        {
            return cached.diag
        }
        guard case let .agent(id) = item,
              let descriptor = await runtime.launchDescriptor(of: id) else { return nil }

        var resolvedPath: String?
        var version: String?
        var healthText = "no integration"
        var canRepair = false
        if let adapter = catalog.adapter(for: descriptor.agentKind) {
            if case let .installed(path, detectedVersion) = await adapter.detectInstallation() {
                resolvedPath = path
                version = detectedVersion
            }
            if let installer = integrationInstaller {
                let health = installer.diagnose(plan: adapter.integrationInstallPlan())
                healthText = Self.healthText(for: health)
                canRepair = health != .healthy
            }
        }
        let diag = IntegrationDiagnostics(
            program: descriptor.program,
            resolvedPath: resolvedPath,
            version: version,
            healthText: healthText,
            canRepair: canRepair
        )
        diagnosticsCache[item] = (diag: diag, at: ContinuousClock.now)
        return diag
    }

    func repairIntegration(for item: SidebarItem) async -> String? {
        guard case let .agent(id) = item,
              let summary = model.agents[id],
              let adapter = catalog.adapter(for: summary.kind),
              let installer = integrationInstaller else { return nil }
        // Whatever the outcome, the cached health text is now stale.
        diagnosticsCache[item] = nil
        do {
            let report = try installer.install(plan: adapter.integrationInstallPlan())
            return "repair outcome: \(Self.outcomeText(for: report.outcome))"
        } catch {
            return "repair failed: \(error)"
        }
    }

    /// Short-TTL memo of §3.17 diagnostics per sidebar item (see
    /// integrationDiagnostics). Entries expire on their own; repair drops
    /// the affected entry eagerly.
    private var diagnosticsCache: [SidebarItem: (diag: IntegrationDiagnostics, at: ContinuousClock.Instant)] = [:]
    private static let diagnosticsTTL: Duration = .seconds(10)

    static func healthText(for health: IntegrationHealth) -> String {
        switch health {
        case .healthy: "healthy"
        // Self-subjecting: a bare "not installed" under INTEGRATION
        // DIAGNOSTICS read as "my shell is broken" for plain-shell agents.
        case .notInstalled: "integration not installed"
        case let .userModified(paths): "user modified — " + paths.joined(separator: ", ")
        case let .corrupted(reason): "corrupted — \(reason)"
        }
    }

    /// Human text for a repair/install outcome — never the raw enum dump
    /// (`conflict(paths: [...])` used to leak into the inspector and logs).
    static func outcomeText(for outcome: InstallOutcome) -> String {
        switch outcome {
        case .installed: "installed"
        case .upgraded: "upgraded"
        case .noChanges: "already up to date"
        case let .conflict(paths): "blocked — " + paths.joined(separator: ", ")
        }
    }

    func cwd(of item: SidebarItem) -> String? {
        switch item {
        case let .agent(id): model.agentCwd[id]
        case let .shell(id): model.shells[id]?.cwd
        }
    }
}

/// Human-readable one-line rendering of timeline events for the inspector
/// and the diagnostics export. App-layer concern: AgentCore events stay
/// symbolic; raw enum dumps never reach the UI (review sweep 5, A3).
enum AgentEventText {
    static func describe(_ event: AgentEvent) -> String {
        switch event {
        case let .stateChanged(_, to, authority):
            "state → \(phaseText(to)) (via \(authorityText(authority)))"
        case let .turnStarted(reason):
            "turn started (\(reasonText(reason)))"
        case let .turnCompleted(hadPrompt):
            hadPrompt ? "turn completed" : "turn completed (no prompt)"
        case let .attentionRaised(kind):
            "needs attention: \(kindText(kind))"
        case let .attentionCleared(kind):
            "attention cleared: \(kindText(kind))"
        case let .promptDelivered(id):
            "prompt \(short(id)) delivered"
        case let .promptDeliveryUnconfirmed(id):
            "prompt \(short(id)) unconfirmed"
        case .queuedPromptCancelled:
            "queued prompt cancelled"
        case let .queuedPromptDeliveryFailed(id):
            "queued prompt \(short(id)) failed to deliver"
        case let .processExited(exitCode, signal, userInitiated):
            exitText(exitCode: exitCode, signal: signal, userInitiated: userInitiated)
        case .sessionIdentityCaptured:
            "session identity captured"
        case let .integrationSequenceGap(expected, received):
            "integration sequence gap (expected #\(expected), saw #\(received))"
        case let .authorityLost(previous):
            "state authority lost (was \(authorityText(previous)))"
        case let .stopCommanded(mode):
            "stop requested (\(modeText(mode)))"
        case let .restartInitiated(generation):
            "restart initiated (surface generation \(generation))"
        case .resumeAttempted:
            "resume attempted"
        }
    }

    private static func phaseText(_ phase: LifecyclePhase) -> String {
        switch phase {
        case .unknown: "unknown"
        case .starting: "starting"
        case .idle: "idle"
        case .working: "working"
        case .waitingForInput: "waiting for input"
        case .stopping: "stopping"
        case let .stopped(reason):
            reason == .userRequested ? "stopped (by you)" : "stopped (completed)"
        case let .failed(failure):
            "failed" + (failure.reason.map { " — \($0)" } ?? "")
        }
    }

    /// Production monotonic clock — same base the domain stamps events with
    /// (uptime nanoseconds), so ages are consistent across surfaces.
    private static let clock = ContinuousRuntimeClock()

    static func nowInstant() -> MonotonicInstant {
        clock.currentInstant()
    }

    /// Coarse relative age for timeline rows ("12s ago").
    static func ageText(from instant: MonotonicInstant, to now: MonotonicInstant) -> String {
        let duration = now - instant
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
        if seconds < 60 {
            return "\(max(0, Int(seconds.rounded())))s ago"
        }
        if seconds < 3600 {
            return "\(Int((seconds / 60).rounded()))m ago"
        }
        if seconds < 86400 {
            return "\(Int((seconds / 3600).rounded()))h ago"
        }
        return "\(Int((seconds / 86400).rounded()))d ago"
    }

    private static func authorityText(_ authority: StateAuthority) -> String {
        switch authority {
        case .integration: "integration"
        case .screen: "screen detection"
        case .process: "process observation"
        case .unknown: "unknown source"
        }
    }

    private static func reasonText(_ reason: TurnOpenReason) -> String {
        switch reason {
        case .promptDelivered: "prompt delivered"
        case .spontaneousWork: "spontaneous work"
        case .integrationOperation: "integration operation"
        }
    }

    private static func kindText(_ kind: AgentEvent.AttentionKind) -> String {
        switch kind {
        case .completionUnread: "unread completion"
        case .inputRequired: "input required"
        case .failure: "failure"
        }
    }

    private static func modeText(_ mode: StopMode) -> String {
        switch mode {
        case .interrupt: "interrupt"
        case .gracefulStop: "graceful stop"
        case .closeView: "close view"
        }
    }

    private static func exitText(exitCode: Int32?, signal: Int32?, userInitiated: Bool) -> String {
        let base = switch (exitCode, signal) {
        case let (_, .some(sig)):
            "terminated by signal \(sig)"
        case (.some(0), _):
            "exited cleanly"
        case let (.some(code), _):
            "exited with code \(code)"
        default:
            "process exited"
        }
        return userInitiated ? base + " (user-initiated)" : base
    }

    private static func short(_ id: CommandID) -> String {
        String(id.rawValue.uuidString.prefix(8))
    }
}

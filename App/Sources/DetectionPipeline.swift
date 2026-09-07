import AgentCore
import Foundation
import TerminalKit

// Stage-8 detection pipeline (§3.12 flow B): GhosttySurface output revisions
// → DetectionScheduler debounce/cadence → SCREEN-space snapshot →
// ScreenDetectionEngine (hysteresis) → runtime evidence ingestion.
//
// Two drivers feed the scheduler:
//  - a main-actor render poller compares each tracked surface's outputRevision
//    (cheap struct mirror) and reports changes — event-accurate at 50 ms
//    granularity, far below the 150 ms debounce;
//  - RuntimeDelta lifecycle changes recompute the evaluation cadence.
//
// A slower process loop runs MacProcessInspector evidence and drives the
// TerminalSessionManager exit poll whose sink reaches the runtime through
// AgentRuntime.processExited (§3.5 "process exited" rows).

@MainActor
final class DetectionPipeline {
    private let clock: FakeClock
    private let scheduler: DetectionScheduler
    private let engine: ScreenDetectionEngine
    private let registry: AgentTerminalRegistry
    private let sessionManager: TerminalSessionManager
    private let runtime: AgentRuntime
    private let inspector = MacProcessInspector()
    /// Fresh catalog for manifest/adapter lookups; identical to the runtime's.
    private let catalog = AgentCatalog.standard()

    private var manifests: [String: ScreenManifest] = [:]
    private var lastSeenRevisions: [TerminalID: UInt64] = [:]
    private var evaluating: Set<TerminalID> = []
    /// Agents whose lifecycle is machine-driven from here on (stop commanded,
    /// restart in flight): screen ingestion is suspended to prevent stale
    /// in-flight adoptions from regressing newer states (§3.7 cadence off).
    private(set) var suspended: Set<AgentID> = []
    /// Stage-16 gate 6c: agents whose adapter version violates the bundled
    /// manifest's adapterVersionRange — screen detection stays the state
    /// source but is marked FALLBACK with this operator-visible reason.
    private(set) var versionFallbacks: [AgentID: String] = [:]
    /// Records (or clears with nil) the §3.7 version-range fallback marker.
    func recordVersionFallback(agentID: AgentID, reason: String?) {
        if let reason {
            versionFallbacks[agentID] = reason
        } else {
            versionFallbacks.removeValue(forKey: agentID)
        }
    }

    func versionFallbackReason(for agentID: AgentID) -> String? {
        versionFallbacks[agentID]
    }

    private var reportedExits: Set<TerminalID> = []
    private var renderTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var running = false
    /// Actor-isolated handler registration, awaited by every scheduler
    /// interaction below: no schedule event can be enqueued before the
    /// handler exists, so the scheduler can never deliver to a nil handler.
    private var handlerRegistered = Task { @MainActor in () }
    init(clock: FakeClock,
         registry: AgentTerminalRegistry,
         sessionManager: TerminalSessionManager,
         runtime: AgentRuntime)
    {
        self.clock = clock
        scheduler = DetectionScheduler(clock: clock)
        engine = ScreenDetectionEngine(clock: clock)
        self.registry = registry
        self.sessionManager = sessionManager
        self.runtime = runtime
        // Actor-isolated registration; every scheduler call site awaits this
        // task first, ordering the handler before any event can be scheduled.
        handlerRegistered = Task { [scheduler] in
            await scheduler.setHandler { [weak self] terminalID in
                Task { @MainActor in
                    await self?.evaluate(terminalID: terminalID)
                }
            }
        }
    }

    func start() {
        guard !running else { return }
        running = true

        // Render revision poller (main actor — surfaces are MainActor-bound).
        renderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollRenderRevisions()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        // Process-evidence loop (~2 Hz is plenty for liveness). Exit polling
        // is deliberately NOT driven here: TerminalSessionManager arms its
        // own 0.5s timer at surface creation and remains the single driver —
        // it must also serve pipeline-less harnesses (MinimalHarness,
        // AutomationBootstrap). Driving both doubled every terminal's probe.
        processTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollProcessEvidence()
                await self?.reportExitedSurfaces()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stop() {
        running = false
        renderTask?.cancel()
        processTask?.cancel()
        renderTask = nil
        processTask = nil
        // After stop() no scheduler event may reach evaluate(): retire the
        // lifecycle handler so late lifecycleChanged deliveries are dropped.
        Task { [scheduler, registration = handlerRegistered] in
            await registration.value
            await scheduler.setHandler { _ in }
        }
    }

    /// Set by the composition root; routes exits to AgentRuntime.
    var exitReporter: (@MainActor (TerminalID, SurfaceGeneration) async throws -> Void)?

    /// Frozen-manager gap: `pollProcessExit` ignores terminals whose phase is
    /// already `.exiting`, so their exit would never reach the sink. Surfaces
    /// expose `processExited` directly — report once through the same path.
    private func reportExitedSurfaces() async {
        for terminalID in registry.trackedTerminals {
            guard reportedExits.contains(terminalID) == false,
                  let status = sessionManager.processStatus(for: terminalID),
                  status.processExited else { continue }
            do {
                try await exitReporter?(terminalID, status.generation)
                // Gate only on success: a failed report stays unmarked so
                // the next poll tick re-drives the transition.
                reportedExits.insert(terminalID)
            } catch {
                continue
            }
        }
    }

    /// RuntimeDelta side-effect: keep the cadence table in sync (§3.7).
    func lifecycleChanged(summary: AgentSummary) {
        guard let binding = registry.binding(for: summary.id) else { return }
        let lifecycle = summary.state.lifecycle
        let terminalID = binding.terminalID
        // Stage 10 wires real per-pane visibility cadence; hidden cadence is
        // the safe default per the §3.7 frequency table.
        Task { [scheduler, registration = handlerRegistered] in
            await registration.value
            await scheduler.lifecycleChanged(
                terminalID: terminalID,
                lifecycle: lifecycle,
                isVisible: false
            )
        }
    }

    func suspend(agentID: AgentID) {
        suspended.insert(agentID)
    }

    /// Inverse of suspend(_:): a failed stop on a still-alive agent must not
    /// stay blind to screen evidence until a full restart. Unlike
    /// generationInvalidated it keeps engine hysteresis — that reset belongs
    /// to restart generations only.
    func unsuspend(agentID: AgentID) {
        suspended.remove(agentID)
        // Output produced while suspended was already recorded in
        // lastSeenRevisions by pollRenderRevisions; clearing re-drives a
        // fresh evaluation on the next poll tick instead of waiting for a
        // further revision change that may never come.
        for terminalID in registry.trackedTerminals where registry.agentID(for: terminalID) == agentID {
            lastSeenRevisions[terminalID] = nil
        }
    }

    /// Restart minted a new generation: forget all hysteresis for the agent.
    /// The new run is machine-driven from a clean slate — it must NOT inherit
    /// the previous run's suspension, or evaluate() would silence the
    /// restarted agent forever (§3.7 cadence off).
    func generationInvalidated(agentID: AgentID) {
        suspended.remove(agentID)
        Task { await engine.invalidate(agentID: agentID) }
    }

    func forget(terminalID: TerminalID) {
        lastSeenRevisions[terminalID] = nil
        reportedExits.remove(terminalID)
        Task { [scheduler, registration = handlerRegistered] in
            await registration.value
            await scheduler.forget(terminalID: terminalID)
        }
    }

    // MARK: - Render revisions

    private func pollRenderRevisions() {
        for terminalID in registry.trackedTerminals {
            guard let session = sessionManager.session(for: terminalID) else { continue }
            let revision = session.outputRevision
            guard lastSeenRevisions[terminalID] != revision else { continue }
            lastSeenRevisions[terminalID] = revision
            Task { [scheduler, registration = handlerRegistered] in
                await registration.value
                await scheduler.outputRevisionChanged(terminalID: terminalID)
            }
            if let agentID = registry.agentID(for: terminalID) {
                Task {
                    try? await runtime.outputRevisionChanged(
                        agentID: agentID,
                        terminalID: terminalID,
                        revision: revision
                    )
                }
            }
        }
    }

    // MARK: - Screen evaluation (§3.7 steps 4–11)

    private func evaluate(terminalID: TerminalID) async {
        guard !evaluating.contains(terminalID) else { return } // one in flight
        evaluating.insert(terminalID)
        defer { evaluating.remove(terminalID) }
        if let agentCheck = registry.agentID(for: terminalID), suspended.contains(agentCheck) {
            return
        }
        guard let agentID = registry.agentID(for: terminalID),
              let binding = registry.binding(for: agentID),
              let manifest = manifest(for: binding.kind),
              let snapshot = try? await sessionManager.read(terminalID, source: .detection),
              !snapshot.text.isEmpty
        else { // parked/blank screen: nothing to evaluate
            return
        }
        guard let state = try? await runtime.state(of: agentID),
              !state.lifecycle.isTerminal
        else {
            return
        }
        if case .stopping = state.lifecycle {
            return
        } // §3.7 cadence off

        let context = ScreenDetectionEngine.EvaluationContext(
            agentID: agentID,
            currentLifecycle: state.lifecycle,
            manifest: manifest
        )
        if ProcessInfo.processInfo.environment["ATERM_DEBUG_SNAPSHOT"] == "1" {
            print(
                "[SNAPSHOT] rev=\(snapshot.outputRevision) text=\(String(snapshot.text.suffix(120)).debugDescription)"
            )
        }
        guard let payload = await engine.evaluate(snapshot, context: context) else {
            // Transient bail (hysteresis window open): the scheduler only
            // fires again on the next revision change, which may never come
            // if the output settled. Drop the sticky revision so the next
            // poll tick re-drives evaluation.
            lastSeenRevisions[terminalID] = nil
            return
        }

        // Re-read the lifecycle AFTER hysteresis resolves: the machine may
        // have moved on while this evaluation was in flight — never regress.
        guard let freshState = try? await runtime.state(of: agentID),
              freshState.lifecycle == state.lifecycle,
              !freshState.lifecycle.isTerminal
        else {
            // Transient bail (state moved under us mid-flight): re-arm via
            // the next poll tick rather than waiting for a new revision.
            lastSeenRevisions[terminalID] = nil
            return
        }
        if case .stopping = freshState.lifecycle {
            return
        } // §3.7 cadence off

        let envelope = ObservationEnvelope(
            agentID: agentID,
            terminalID: terminalID,
            surfaceGeneration: binding.surfaceGeneration,
            sourceID: "screen",
            sourceKind: .screen,
            sequence: nil,
            outputRevision: snapshot.outputRevision,
            observedAt: clock.now,
            receivedAt: clock.now
        )
        await runtime.ingest(Evidence(envelope: envelope, payload: .screen(payload)))
    }

    /// Bundled manifests cover integration agents; generic shells get a
    /// minimal app-side manifest that recognizes a live prompt on the last
    /// line (idle) with everything else falling back to unknown (§3.7).
    private func manifest(for kind: AgentKind) -> ScreenManifest? {
        if let name = catalog.adapter(for: kind)?.bundledManifestName {
            return bundledManifest(named: name)
        }
        if kind == .genericShell {
            return Self.shellManifest
        }
        return nil
    }

    private static let shellManifest: ScreenManifest = {
        var candidates = ["/bin/zsh", "/bin/bash"]
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            candidates.insert(shell, at: 0)
        }
        return ScreenManifest(
            manifestVersion: 1,
            agentKind: .genericShell,
            foregroundExecutables: candidates,
            rules: [
                ScreenRule(
                    id: "shell-idle-prompt",
                    resultingLifecycle: .idle,
                    priority: 10,
                    stabilityRequirement: .stable(.milliseconds(400)),
                    allMatchers: [
                        ScreenMatcher(
                            kind: .regex,
                            pattern: "[%$#>]\\s*$",
                            caseSensitive: true,
                            // Trailing-newline normalization can leave an
                            // empty final line; match across the last two.
                            region: .lastNLines(2)
                        ),
                    ]
                ),
            ],
            fallback: .unknown
        )
    }()

    private func bundledManifest(named name: String) -> ScreenManifest? {
        if let cached = manifests[name] {
            return cached
        }
        guard let manifest = try? ScreenManifestLoader.loadBundled(named: name) else { return nil }
        manifests[name] = manifest
        return manifest
    }

    // MARK: - Process evidence

    private func pollProcessEvidence() {
        for (agentID, binding) in registry.bindings {
            // Suspended (stop commanded / restart in flight) or already-exited
            // agents: further evidence would only regress machine state via
            // retained ledger observations (§3.7 cadence off).
            guard !suspended.contains(agentID),
                  let status = sessionManager.processStatus(for: binding.terminalID),
                  !status.isClosing,
                  !status.processExited else { continue }
            let pid = Int32(truncatingIfNeeded: status.foregroundPID)
            let terminalID = binding.terminalID
            let generation = binding.surfaceGeneration
            let candidates = catalog.adapter(for: binding.kind)?.executableCandidates ?? []

            Task { [inspector, runtime, clock, self] in
                guard let payload = try? await inspector.inspect(
                    terminalID: terminalID,
                    pid: pid,
                    foregroundExecutableCandidates: candidates
                ) else { return }
                // Unchanged liveness evidence carries no information: the
                // machine state a re-ingestion would produce is identical,
                // so skip it instead of growing the retained ledger (§3.7).
                if let last = lastProcessPayloads[agentID], last == payload {
                    return
                }
                lastProcessPayloads[agentID] = payload
                let envelope = ObservationEnvelope(
                    agentID: agentID,
                    terminalID: terminalID,
                    surfaceGeneration: generation,
                    sourceID: "process",
                    sourceKind: .process,
                    sequence: nil,
                    outputRevision: nil,
                    observedAt: clock.now,
                    receivedAt: clock.now
                )
                await runtime.ingest(Evidence(envelope: envelope, payload: .process(payload)))
            }
        }
        // Drop cache rows for agents that unbound since the last tick.
        lastProcessPayloads = lastProcessPayloads.filter { registry.bindings[$0.key] != nil }
    }

    /// Last process evidence ingested per agent; identical payloads are not
    /// re-ingested. MainActor-isolated with the pipeline.
    private var lastProcessPayloads: [AgentID: ProcessEvidencePayload] = [:]
}

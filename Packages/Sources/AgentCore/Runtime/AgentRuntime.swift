import Foundation

// AgentRuntime — the ONLY mutation owner for AgentState (architecture §3.5).
// Swift actor; integrates evidence ordering, authority resolution, the pure
// state machine, turn tracking, attention policy, prompt queue/watchdog, and
// projects read-only snapshots plus incremental deltas.

public actor AgentRuntime {
    private let clock: FakeClock
    private let catalog: AgentCatalog

    private var terminalPort: (any TerminalControlling)?
    private var persistence: (any StatePersisting)?

    private var workspaces: [WorkspaceID: Workspace] = [:]
    /// Insertion order of `workspaces` (dictionaries are unordered): boot
    /// adopts persisted rows in their stored order, so this IS the
    /// authoritative workspace enumeration for the control plane.
    private var workspaceOrder: [WorkspaceID] = []
    private var sessions: [AgentID: AgentSession] = [:]
    private var ledgers: [AgentID: EvidenceLedger] = [:]
    private var turnTrackers: [AgentID: TurnTracker] = [:]
    private var watchdogs: [AgentID: PromptWatchdog] = [:]

    /// Test-only fault injection for the §3.5 restart-rebind compensation
    /// path (AgentExecutionCoordinator.restartAgent's reattach catch). Always nil in
    /// shipping; set exclusively from test targets via the public setter below.
    private var _testReattachFailure: (any Error)?

    /// One-shot: the NEXT `reattach(agentID:terminalID:generation:)` throws
    /// this error instead of touching state. Cleared after firing.
    public func _testFailNextReattach(_ error: any Error) {
        _testReattachFailure = error
    }

    /// Armed delivery watches awaiting confirmation.
    ///
    /// `stateRevisionAtArm` snapshots the session's state revision when the
    /// watchdog was armed (§3.11 watchdog step 1): any confirmation must come
    /// from evidence observed AFTER the delivery, never from a revision the
    /// prompt could not have caused.
    private struct DeliveryWatch {
        let commandID: CommandID
        let baseOutputRevision: UInt64
        let stateRevisionAtArm: UInt64
    }

    /// Client-supplied idempotency keys (stage-9): a retried prompt carrying a
    /// commandID that already produced a receipt replays that receipt WITHOUT
    /// re-delivering, appending events, or touching the timeline — the same
    /// semantics the control-plane IdempotencyCache gives the socket path.
    /// Strictly in-memory (never persisted), bounded with oldest eviction.
    private static let receiptReplayLimit = 64
    private var receiptReplays: [CommandID: PromptReceipt] = [:]
    private var receiptReplayOrder: [CommandID] = []

    /// Armed delivery watches awaiting confirmation.
    private var deliveryWatches: [AgentID: DeliveryWatch] = [:]

    /// Grace-period kill tasks for gracefulStop, invalidated by generation.
    private var graceTasks: [AgentID: Task<Void, Never>] = [:]

    private var visibleAgents: Set<AgentID> = []
    private let deltas = RuntimeDeltaStream()
    private var timelines: [AgentID: [TimelineEvent]] = [:]
    private static let timelineLimit = 1000

    public init(clock: FakeClock, catalog: AgentCatalog = .standard()) {
        self.clock = clock
        self.catalog = catalog
    }

    // MARK: Wiring

    public func setTerminalPort(_ port: any TerminalControlling) {
        terminalPort = port
    }

    public func setPersistence(_ persistence: any StatePersisting) {
        self.persistence = persistence
    }

    public func deltaStream() -> AsyncStream<RuntimeDelta> {
        deltas.stream
    }

    // MARK: Creation / registration

    /// Adopts a workspace whose identity the CALLER owns: a row restored
    /// from persistence keeps its persisted ID; a workspace minted for a
    /// first run is registered under exactly the ID that gets persisted.
    /// The runtime never substitutes an identity of its own — runtime,
    /// store, layout and control plane share ONE `WorkspaceID` (§3.14).
    @discardableResult
    public func openWorkspace(_ workspace: Workspace) -> WorkspaceID {
        if workspaces[workspace.id] == nil {
            workspaceOrder.append(workspace.id)
        }
        workspaces[workspace.id] = workspace
        return workspace.id
    }

    /// Creates and registers a brand-new workspace, minting its identity.
    @discardableResult
    public func createWorkspace(name: String, rootPath: String) -> WorkspaceID {
        openWorkspace(Workspace(
            name: name,
            rootPath: rootPath,
            createdAt: clock.now,
            updatedAt: clock.now
        ))
    }

    /// Authoritative workspace snapshot (control-plane `workspace.list`).
    public func listWorkspaces() -> [Workspace] {
        workspaceOrder.compactMap { workspaces[$0] }
    }

    /// Creates an agent in `starting/launching` (§3.5 table row 1). The terminal
    /// layer performs the actual launch and reports back via `surfaceCreated`.
    @discardableResult
    public func createAgent(
        _ request: AgentLaunchRequest,
        in workspaceID: WorkspaceID
    ) async throws -> AgentID {
        guard workspaces[workspaceID] != nil else { throw RuntimeErrors.agentNotFound }
        guard let adapter = catalog.adapter(for: request.agentKind) else {
            throw RuntimeErrors.launchFailed
        }

        let descriptor = try adapter.makeLaunchDescriptor(request: request)
        let now = clock.now
        let agentID = AgentID()
        var session = AgentSession(
            id: agentID,
            workspaceID: workspaceID,
            kind: request.agentKind,
            displayName: request.displayName,
            taskSummary: request.taskSummary,
            cwd: request.workingDirectory,
            launchDescriptor: descriptor,
            resumePolicy: adapter.capabilities.sessionIdentity ? .manual : .none,
            state: .fresh(at: now),
            createdAt: now,
            lastActivityAt: now
        )
        session.state.process = .launching
        session.state.lifecycle = .starting
        session.state.authority = .unknown
        session.state.revision = 1

        sessions[agentID] = session
        ledgers[agentID] = EvidenceLedger()
        turnTrackers[agentID] = TurnTracker()

        workspaces[workspaceID]?.agentOrder.append(agentID)
        workspaces[workspaceID]?.updatedAt = now

        publish(agentID: agentID)
        persist(agentID: agentID)
        return agentID
    }

    /// The terminal layer reports a successfully created surface (§3.5 row 2).
    public func surfaceCreated(
        agentID: AgentID,
        terminalID: TerminalID,
        generation: SurfaceGeneration,
        pid: Int32?,
        processGroupID: Int32?
    ) async throws {
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        session.attach(terminal: terminalID)
        session.surfaceGeneration = generation
        sessions[agentID] = session

        ledgers[agentID]?.generationChanged(generation)

        let plan = AgentStateMachine.plan(
            current: sessions[agentID]!.state,
            trigger: .processLaunched(pid: pid, processGroupID: processGroupID),
            turnTracker: turnTrackers[agentID] ?? TurnTracker(),
            agentVisibleAndActive: false,
            at: clock.now
        )
        apply(plan: plan, to: agentID)
    }

    /// The terminal layer reports a polled process exit (ADR-0002 primary
    /// exit signal). Mirrors `surfaceCreated`: a pure pass-through into the
    /// state machine (§3.5 rows "process exited": exit 0 + user stop →
    /// stopped(userRequested); exit 0 → stopped(completed); otherwise failed).
    public func processExited(
        agentID: AgentID,
        exitCode: Int32?,
        signal: Int32?,
        userInitiated: Bool
    ) async throws {
        guard sessions[agentID] != nil else { throw RuntimeErrors.agentNotFound }
        let plan = AgentStateMachine.plan(
            current: sessions[agentID]!.state,
            trigger: .processExited(exitCode: exitCode, signal: signal, userInitiated: userInitiated),
            turnTracker: turnTrackers[agentID] ?? TurnTracker(),
            agentVisibleAndActive: visibleAgents.contains(agentID),
            at: clock.now
        )
        apply(plan: plan, to: agentID)
    }

    /// Semantic completion of a FAILED launch (§3.5): the terminal layer
    /// could not bring a surface up AFTER `createAgent` minted the session.
    /// Applies the machine's `.launchFailed` edge so orchestration can never
    /// strand a "starting" zombie — previously this trigger had NO public
    /// entry, which forced compensations to leave sessions half-alive.
    public func launchFailed(agentID: AgentID, reason: String) async throws {
        guard let session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        let plan = AgentStateMachine.plan(
            current: session.state,
            trigger: .launchFailed(reason),
            turnTracker: turnTrackers[agentID] ?? TurnTracker(),
            agentVisibleAndActive: visibleAgents.contains(agentID),
            at: clock.now
        )
        apply(plan: plan, to: agentID)
    }

    // MARK: Observation ingestion

    /// A render increased the terminal's output revision.
    public func outputRevisionChanged(agentID: AgentID, terminalID: TerminalID, revision: UInt64) async throws {
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        guard session.terminalID == terminalID else { throw RuntimeErrors.terminalUnavailable }
        session.outputRevision = revision
        sessions[agentID] = session
        ledgers[agentID]?.outputRevisionChanged(revision)

        // Watchdog confirmation path: output moved after our delivery.
        if let watch = deliveryWatches[agentID], revision > watch.baseOutputRevision {
            await confirmDelivery(agentID: agentID, signal: .outputRevisionChanged)
        }
    }

    /// Ingests one observation: envelope ordering first, then authority
    /// resolution, then the pure state machine (§3.6 → §3.5).
    public func ingest(_ evidence: Evidence) async {
        let agentID = evidence.envelope.agentID
        guard sessions[agentID] != nil, ledgers[agentID] != nil else { return }

        let decision = ledgers[agentID]!.accept(evidence)

        switch decision {
        case .acknowledgedDuplicate:
            // Acknowledged to sender upstream; no event, no state change.
            return
        case .discardedStaleGeneration, .discardedStaleOutputRevision:
            return
        case let .acceptedWithSequenceGap(expected):
            appendEvent(
                .integrationSequenceGap(expected: expected, received: evidence.envelope.sequence ?? 0),
                agentID: agentID
            )
        case .accepted:
            break
        }

        // Operation markers drive turn tracking even without lifecycle change.
        if case let .integrationOperation(operation) = evidence.payload {
            apply(operation: operation, agentID: agentID)
            return
        }

        guard let winning = StateAuthorityResolver.resolve(in: ledgers[agentID]!) else { return }
        guard let adopted = Self.lifecycle(from: winning.payload) else {
            // e.g. a bare process observation: record authority only.
            refreshAuthorityOnly(agentID: agentID)
            return
        }

        applyAdopted(lifecycle: adopted, evidence: winning, agentID: agentID)
    }

    /// Integration stopped reporting: expire it and fall back (§3.5 last row).
    public func integrationExpired(sourceID: String, agentID: AgentID) async {
        ledgers[agentID]?.expireIntegration(sourceID: sourceID, at: clock.now)

        let stillHasIntegration = ledgers[agentID]?.integrationObservations.values.contains { evidence in
            if case .integrationLifecycle = evidence.payload {
                return true
            }
            return false
        } ?? false

        if !stillHasIntegration, let session = sessions[agentID], session.state.authority == .integration {
            let plan = AgentStateMachine.plan(
                current: session.state,
                trigger: .authorityLost,
                turnTracker: turnTrackers[agentID] ?? TurnTracker(),
                agentVisibleAndActive: visibleAgents.contains(agentID),
                at: clock.now
            )
            apply(plan: plan, to: agentID)
        }
    }

    private static func lifecycle(from payload: EvidencePayload) -> LifecyclePhase? {
        switch payload {
        case let .integrationLifecycle(phase): phase
        case let .screen(screenPayload): screenPayload.resultingLifecycle
        default: nil
        }
    }

    // MARK: Commands (§3.11)

    public func prompt(
        _ agentID: AgentID,
        _ text: String,
        _ policy: PromptPolicy,
        commandID clientCommandID: CommandID? = nil
    ) async throws -> PromptReceipt {
        if let clientCommandID, let replay = receiptReplays[clientCommandID] {
            return replay
        }
        let receipt = try await dispatchPrompt(
            agentID, text, policy, clientCommandID: clientCommandID
        )
        if let clientCommandID {
            rememberReceipt(receipt, forKey: clientCommandID)
        }
        return receipt
    }

    /// The pre-stage-9 prompt body, unchanged in behavior.
    private func dispatchPrompt(
        _ agentID: AgentID,
        _ text: String,
        _ policy: PromptPolicy,
        clientCommandID: CommandID?
    ) async throws -> PromptReceipt {
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        let commandID = clientCommandID ?? CommandID()

        switch session.state.lifecycle {
        case let .waitingForInput(descriptor):
            // waitingForInput(terminalOnly): composer disabled entirely (§3.11).
            guard descriptor.safeReplyMode == .composerAllowed, descriptor.kind == .freeText else {
                throw RuntimeErrors.waitingForTerminalInput
            }
            // waitingForInput(composerAllowed): always sendNow.
            return try await deliverPrompt(commandID: commandID, text: text, agentID: agentID)

        case .unknown:
            // unknown: explicit sendNow only (§3.11).
            guard policy.isExplicitSendNow else { throw RuntimeErrors.invalidLifecycle }
            return try await deliverPrompt(commandID: commandID, text: text, agentID: agentID)

        case .idle:
            return try await deliverPrompt(commandID: commandID, text: text, agentID: agentID)

        case .working, .starting, .stopping:
            switch policy {
            case .sendNow:
                return try await deliverPrompt(commandID: commandID, text: text, agentID: agentID)
            case .queueWhenIdle:
                if catalog.adapter(for: session.kind)?.capabilities.isProcessOnly ?? true {
                    throw RuntimeErrors.invalidLifecycle
                }
                try Self.enqueueOnSession(&session, text: text, commandID: commandID, at: clock.now)
                sessions[agentID] = session
                publish(agentID: agentID)
                return PromptReceipt(commandID: commandID, agentID: agentID, outcome: .queued)
            case .rejectUnlessIdle:
                throw RuntimeErrors.invalidLifecycle
            }

        case .stopped, .failed:
            throw RuntimeErrors.invalidLifecycle
        }
    }

    /// Single-slot queueing (§3.11): an occupied slot is a hard error — the
    /// new prompt is rejected with `queuedPromptAlreadyExists` and whatever
    /// is already queued survives intact. There is deliberately NO
    /// replacement path here.
    private static func enqueueOnSession(
        _ session: inout AgentSession,
        text: String,
        commandID: CommandID,
        at instant: MonotonicInstant
    ) throws {
        guard session.queuedPrompt == nil else {
            throw RuntimeErrors.queuedPromptAlreadyExists
        }
        var queue = PromptQueue()
        try queue.enqueue(
            QueuedPrompt(commandID: commandID, text: text, queuedAt: instant),
            replacingExisting: false
        )
        session.setQueuedPrompt(queue.queued)
    }

    private func deliverPrompt(
        commandID: CommandID,
        text: String,
        agentID: AgentID
    ) async throws -> PromptReceipt {
        // Pre-delivery read is a throwaway snapshot (§3.11): only the
        // terminal handle is needed here, and nothing derived from it may
        // survive the await below — writing a pre-await copy back would
        // clobber concurrent actor mutations.
        guard let port = terminalPort else {
            throw RuntimeErrors.terminalUnavailable
        }
        guard let terminalID = sessions[agentID]?.terminalID else {
            throw RuntimeErrors.terminalUnavailable
        }

        try await port.deliverInput(terminalID, text: text, submit: true)

        // Delivery succeeded: re-read the LIVE entry; the pre-await copy is
        // stale by now and must never be written back across an await.
        // Residual edge (accepted): if the agent is removed during the
        // deliverInput suspension, the text IS on the terminal but
        // agentNotFound throws here — receipt, turn tracking and the
        // DeliveryWatch are skipped. Callers log and restore the draft; the
        // alternative (resurrecting a removed session) is worse.
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        appendEvent(.promptDelivered(commandID: commandID), agentID: agentID)

        // Open the turn (§3.5: delivered prompt opens it).
        var tracker = turnTrackers[agentID] ?? TurnTracker()
        if tracker.promptDelivered(commandID: commandID, at: clock.now) {
            turnTrackers[agentID] = tracker
            appendEvent(.turnStarted(reason: .promptDelivered(commandID)), agentID: agentID)
        }
        session.lastActivityAt = clock.now
        sessions[agentID] = session
        let watchdogInstance = watchdog(for: agentID)
        // Supersede an outstanding watch BEFORE the DeliveryWatch slot below
        // is overwritten, and record §3.11 rule 6 for the displaced command
        // right here: its own timeout resolution would be silently dropped by
        // deliveryWatchResolved once the slot no longer names it. A
        // redelivery of the SAME commandID skips the extra record — the
        // fresh watch armed below reports for it.
        if let superseded = await watchdogInstance.supersedePending(),
           superseded != commandID
        {
            appendEvent(.promptDeliveryUnconfirmed(commandID: superseded), agentID: agentID)
            publish(agentID: agentID)
            persist(agentID: agentID)
        }
        // Queue-drain redelivery deliberately reuses the commandID: drop
        // signals buffered for EARLIER deliveries of this command so a stale
        // echo cannot falsely confirm the fresh watch (§3.11).
        await watchdogInstance.invalidateBufferedConfirmation(for: commandID)
        deliveryWatches[agentID] = DeliveryWatch(
            commandID: commandID,
            baseOutputRevision: session.outputRevision,
            stateRevisionAtArm: session.state.revision
        )
        let watchOutcomeTask = Task {
            await watchdogInstance.watch(commandID: commandID)
        }
        Task {
            let outcome = await watchOutcomeTask.value
            await self.deliveryWatchResolved(outcome: outcome, agentID: agentID, commandID: commandID)
        }

        publish(agentID: agentID)
        return PromptReceipt(commandID: commandID, agentID: agentID, outcome: .delivered)
    }

    /// Called by the armed watchdog task.
    func deliveryWatchResolved(outcome: PromptWatchdog.Outcome, agentID: AgentID, commandID: CommandID) async {
        guard deliveryWatches[agentID]?.commandID == commandID else { return }
        deliveryWatches[agentID] = nil
        switch outcome {
        case .confirmed:
            break
        case .timedOut:
            // Record the failure. NEVER auto-retry (§3.11 rule 7).
            appendEvent(.promptDeliveryUnconfirmed(commandID: commandID), agentID: agentID)
            publish(agentID: agentID)
            persist(agentID: agentID)
        }
    }

    /// Test/diagnostic hook: is a delivery watchdog armed for this agent?
    public func isDeliveryWatchArmed(_ agentID: AgentID) async -> Bool {
        guard let watch = deliveryWatches[agentID], let instance = watchdogs[agentID] else { return false }
        return await instance.isWatching(commandID: watch.commandID)
    }

    /// Snapshot of the armed delivery watch (diagnostics/tests). `nil` when
    /// no watchdog is armed. `stateRevisionAtArm` is the §3.11 watchdog
    /// step-1 record: the state revision observed when the delivery was made.
    public struct DeliveryWatchStatus: Equatable, Sendable {
        public let commandID: CommandID
        public let baseOutputRevision: UInt64
        public let stateRevisionAtArm: UInt64
    }

    public func deliveryWatchStatus(_ agentID: AgentID) async -> DeliveryWatchStatus? {
        guard let watch = deliveryWatches[agentID] else { return nil }
        return DeliveryWatchStatus(
            commandID: watch.commandID,
            baseOutputRevision: watch.baseOutputRevision,
            stateRevisionAtArm: watch.stateRevisionAtArm
        )
    }

    private func rememberReceipt(_ receipt: PromptReceipt, forKey key: CommandID) {
        if receiptReplays[key] == nil {
            receiptReplayOrder.append(key)
            while receiptReplayOrder.count > Self.receiptReplayLimit {
                receiptReplays.removeValue(forKey: receiptReplayOrder.removeFirst())
            }
        }
        receiptReplays[key] = receipt
    }

    private func confirmDelivery(agentID: AgentID, signal: PromptWatchdog.ConfirmSignal) async {
        guard let watch = deliveryWatches[agentID] else { return }
        await watchdogs[agentID]?.confirm(signal, for: watch.commandID)
    }

    public func cancelQueuedPrompt(_ agentID: AgentID) async throws {
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        if session.queuedPrompt != nil {
            session.setQueuedPrompt(nil)
            sessions[agentID] = session
            appendEvent(.queuedPromptCancelled, agentID: agentID)
            publish(agentID: agentID)
        }
    }

    public func interrupt(_ agentID: AgentID) async throws {
        try await stopOrInterrupt(agentID: agentID, mode: .interrupt)
    }

    public func stop(_ agentID: AgentID, mode: StopMode) async throws {
        try await stopOrInterrupt(agentID: agentID, mode: mode)
    }

    private func stopOrInterrupt(agentID: AgentID, mode: StopMode) async throws {
        guard let session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }

        // closeView never signals; interrupt/gracefulStop need a live
        // terminal. Resolve the handle BEFORE applying the plan: applying
        // first would force .stopping and persist stopCommanded, then throw —
        // wedging the agent with a live process, no grace-kill backstop, and
        // a phantom stop timeline event.
        let target: (port: any TerminalControlling, terminalID: TerminalID)?
        if mode == .closeView {
            target = nil
        } else {
            guard let port = terminalPort, let terminalID = session.terminalID else {
                throw RuntimeErrors.terminalUnavailable
            }
            target = (port, terminalID)
        }

        let plan = AgentStateMachine.plan(
            current: session.state,
            trigger: .stopRequested(mode),
            turnTracker: turnTrackers[agentID] ?? TurnTracker(),
            agentVisibleAndActive: visibleAgents.contains(agentID),
            at: clock.now
        )
        apply(plan: plan, to: agentID)

        // Pre-checked above: only closeView reaches this without a handle.
        guard let target else { return }

        switch mode {
        case .interrupt:
            try await target.port.sendSignal(.interrupt, to: target.terminalID)

        case .gracefulStop:
            // SIGTERM, 2 s grace, then SIGKILL — unless restart superseded us.
            // Arm the backstop via defer so a failed SIGTERM delivery still
            // gets the 2 s sweep; otherwise the agent wedges in .stopping
            // with a live process and no further signal attempts.
            let generation = session.surfaceGeneration
            graceTasks[agentID]?.cancel()
            defer { armGraceKill(agentID: agentID, generation: generation) }
            try await target.port.sendSignal(.terminate, to: target.terminalID)

        case .closeView:
            break
        }
    }

    /// Arms the deferred SIGKILL sweep for a graceful stop (§3.5 stop flow).
    private func armGraceKill(agentID: AgentID, generation: SurfaceGeneration) {
        graceTasks[agentID] = Task {
            await clock.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await enforceGraceKill(agentID: agentID, generation: generation)
        }
    }

    func enforceGraceKill(agentID: AgentID, generation: SurfaceGeneration) async {
        guard let session = sessions[agentID],
              session.surfaceGeneration == generation,
              let port = terminalPort,
              let terminalID = session.terminalID else { return }
        switch session.state.process {
        case .running, .exiting, .launching:
            try? await port.sendSignal(.kill, to: terminalID)
        default:
            break
        }
    }

    /// Restart: new surface generation, old observations discarded (§3.5).
    public func restart(_ agentID: AgentID) async throws {
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        graceTasks[agentID]?.cancel()

        let generation = session.surfaceGeneration.successor()
        session.surfaceGeneration = generation

        // Successful relaunch intent clears failure/input attention (§3.4);
        // the old session reference survives until the new start succeeds.
        session.state.attention = AttentionPolicy.clearForRelaunch(session.state.attention)
        sessions[agentID] = session

        ledgers[agentID]?.generationChanged(generation)
        let tracker = TurnTracker()
        turnTrackers[agentID] = tracker
        // A pre-restart delivery watch would falsely confirm against the
        // successor surface: reattach resets outputRevision to 0, so new
        // revisions exceed the stale baseOutputRevision (§3.11). Drop it;
        // the pending watchdog resolves against a missing watch as a no-op.
        deliveryWatches[agentID] = nil

        let plan = AgentStateMachine.plan(
            current: sessions[agentID]!.state,
            trigger: .restartRequested(generation),
            turnTracker: tracker,
            agentVisibleAndActive: visibleAgents.contains(agentID),
            at: clock.now
        )
        apply(plan: plan, to: agentID)
    }

    /// Restart rebind (§3.5 "Surface generation changed"): after the app's
    /// launch pipeline spawned the successor surface, the session's
    /// single-live-terminal invariant is re-pointed at it. Every subsequent
    /// prompt/stop/read/sendKeys/watchdog confirmation then flows against the
    /// NEW terminal; observations of the retired terminal are rejected with
    /// `terminalUnavailable` by their terminalID guards.
    public func reattach(
        agentID: AgentID,
        terminalID: TerminalID,
        generation: SurfaceGeneration
    ) throws {
        if let injected = _testReattachFailure {
            _testReattachFailure = nil
            throw injected
        }
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        session.detachTerminal()
        session.attach(terminal: terminalID)
        session.surfaceGeneration = generation
        // The successor surface starts from a fresh render history.
        session.outputRevision = 0
        // New surface generation: the ledger's observation watermark
        // restarts with it, or accept() would discard every observation
        // from the successor surface (§3.5, §3.6).
        ledgers[agentID]?.generationChanged(generation)
        sessions[agentID] = session
        publish(agentID: agentID)
    }

    public func resume(_ agentID: AgentID) async throws {
        guard let session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        guard let adapter = catalog.adapter(for: session.kind),
              adapter.capabilities.sessionIdentity
        else {
            throw RuntimeErrors.resumeUnsupported
        }
        guard let reference = session.sessionReference else {
            throw RuntimeErrors.resumeReferenceMissing
        }
        guard adapter.buildResumeSpec(sessionReference: reference) != nil else {
            throw RuntimeErrors.resumeUnsupported
        }
        guard terminalPort != nil else { throw RuntimeErrors.terminalUnavailable }
        appendEvent(.resumeAttempted(reference), agentID: agentID)
        publish(agentID: agentID)
    }

    public func focus(_ agentID: AgentID) async throws {
        guard sessions[agentID] != nil else { throw RuntimeErrors.agentNotFound }
        visibleAgents.insert(agentID)
    }

    public func read(_ agentID: AgentID, source: TerminalReadSource) async throws -> TerminalSnapshot {
        guard let session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        guard let port = terminalPort, let terminalID = session.terminalID else {
            throw RuntimeErrors.terminalUnavailable
        }
        guard let snapshot = try await port.read(terminalID, source: source) else {
            throw RuntimeErrors.semanticStateUnavailable
        }
        return snapshot
    }

    public func sendKeys(_ agentID: AgentID, keys: [String]) async throws {
        guard let session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        guard let port = terminalPort, let terminalID = session.terminalID else {
            throw RuntimeErrors.terminalUnavailable
        }
        try await port.sendKeys(terminalID, keys: keys)
    }

    // MARK: Attention

    /// FocusCoordinator calls this after ≥500 ms continuous visibility;
    /// clears completionUnread ONLY (§3.12 flow E).
    public func markSeen(_ agentID: AgentID) async throws {
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        let cleared = AttentionPolicy.clearCompletionOnSeen(session.state.attention)
        if cleared != session.state.attention {
            session.state.attention = cleared
            session.state.revision += 1
            sessions[agentID] = session
            appendEvent(.attentionCleared(kind: .completionUnread), agentID: agentID)
            publish(agentID: agentID)
            persist(agentID: agentID)
        }
    }

    public func setVisibility(_ agentID: AgentID, isVisible: Bool) throws {
        guard sessions[agentID] != nil else { throw RuntimeErrors.agentNotFound }
        if isVisible {
            visibleAgents.insert(agentID)
        } else {
            visibleAgents.remove(agentID)
        }
    }

    public func acknowledgeFailure(_ agentID: AgentID) async throws {
        guard var session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        let cleared = AttentionPolicy.acknowledgeFailure(session.state.attention)
        if cleared != session.state.attention {
            session.state.attention = cleared
            session.state.revision += 1
            sessions[agentID] = session
            appendEvent(.attentionCleared(kind: .failure), agentID: agentID)
            publish(agentID: agentID)
            persist(agentID: agentID)
        }
    }

    // MARK: Reading state

    public func state(of agentID: AgentID) throws -> AgentState {
        guard let session = sessions[agentID] else { throw RuntimeErrors.agentNotFound }
        return session.state
    }

    public func projection() -> RuntimeProjection {
        syncTurnMirrors()
        return RuntimeProjectionBuilder.build(sessions: sessions.values, generatedAt: clock.now)
    }

    public func launchDescriptor(of agentID: AgentID) -> LaunchDescriptor? {
        sessions[agentID]?.launchDescriptor
    }

    /// Session references are captured by the evidence ledger (hook
    /// sessionIdentity reports), never assigned directly — mirror the
    /// ledger's reference into the session so §3.14 commits persist it and
    /// projections report `hasSessionReference` truthfully.
    private func syncSessionReference(_ agentID: AgentID) {
        guard var session = sessions[agentID],
              let reference = ledgers[agentID]?.sessionReference,
              session.sessionReference != reference else { return }
        session.sessionReference = reference
        // Bump so the next persist() commit carries a fresh revision;
        // otherwise the §3.14 upsert skips the identity-only ingest path.
        session.state.revision += 1
        sessions[agentID] = session
    }

    /// Refreshes every session's denormalized turn mirror from its tracker.
    private func syncTurnMirrors() {
        for agentID in sessions.keys {
            guard var session = sessions[agentID], let tracker = turnTrackers[agentID] else { continue }
            if session.turn != tracker.activeTurn {
                session.setTurn(tracker.activeTurn)
                sessions[agentID] = session
            }
        }
    }

    public func timeline(of agentID: AgentID) -> [TimelineEvent] {
        timelines[agentID] ?? []
    }

    public func capturedSessionReference(of agentID: AgentID) -> SessionReference? {
        ledgers[agentID]?.sessionReference ?? sessions[agentID]?.sessionReference
    }

    // MARK: Internal machinery

    private func watchdog(for agentID: AgentID) -> PromptWatchdog {
        if let existing = watchdogs[agentID] {
            return existing
        }
        let fresh = PromptWatchdog(clock: clock)
        watchdogs[agentID] = fresh
        return fresh
    }

    private func applyAdopted(lifecycle: LifecyclePhase, evidence: Evidence, agentID: AgentID) {
        guard var session = sessions[agentID] else { return }
        // Terminal phases are process-authority-only for lifecycle (§3.5, §3.6):
        // a late screen manifest or integration heartbeat adopted after
        // processExited must not resurrect a stopped/failed agent.
        switch session.state.lifecycle {
        case .stopped, .failed:
            if evidence.authority != .process {
                return
            }
        default:
            break
        }

        let previousAttention = session.state.attention

        let plan = AgentStateMachine.plan(
            current: session.state,
            adopting: lifecycle,
            authority: evidence.authority,
            turnTracker: turnTrackers[agentID] ?? TurnTracker(),
            agentVisibleAndActive: visibleAgents.contains(agentID),
            at: evidence.envelope.receivedAt
        )

        var newState = plan.newState
        newState.attention = AttentionPolicy.update(
            current: previousAttention,
            from: session.state.lifecycle,
            to: newState.lifecycle,
            turnClosedWithCompletion: plan.turnClosedWithCompletion,
            agentVisibleAndActive: visibleAgents.contains(agentID),
            at: evidence.envelope.receivedAt,
            eventID: RuntimeEventID()
        )

        session.state = newState
        sessions[agentID] = session
        turnTrackers[agentID] = plan.turnTracker

        for event in plan.events {
            appendEvent(event, agentID: agentID)
        }
        switch (previousAttention, newState.attention) {
        case (.inputRequired, .inputRequired):
            break
        case (_, .inputRequired):
            appendEvent(.attentionRaised(kind: .inputRequired), agentID: agentID)
        case let (.inputRequired, other) where other.rank < AttentionRank.inputRequired:
            appendEvent(.attentionCleared(kind: .inputRequired), agentID: agentID)
        default:
            break
        }
        if case .failure = newState.attention {
            if case .failure = previousAttention {} else {
                appendEvent(.attentionRaised(kind: .failure), agentID: agentID)
            }
        }

        // Watchdog: working transition confirms delivery (§3.11 rule 5b).
        if case .working = newState.lifecycle {
            Task { await confirmDelivery(agentID: agentID, signal: .lifecycleBecameWorking) }
        }

        publish(agentID: agentID)
        persist(agentID: agentID)
        deliverQueuedPromptIfEligible(agentID: agentID)
    }

    private func refreshAuthorityOnly(agentID: AgentID) {
        guard var session = sessions[agentID], ledgers[agentID] != nil else { return }
        let authority = StateAuthorityResolver.effectiveAuthority(in: ledgers[agentID]!)
        if session.state.authority != authority {
            session.state.authority = authority
            session.state.revision += 1
            sessions[agentID] = session
            publish(agentID: agentID)
            persist(agentID: agentID)
        }
    }

    private func apply(operation: IntegrationOperation, agentID: AgentID) {
        guard var session = sessions[agentID] else { return }
        var tracker = turnTrackers[agentID] ?? TurnTracker()

        switch operation {
        case .started:
            if tracker.integrationOperationStarted(at: clock.now) {
                appendEvent(.turnStarted(reason: .integrationOperation), agentID: agentID)
                turnTrackers[agentID] = tracker
            }
            Task { await confirmDelivery(agentID: agentID, signal: .integrationOperationStart) }

        case .completed:
            let openedByPrompt = tracker.activeTurn?.openedByPrompt ?? false
            if tracker.integrationCompleted() {
                appendEvent(.turnCompleted(hadPrompt: openedByPrompt), agentID: agentID)
                turnTrackers[agentID] = tracker
                // Completion attention mirrors the working→idle rule.
                if !visibleAgents.contains(agentID), session.state.attention.rank < AttentionRank.completionUnread {
                    session.state.attention = .completionUnread(since: clock.now, eventID: RuntimeEventID())
                    // §3.14 store upsert keys on revision — without the bump
                    // this attention change is never persisted.
                    session.state.revision += 1
                }
                session.lastActivityAt = clock.now
                sessions[agentID] = session
            }
        }
        publish(agentID: agentID)
        persist(agentID: agentID)
    }

    private func apply(plan: StateTransitionPlan, to agentID: AgentID) {
        guard var session = sessions[agentID] else { return }
        var newState = plan.newState
        let eventsToAppend = plan.events
        let previousAttention = session.state.attention

        // Attention side effects on exit paths.
        if case .failed = newState.lifecycle {
            // Mirror applyAdopted: a no-op failed→failed edge keeps its
            // existing attention instead of re-minting a fresh timestamp.
            if case .failure = previousAttention {} else {
                newState.attention = .failure(since: newState.observedAt, eventID: RuntimeEventID())
            }
        } else if case .stopped(.userRequested) = newState.lifecycle {
            // User stop clears the queue and never raises failure attention
            // (§3.5); a deliberate user action also supersedes badges —
            // inputRequired must never strand on a dead agent.
            session.setQueuedPrompt(nil)
            newState.attention = .none
        } else if case .stopped(.completed) = newState.lifecycle, plan.turnClosedWithCompletion {
            newState.attention = .completionUnread(since: newState.observedAt, eventID: RuntimeEventID())
        }

        // Terminal normalizer: no API clears inputRequired on a non-waiting
        // agent, so a terminal lifecycle must never carry it forward.
        var terminal = false
        if case .stopped = newState.lifecycle {
            terminal = true
        }
        if case .failed = newState.lifecycle {
            terminal = true
        }
        if terminal, case .inputRequired = newState.attention {
            newState.attention = .none
        }

        session.state = newState
        sessions[agentID] = session
        turnTrackers[agentID] = plan.turnTracker

        for event in eventsToAppend {
            appendEvent(event, agentID: agentID)
        }
        if case .failure = newState.attention {
            if case .failure = previousAttention {} else {
                appendEvent(.attentionRaised(kind: .failure), agentID: agentID)
            }
        }

        publish(agentID: agentID)
        persist(agentID: agentID)
    }

    /// Delivers the queued prompt when the agent reaches a validated idle —
    /// never while waitingForInput, never in unknown (§3.4 safety rules).
    /// Eligibility is re-validated inside this actor turn, and a failed
    /// delivery is surfaced as `queuedPromptDeliveryFailed` via the timeline
    /// and RuntimeDelta — never silently dropped (§3.11 failure taxonomy).
    private func deliverQueuedPromptIfEligible(agentID: AgentID) {
        guard var session = sessions[agentID],
              let queued = session.queuedPrompt else { return }
        // Re-validate eligibility in the same actor turn that takes the
        // prompt: the lifecycle may have moved on since this drain was
        // scheduled.
        guard case .idle = session.state.lifecycle else { return }

        session.setQueuedPrompt(nil)
        sessions[agentID] = session

        let commandID = queued.commandID
        let text = queued.text
        Task {
            // Consume any stale replay receipt from the original queueing
            // attempt so this delivery dispatches fresh under the queued
            // command's ID and failure reports stay client-correlatable.
            receiptReplays[commandID] = nil
            do {
                _ = try await self.prompt(agentID, text, .sendNow, commandID: commandID)
            } catch {
                self.recordQueuedPromptDeliveryFailure(commandID: commandID, agentID: agentID)
            }
        }
    }

    /// Called when a drained queued prompt could not be delivered. The text is
    /// gone from the queue; the event is the durable trace the UI/API surface.
    func recordQueuedPromptDeliveryFailure(commandID: CommandID, agentID: AgentID) {
        appendEvent(.queuedPromptDeliveryFailed(commandID: commandID), agentID: agentID)
        publish(agentID: agentID)
    }

    // MARK: Bookkeeping

    private func appendEvent(_ event: AgentEvent, agentID: AgentID) {
        var timeline = timelines[agentID] ?? []
        timeline.append(TimelineEvent(agentID: agentID, at: clock.now, event: event))
        if timeline.count > Self.timelineLimit {
            timeline.removeFirst(timeline.count - Self.timelineLimit)
        }
        timelines[agentID] = timeline
    }

    private func publish(agentID: AgentID) {
        guard var session = sessions[agentID] else { return }
        syncSessionReference(agentID)
        session = sessions[agentID]!
        // Keep the denormalized turn mirror in sync with the tracker so
        // projections and deltas report turnActive truthfully.
        if let tracker = turnTrackers[agentID], session.turn != tracker.activeTurn {
            session.setTurn(tracker.activeTurn)
            sessions[agentID] = session
        }
        deltas.yield(.agentChanged(AgentSummary(session: session)))
    }

    private func persist(agentID: AgentID) {
        syncSessionReference(agentID)
        guard let session = sessions[agentID], let persistence else { return }
        let commit = StateCommit(
            agentID: agentID,
            state: session.state,
            events: timelines[agentID] ?? [],
            sessionReference: session.sessionReference,
            session: session
        )
        // Runtime never blocks lifecycle detection on disk I/O (§3.14).
        Task {
            await persistence.commit(commit)
        }
    }
}

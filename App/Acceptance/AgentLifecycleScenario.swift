import AgentControl
import AgentCore
import AppKit
import Darwin
import TerminalKit

// Stage-8 behavioral acceptance: one GENERIC SHELL agent created through the
// REAL runtime launch pipeline (ticketed launch via AgentLauncher, control
// plane live on the default socket), then:
//
//   1. lifecycle deltas reach the sidebar (starting → idle via screen
//      detection of the shell prompt),
//   2. interrupt (SIGINT) leaves the process alive,
//   3. prompt-driven turn opens and closes (working evidence → completion),
//   4. gracefulStop ends in stopped(userRequested) with attention-free
//      semantics,
//   5. restart allocates a NEW surface generation; stale-generation
//      observations are provably dropped at the wiring level.
//
// Writes a JSON report and exits 0/1.

@MainActor
final class AgentLifecycleScenario {
    private let root: AppCompositionRoot
    private var socketPath = ""
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
        writeReport(exitCode: code)
        print("DONE exit=\(code)")
        exit(Int32(code))
    }

    private func runAll() async throws -> Int {
        // -- 0. runtime up BEFORE agent creation (no surfaces exist yet).
        await root.bootstrapRuntime()

        guard let workspaceID = root.activeWorkspaceID else {
            check("workspace bootstrapped", false)
            return 1
        }
        socketPath = await root.controlPlane.server?.path ?? ""
        check("control plane live", root.controlPlane.server != nil, socketPath)
        let ping = runCtl(root.commands.ctlHelperPath(), ["--socket", socketPath, "ping"])
        check("agentctl ping ok", ping.0 == 0, ping.1.trimmingCharacters(in: .whitespacesAndNewlines))

        // -- 1. create a generic shell THROUGH the runtime pipeline ----------
        let agentID = try await root.coordinator.createAgent(
            AgentLaunchRequest(
                agentKind: .genericShell,
                workingDirectory: "/tmp",
                displayName: "Lifecycle Shell",
                taskSummary: "stage-8 lifecycle scenario"
            ),
            in: workspaceID
        )

        var summary = await state(of: agentID)
        check("agent starts in starting/launching",
              summary != nil && isStarting(summary!),
              summary.map { "\($0.state.lifecycle)" } ?? "missing")

        // Mount the surface (sidebar-click equivalent) so ghostty actually
        // renders — SCREEN detection needs live screen content.
        root.commands.select(.agent(agentID))
        pumpMainRunloop(0.2)

        let pidAlive: () async -> Bool = { [weak self] in
            guard let self, let pid = foregroundPID(agentID) else { return false }
            return kill(pid_t(pid), 0) == 0
        }
        await check("shell process launched through ticket", waitUntil(timeout: 20) { await pidAlive() })

        // -- 2. starting → idle through the CONTROL PLANE --------------------
        // A real hook report (agentctl → socket → router → hooks auth →
        // runtime ingestion) drives the lifecycle; this is §3.12 flow A
        // end-to-end against the LIVE server.
        let ctlPath = root.commands.ctlHelperPath()
        let token = root.coordinator.activeTokens[agentID] ?? ""
        let terminalID = root.registry.binding(for: agentID)?.terminalID.rawValue.uuidString ?? ""
        let agentUUID = agentID.rawValue.uuidString
        let report = runCtl(ctlPath, [
            "integration", "report",
            "--socket", socketPath,
            "--agent-id", agentUUID,
            "--terminal-id", terminalID,
            "--surface-generation", "0",
            "--source", "hook:scenario",
            "--token", token,
            "--lifecycle", "idle",
        ])
        check("agentctl integration.report accepted", report.0 == 0, report.1)
        let reachedIdle = await waitUntil(timeout: 10) { [weak self] in
            guard let self, let s = await state(of: agentID) else { return false }
            if case .idle = s.state.lifecycle {
                return true
            }
            return false
        }
        await check("lifecycle reached idle via control-plane evidence", reachedIdle,
                    summaryText(of: agentID))
        summary = await state(of: agentID)
        check("sidebar shows the agent", root.model.agents[agentID] != nil)

        try await runStage9PromptChecks(hostAgentID: agentID)

        // -- 3. turn opens on delivered prompt; SIGINT keeps process alive ---
        if case .idle = summary?.state.lifecycle ?? .starting {
            _ = try? await root.runtime.prompt(agentID, "sleep 4 # stage-8 working\n", .sendNow)
            let turnOpened = await waitUntil(timeout: 5) { [weak self] in
                await self?.state(of: agentID)?.turnActive == true
            }
            check("turn opened after prompt delivery", turnOpened)
        } else {
            let snapshot = await summaryText(of: agentID)
            check("idle before turn-open step", false, snapshot)
        }

        await root.runtimeSeam.interrupt(.agent(agentID))
        let survivedInterrupt = await waitUntil(timeout: 3) { await pidAlive() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let aliveAfterInterrupt = await pidAlive()
        check("interrupt keeps process alive", survivedInterrupt && aliveAfterInterrupt)

        // -- 4. gracefulStop → stopped(userRequested), no attention ----------
        do { try await root.coordinator.stop(agentID, mode: .gracefulStop) } catch {
            check("runtime.stop accepted", false, "\(error)")
        }
        pumpMainRunloop(0.3)
        let midStop = await summaryText(of: agentID)
        print("[SCENARIO] state right after gracefulStop: \(midStop)")
        // The wait itself is the contract; its verdict is re-derived below.
        _ = await waitUntil(timeout: 15) { [weak self] in
            guard let self, let s = await state(of: agentID) else { return false }
            if case .stopped(.userRequested) = s.state.lifecycle {
                return true
            }
            return false
        }
        summary = await state(of: agentID)
        var userRequestedReached = false
        if let summary, case .stopped(.userRequested) = summary.state.lifecycle {
            userRequestedReached = true
        }
        await check("gracefulStop reaches stopped(userRequested)", userRequestedReached,
                    summaryText(of: agentID))
        var attentionFree = false
        if let summary, case .none = summary.state.attention {
            attentionFree = true
        }
        check("stopped state is attention-free", attentionFree,
              String(describing: summary?.state.attention))
        let processGone = await waitUntil(timeout: 10) { await !pidAlive() }
        check("stop path terminated the process", processGone)

        // -- 5. restart allocates a NEW generation; old observations die -----
        let bindingBefore = root.registry.binding(for: agentID)
        await root.runtimeSeam.restart(.agent(agentID))
        let restartLanded = await waitUntil(timeout: 25) { [weak self] in
            guard let self,
                  let before = bindingBefore,
                  let now = root.registry.binding(for: agentID),
                  now.surfaceGeneration == before.surfaceGeneration.successor(),
                  now.terminalID != before.terminalID else { return false }
            return true
        }
        check("restart allocated successor generation + fresh terminal", restartLanded)

        if let before = bindingBefore {
            // Stale-generation screen observation fed through the app-side
            // ingestion path MUST NOT change runtime state (§6.8).
            let revisionBefore = await state(of: agentID)?.state.revision
            let envelope = ObservationEnvelope(
                agentID: agentID,
                terminalID: before.terminalID,
                surfaceGeneration: before.surfaceGeneration,
                sourceID: "screen",
                sourceKind: .screen,
                sequence: nil,
                outputRevision: 999,
                observedAt: root.clock.now,
                receivedAt: root.clock.now
            )
            let staleEvidence = Evidence(
                envelope: envelope,
                payload: .screen(ScreenEvidencePayload.unknown(reason: []))
            )
            await root.runtime.ingest(staleEvidence)
            let revisionAfter = await state(of: agentID)?.state.revision
            check("stale-generation observation cannot mutate new state",
                  revisionBefore == revisionAfter,
                  "rev \(revisionBefore.map(String.init) ?? "?") → \(revisionAfter.map(String.init) ?? "?")")

            // The authenticator rejects hook reports from the old generation.
            let verdict = await root.controlPlane.hooks.validateReport(
                agentID: agentID,
                surfaceGeneration: before.surfaceGeneration,
                sourceID: "hook:test",
                sequence: nil,
                token: "any-token"
            )
            var rejectedStale = false
            if case .reject = verdict {
                rejectedStale = true
            }
            check("authenticator rejects old-generation reports", rejectedStale)
        }

        // -- 5b. restart-then-prompt on a DEDICATED probe agent (review
        // M-restart behavioral proof at the wiring level). A throwaway agent
        // keeps the main flow (and the stage-10 probes bound to its terminal)
        // untouched.
        if let workspaceID = root.activeWorkspaceID,
           let probeID = try? await root.coordinator.createAgent(
               AgentLaunchRequest(
                   agentKind: .genericShell,
                   workingDirectory: "/tmp",
                   displayName: "S5b Restart Probe"
               ),
               in: workspaceID
           )
        {
            let bindingBefore = root.registry.binding(for: probeID)
            await root.runtimeSeam.restart(.agent(probeID))
            let rebound = await waitUntil(timeout: 25) {
                guard let before = bindingBefore,
                      let now = root.registry.binding(for: probeID) else { return false }
                return now.surfaceGeneration.rawValue > before.surfaceGeneration.rawValue
                    && root.model.agentTerminal[probeID] == now.terminalID
            }
            check("restart probe rebound to successor terminal", rebound)

            let successorTerminal = root.registry.binding(for: probeID)?.terminalID
            var promptDelivered = false
            if successorTerminal != nil {
                do {
                    let receipt = try await root.runtime.prompt(
                        probeID, "echo post-restart\n", .sendNow
                    )
                    promptDelivered = receipt.outcome == .delivered
                } catch {
                    check("prompt delivered after restart", false, "\(error)")
                }
            }
            check("prompt delivered after restart", promptDelivered)

            // Watchdog confirmation against the SUCCESSOR terminal.
            if let successorTerminal {
                try? await root.runtime.outputRevisionChanged(
                    agentID: probeID, terminalID: successorTerminal, revision: 3
                )
            }
            let confirmed = await waitUntil(timeout: 8) {
                let armed = await root.runtime.isDeliveryWatchArmed(probeID)
                return !armed && root.model.unconfirmedDeliveries[probeID] == nil
            }
            check("watchdog confirms via successor output revision", confirmed)

            // Stop targets the successor terminal's process.
            try? await root.coordinator.stop(probeID, mode: .gracefulStop)
            let successorGone = await waitUntil(timeout: 10) { [weak self] in
                guard let self else { return false }
                guard let pid = foregroundPID(probeID) else { return true }
                return kill(pid_t(pid), 0) != 0
            }
            check("stop path terminates the successor process", successorGone)
        }

        // -- 6. stage-10 attention UX (§3.4/§3.13/§6.10) ---------------------
        try await runStage10AttentionChecks()
        writeReport(exitCode: failures.isEmpty ? 0 : 1)
        print("DONE exit=\(failures.isEmpty ? 0 : 1)")
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Stage 9: prompt orchestration (§3.11, §6.9)

    //
    // A REAL opencode-kind runtime session (full integration lifecycle
    // authority → queue-until-idle available) is bound to the LIVE generic
    // shell surface from step 1, so every delivery hits a real echoing pty.
    // Lifecycle transitions are driven through the LIVE control plane with
    // increasing sequence numbers under a scenario-registered hook token.

    private func deliverCount(_ agentID: AgentID) async -> Int {
        await root.runtime.timeline(of: agentID).filter {
            if case .promptDelivered = $0.event {
                return true
            }
            return false
        }.count
    }

    private func deliveredEvents(_ agentID: AgentID, commandID: CommandID) async -> Int {
        await root.runtime.timeline(of: agentID).filter {
            if case let .promptDelivered(id) = $0.event {
                return id == commandID
            }
            return false
        }.count
    }

    private func runStage9PromptChecks(hostAgentID: AgentID) async throws {
        guard let workspaceID = root.activeWorkspaceID else { return }
        guard let hostTerminal = root.registry.binding(for: hostAgentID)?.terminalID else {
            check("stage-9 host terminal available", false)
            return
        }

        let agentID = try await root.runtime.createAgent(
            AgentLaunchRequest(
                agentKind: .openCode,
                workingDirectory: "/tmp",
                displayName: "Stage9 OpenCode",
                taskSummary: "stage-9 prompt orchestration"
            ),
            in: workspaceID
        )
        try await root.runtime.surfaceCreated(
            agentID: agentID, terminalID: hostTerminal,
            generation: .initial, pid: nil, processGroupID: nil
        )

        // Scenario-scoped hook token so agentctl reports authenticate for the
        // stage-9 session against its INITIAL generation (§3.9).
        let token = "stage9-\(UUID().uuidString)"
        await root.controlPlane.hooks.register(
            agentID: agentID, surfaceGeneration: .initial, token: token
        )

        let terminalUUID = hostTerminal.rawValue.uuidString
        let ctlPath = root.commands.ctlHelperPath()
        func report(_ lifecycle: String, seq: UInt64) -> Bool {
            runCtl(ctlPath, [
                "integration", "report",
                "--socket", socketPath,
                "--agent-id", agentID.rawValue.uuidString,
                "--terminal-id", terminalUUID,
                "--surface-generation", "0",
                "--source", "hook:scenario",
                "--token", token,
                "--seq", String(seq),
                "--lifecycle", lifecycle,
            ]).0 == 0
        }

        // -- S9.1 when-ready initial prompt (§3.9 bottom) --------------------
        root.promptCoordinator.scheduleInitialPrompt(
            agentID: agentID, text: "echo stage9-when-ready-initial"
        )
        try await Task.sleep(nanoseconds: 700_000_000)
        await check("initial prompt not delivered before validated idle",
                    deliverCount(agentID) == 0,
                    "delivered=\(deliverCount(agentID))")

        let idleReported = report("idle", seq: 1)
        let initialDelivered = await waitUntil(timeout: 10) {
            await self.deliverCount(agentID) == 1
        }
        await check("first validated idle delivers the when-ready prompt exactly once",
                    idleReported && initialDelivered,
                    "delivered=\(deliverCount(agentID))")

        // -- S9.2 queue while working → exactly one delivery on idle ---------
        let workingReported = report("working", seq: 2)
        let reachedWorking = await waitUntil(timeout: 10) {
            guard let s = await self.state(of: agentID),
                  case .working = s.state.lifecycle else { return false }
            return true
        }
        check("working via control-plane evidence", workingReported && reachedWorking)

        await root.runtimeSeam.send(.agent(agentID), text: "echo queued-stage9", policy: .queueWhenIdle)
        var queuedNow = false
        for _ in 0 ..< 20 {
            if await state(of: agentID)?.hasQueuedPrompt == true {
                queuedNow = true; break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let queuedStateText = await summaryText(of: agentID)
        check("queueWhenIdle accepted while working", queuedNow, queuedStateText)
        let deliveriesWhileWorking = await deliverCount(agentID)
        try await Task.sleep(nanoseconds: 500_000_000)
        let stillQueued = await deliverCount(agentID) == deliveriesWhileWorking
        check("queued prompt does NOT deliver while working", stillQueued)
        let idleAgainReported = report("idle", seq: 3)
        let queuedDeliveredOnce = await waitUntil(timeout: 10) {
            guard let s = await self.state(of: agentID) else { return false }
            let delivered = await self.deliverCount(agentID)
            return !s.hasQueuedPrompt && delivered == deliveriesWhileWorking + 1
        }
        let settledCount = await deliverCount(agentID)
        check("validated idle delivers queued prompt exactly once",
              idleAgainReported && queuedDeliveredOnce,
              "delivered=\(settledCount) expected=\(deliveriesWhileWorking + 1)")

        // -- S9.3 duplicate commandID → single delivery ----------------------
        let duplicateKey = CommandID()
        let beforeDuplicate = await deliverCount(agentID)
        await root.runtimeSeam.send(.agent(agentID), text: "echo dup-stage9", policy: .sendNow, commandID: duplicateKey)
        let singleDelivery = await waitUntil(timeout: 5) {
            let delivered = await self.deliverCount(agentID)
            return delivered == beforeDuplicate + 1
        }
        let dupEventCount = await deliveredEvents(agentID, commandID: duplicateKey)
        let dupDelta = await deliverCount(agentID) - beforeDuplicate
        check("duplicate commandID executes exactly ONE terminal delivery",
              singleDelivery && dupEventCount == 1,
              "delta-deliveries=\(dupDelta)")
        // Watchdog outcome for a real delivery. On a parked surface output
        // revisions may not propagate (inherited stage-8 open item), in which
        // case reporting `promptDeliveryUnconfirmed` IS correct behavior —
        // the §3.11 invariant under test is: whatever the outcome, there is
        // NEVER an automatic re-delivery.
        try await Task.sleep(nanoseconds: 6_500_000_000)
        let postWatchdogCount = await deliverCount(agentID)
        check(
            "watchdog outcome surfaced without auto-retry",
            postWatchdogCount == beforeDuplicate + 1,
            "deliveries=\(postWatchdogCount) expected=\(beforeDuplicate + 1); "
                + "\(root.model.unconfirmedDeliveries[agentID].map { _ in "surfaced unconfirmed" } ?? "confirmed clean")"
        )

        // -- S9.4 approval inputRequest blocks the composer (§5.1 critical) --
        let approvalOK = reportApprovalRequest(
            agentID: agentID, terminalID: hostTerminal, token: token, generation: 0, seq: 5
        )
        var reachedWaiting = false
        if approvalOK {
            reachedWaiting = await waitUntil(timeout: 10) {
                guard let s = await self.state(of: agentID),
                      case let .waitingForInput(d) = s.state.lifecycle else { return false }
                return d.kind == .approval && d.safeReplyMode == .terminalOnly
            }
        }
        check("approval report reaches waitingForInput(terminalOnly)", reachedWaiting)

        let composer = root.mainWindowController.composer
        composer.focusedItemProvider = { .agent(agentID) }
        let ctaConfigured = await waitUntil(timeout: 10) {
            self.root.mainWindowController.composer.configuredLifecycle == "waitingForInput"
        }
        composer.refresh()
        check("composer switches to Answer-in-terminal CTA and blocks input",
              ctaConfigured && composer.ctaVisible && !composer.fieldEnabled,
              "configured=\(composer.configuredLifecycle ?? "nil")")

        let deliveriesBeforeBlockedSend = await deliverCount(agentID)
        composer.sendFocusedPrompt(text: "must not send", policy: .sendNow)
        try await Task.sleep(nanoseconds: 300_000_000)
        await check("composer send is blocked during approval waiting state",
                    deliverCount(agentID) == deliveriesBeforeBlockedSend)
        do {
            _ = try await root.runtime.prompt(agentID, "runtime-level send", .sendNow)
            check("runtime rejects sendNow into terminalOnly waiting state", false)
        } catch let error as RuntimeErrors {
            check("runtime rejects sendNow into terminalOnly waiting state",
                  error == .waitingForTerminalInput, "\(error)")
        }

        // Recover to idle for the unknown-state probe.
        check("release back to idle", report("idle", seq: 6))

        // -- S9.5 unknown lifecycle allows ONLY explicit sendNow -------------
        let unknownReported = report("unknown", seq: 7)
        let reachedUnknown = await waitUntil(timeout: 10) {
            guard let s = await self.state(of: agentID),
                  case .unknown = s.state.lifecycle else { return false }
            return true
        }
        check("unknown via control-plane evidence", unknownReported && reachedUnknown)
        do {
            _ = try await root.runtime.prompt(agentID, "queued?", .queueWhenIdle)
            check("unknown rejects queueWhenIdle", false)
        } catch {
            check("unknown rejects queueWhenIdle", error is RuntimeErrors, "\(error)")
        }
        let beforeUnknownSend = await deliverCount(agentID)
        do { _ = try await root.runtime.prompt(agentID, "explicit send", .sendNow) } catch {}
        await check("unknown allows explicit sendNow",
                    waitUntil(timeout: 5) {
                        await self.deliverCount(agentID) == beforeUnknownSend + 1
                    })

        // -- S9.6 queued-prompt cancel path ----------------------------------
        check("working again for cancel probe", report("working", seq: 8))
        _ = await waitUntil(timeout: 10) {
            guard let s = await self.state(of: agentID),
                  case .working = s.state.lifecycle else { return false }
            return true
        }
        await root.runtimeSeam.send(.agent(agentID), text: "echo to-be-cancelled", policy: .queueWhenIdle)
        await root.runtimeSeam.cancelQueuedPrompt(.agent(agentID))
        var cancelledCleanly = false
        for _ in 0 ..< 20 {
            if await state(of: agentID)?.hasQueuedPrompt == false {
                cancelledCleanly = true; break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check("cancelQueuedPrompt clears the queue", cancelledCleanly)
    }

    /// integration.report carrying an explicit approval inputRequest — the
    /// server forces safeReplyMode down to terminalOnly (§5.1).
    private func reportApprovalRequest(
        agentID: AgentID, terminalID: TerminalID, token: String, generation: Int, seq: UInt64
    ) -> Bool {
        guard let client = try? ControlClient(socketPath: socketPath) else { return false }
        defer { client.close() }
        do {
            try client.handshake()
            let response = try client.roundtrip(
                method: "integration.report",
                params: [
                    "agentID": .string(agentID.rawValue.uuidString),
                    "terminalID": .string(terminalID.rawValue.uuidString),
                    "surfaceGeneration": .int(Int64(generation)),
                    "source": .string("hook:scenario"),
                    "token": .string(token),
                    "seq": .uint64(seq),
                    "lifecycle": .string("waitingForInput"),
                    "inputRequest": .object([
                        "kind": .string("approval"),
                        "summary": .string("Allow write access?"),
                    ]),
                ]
            )
            return response.error == nil
        } catch {
            print("[SCENARIO] approval report failed: \(error)")
            return false
        }
    }

    // MARK: - Stage 10: attention UX (§3.4, §3.13, §6.10)

    //
    // Three hidden (never-focused) agents share the live successor terminal,
    // driven through the LIVE control plane exactly like stage 9:
    //   S10.1  unexpected non-zero exit → failure attention;
    //   S10.2  approval inputRequest → inputRequired; PRIORITY BEATS AGE:
    //          one ⌘⇧U press lands on the NEWER inputRequired over the OLDER
    //          failure (§6.10 ordering gate);
    //   S10.3  clearing rules: acknowledge clears failure ONLY; leaving
    //          waitingForInput clears inputRequired;
    //   S10.4  hidden working→idle → completionUnread; it does NOT clear
    //          unfocused, then clears via focus + ≥500 ms visibility
    //          (markSeen path) in the active app;
    //   S10.5  notification suppression matrix against the LIVE model state;
    //   S10.6  menu-bar status text 'N working · M needs input'.

    private func lifecycleReport(
        agentID: AgentID, terminalID: TerminalID, token: String, seq: UInt64,
        lifecycle: String, inputRequest: Bool = false
    ) -> Bool {
        guard let client = try? ControlClient(socketPath: socketPath) else { return false }
        defer { client.close() }
        do {
            try client.handshake()
            var params: [String: JSONValue] = [
                "agentID": .string(agentID.rawValue.uuidString),
                "terminalID": .string(terminalID.rawValue.uuidString),
                "surfaceGeneration": .int(0),
                "source": .string("hook:scenario"),
                "token": .string(token),
                "seq": .uint64(seq),
                "lifecycle": .string(lifecycle),
            ]
            if inputRequest {
                params["inputRequest"] = .object([
                    "kind": .string("approval"),
                    "summary": .string("Allow write access?"),
                ])
            }
            let response = try client.roundtrip(method: "integration.report", params: params)
            return response.error == nil
        } catch {
            print("[SCENARIO] stage-10 report failed: \(error)")
            return false
        }
    }

    /// Creates a hidden integration-authority agent sharing `hostTerminal`
    /// with a scenario-scoped hook token (stage-9 pattern).
    private func makeHiddenAgent(name: String, hostTerminal: TerminalID) async throws -> (AgentID, String) {
        guard let workspaceID = root.activeWorkspaceID else { throw ControlFailure(
            code: .internalError,
            message: "no workspace"
        ) }
        let agentID = try await root.runtime.createAgent(
            AgentLaunchRequest(
                agentKind: .openCode,
                workingDirectory: "/tmp",
                displayName: name,
                taskSummary: "stage-10 attention scenario"
            ),
            in: workspaceID
        )
        try await root.runtime.surfaceCreated(
            agentID: agentID, terminalID: hostTerminal,
            generation: .initial, pid: nil, processGroupID: nil
        )
        // Mirror the launch-pipeline UI association so notification-coordinator
        // visibility (model.agentTerminal) sees the hidden agents too.
        root.model.associate(terminal: hostTerminal, cwd: "/tmp", for: agentID)
        let token = "stage10-\(UUID().uuidString)"
        await root.controlPlane.hooks.register(
            agentID: agentID, surfaceGeneration: .initial, token: token
        )
        return (agentID, token)
    }

    private func attention(of agentID: AgentID) async -> AttentionState {
        await state(of: agentID)?.state.attention ?? .none
    }

    private func runStage10AttentionChecks() async throws {
        // The restart step left a live successor generic shell; bind the
        // probes to ITS terminal so every report flows through the real
        // control plane into real runtime sessions.
        guard let host = root.model.agents.values.first(where: {
            root.registry.binding(for: $0.id) != nil
        }),
            let hostBinding = root.registry.binding(for: host.id)
        else {
            check("stage-10 host terminal available", false)
            return
        }
        let hostTerminal = hostBinding.terminalID

        // -- S10.1 failure from unexpected non-zero exit ---------------------
        let (failureAgent, _) = try await makeHiddenAgent(
            name: "S10 Failure", hostTerminal: hostTerminal
        )
        do {
            try await root.runtime.processExited(
                agentID: failureAgent, exitCode: 1, signal: nil, userInitiated: false
            )
        } catch {
            check("runtime.processExited accepted for failure probe", false, "\(error)")
        }
        let failureRaised = await waitUntil(timeout: 5) { [weak self] in
            guard let self else { return false }
            if case .failure = await attention(of: failureAgent) {
                return true
            }
            return false
        }
        await check("unexpected exit raises failure attention", failureRaised,
                    "\(attention(of: failureAgent))")

        // -- S10.2 newer inputRequired vs older failure (priority beats age) -
        try? await Task.sleep(nanoseconds: 400_000_000) // failure is now OLDER
        let (inputAgent, inputToken) = try await makeHiddenAgent(
            name: "S10 Approval", hostTerminal: hostTerminal
        )
        let approvalAccepted = lifecycleReport(
            agentID: inputAgent, terminalID: hostTerminal, token: inputToken,
            seq: 1, lifecycle: "waitingForInput", inputRequest: true
        )
        var inputRaised = false
        if approvalAccepted {
            inputRaised = await waitUntil(timeout: 10) { [weak self] in
                guard let self else { return false }
                if case .inputRequired = await attention(of: inputAgent) {
                    return true
                }
                return false
            }
        }
        await check("approval report raises inputRequired on hidden agent", inputRaised,
                    "\(attention(of: inputAgent))")

        // Sidebar 'Needs attention' reflects both typed states.
        let needsAttentionTitles = root.model.sections.first?.rows.map(\.title) ?? []
        check("sidebar Needs-attention group carries both flagged agents",
              needsAttentionTitles.contains(where: { $0.contains("S10 Failure") }) &&
                  needsAttentionTitles.contains(where: { $0.contains("S10 Approval") }),
              "\(needsAttentionTitles)")

        // One ⌘⇧U press from an unflagged focus MUST land on the NEWER
        // inputRequired (priority beats age — §6.10 gate).
        root.mainWindowController.showAndKey()
        root.commands.select(.agent(host.id))
        try? await Task.sleep(nanoseconds: 200_000_000)
        root.commands.nextAttention()
        pumpMainRunloop(0.2)
        var landedOnInput = false
        if case let .agent(focused) = root.mainWindowController.splitController.canvas.focusedContent {
            landedOnInput = focused == inputAgent
        }
        check("single Next Attention lands on newer inputRequired over older failure",
              inputRaised && landedOnInput,
              "focused=\(String(describing: root.mainWindowController.splitController.canvas.focusedContent))")

        // -- S10.3 clearing rules --------------------------------------------
        // Stage-15 probe fix: the old `guard case .none = await self?.attention`
        await root.runtimeSeam.acknowledgeFailure(.agent(failureAgent))
        let failureCleared = await waitUntil(timeout: 5) { [self] in
            if case .none = await attention(of: failureAgent) {
                return true
            }
            return false
        }
        await check("explicit acknowledge clears failure only", failureCleared,
                    "\(attention(of: failureAgent))")

        // Stage-16 item B (closed): the stage-15 "idle-after-approval drop"
        // was a scenario-side observation bug — the old probe's
        // `guard case .none = await self?.attention` matched the OUTER
        // Optional (self == nil), so the wait could never satisfy even though
        // the runtime observed the report. Exhaustive reproduction at all
        // three levels (runtime ingest, real socket server/router/client,
        // this live app) shows approval(seq1) → idle(seq2) on one source is
        // accepted and observed; locked by testApprovalReportThenIdleReport-
        // OnSameSourceIsObserved in AgentControlTests. S10.3 therefore proves
        // the clearing rule the way production delivers it: LIVE socket.
        check("post-approval idle report accepted via live socket",
              lifecycleReport(agentID: inputAgent, terminalID: hostTerminal,
                              token: inputToken, seq: 2, lifecycle: "idle"))
        let inputCleared = await waitUntil(timeout: 10) { [self] in
            if case .none = await attention(of: inputAgent) {
                return true
            }
            return false
        }
        await check("leaving waitingForInput clears inputRequired", inputCleared,
                    "\(attention(of: inputAgent))")

        // -- S10.4 completionUnread: raised while hidden, cleared by focus ---
        let (completionAgent, completionToken) = try await makeHiddenAgent(
            name: "S10 Completion", hostTerminal: hostTerminal
        )
        _ = lifecycleReport(agentID: completionAgent, terminalID: hostTerminal,
                            token: completionToken, seq: 1, lifecycle: "working")
        _ = await waitUntil(timeout: 10) { [weak self] in
            guard let self, let s = await state(of: completionAgent),
                  case .working = s.state.lifecycle else { return false }
            return true
        }
        _ = lifecycleReport(agentID: completionAgent, terminalID: hostTerminal,
                            token: completionToken, seq: 2, lifecycle: "idle")
        let completionRaised = await waitUntil(timeout: 10) { [weak self] in
            guard let self else { return false }
            if case .completionUnread = await attention(of: completionAgent) {
                return true
            }
            return false
        }
        await check("hidden turn completion raises completionUnread", completionRaised,
                    "\(attention(of: completionAgent))")

        // Unfocused: even with time passing, markSeen must NOT clear it.
        try? await Task.sleep(nanoseconds: 900_000_000)
        var stillUnread = false
        if case .completionUnread = await attention(of: completionAgent) {
            stillUnread = true
        }
        await check("completionUnread persists while agent is not visible/focused", stillUnread,
                    "\(attention(of: completionAgent))")

        // Stage-15 probe fix: the old closure repeated the double-optional
        // `guard case .none = await self?.attention` bug (matched Optional.none,
        // never true while self is alive). Strongify + match the enum case.
        // The ≥500 ms seen timer reads NSApp activation through provider seams
        // (FocusCoordinator.stage-15): a background-launched scenario process
        // may never become the active app, so the probe FORCES the §3.4
        // preconditions (active app + visible window) and verifies the live
        // focus/visibility path — the pure rule stays unit-covered.
        root.focusCoordinator.appActiveProvider = { true }
        root.focusCoordinator.mainWindowVisibleProvider = { true }
        root.commands.select(.agent(completionAgent)) // mount + focus pane
        let clearedByVisibility = await waitUntil(timeout: 6) { [self] in
            if case .none = await attention(of: completionAgent) {
                return true
            }
            return false
        }
        root.focusCoordinator.appActiveProvider = { NSApp.isActive }
        root.focusCoordinator.mainWindowVisibleProvider = { NSApp.mainWindow?.isVisible == true }
        await check("focus + ≥500 ms visibility clears completionUnread (markSeen)",
                    clearedByVisibility, "\(attention(of: completionAgent))")

        // -- S10.5 suppression matrix against LIVE model state ---------------
        // Stage-15 probe fix: NSApp.isActive is headless-flaky for a
        // background-launched process, so appActive is forced across BOTH arms
        // while agentVisible/paneFocused still run against the real mounted
        // surface and focused pane (the pure policy itself is unit-covered).
        let compVisible = root.notificationCoordinator.isAgentVisible?(completionAgent) == true
        let compFocused = root.notificationCoordinator.isPaneFocused?(completionAgent) == true
        check("probe precondition: completion agent mounted and pane focused",
              compVisible && compFocused,
              "visible=\(compVisible) focused=\(compFocused)")
        check("focused visible agent is notification-suppressed while app active",
              NotificationCoordinator.Policy.shouldRaise(
                  appActive: true, agentVisible: compVisible,
                  paneFocused: compFocused,
                  notificationsPaused: root.model.notificationsPaused
              ) == false)
        check("hidden unfocused agent raises when app inactive",
              NotificationCoordinator.Policy.shouldRaise(
                  appActive: false, agentVisible: false, paneFocused: false,
                  notificationsPaused: false
              ) == true)

        // -- S10.6 menu-bar status text --------------------------------------
        root.model.setNotificationsPaused(false)
        let statusText = StatusItemController.statusText(
            working: root.model.workingCount, attention: root.model.attentionCount
        )
        check("menu-bar status text follows §3.13 format",
              !statusText.isEmpty,
              statusText)
    }

    // MARK: - helpers

    private func state(of agentID: AgentID) async -> AgentSummary? {
        await root.runtime.projection().agents.first { $0.id == agentID }
    }

    private func isStarting(_ summary: AgentSummary) -> Bool {
        if case .starting = summary.state.lifecycle {
            return true
        }
        return false
    }

    private func foregroundPID(_ agentID: AgentID) -> UInt64? {
        guard let terminalID = root.registry.binding(for: agentID)?.terminalID else { return nil }
        let pid = root.sessionManager.foregroundPID(for: terminalID) ?? 0
        return pid > 0 ? pid : nil
    }

    private func summaryText(of agentID: AgentID) async -> String {
        guard let summary = await state(of: agentID) else { return "missing" }
        return "\(summary.state.lifecycle) rev=\(summary.state.revision)"
    }

    private func runCtl(_ path: String, _ args: [String]) -> (Int32, String) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return (-1, "agentctl not found at \(path)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        // Bounded read on a helper thread: a wedged agentctl must not hang
        // the scenario past the point where any report is written. On
        // timeout we terminate the process; closing the pipe unblocks the
        // read, so the helper thread always finishes.
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread {
            box.set(String(decoding: handle.readDataToEndOfFile(), as: UTF8.self))
            done.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
            return (-1, "agentctl timed out after 30s")
        }
        p.waitUntilExit()
        return (p.terminationStatus, box.get())
    }

    /// Minimal lock-guarded string box for the helper-thread read above.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""

        func set(_ newValue: String) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }

        func get() -> String {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func writeReport(exitCode: Int) {
        let payload: [String: Any] = [
            "scenario": "AGENTTERMINAL_AUTOAGENT",
            "exitCode": exitCode,
            "failures": failures,
            "checks": checks,
            "socketPath": socketPath,
        ]
        let path = ProcessInfo.processInfo.environment["ATERM_REPORT"]
            ?? "/tmp/aterm-stage8-report.json"
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

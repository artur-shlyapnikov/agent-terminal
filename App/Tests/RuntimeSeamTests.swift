import AgentControl
import AgentCore
import AgentStore
@testable import AgentTerminal
import AppKit
@testable import TerminalKit
import XCTest

// Round 8 Suite C (R8-5, R8-6): RuntimeSeam laws over real child processes.
//
// R8-5 pins §3.11's shell stop ladder (SIGTERM → 2 s grace → SIGKILL against
// the foreground child's PROCESS GROUP) through a TERM-immune child: an
// interactive `/bin/sh` ignores bare SIGTERM, so a dead child after
// `stop(.shell)` proves the KILL leg fired. Foundation Process children get
// their own process group, so the pgid routing in
// TerminalSessionManager.sendSignal is genuinely exercised.
//
// R8-6 pins the swallowed-error law: every failed action funnels into
// DiagnosticsLogRing instead of throwing into UI call sites.

@MainActor
private final class HarnessSurface: NativeTerminalSurface {
    var screenText: String?
    var viewportText: String?
    var processExitedFlag = false
    /// Injection point for the foreground-child pid the signal ladder reads.
    var foregroundPIDValue: UInt64 = 0

    func setFocus(_: Bool) {}
    func setOccluded(_: Bool) {}
    func resize(widthPixels _: UInt32, heightPixels _: UInt32, scaleFactor _: Double) {}
    func sendText(_: String) {}
    func sendKey(_: GhosttyKeyEvent) -> Bool {
        true
    }

    func sendPreedit(_: String?) {}
    func mouseButton(state _: MouseButtonState, button _: MouseButton, modifiers _: KeyModifiers) -> Bool {
        true
    }

    func mousePosition(x _: Double, y _: Double, modifiers _: KeyModifiers) {}
    func mouseScroll(dx _: Double, dy _: Double, packedModifiers _: Int32) {}
    func isProcessExited() -> Bool {
        processExitedFlag
    }

    func foregroundPID() -> UInt64 {
        foregroundPIDValue
    }

    func gridSize() -> (columns: UInt32, rows: UInt32)? {
        nil
    }

    func readScreen() -> String? {
        screenText
    }

    func readViewport() -> String? {
        viewportText
    }

    func performFree() {}
}

@MainActor
private final class HarnessEngine: TerminalEngine {
    var eventSink: (@MainActor (GhosttyEvent) -> Void)?
    private(set) var surfaces: [HarnessSurface] = []

    func createSurface(
        view _: NSView,
        spec _: TerminalLaunchSpec,
        box _: SurfaceCallbackBox
    ) throws -> any NativeTerminalSurface {
        let surface = HarnessSurface()
        surfaces.append(surface)
        return surface
    }

    func tick() {}
    func shutdown() {}
}

@MainActor
private final class HarnessParkingHost: TerminalParkingHosting {
    let parkingContentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

    func park(_ view: NSView) {
        view.removeFromSuperview()
        parkingContentView.addSubview(view)
    }
}

@MainActor
final class RuntimeSeamTests: XCTestCase {
    private struct Wired {
        let seam: RuntimeSeam
        let runtime: AgentRuntime
        let manager: TerminalSessionManager
        let engine: HarnessEngine
    }

    private func makeWired() -> Wired {
        let runtime = AgentRuntime(clock: FakeClock())
        let engine = HarnessEngine()
        let manager = TerminalSessionManager(
            engine: engine,
            parkingHost: HarnessParkingHost(),
            ticketWriter: nil,
            inputBracketedPaste: false
        )
        let seam = RuntimeSeam(runtime: runtime, sessionManager: manager, model: AppModel())
        return Wired(seam: seam, runtime: runtime, manager: manager, engine: engine)
    }

    // MARK: C1 / R8-5 — shell stop ladder kills a TERM-immune foreground child

    func testStoppingAShellRunsTheTerminateThenKillLadderAgainstTheForegroundChild() async throws {
        let wired = makeWired()

        let session = try wired.manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )

        // A REAL child whose whole PROCESS GROUP ignores SIGTERM
        // (`trap "" TERM`; the backgrounded sleep INHERITS the ignored
        // disposition — a foreground `sleep 30` would instead die from the
        // terminate leg, ending the script before the kill leg). Surviving
        // the terminate leg and dying anyway proves the SIGKILL leg fired
        // against the group.
        let readyMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-trap-ready-\(UUID().uuidString)")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", """
        trap "" TERM
        : > '\(readyMarker.path)'
        sleep 30 & wait
        """]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
            }
            try? FileManager.default.removeItem(at: readyMarker)
        }

        // Event-driven readiness: never signal before the child has
        // INSTALLED its TERM trap, or the ladder would win a startup race
        // instead of exercising the kill leg.
        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: readyMarker.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: readyMarker.path),
            "TERM-immune child never installed its trap"
        )

        let surface = try XCTUnwrap(wired.engine.surfaces.first)
        surface.foregroundPIDValue = UInt64(child.processIdentifier)

        let beforeLines = Set(DiagnosticsLogRing.shared.lines)
        await wired.seam.stop(.shell(session.id))

        // SIGKILL delivery is near-instant but asynchronous to Foundation's
        // exit observation — short bounded wait.
        let deadline = Date().addingTimeInterval(2)
        while child.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(
            child.isRunning,
            "TERM-immune child outlived the stop ladder — the SIGKILL leg never reached its process group"
        )

        // The ladder completed cleanly: it recorded nothing at all. The
        // ring is a 500-cap FIFO, so a count-delta is vacuous once the
        // suite has filled it — use the full-content set-diff from C2
        // (see C2 for the ring law itself).
        let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertTrue(added.isEmpty, "stop ladder recorded unexpected diagnostics: \(added)")
    }

    // MARK: C2 / R8-6 — failed actions land in the diagnostics ring, never throw

    func testFailedActionsAreSwallowedIntoTheDiagnosticsRingInsteadOfThrowing() async throws {
        let wired = makeWired() // empty manager, runtime without any agents
        // Full-content snapshot, not an index: the ring is a 500-cap FIFO,
        // so once a full suite fills it the count never grows and index
        // slices silently miss every record. Timestamps make lines unique,
        // so a set-diff yields exactly this test's records.
        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        // None of these may throw into the caller; every failure must be
        // recorded instead. The agent stop goes through a WIRED coordinator
        // (the lifecycle owner); interrupt/visibility stay seam-level.
        let pipeline = makeDetectionPipeline(wired)
        wireCoordinator(wired, pipeline: pipeline)
        defer { pipeline.stop() }
        try? await wired.seam.coordinator?.stop(AgentID(), mode: .gracefulStop)
        await wired.seam.interrupt(.shell(TerminalID()))
        await wired.seam.restart(.shell(TerminalID())) // shells have no restart semantics (no-op guard)
        await wired.seam.resume(.agent(AgentID()))
        wired.seam.setVisible(.agent(AgentID()), false) // fire-and-forget Task internally

        // Bounded wait so all three records land — including the detached
        // visibility Task's — so nothing leaks into later tests' ring diffs.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
            if added.contains(where: { $0.contains("stop failed for") }),
               added.contains(where: { $0.contains("shell interrupt failed") }),
               added.contains(where: { $0.contains("set visibility failed") })
            {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertGreaterThanOrEqual(added.count, 2, "expected at least the stop and interrupt failures: \(added)")
        XCTAssertTrue(added.contains(where: { $0.contains("stop failed for") }), "ring: \(added)")
        XCTAssertTrue(added.contains(where: { $0.contains("shell interrupt failed") }), "ring: \(added)")
        // The bounded loop must have observed the detached visibility
        // Task's record — expiry without the record is a quiesce failure,
        // not a pass.
        XCTAssertTrue(
            added.contains(where: { $0.contains("set visibility failed") }),
            "visibility failure never landed in the ring within the budget: \(added)"
        )

        // Every recorded line already passed through DiagnosticRedactor at
        // record time (sanitize is idempotent on its own output).
        for line in added {
            XCTAssertEqual(DiagnosticRedactor.sanitize(line), line, "unsanitized line: \(line)")
        }
    }

    // MARK: Round 15 A1 — nil coordinator seam: restart is a silent no-op

    func testRestartUnderNilCoordinatorIsASilentNoOp() async throws {
        let wired = makeWired() // coordinator stays nil — the harness never assigns it
        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "nil-seam-restart"),
            in: ws
        )
        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        // KNOWN agent: the optional-chained `coordinator?.restartAgent(id)`
        // evaluates to Optional<Void>.none without throwing. The restart must
        // stay SILENT (no ring record) and NON-MUTATING (no fallback to bare
        // runtime.restart; the session is untouched).
        await wired.seam.restart(.agent(id))
        let addedForKnown = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertTrue(addedForKnown.isEmpty, "nil-seam restart must not record anything, ring gained: \(addedForKnown)")
        let stateAfterKnown = try await wired.runtime.state(of: id)
        XCTAssertEqual(stateAfterKnown.lifecycle, .starting, "restart must not mutate the session under the nil seam")
        XCTAssertEqual(
            stateAfterKnown.revision,
            1,
            "createAgent mints revision 1 and the nil-seam restart must not mint another"
        )

        // UNKNOWN agent: still silent. With a WIRED pipeline the same call
        // throws agentNotFound and records "restart failed for …" — the nil
        // seam must manufacture neither that error nor an unwrap crash.
        await wired.seam.restart(.agent(AgentID()))
        let addedForUnknown = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertTrue(
            addedForUnknown.isEmpty,
            "nil-seam restart on an unknown agent must not record anything, ring gained: \(addedForUnknown)"
        )
    }

    // MARK: Round 15 A2 — nil coordinator seam: stop is a silent no-op

    /// The lifecycle saga lives in the coordinator; a harness seam without
    /// one must neither mutate state nor emit diagnostics.
    func testStopUnderNilCoordinatorIsASilentNoOp() async throws {
        let wired = makeWired()
        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "nil-seam-stop"),
            in: ws
        )
        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        await wired.seam.stop(.agent(id))

        let state = try await wired.runtime.state(of: id)
        XCTAssertEqual(state.lifecycle, .starting, "no lifecycle mutation without a coordinator")
        let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertTrue(added.isEmpty, "silent no-op must not log, got: \(added)")
    }

    // MARK: Round 17 D1/D2 — failed-stop compensation through the owned pipeline

    /// Shared arrange: an inert pipeline (start() never called — construction
    /// arms no tasks) owned by a REAL coordinator wired into the seam. The
    /// old weak-global registry slot is gone; ownership is explicit now.
    private func makeDetectionPipeline(_ wired: Wired) -> DetectionPipeline {
        DetectionPipeline(
            clock: FakeClock(),
            registry: AgentTerminalRegistry(),
            sessionManager: wired.manager,
            runtime: wired.runtime
        )
    }

    /// Attaches a REAL coordinator (owning `pipeline`) to the seam.
    private func wireCoordinator(_ wired: Wired, pipeline: DetectionPipeline) {
        let coordinator = AgentExecutionCoordinator(
            runtime: wired.runtime,
            clock: FakeClock(),
            sessionManager: wired.manager,
            registry: AgentTerminalRegistry(),
            model: AppModel(),
            hooks: HookAuthenticator(),
            agentRepository: nil,
            launcherExecutable: URL(fileURLWithPath: "/bin/true"),
            controlSocketPath: "/tmp/aterm-test.sock",
            detectionPipeline: pipeline
        )
        wired.seam.coordinator = coordinator
    }

    /// D1: a failed runtime stop on a STILL-ALIVE agent (lifecycle not
    /// terminal) must clear the stop ladder's screen-detection suspension AND
    /// record the re-enable — the live-agent leg is observably different from
    /// the plain-failure leg.
    func testFailedStopOnLiveAgentUnsuspendsScreenDetectionThroughTheCoordinator() async throws {
        let wired = makeWired()
        let pipeline = makeDetectionPipeline(wired)
        wireCoordinator(wired, pipeline: pipeline)
        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "stop-unsuspend"),
            in: ws
        )
        defer { pipeline.stop() }

        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        // The semantic stop marks user intent (suspending detection), then
        // runtime.stop fails deterministically here (no bound terminal port);
        // .stopping is not terminal, so the compensation leg must unsuspend
        // and record "…; screen detection re-enabled".
        try? await wired.seam.coordinator?.stop(id, mode: .gracefulStop)

        XCTAssertFalse(pipeline.suspended.contains(id), "suspension must be lifted for a live agent")

        let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertEqual(added.count, 1, "expected exactly one ring record, got: \(added)")
        XCTAssertTrue(
            added.first?.contains("screen detection re-enabled") == true,
            "live-agent leg must record the re-enable: \(added)"
        )
    }

    /// D2: when the agent is GONE (agentNotFound), the catch records the
    /// PLAIN failure line and performs NO registry mutation — unrelated
    /// suspensions are dead state belonging to no successor; the seam must
    /// not reach into the shared pipeline for them.
    func testFailedStopOnVanishedAgentLeavesSuspensionsUntouched() async {
        let wired = makeWired()
        let pipeline = makeDetectionPipeline(wired)
        wireCoordinator(wired, pipeline: pipeline)
        defer { pipeline.stop() }

        // Bystander sentinel: an UNRELATED agent's suspension must survive.
        let bystander = AgentID()
        pipeline.suspend(agentID: bystander)
        XCTAssertTrue(pipeline.suspended.contains(bystander))

        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        // Never-created agent: runtime.state throws agentNotFound → plain
        // record only.
        try? await wired.seam.coordinator?.stop(AgentID(), mode: .gracefulStop)

        XCTAssertTrue(
            pipeline.suspended.contains(bystander),
            "a vanished agent's failure must not mutate unrelated suspensions"
        )

        let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertTrue(added.contains(where: { $0.contains("stop failed for") }), "ring: \(added)")
        XCTAssertFalse(
            added.contains { $0.contains("screen detection re-enabled") },
            "gone-agent leg must not resurrect suspension state: \(added)"
        )
    }

    // MARK: Round 18 F1 — adopted-failure edge guard (fd3a135)

    /// Screen evidence carrying an unchanged `.failed` lifecycle; only the
    /// envelope instants advance between ingests (sequence stays nil so the
    /// integration-ledger duplicate rule is not exercised).
    private func failureEvidence(_ agentID: AgentID, _ n: UInt64) -> Evidence {
        Evidence(
            envelope: ObservationEnvelope(
                agentID: agentID,
                terminalID: nil,
                surfaceGeneration: .initial,
                sourceID: "screen",
                sourceKind: .screen,
                observedAt: MonotonicInstant(nanosecondsSinceEpoch: Int64(n)),
                receivedAt: MonotonicInstant(nanosecondsSinceEpoch: Int64(n))
            ),
            payload: .screen(ScreenEvidencePayload(
                matchedRuleID: "r",
                resultingLifecycle: .failed(FailureDescriptor(reason: "boom")),
                supportingRules: ["r"],
                conflictingRules: []
            ))
        )
    }

    /// `applyAdopted` appends `.attentionRaised(kind: .failure)` ONLY on the
    /// transition INTO `.failure`; repeated ingestion of the same failure
    /// evidence must be a full no-op plan — no duplicate attention events and
    /// no revision churn.
    func testRepeatedAdoptionOfUnchangedFailureRaisesFailureAttentionExactlyOnce() async throws {
        let wired = makeWired()
        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "adopt-failure"),
            in: ws
        )

        await wired.runtime.ingest(failureEvidence(id, 1))
        let revisionAfterFirst = try await wired.runtime.state(of: id).revision

        // Second ingest of the SAME failure with an advanced receivedAt.
        await wired.runtime.ingest(failureEvidence(id, 2))

        // 1. Exactly ONE failure attentionRaised — the first transition only.
        let timeline = await wired.runtime.timeline(of: id)
        let failureRaisals = timeline.filter { $0.event == .attentionRaised(kind: .failure) }
        XCTAssertEqual(failureRaisals.count, 1, "timeline events: \(timeline.map(\.event))")

        // 2. Same-lifecycle adoption must not churn the revision.
        let stateAfterRepeat = try await wired.runtime.state(of: id)
        XCTAssertEqual(
            stateAfterRepeat.revision, revisionAfterFirst,
            "repeated unchanged-failure adoption must not mint a revision"
        )

        // 3. The failed lifecycle carries its descriptor through.
        guard case let .failed(descriptor) = stateAfterRepeat.lifecycle else {
            return XCTFail("expected .failed, got \(stateAfterRepeat.lifecycle)")
        }
        XCTAssertEqual(descriptor.reason, "boom")
    }

    // MARK: Round 19 F1/F2 — focus mailbox deselection drain (10fb072)

    /// Screen evidence carrying `.working`: the lifecycle edge opens a turn,
    /// so the later clean non-user-initiated exit closes it and the §3.5
    /// completion rule decides completionUnread from VISIBILITY at exit
    /// time — the indirect, fully-public probe for `runtime.focus` landing.
    private func workEvidence(_ agentID: AgentID, _ n: UInt64) -> Evidence {
        Evidence(
            envelope: ObservationEnvelope(
                agentID: agentID,
                terminalID: nil,
                surfaceGeneration: .initial,
                sourceID: "screen",
                sourceKind: .screen,
                observedAt: MonotonicInstant(nanosecondsSinceEpoch: Int64(n)),
                receivedAt: MonotonicInstant(nanosecondsSinceEpoch: Int64(n))
            ),
            payload: .screen(ScreenEvidencePayload(
                matchedRuleID: "r",
                resultingLifecycle: .working,
                supportingRules: ["r"],
                conflictingRules: []
            ))
        )
    }

    /// Lets MainActor-queued tasks (the focus drain, visibility Tasks) run
    /// to completion: bounded yields with tiny real sleeps, no fixed settle.
    private func quiesceMainActor(rounds: Int = 40) async {
        for _ in 0 ..< rounds {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// F1: `setFocused(A)` followed SYNCHRONOUSLY by `setFocused(nil)` must
    /// drain the coalescing mailbox — the lazily-started drain task cannot
    /// run between the two MainActor calls, so `pendingFocusItem = nil`
    /// (:72-74) provably executes before the drain ever reads it. Removing
    /// that arm leaves A queued, the drain delivers it, and the probe below
    /// flips (no completionUnread).
    func testDeselectionDrainsMailboxSoQueuedFocusNeverLands() async throws {
        let wired = makeWired()
        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "drain-deselect"),
            in: ws
        )
        // Open a turn so the clean exit closes one: completionUnread is
        // raised ONLY when the agent was NOT visible/active at exit time.
        await wired.runtime.ingest(workEvidence(id, 1))
        let coordinator = FocusCoordinator(seam: wired.seam, model: AppModel())

        coordinator.setFocused(item: .agent(id))
        coordinator.setFocused(item: nil) // NO awaits between the two calls

        await quiesceMainActor()

        try await wired.runtime.processExited(agentID: id, exitCode: 0, signal: nil, userInitiated: false)
        let state = try await wired.runtime.state(of: id)
        XCTAssertEqual(state.lifecycle, .stopped(.completed))
        guard case .completionUnread = state.attention else {
            return XCTFail("queued focus leaked past deselection; attention is \(state.attention)")
        }
    }

    /// F2 (positive control): without the deselection, the drain delivers
    /// the queued focus and `visibleAgents` contains the agent — the clean
    /// exit then does NOT raise completionUnread. Guards F1 against passing
    /// vacuously.
    func testFocusWithoutDeselectionStillDeliversThroughDrain() async throws {
        let wired = makeWired()
        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "drain-deliver"),
            in: ws
        )
        await wired.runtime.ingest(workEvidence(id, 1))
        let coordinator = FocusCoordinator(seam: wired.seam, model: AppModel())

        coordinator.setFocused(item: .agent(id))
        await quiesceMainActor()

        try await wired.runtime.processExited(agentID: id, exitCode: 0, signal: nil, userInitiated: false)
        let state = try await wired.runtime.state(of: id)
        XCTAssertEqual(state.lifecycle, .stopped(.completed))
        XCTAssertEqual(state.attention, .none, "the delivered focus must suppress completionUnread")
    }

    // MARK: Round 24 FC-A — same-item refocus preserves the visibility clock

    func testSameItemRefocusPreservesFocusedSinceAndDeselectionClearsIt() {
        let wired = makeWired()
        let coordinator = FocusCoordinator(seam: wired.seam, model: AppModel())
        let shell = SidebarItem.shell(TerminalID())

        coordinator.setFocused(item: shell)
        let t0 = coordinator.focusedSince
        XCTAssertNotNil(t0)

        coordinator.setFocused(item: shell) // NO awaits between the two calls

        XCTAssertEqual(
            coordinator.focusedSince, t0,
            "same-item refocus is an early-return no-op: resetting the clock would starve tickVisibility forever"
        )
        XCTAssertEqual(coordinator.focusedItem, shell)

        coordinator.setFocused(item: nil)
        XCTAssertNil(coordinator.focusedSince)
        XCTAssertNil(coordinator.focusedItem)
    }

    // MARK: Round 24 FC-B1/B2 — tickVisibility end-to-end gating

    /// Shared arrange for the tickVisibility pair: a stopped agent already
    /// carrying `.completionUnread` (raised by its clean exit while invisible).
    private func makeUnreadStoppedAgent(_ wired: Wired, displayName: String) async throws -> AgentID {
        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: displayName),
            in: ws
        )
        // Open a turn so the later clean non-user-initiated exit closes one.
        await wired.runtime.ingest(workEvidence(id, 1))
        try await wired.runtime.processExited(agentID: id, exitCode: 0, signal: nil, userInitiated: false)
        guard case .completionUnread = try await wired.runtime.state(of: id).attention else {
            throw XCTSkip("fixture precondition failed: expected completionUnread")
        }
        return id
    }

    /// FC-B1: both negative legs of the §3.4 gate leave completionUnread
    /// intact — app-inactive far past the span, and both-true sub-span. A
    /// refactor bypassing VisibilityPolicy (mark seen on every fire) flips
    /// either probe.
    func testTickVisibilityNegativeLegsLeaveCompletionUnreadIntact() async throws {
        let wired = makeWired()
        let id = try await makeUnreadStoppedAgent(wired, displayName: "tick-negative")
        let coordinator = FocusCoordinator(seam: wired.seam, model: AppModel())

        // Leg 1: far past the required span, but the app is inactive.
        coordinator.appActiveProvider = { false }
        coordinator.mainWindowVisibleProvider = { true }
        coordinator.setFocused(item: .agent(id))
        await quiesceMainActor()
        try coordinator.tickVisibility(now: XCTUnwrap(coordinator.focusedSince?.addingTimeInterval(10)))
        await quiesceMainActor()
        guard case .completionUnread = try await wired.runtime.state(of: id).attention else {
            return try await XCTFail(
                "inactive app must never reach markSeen; attention is \(wired.runtime.state(of: id).attention)"
            )
        }

        // Leg 2: providers both true, but now sub-span (continuous clock).
        // The inactive tick above RESET the span (§3.4 continuity law), so
        // first re-arm it with an active tick — that tick cannot count —
        // then probe a sub-span follow-up.
        coordinator.appActiveProvider = { true }
        coordinator.mainWindowVisibleProvider = { true }
        coordinator.tickVisibility(now: Date())
        await quiesceMainActor()
        try coordinator.tickVisibility(now: XCTUnwrap(coordinator.focusedSince?.addingTimeInterval(0.1)))
        await quiesceMainActor()
        guard case .completionUnread = try await wired.runtime.state(of: id).attention else {
            return try await XCTFail(
                "sub-span tick must never reach markSeen; attention is \(wired.runtime.state(of: id).attention)"
            )
        }
    }

    /// FC-B2 (positive control): exact 0.5 s boundary with both providers
    /// true dispatches markSeen → completionUnread clears to `.none`. Guards
    /// FC-B1 against passing vacuously.
    func testTickVisibilityAtExactBoundaryClearsCompletionUnread() async throws {
        let wired = makeWired()
        let id = try await makeUnreadStoppedAgent(wired, displayName: "tick-boundary")
        let coordinator = FocusCoordinator(seam: wired.seam, model: AppModel())

        coordinator.appActiveProvider = { true }
        coordinator.mainWindowVisibleProvider = { true }
        coordinator.setFocused(item: .agent(id))
        try coordinator.tickVisibility(now: XCTUnwrap(coordinator.focusedSince?.addingTimeInterval(0.5)))
        await quiesceMainActor()

        let state = try await wired.runtime.state(of: id)
        XCTAssertEqual(state.attention, .none, "markSeen must clear completionUnread at the inclusive boundary")
    }

    // MARK: Round 24 FC-C — synchronous A→B supersedes in the coalescing mailbox

    func testSynchronousRefocusSupersedesQueuedFocusDelivery() async throws {
        let wired = makeWired()
        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let a = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "supersede-a"),
            in: ws
        )
        let b = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "supersede-b"),
            in: ws
        )
        await wired.runtime.ingest(workEvidence(a, 1))
        await wired.runtime.ingest(workEvidence(b, 2))
        let coordinator = FocusCoordinator(seam: wired.seam, model: AppModel())

        coordinator.setFocused(item: .agent(a))
        coordinator.setFocused(item: .agent(b)) // NO awaits between the two calls

        await quiesceMainActor()

        XCTAssertEqual(coordinator.focusedItem, .agent(b))
        XCTAssertNotNil(coordinator.focusedSince)

        // A's clean exit raises completionUnread — proof focus(a) never landed
        // (a visible agent's clean exit suppresses it, per the F2 mechanism).
        try await wired.runtime.processExited(agentID: a, exitCode: 0, signal: nil, userInitiated: false)
        guard case .completionUnread = try await wired.runtime.state(of: a).attention else {
            return try await XCTFail(
                "superseded focus(a) leaked into visibleAgents; attention is \(wired.runtime.state(of: a).attention)"
            )
        }

        // Positive control: B's delivered focus suppresses completionUnread.
        try await wired.runtime.processExited(agentID: b, exitCode: 0, signal: nil, userInitiated: false)
        let bState = try await wired.runtime.state(of: b)
        XCTAssertEqual(bState.lifecycle, .stopped(.completed))
        XCTAssertEqual(bState.attention, .none, "the delivered focus(b) must suppress completionUnread")
    }

    // MARK: R27-RS1 — clearVisibilityState cancels a removed agent's pending delivery

    /// A removed agent's visibility bookkeeping dies WITH its in-flight
    /// task: clearVisibilityState cancels the detached delivery so a
    /// never-registered agent cannot land a late "set visibility failed"
    /// record. Both calls share one MainActor turn — the MainActor-inherited
    /// task cannot start until the test's next suspension, so the in-body
    /// isCancelled guard sees the cancel deterministically (F1's mailbox
    /// discipline). Positive control proves the record path itself is live.
    func testClearingVisibilityStateCancelsPendingDeliverySoNoLateFailureIsRecorded() async throws {
        let wired = makeWired()
        let ghost = AgentID() // never registered → delivery throws agentNotFound
        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        // One MainActor turn: arm the detached delivery, then drop the
        // agent's bookkeeping (what the composition root does on remove),
        // then prove a second clear on the emptied entry is a tolerated no-op.
        wired.seam.setVisible(.agent(ghost), true)
        wired.seam.clearVisibilityState(for: .agent(ghost))
        wired.seam.clearVisibilityState(for: .agent(ghost))

        // Budget ≥ the one C2 needs for such a record to land.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
            if added.contains(where: { $0.contains("set visibility failed for \(ghost.rawValue.uuidString)") }) {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertFalse(
            added.contains(where: { $0.contains("set visibility failed for \(ghost.rawValue.uuidString)") }),
            "a cancelled visibility delivery must not record: \(added)"
        )
    }

    /// Positive control (guards vacuous pass): identical arrange WITHOUT the
    /// clear calls — the failure record MUST land within the same budget
    /// (expiry without the record is a quiesce failure, per C2's discipline).
    func testUnclearedVisibilityTaskStillRecordsItsFailure() async throws {
        let wired = makeWired()
        let ghost = AgentID()
        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        wired.seam.setVisible(.agent(ghost), true)

        let deadline = Date().addingTimeInterval(2)
        var landed = false
        while Date() < deadline {
            let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
            if added.contains(where: { $0.contains("set visibility failed for \(ghost.rawValue.uuidString)") }) {
                landed = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(landed, "an uncancelled delivery must record its failure within the budget")
    }

    // MARK: R28-S4 — deliverPrompt survives concurrent evidence ingestion

    /// Regression: writing a PRE-await session copy back after
    /// `port.deliverInput` would clobber mutations the actor applied while
    /// delivery was suspended. The gated port holds the delivery in-flight
    /// (actor released) while an evidence ingest mutates the same agent's
    /// state; the post-delivery state must retain the ingested mutation.
    func testDeliverPromptSurvivesConcurrentEvidenceIngestion() async throws {
        let wired = makeWired()
        let port = GatedTerminalPort()
        await wired.runtime.setTerminalPort(port)

        let ws = await wired.runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await wired.runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "gated-delivery"),
            in: ws
        )
        try await wired.runtime.surfaceCreated(
            agentID: id,
            terminalID: TerminalID(),
            generation: .initial,
            pid: 1000,
            processGroupID: 1000
        )
        let revisionBeforePrompt = try await wired.runtime.state(of: id).revision

        // Act: start the prompt; it parks INSIDE the port's deliverInput gate
        // (delivery in flight, runtime actor suspended-free). Event-driven:
        // the gate entry flag is set synchronously before parking.
        let promptTask = Task { try await wired.runtime.prompt(id, "hello", .sendNow) }
        let gateDeadline = Date().addingTimeInterval(2)
        while !port.deliveryEntered, Date() < gateDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(port.deliveryEntered, "the prompt never reached the terminal port")

        // Concurrent mutation while delivery is provably parked.
        await wired.runtime.ingest(workEvidence(id, 1)) // screen evidence → lifecycle .working
        port.openGate()

        let receipt = try await promptTask.value
        XCTAssertEqual(receipt.outcome, .delivered)

        // The ingested mutation SURVIVED the delivery write-back: lifecycle
        // adopted from the concurrent evidence is still present, and the
        // revision advanced past the pre-prompt value.
        let state = try await wired.runtime.state(of: id)
        XCTAssertEqual(state.lifecycle, .working,
                       "a pre-await session copy was written back over the concurrent ingest")
        XCTAssertGreaterThan(state.revision, revisionBeforePrompt)
    }
}

// MARK: - Round 28 file-local fixture

/// TerminalControlling double whose `deliverInput` parks on a gate before
/// returning, holding the caller's actor suspension mid-delivery so the test
/// can interleave concurrent runtime work. (File-local because the shared
/// FakeTerminalPort lives inside the AgentCoreTests SwiftPM target and cannot
/// be subclassed here.)
private final class GatedTerminalPort: TerminalControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private(set) var deliveryEntered = false

    /// Releases a parked (or future) deliverInput call.
    func openGate() {
        lock.lock()
        let continuation = gateContinuation
        gateContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func deliverInput(_ terminalID: TerminalID, text _: String, submit _: Bool) async throws {
        lock.withLock { deliveryEntered = true }
        _ = terminalID
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            self.gateContinuation = continuation
            self.lock.unlock()
        }
    }

    func sendKeys(_: TerminalID, keys _: [String]) async throws {}

    func sendSignal(_: SignalIntent, to _: TerminalID) async throws {}

    func read(_: TerminalID, source _: TerminalReadSource) async throws -> TerminalSnapshot? {
        nil
    }
}

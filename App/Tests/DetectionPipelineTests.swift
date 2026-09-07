import AgentControl
import AgentCore
@testable import AgentTerminal
import AppKit
@testable import TerminalKit
import XCTest

// Round-3 Suite H (R3-1/R3-2/R3-4): DetectionPipeline exit-report gates,
// screen-evidence ingestion, suspend gate, and the production stop→suspend
// wiring through AgentExecutionCoordinator.markUserStop.
//
// Fixture law: the proven fakes in Packages/Tests/TerminalKitTests/
// SharedFakes.swift are internal to that SwiftPM test target — the App bundle
// re-declares deliberate file-private copies here. `launchDirect` wraps the
// fake native surface in the REAL GhosttySurface, so process-exit polling,
// snapshots and generations all run production code against canned bytes.

private struct ProbeFailure: Error {}

@MainActor
private final class HarnessSurface: NativeTerminalSurface {
    var screenText: String?
    var viewportText: String?
    var processExitedFlag = false
    var foregroundPIDValue: UInt64 = 0
    private(set) var freed = false

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

    func performFree() {
        freed = true
    }
}

@MainActor
private final class HarnessEngine: TerminalEngine {
    var eventSink: (@MainActor (GhosttyEvent) -> Void)?
    private(set) var surfaces: [HarnessSurface] = []

    /// The view/spec are deliberately untouched: no libghostty involvement.
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

/// Lock-guarded record of exit-report invocations (pattern:
/// AgentTerminalRegistryTests.changeCounter).
private final class ExitReportRecorder: @unchecked Sendable {
    struct Report: Equatable {
        let terminalID: TerminalID
        let generation: SurfaceGeneration
    }

    private let lock = NSLock()
    private var reports: [Report] = []

    func append(_ terminalID: TerminalID, _ generation: SurfaceGeneration) {
        lock.lock()
        defer { lock.unlock() }
        reports.append(Report(terminalID: terminalID, generation: generation))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reports.count
    }

    var all: [Report] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}

@MainActor
final class DetectionPipelineTests: XCTestCase {
    private struct Stack {
        let clock: FakeClock
        let runtime: AgentRuntime
        let registry: AgentTerminalRegistry
        let manager: TerminalSessionManager
        let engine: HarnessEngine
        let pipeline: DetectionPipeline
    }

    // MARK: - Arrangement helpers

    private func makeStack() -> Stack {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let registry = AgentTerminalRegistry()
        let engine = HarnessEngine()
        let manager = TerminalSessionManager(
            engine: engine,
            parkingHost: HarnessParkingHost(),
            inputBracketedPaste: false
        )
        let pipeline = DetectionPipeline(
            clock: clock,
            registry: registry,
            sessionManager: manager,
            runtime: runtime
        )
        return Stack(
            clock: clock, runtime: runtime, registry: registry,
            manager: manager, engine: engine, pipeline: pipeline
        )
    }

    /// Runtime agent + direct-launched shell surface + registry binding, with
    /// the fake native showing an idle prompt (`"$ "`).
    private func bindShellAgent(
        _ stack: Stack
    ) async throws -> (agent: AgentID, terminal: TerminalID, surface: HarnessSurface) {
        let workspace = await stack.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        let agent = try await stack.runtime.createAgent(
            AgentLaunchRequest(
                agentKind: .genericShell,
                workingDirectory: "/tmp",
                displayName: "det-agent"
            ),
            in: workspace
        )
        let session = try stack.manager.launchDirect(
            workspaceID: workspace,
            agentID: agent,
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        // MOUNT the fixture: parked terminals whose process exits are torn
        // down by the manager's reclaim policy (§3.8), which would race the
        // pipeline's retry/forget gates under test. Mounted terminals stay
        // for scrollback — exactly the §3.5 "Close View ≠ Stop Agent" law —
        // so the gates become deterministically observable.
        try? stack.manager.mount(
            terminalID: session.id, paneID: PaneID(), container: NSView()
        )
        let surface = try XCTUnwrap(stack.engine.surfaces.last)
        surface.screenText = "$ "
        stack.registry.bind(
            agentID: agent,
            to: AgentBinding(
                terminalID: session.id,
                surfaceGeneration: .initial,
                kind: .genericShell,
                displayName: "det-agent",
                cwd: "/tmp"
            )
        )
        return (agent, session.id, surface)
    }

    /// Arms hidden-cadence evaluations via `lifecycleChanged` (hidden `.starting`
    /// cadence = 2 Hz ⇒ 500 ms) and fires them deterministically on the
    /// shared FakeClock.
    ///
    /// Ordering law (TEST-STALL-FIX): `lifecycleChanged` enqueues its
    /// scheduler-arm task on the main actor, so each arm lands AFTER that same
    /// iteration's advance — but an already-elapsed sleeper returns
    /// immediately, so the NEXT advance (and the trailing sweep below) usually
    /// crosses the freshly armed deadline. NOT guaranteed under load: the arm
    /// task may land after the last advance, arming a deadline nothing ever
    /// crosses. Adoption waits must therefore poll with `waitUntilDriving`,
    /// which keeps the clock moving (as the production RealtimeClockDriver
    /// does) so a late-armed deadline still fires.
    private func driveEvaluation(_ stack: Stack, agent: AgentID, times: Int = 1) async {
        for _ in 0 ..< times {
            let projection = await stack.runtime.projection()
            guard let summary = projection.agents.first(where: { $0.id == agent }) else {
                XCTFail("agent \(agent) missing from runtime projection")
                return
            }
            stack.pipeline.lifecycleChanged(summary: summary)
            await Task.yield()
            stack.clock.advance(by: .milliseconds(500))
            await Task.yield()
        }
        // Trailing sweep: guarantees the LAST arm (enqueued after its own
        // iteration's advance) fires too.
        stack.clock.advance(by: .milliseconds(500))
        await Task.yield()
    }

    /// Bounded polling, no settles (RuntimeWiringTests precedent).
    private func waitUntil(
        timeout: TimeInterval = 3,
        interval: TimeInterval = 0.02,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Bounded polling that keeps the shared FakeClock moving. A scheduler
    /// arm that lands on the main actor AFTER driveEvaluation's last advance
    /// (Task.yield offers the actor; it does not guarantee the handoff)
    /// arms a 500 ms deadline that no later advance would ever cross — the
    /// frozen clock is the artificial bit: the production RealtimeClockDriver
    /// advances the domain clock continuously. Advancing inside the poll
    /// closes that hole for every interleaving.
    private func waitUntilDriving(
        _ stack: Stack,
        timeout: TimeInterval = 3,
        interval: TimeInterval = 0.02,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            stack.clock.advance(by: .milliseconds(250))
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    // MARK: H1 — failed exit report stays unmarked and is retried

    func testFailedExitReportsStayUnmarkedAndAreRetried() async throws {
        let stack = makeStack()
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        let recorder = ExitReportRecorder()
        stack.pipeline.exitReporter = { [recorder] terminalID, generation in
            recorder.append(terminalID, generation)
            throw ProbeFailure()
        }
        bound.surface.processExitedFlag = true

        stack.pipeline.start()
        defer { stack.pipeline.stop() }

        // Every poll pass retries the SAME terminal despite every report
        // throwing — no gate insertion, no terminal loss. The manager's
        // public poll is pumped EXPLICITLY: the runloop Timer is not
        // guaranteed to fire under parallel-test load (TEST-STALL-FIX).
        await waitUntil {
            stack.manager.pollProcessExits()
            return recorder.count >= 3
        }
        XCTAssertGreaterThanOrEqual(recorder.count, 3)
        XCTAssertTrue(recorder.all.allSatisfy {
            $0.terminalID == bound.terminal && $0.generation == .initial
        })
    }

    // MARK: H2 — successful exit report is recorded exactly once

    func testSuccessfulExitReportIsRecordedExactlyOnce() async throws {
        let stack = makeStack()
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        let recorder = ExitReportRecorder()
        stack.pipeline.exitReporter = { [recorder] terminalID, generation in
            recorder.append(terminalID, generation)
        }
        bound.surface.processExitedFlag = true

        stack.pipeline.start()
        defer { stack.pipeline.stop() }

        await waitUntil {
            stack.manager.pollProcessExits()
            return recorder.count == 1
        }
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(
            recorder.all,
            [ExitReportRecorder.Report(terminalID: bound.terminal, generation: .initial)]
        )

        // Negative stability window (~2 further poll ticks): no duplicate
        // reporting once the terminal entered `reportedExits`.
        await waitUntil(timeout: 1.3) { recorder.count > 1 }
        XCTAssertEqual(recorder.count, 1)
    }

    // MARK: H3 — forget re-arms exit reporting for a rebound terminal

    func testForgetReArmsExitReportingForAReboundTerminal() async throws {
        let stack = makeStack()
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        let recorder = ExitReportRecorder()
        stack.pipeline.exitReporter = { [recorder] terminalID, generation in
            recorder.append(terminalID, generation)
        }
        bound.surface.processExitedFlag = true

        stack.pipeline.start()
        defer { stack.pipeline.stop() }

        await waitUntil {
            stack.manager.pollProcessExits()
            return recorder.count == 1
        }
        XCTAssertEqual(recorder.count, 1)

        // Restart cutover path: explicit re-arm clears the reportedExits gate.
        stack.pipeline.forget(terminalID: bound.terminal)
        await waitUntil { recorder.count == 2 }
        XCTAssertEqual(recorder.count, 2)
        XCTAssertTrue(recorder.all.allSatisfy {
            $0.terminalID == bound.terminal && $0.generation == .initial
        })
    }

    // MARK: H4 — positive control: screen evaluation adopts idle/screen

    func testScreenEvaluationAdoptsIdleWithScreenAuthorityFromStarting() async throws {
        let stack = makeStack()
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        await driveEvaluation(stack, agent: bound.agent)

        await waitUntilDriving(stack) {
            guard let state = try? await stack.runtime.state(of: bound.agent) else {
                return false
            }
            return state.lifecycle == .idle
        }
        let state = try await stack.runtime.state(of: bound.agent)
        XCTAssertEqual(state.lifecycle, .idle)
        XCTAssertEqual(state.authority, .screen)
    }

    // MARK: H5 — suspended agent never ingests screen evidence

    func testSuspendedAgentNeverIngestsScreenEvidence() async throws {
        let stack = makeStack()
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        stack.pipeline.suspend(agentID: bound.agent)
        await driveEvaluation(stack, agent: bound.agent, times: 3)

        XCTAssertTrue(stack.pipeline.suspended.contains(bound.agent))
        let state = try await stack.runtime.state(of: bound.agent)
        XCTAssertEqual(state.lifecycle, .starting)
        XCTAssertEqual(state.authority, .unknown)
    }

    // MARK: H6 — markUserStop suspends detection through the production caller

    func testMarkUserStopSuspendsDetectionThroughTheProductionCaller() async throws {
        let stack = makeStack()
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        let coordinator = AgentExecutionCoordinator(
            runtime: stack.runtime,
            clock: stack.clock,
            sessionManager: stack.manager,
            registry: stack.registry,
            model: AppModel(),
            hooks: HookAuthenticator(),
            agentRepository: nil,
            launcherExecutable: URL(fileURLWithPath: "/bin/true"),
            controlSocketPath: "/tmp/aterm-test.sock",
            // The coordinator OWNS its pipeline now — no global slot.
            detectionPipeline: stack.pipeline
        )

        coordinator.markUserStop(bound.agent)
        XCTAssertTrue(stack.pipeline.suspended.contains(bound.agent))
        XCTAssertTrue(coordinator.isUserStopped(bound.agent))

        // clearUserStop releases the user-intent flag but NOT the suspension —
        // the stop ladder owns the lifecycle from then on.
        coordinator.clearUserStop(bound.agent)
        XCTAssertFalse(coordinator.isUserStopped(bound.agent))
        XCTAssertTrue(stack.pipeline.suspended.contains(bound.agent))
    }

    // MARK: Round 14 D1 — generationInvalidated unsuspends (89af72d restart law)

    func testGenerationInvalidatedUnsuspendsUserStoppedAgent() async throws {
        let stack = makeStack()
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        // Pre-state: a suspended agent ingests no screen evidence.
        stack.pipeline.suspend(agentID: bound.agent)
        XCTAssertTrue(stack.pipeline.suspended.contains(bound.agent))
        await driveEvaluation(stack, agent: bound.agent, times: 3)
        let suspendedState = try await stack.runtime.state(of: bound.agent)
        XCTAssertEqual(suspendedState.lifecycle, .starting)
        XCTAssertEqual(suspendedState.authority, .unknown)

        // Restart minted a new generation — the old run's suspension must
        // not silence the successor.
        stack.pipeline.generationInvalidated(agentID: bound.agent)

        XCTAssertFalse(stack.pipeline.suspended.contains(bound.agent))

        // The unsuspended agent adopts screen evidence again.
        await driveEvaluation(stack, agent: bound.agent, times: 3)
        await waitUntil {
            guard let state = try? await stack.runtime.state(of: bound.agent) else {
                return false
            }
            return state.lifecycle != .starting
        }
        let state = try await stack.runtime.state(of: bound.agent)
        XCTAssertNotEqual(state.lifecycle, .starting)
        XCTAssertEqual(state.authority, .screen)
    }

    // MARK: Round 19 D1 — ordered scheduler-handler registration (10fb072)

    /// Every scheduler interaction awaits `handlerRegistered` before
    /// delivering, so events raised around startup can never fire into a nil
    /// handler. The observable law: evaluation effects LAND regardless of
    /// task scheduling between init and the first mutator call.
    func testSchedulerEventsFiredBeforeHandlerRegistrationStillEvaluate() async throws {
        // No awaits between init and this mutator: the forget below is
        // enqueued while the registration Task may not have completed yet.
        let stack = makeStack()
        stack.pipeline.forget(terminalID: TerminalID())
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        await driveEvaluation(stack, agent: bound.agent)

        await waitUntilDriving(stack) {
            guard let state = try? await stack.runtime.state(of: bound.agent) else {
                return false
            }
            return state.lifecycle == .idle
        }
        let state = try await stack.runtime.state(of: bound.agent)
        XCTAssertEqual(state.lifecycle, .idle, "startup-raced scheduler events must still evaluate")
        XCTAssertEqual(state.authority, .screen)
    }

    // MARK: Round 19 D2 — forget clears dedupe state, delivers post-registration

    /// `forget` synchronously clears `lastSeenRevisions`/`reportedExits` and
    /// delivers `scheduler.forget` only AFTER registration — a forget racing
    /// startup neither crashes into a nil handler nor leaves stale dedupe
    /// state suppressing legitimate reports after rebind.
    func testForgetAfterRegistrationClearsRevisionTrackingAndReachesScheduler() async throws {
        let stack = makeStack()
        defer {
            stack.pipeline.stop()
            stack.engine.shutdown()
        }
        let bound = try await bindShellAgent(stack)

        let recorder = ExitReportRecorder()
        stack.pipeline.exitReporter = { [recorder] terminalID, generation in
            recorder.append(terminalID, generation)
        }
        bound.surface.processExitedFlag = true

        // Startup-race forget: issued BEFORE start(), i.e. possibly before
        // the registration task completed.
        stack.pipeline.forget(terminalID: bound.terminal)

        stack.pipeline.start()
        defer { stack.pipeline.stop() }

        // 1. No crash, no nil-handler route: the exit report reaches the sink
        // (manager poll pumped explicitly — runloop Timer is not guaranteed
        // to fire under parallel-test load).
        await waitUntil {
            stack.manager.pollProcessExits()
            return recorder.count >= 1
        }
        XCTAssertEqual(recorder.count, 1)

        // 2. forget's SYNCHRONOUS reportedExits clear re-arms reporting —
        // stale dedupe state would suppress this second report forever.
        stack.pipeline.forget(terminalID: bound.terminal)
        await waitUntil {
            stack.manager.pollProcessExits()
            return recorder.count >= 2
        }
        XCTAssertEqual(recorder.count, 2)

        // 3. Revision tracking cleared too: a rebound FRESH terminal's first
        // render-revision scan must evaluate once (screen adoption proves the
        // scheduler delivered post-registration).
        let rebound = try await bindShellAgent(stack)
        rebound.surface.screenText = "$ "
        // The render poller ticks in real time while the scheduler debounce
        // runs on the FakeClock — advance both until the evaluation lands.
        await waitUntil {
            for _ in 0 ..< 3 {
                await Task.yield()
                stack.clock.advance(by: .milliseconds(200))
            }
            guard let state = try? await stack.runtime.state(of: rebound.agent) else {
                return false
            }
            return state.lifecycle == .idle && state.authority == .screen
        }
        let reboundState = try await stack.runtime.state(of: rebound.agent)
        XCTAssertEqual(reboundState.lifecycle, .idle, "the rebound terminal's fresh revision must evaluate")
        XCTAssertEqual(reboundState.authority, .screen)
    }
}

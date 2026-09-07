import AgentControl
import AgentCore
import AgentStore
@testable import AgentTerminal
import XCTest

// Stage-8 acceptance (§6.8): wiring-level behavioral tests over the REAL
// AgentRuntime with deterministic fakes — no libghostty dependency.
//
//  1. stale-generation observations cannot change new agent state;
//  2. restart increments the generation and drops old evidence;
//  3. persistence degradation never blocks the runtime and surfaces banner
//     state (§3.12A / §3.14 step 8);
//  4. the EventStreamBroker fans deltas out to two subscribers as the single
//     owner of runtime.deltaStream() (§3.2) — UI and control share one pump.

/// NSLock-guarded observation slot shared between child Tasks (writers) and
/// waitUntil polling closures (readers) — same discipline as Stage9's
/// RecordingTerminalPort, keeping cross-domain access synchronized.
private final class ObservationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var underlying: T

    init(_ initial: T) {
        underlying = initial
    }

    /// Synchronous so NSLock usage stays out of async contexts
    /// (`lock` is unavailable there under Swift 6 upcoming-feature strictness).
    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return underlying
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            underlying = newValue
        }
    }
}

@MainActor
final class RuntimeWiringTests: XCTestCase {
    private struct SimulatedWriteFailure: Error {}

    private func makeStartedAgent(
        runtime: AgentRuntime,
        displayName: String = "wired-agent"
    ) async throws -> AgentID {
        let workspace = await runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        let agentID = try await runtime.createAgent(
            AgentLaunchRequest(
                agentKind: .genericShell,
                workingDirectory: "/tmp",
                displayName: displayName
            ),
            in: workspace
        )
        try await runtime.surfaceCreated(
            agentID: agentID,
            terminalID: TerminalID(),
            generation: .initial,
            pid: 4711,
            processGroupID: 4711
        )
        return agentID
    }

    /// Integration-authority observation (the strongest §3.6 authority);
    /// envelope generation/revision ordering rules are what these tests probe.
    private func lifecycleEvidence(
        agent: AgentID,
        terminal: TerminalID?,
        generation: SurfaceGeneration,
        outputRevision: UInt64,
        lifecycle: LifecyclePhase,
        at instant: MonotonicInstant
    ) -> Evidence {
        Evidence(
            envelope: ObservationEnvelope(
                agentID: agent,
                terminalID: terminal,
                surfaceGeneration: generation,
                sourceID: "hook:test",
                sourceKind: .integration,
                sequence: nil,
                outputRevision: outputRevision,
                observedAt: instant,
                receivedAt: instant
            ),
            payload: .integrationLifecycle(lifecycle)
        )
    }

    // MARK: 1+2 — stale-generation rejection & restart invalidation

    func testStaleGenerationObservationCannotChangeNewAgentState() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let agent = try await makeStartedAgent(runtime: runtime)

        // Drive the CURRENT generation to idle through the documented path.
        await runtime.ingest(lifecycleEvidence(
            agent: agent, terminal: nil, generation: .initial,
            outputRevision: 3, lifecycle: .idle, at: clock.now
        ))
        var summary = await runtime.projection().agents.first { $0.id == agent }
        guard case .idle = summary?.state.lifecycle else {
            return XCTFail("setup: expected idle, got \(String(describing: summary?.state.lifecycle))")
        }
        let revisionBeforeRestart = try XCTUnwrap(summary?.state.revision)

        // Restart mints generation #1; every generation-#0 observation is inert.
        try await runtime.restart(agent)

        await runtime.ingest(lifecycleEvidence(
            agent: agent, terminal: nil, generation: .initial, // STALE generation
            outputRevision: 99, lifecycle: .working, at: clock.now
        ))

        summary = await runtime.projection().agents.first { $0.id == agent }
        guard case .starting = summary?.state.lifecycle else {
            return XCTFail("stale evidence mutated state: \(String(describing: summary?.state.lifecycle))")
        }
        XCTAssertEqual(summary?.state.revision, revisionBeforeRestart + 1,
                       "restart bumps exactly once; stale evidence adds nothing")
    }

    // MARK: 3 — persistence-degraded keeps runtime alive

    func testPersistenceDegradedKeepsRuntimeAliveAndSurfacesBanner() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let model = AppModel()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-wiring-\(UUID().uuidString).sqlite")
        // Remove the temp store on EVERY exit path — a failed assertion
        // must not leak the sqlite file or the GRDB handle.
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try AgentDatabase(databaseURL: url)
        try database.migrate()
        let writer = DatabaseWriter(
            transactor: PoolTransactor(pool: database.pool),
            retryDelay: .milliseconds(1),
            maxAttempts: 1,
            failureInjector: { _ in SimulatedWriteFailure() }
        )

        await runtime.setPersistence(writer)

        let degradedSeen = ObservationBox(false)
        let healthTask = Task {
            for await health in await writer.healthUpdates() {
                if case .degraded = health {
                    degradedSeen.value = true
                    break
                }
            }
        }

        // Full lifecycle flow while EVERY commit fails on disk.
        let agent = try await makeStartedAgent(runtime: runtime)
        try await runtime.processExited(
            agentID: agent, exitCode: 0, signal: nil, userInitiated: true
        )

        let state = try await runtime.state(of: agent)
        guard case .stopped(.userRequested) = state.lifecycle else {
            return XCTFail("runtime must keep mutating state despite degraded store")
        }
        // The degraded signal maps onto the UI banner through the ONE
        // production mapping (AppModel.apply) — no manual banner writes.
        let bannerTask = Task { @MainActor in
            for await health in await writer.healthUpdates() {
                model.apply(persistenceHealth: health)
            }
        }
        await waitUntil("degraded signal observed", timeout: 5) { degradedSeen.value }
        XCTAssertTrue(degradedSeen.value, "expected the degraded health transition")
        await waitUntil("degraded banner surfaced", timeout: 5) { model.degradedBanner != nil }
        XCTAssertTrue(model.degradedBanner?.hasPrefix("Persistence degraded — ") == true)
        bannerTask.cancel()

        healthTask.cancel()
    }

    // MARK: 4 — broker single-subscription ownership

    func testBrokerFansOutToUIAndControlSubscribers() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let broker = EventStreamBroker(streamProvider: EventStreamBroker.provider(for: runtime))

        // Subscribe FIRST (settling the actor state), then consume.
        let uiStream = await broker.subscribe(agentID: nil)
        let controlStream = await broker.subscribe(agentID: nil)
        let liveSubscribers = await broker.liveSubscribers
        XCTAssertEqual(liveSubscribers, 2)

        let uiSummaries = ObservationBox<[AgentSummary]>([])
        let controlSummaries = ObservationBox<[AgentSummary]>([])
        let uiTask = Task {
            for try await summary in uiStream {
                uiSummaries.value.append(summary)
                break
            }
        }
        let controlTask = Task {
            for try await summary in controlStream {
                controlSummaries.value.append(summary)
                break
            }
        }

        let agent = try await makeStartedAgent(runtime: runtime)

        await waitUntil("both subscribers received the delta", timeout: 5) {
            !uiSummaries.value.isEmpty && !controlSummaries.value.isEmpty
        }
        XCTAssertEqual(uiSummaries.value.first?.id, agent)
        XCTAssertEqual(controlSummaries.value.first?.id, agent,
                       "both consumers received the SAME delta through one pump")

        _ = try? await uiTask.value
        _ = try? await controlTask.value
    }

    // MARK: R28-S3 — rebind sweeps the stale mapping; remove clears the rest

    /// R28-S3 history: a bind-before-rebind race used to leave TWO live
    /// reverse mappings for one agent. Eager rebind sweeping fixed that: `bind` retires every
    /// prior reverse mapping for the agent (a bind-before-rebind race can no
    /// longer leave two live mappings), so the stale mapping must already be
    /// GONE after the second bind. Removing the agent then sweeps the current
    /// mapping and the forward binding.
    func testRebindSweepsStaleMappingAndRemoveClearsCurrent() {
        let registry = AgentTerminalRegistry()
        let agent = AgentID()
        let oldTerminal = TerminalID()
        let successorTerminal = TerminalID()

        // Arrange: bind, then rebind to a successor terminal — the exact
        // sequence a bind-and-spawn performs.
        registry.bind(
            agentID: agent,
            to: AgentBinding(
                terminalID: oldTerminal,
                surfaceGeneration: .initial,
                kind: .genericShell,
                displayName: "swept",
                cwd: "/tmp"
            )
        )
        registry.bind(
            agentID: agent,
            to: AgentBinding(
                terminalID: successorTerminal,
                surfaceGeneration: .initial.successor(),
                kind: .genericShell,
                displayName: "swept",
                cwd: "/tmp"
            )
        )

        // The rebind swept the stale mapping EAGERLY — no two-mapping window.
        XCTAssertNil(registry.agentID(for: oldTerminal),
                     "rebinding must retire the stale terminal's reverse mapping")
        XCTAssertEqual(registry.agentID(for: successorTerminal), agent)

        // Act.
        registry.remove(agentID: agent)

        // Assert: the current reverse mapping, the forward binding, and the
        // terminal tracking are all cleared.
        XCTAssertNil(registry.agentID(for: successorTerminal))
        XCTAssertNil(registry.binding(for: agent))
        XCTAssertTrue(registry.trackedTerminals.isEmpty)
    }

    // MARK: helpers

    private func waitUntil(
        _ label: String, timeout: TimeInterval, interval: TimeInterval = 0.02,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        // Expiry must FAIL, not silently return: a wait that gives up is a
        // skipped assertion, not a passed one.
        let final = await condition()
        XCTAssertTrue(final, "condition not met in \(timeout)s: \(label)",
                      file: file, line: line)
    }
}

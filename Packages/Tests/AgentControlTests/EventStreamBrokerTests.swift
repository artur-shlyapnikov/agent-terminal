@testable import AgentControl
import AgentCore
import XCTest

// Round 8 Suites A (R8-1..R8-3): EventStreamBroker fan-out laws pinned over a
// plain manual source — no socket, no runtime. The broker is a public actor
// constructible with ANY stream provider (EventStreamBroker.init), so the
// tests drive deltas deterministically through stored continuations.
//
// Laws under test:
// - B1: the shared pump is started once at first subscribe and NEVER torn
//   down/restarted across subscribe→detach→resubscribe cycles (header note:
//   restarting races the single-consumer runtime stream and drops one delta).
// - B2: per-subscriber agent filters isolate agents; unfiltered receives all.
// - B3: per-subscriber `.bufferingNewest(64)` coalesces a stalled consumer's
//   backlog down to the NEWEST delta without blocking the pump.

/// Manual-source provider: records how many times the broker pulled the
/// stream and hands the test continuations to push deltas deterministically.
private final class SourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pulls = 0
    private var continuations: [AsyncStream<RuntimeDelta>.Continuation] = []

    func pull() -> AsyncStream<RuntimeDelta> {
        let stream = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations.append(continuation) }
        }
        lock.withLock { pulls += 1 }
        return stream
    }

    /// Yields to EVERY stored continuation so multi-subscriber ordering laws
    /// stay deterministic.
    func push(_ delta: RuntimeDelta) {
        lock.withLock {
            for continuation in continuations {
                continuation.yield(delta)
            }
        }
    }

    var pullCount: Int {
        lock.withLock { pulls }
    }
}

/// Lock-guarded revision recorder fed by consumer tasks.
private final class RevisionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [UInt64] = []

    func append(_ revision: UInt64) {
        lock.withLock { revisions.append(revision) }
    }

    var all: [UInt64] {
        lock.withLock { revisions }
    }
}

private func makeSummary(_ id: AgentID, revision: UInt64) -> AgentSummary {
    let session = AgentSession(
        id: id,
        workspaceID: WorkspaceID(),
        kind: .genericShell,
        displayName: "test",
        taskSummary: nil,
        cwd: "/tmp",
        launchDescriptor: LaunchDescriptor(
            agentKind: .genericShell,
            program: "sh",
            arguments: [],
            workingDirectory: "/tmp"
        ),
        resumePolicy: .none,
        state: AgentState(
            lifecycle: .idle,
            revision: revision,
            observedAt: MonotonicInstant.zero
        ),
        createdAt: MonotonicInstant.zero,
        lastActivityAt: MonotonicInstant.zero
    )
    return AgentSummary(session: session)
}

/// Starts a detached consumer recording every received revision.
private func consume(
    _ stream: AsyncThrowingStream<AgentSummary, any Error>,
    into collector: RevisionCollector
) -> Task<Void, Never> {
    Task {
        do {
            for try await summary in stream {
                collector.append(summary.state.revision)
            }
        } catch {
            // Stream failure ends the consumer; the collectors record what
            // arrived before the failure.
        }
    }
}

/// Bounded event-driven poll: fails via XCTFail when the condition never
/// becomes true within the deadline.
private func eventually(
    deadline: Duration = .seconds(5),
    _ condition: () async -> Bool,
    _ message: @autoclosure () -> String = "condition never became true"
) async {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail(message())
}

@MainActor
final class EventStreamBrokerTests: XCTestCase {
    // MARK: B1 / R8-1 — pump longevity across a full subscribe/detach/resubscribe cycle

    func testPumpOutlivesFullSubscribeDetachResubscribeCycleAndDeliversLaterDeltas() async {
        let box = SourceBox()
        let id = AgentID()
        let broker = EventStreamBroker(streamProvider: { box.pull() })

        // Subscribe s1 (unfiltered); consume so delivery can be observed.
        let first = await broker.subscribe(agentID: nil)
        let firstCollector = RevisionCollector()
        let firstTask = consume(first, into: firstCollector)

        // The pump's provider-pull is asynchronous to subscribe(); a push
        // that lands before pull() registers a continuation would be
        // dropped by this manual source (the production runtime source
        // buffers instead). Wait for the pull so delivery is deterministic.
        await eventually({ box.pullCount >= 1 }, "pump never pulled the provider stream")
        box.push(.agentChanged(makeSummary(id, revision: 1)))
        await eventually({ firstCollector.all == [1] }, "first subscriber never received rev 1")

        // Cancel the consumer → stream termination fires onTermination → detach.
        firstTask.cancel()
        await eventually({ await broker.liveSubscribers == 0 }, "subscriber count never dropped to zero")

        // Resubscribe AFTER the detach; the idle-at-zero pump must still be
        // the SAME single pull of the provider stream.
        let second = await broker.subscribe(agentID: nil)
        let secondCollector = RevisionCollector()
        let secondTask = consume(second, into: secondCollector)

        box.push(.agentChanged(makeSummary(id, revision: 2)))
        await eventually({ secondCollector.all == [2] }, "resubscribed subscriber never received rev 2")

        // THE core law: exactly ONE provider consumption across both
        // subscriptions — a restarted pump would pull twice.
        XCTAssertEqual(box.pullCount, 1)

        secondTask.cancel()
    }

    // MARK: B2 / R8-2 — per-agent filter isolation

    func testSubscriberFilterIsolatesAgentsWhileUnfilteredReceivesAll() async {
        let box = SourceBox()
        let a = AgentID()
        let b = AgentID()
        let broker = EventStreamBroker(streamProvider: { box.pull() })

        let filteredStream = await broker.subscribe(agentID: a)
        let unfilteredStream = await broker.subscribe(agentID: nil)
        let filtered = RevisionCollector()
        let unfiltered = RevisionCollector()
        let filteredTask = consume(filteredStream, into: filtered)
        let unfilteredTask = consume(unfilteredStream, into: unfiltered)

        await eventually({ box.pullCount >= 1 }, "pump never pulled the provider stream")
        box.push(.agentChanged(makeSummary(b, revision: 1)))
        box.push(.agentChanged(makeSummary(a, revision: 2)))
        box.push(.agentChanged(makeSummary(b, revision: 3)))

        await eventually({ unfiltered.all == [1, 2, 3] }, "unfiltered subscriber lost or reordered deltas")
        await eventually({ filtered.all == [2] }, "filtered subscriber did not receive exactly its own delta")

        // Bounded no-further-arrival check after the settle point.
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(filtered.all, [2], "foreign agents' deltas leaked through the filter")

        filteredTask.cancel()
        unfilteredTask.cancel()
    }

    // MARK: B3 / R8-3 — bufferingNewest coalescing under backpressure

    func testSlowConsumerCoalescesToNewestUnderBackpressureWithoutBlockingThePump() async throws {
        let box = SourceBox()
        let id = AgentID()
        let broker = EventStreamBroker(streamProvider: { box.pull() })

        // Slow consumer: subscribed but never read until after the flood.
        let slowStream = await broker.subscribe(agentID: nil)

        // Fast consumer: reads everything as it arrives.
        let fastStream = await broker.subscribe(agentID: nil)
        let fastCollector = RevisionCollector()
        let fastTask = consume(fastStream, into: fastCollector)

        await eventually({ box.pullCount >= 1 }, "pump never pulled the provider stream")
        for revision in 1 ... 100 {
            box.push(.agentChanged(makeSummary(id, revision: UInt64(revision))))
        }

        // A subscriber draining slower than the pump may lose any of its
        // oldest pending deltas per the bufferingNewest contract — the
        // COUNT arriving at the fast subscriber is unguaranteed under a
        // 100-revision flood. The pinned law is: the NEWEST revision
        // survives, arrival order is FIFO, and the pump never blocks.
        // (R25 review: a `>= bufferCapacity` gate races the in-flight tail;
        // even `== 100` races the consumer's own scheduling, so the wait
        // targets the newest revision rather than the flood size.)
        await eventually(
            { fastCollector.all.last == 100 },
            "pump blocked behind a stalled consumer"
        )
        XCTAssertTrue(fastCollector.all == fastCollector.all.sorted(), "fast subscriber deltas must stay ordered")
        XCTAssertGreaterThanOrEqual(fastCollector.all.count, 1)
        XCTAssertLessThanOrEqual(fastCollector.all.count, 100)

        // Drain the slow stream with a bounded consumer. `.bufferingNewest`
        // keeps the newest `bufferCapacity` deltas (older ones are coalesced
        // away): the drained backlog must be EXACTLY revs 37...100 —
        // FIFO/oldest-drop buffering yields 1...64 and `.unbounded` yields
        // all of 1...100, so any regression shows here. The LAST value is
        // always the newest revision (rev 100): state-based consumers only
        // ever skip intermediate revisions, never the current state.
        let slowCollector = RevisionCollector()
        let slowTask = Task {
            var seen = 0
            for try await summary in slowStream {
                slowCollector.append(summary.state.revision)
                seen += 1
                if seen >= EventStreamBroker.defaultBufferCapacity {
                    break
                } // bounded drain
            }
        }
        await eventually(
            { slowCollector.all.count == EventStreamBroker.defaultBufferCapacity },
            "slow consumer never yielded its coalesced backlog"
        )
        // Grace window: values beyond the capacity would expose unbounded or
        // FIFO buffering masquerading as coalescing.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(
            slowCollector.all,
            Array(37 ... 100),
            "backlog was not capped at bufferCapacity with newest-survives semantics"
        )
        XCTAssertEqual(slowCollector.all.last, 100, "current state (newest revision) was not retained")

        slowTask.cancel()
        fastTask.cancel()
    }

    // MARK: R21-B2 — removal/projection deltas are never fanned out

    func testRemovalAndProjectionDeltasAreNeverFannedOutToSummarySubscribers() async {
        let box = SourceBox()
        let id = AgentID()
        let broker = EventStreamBroker(streamProvider: { box.pull() })

        let unfilteredStream = await broker.subscribe(agentID: nil)
        let filteredStream = await broker.subscribe(agentID: id)
        let unfiltered = RevisionCollector()
        let filtered = RevisionCollector()
        let unfilteredTask = consume(unfilteredStream, into: unfiltered)
        let filteredTask = consume(filteredStream, into: filtered)

        await eventually({ box.pullCount >= 1 }, "pump never pulled the provider stream")

        // Non-summary deltas: dispatch must produce NOTHING on any stream.
        box.push(.agentRemoved(AgentID()))
        box.push(.projectionReplaced(RuntimeProjection(agents: [], generatedAt: .zero)))
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertTrue(unfiltered.all.isEmpty, "non-summary deltas leaked into the unfiltered stream")
        XCTAssertTrue(filtered.all.isEmpty, "non-summary deltas leaked into the filtered stream")

        // Positive control: agentChanged remains the yielded variant, and no
        // stray finish() detached either consumer along the way.
        box.push(.agentChanged(makeSummary(id, revision: 1)))
        await eventually(
            { unfiltered.all == [1] && filtered.all == [1] },
            "agentChanged control failed after silent non-summary deltas"
        )
        let live = await broker.liveSubscribers
        XCTAssertEqual(live, 2, "a non-summary delta finished/detached a subscriber stream")

        unfilteredTask.cancel()
        filteredTask.cancel()
    }

    // MARK: R21-W1 — immediate match without subscribing + honest not-found

    func testWaitMatchesImmediatelyWithoutSubscribingAndReportsAgentNotFoundOnNilRead() async {
        let snapshot = LifecycleSnapshot(stateRevision: 7, lifecycle: .idle)
        let subscriptions = CallCounter()

        // Already-satisfied predicate: matched synchronously at steps 1–2,
        // BEFORE any subscription is created.
        let immediate = await waitForLifecycle(
            targets: [.idle],
            minStateRevision: nil,
            timeout: .seconds(1),
            reader: { snapshot },
            events: {
                subscriptions.increment()
                return AsyncThrowingStream { $0.finish() }
            }
        )
        XCTAssertEqual(immediate, .success(.matched(stateRevision: 7, lifecycle: .idle)))
        XCTAssertEqual(subscriptions.value, 0, "a settled wait must never open a subscription")

        // The early return is predicate-gated, not unconditional: an
        // unmatched lifecycle falls through to subscribing (the immediately
        // finished event stream surfaces as structured .cancelled).
        let fallthroughWait = await waitForLifecycle(
            targets: [.stopped],
            minStateRevision: nil,
            timeout: .seconds(1),
            reader: { snapshot },
            events: {
                subscriptions.increment()
                return AsyncThrowingStream { $0.finish() }
            }
        )
        XCTAssertEqual(fallthroughWait, .success(.cancelled))
        XCTAssertEqual(subscriptions.value, 1)

        // A NIL initial read is exactly .failure(.agentNotFound) — also
        // without subscribing.
        let missing = await waitForLifecycle(
            targets: [.idle],
            minStateRevision: nil,
            timeout: .seconds(1),
            reader: { nil },
            events: {
                subscriptions.increment()
                return AsyncThrowingStream { $0.finish() }
            }
        )
        XCTAssertEqual(missing, .failure(.agentNotFound))
        XCTAssertEqual(subscriptions.value, 1, "not-found must short-circuit before subscribing too")
    }

    // MARK: R21-W2 — readerFailed mapping + minStateRevision floor on both legs

    func testReaderFailureMapsToReaderFailedAndMinStateRevisionGatesBothLegs() async {
        struct DummyError: Error {}

        // A throwing reader maps to .readerFailed — never agentNotFound,
        // never timedOut ("reader failure must not masquerade as agentNotFound").
        let failed = await waitForLifecycle(
            targets: [.idle],
            minStateRevision: nil,
            timeout: .seconds(1),
            reader: { throw DummyError() },
            events: { AsyncThrowingStream { $0.finish() } }
        )
        guard case let .failure(.readerFailed(message)) = failed else {
            return XCTFail("expected .readerFailed, got \(failed)")
        }
        XCTAssertFalse(message.isEmpty)

        // Floor leg: an initial read matching the lifecycle BELOW the floor
        // must NOT match; the (alive, never-matching) stream lets the
        // deadline fire, and the timeout echoes the last-known revision.
        let idleBox = SummaryPushBox()
        let floorBlocked = await waitForLifecycle(
            targets: [.working],
            minStateRevision: 6,
            timeout: .milliseconds(300),
            reader: { LifecycleSnapshot(stateRevision: 5, lifecycle: .working) },
            events: { idleBox.stream() }
        )
        XCTAssertEqual(floorBlocked, .success(.timedOut(lastKnownRevision: 5)))

        // Streamed-floor leg: a streamed event still below the floor is
        // skipped; the first qualifying revision matches well under timeout.
        let box = SummaryPushBox()
        async let streamedResult = waitForLifecycle(
            targets: [.working],
            minStateRevision: 6,
            timeout: .seconds(2),
            reader: { LifecycleSnapshot(stateRevision: 1, lifecycle: .working) },
            events: { box.stream() }
        )
        await eventually(deadline: .seconds(2)) {
            box.subscriptions >= 1
        }
        box.push(Self.makeWorkingSummary(AgentID(), revision: 5)) // below floor → skipped
        box.push(Self.makeWorkingSummary(AgentID(), revision: 7)) // qualifying → match
        let streamed = await streamedResult
        XCTAssertEqual(streamed, .success(.matched(stateRevision: 7, lifecycle: .working)))
    }

    /// R21 helper: like `makeSummary` but with a WORKING lifecycle so the
    /// streamed-floor leg can exercise matching above the revision floor.
    private static func makeWorkingSummary(_ id: AgentID, revision: UInt64) -> AgentSummary {
        let session = AgentSession(
            id: id,
            workspaceID: WorkspaceID(),
            kind: .genericShell,
            displayName: "test",
            taskSummary: nil,
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: .genericShell,
                program: "sh",
                arguments: [],
                workingDirectory: "/tmp"
            ),
            resumePolicy: .none,
            state: AgentState(
                lifecycle: .working,
                revision: revision,
                observedAt: MonotonicInstant.zero
            ),
            createdAt: MonotonicInstant.zero,
            lastActivityAt: MonotonicInstant.zero
        )
        return AgentSummary(session: session)
    }

    // MARK: R21-B1 — pump drop after provider-stream end + fresh pull on next subscribe

    func testProviderStreamEndDropsPumpAndNextSubscribeStartsAFreshPull() async {
        let box = TwoPhaseSourceBox()
        let id = AgentID()
        let broker = EventStreamBroker(streamProvider: { box.pull() })

        // s1 registers, the pump pulls the FINISHED stream, the loop exits,
        // and clearPump re-arms because s1 is still registered — observable
        // as a SECOND provider pull of the live stream.
        let first = await broker.subscribe(agentID: nil)
        let firstCollector = RevisionCollector()
        let firstTask = consume(first, into: firstCollector)
        await eventually({ box.pullCount >= 1 }, "pump never pulled the finished provider stream")
        await eventually({ box.pullCount >= 2 }, "dead pump was never dropped/re-armed for late subscribers")

        // A subsequent subscriber attaches to pump #2 and receives deltas
        // from the FRESH stream. No third pull may occur.
        let second = await broker.subscribe(agentID: nil)
        let secondCollector = RevisionCollector()
        let secondTask = consume(second, into: secondCollector)
        box.push(.agentChanged(makeSummary(id, revision: 1)))
        await eventually({ secondCollector.all == [1] }, "second subscriber never received delta from the fresh stream")
        XCTAssertEqual(box.pullCount, 2, "an immortal zombie pump yields 1 forever; eager restart yields more than 2")
        let live = await broker.liveSubscribers
        XCTAssertEqual(live, 2, "subscriber bookkeeping inconsistent across the re-arm")

        firstTask.cancel()
        secondTask.cancel()
    }
}

// MARK: - R21 fixtures (additive; SourceBox's existing laws untouched)

/// Lock-guarded call counter shared into @Sendable closures.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

/// Manual summary source: hands the test the continuation so events can be
/// pushed while a wait algorithm is subscribed.
private final class SummaryPushBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AgentSummary, any Error>.Continuation?
    private var subscriptionCount = 0

    func stream() -> AsyncThrowingStream<AgentSummary, any Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { [self] cont in
            lock.withLock {
                continuation = cont
                subscriptionCount += 1
            }
        }
    }

    /// Number of continuations registered so far; lets tests await actual
    /// subscription instead of sleeping a fixed interval.
    var subscriptions: Int {
        lock.withLock { subscriptionCount }
    }

    func push(_ summary: AgentSummary) {
        _ = lock.withLock { continuation?.yield(summary) }
    }
}

/// Two-phase provider for the pump-restart law: the FIRST pull returns an
/// already-FINISHED stream (provider death); every later pull returns a live
/// manual stream whose continuations are stored for deterministic pushes.
private final class TwoPhaseSourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pulls = 0
    private var liveContinuations: [AsyncStream<RuntimeDelta>.Continuation] = []

    func pull() -> AsyncStream<RuntimeDelta> {
        let first = lock.withLock { () -> Bool in
            pulls += 1
            return pulls == 1
        }
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            if first {
                continuation.finish()
                return
            }
            lock.withLock { liveContinuations.append(continuation) }
        }
    }

    /// Yields to every stored LIVE continuation (the dead first pull has none).
    func push(_ delta: RuntimeDelta) {
        lock.withLock {
            for continuation in liveContinuations {
                continuation.yield(delta)
            }
        }
    }

    var pullCount: Int {
        lock.withLock { pulls }
    }
}

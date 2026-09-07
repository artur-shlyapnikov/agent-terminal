import AgentCore
import Foundation

// Subscription fan-out over the runtime delta stream (architecture §3.16,
// §4.5). The broker holds the SINGLE runtime subscription (RuntimeDeltaStream
// is single-consumer) and fans out to per-client subscribers.
//
// Backpressure policy (documented contract, control-v1.md §events.subscribe):
// - each subscriber keeps only the most recent `bufferCapacity` deltas;
//   older deltas for a slow consumer are coalesced away (AsyncStream
//   .bufferingNewest).
// - This is lossless for STATE-based consumers because every `agentChanged`
//   delta carries the full AgentSummary — dropping intermediate deltas only
//   skips intermediate revisions, never the current state. Consumers that
//   need every intermediate transition must use the persisted timeline, not
//   the live stream.
// - The shared pump is LONG-LIVED: it idles while zero subscribers remain
//   rather than being torn down and recreated. Cancelling and restarting the
//   pump races with the single-consumer runtime stream — a cancelled pump can
//   consume one more delta before observing cancellation and drop it onto an
//   empty subscriber set. With an idle-at-zero pump, every delta consumed
//   after `subscribe` registered a reader is delivered (dispatch runs under
//   actor isolation); deltas consumed while nobody listens are legitimately
//   droppable under the bufferingNewest contract above.

public actor EventStreamBroker {
    public static let defaultBufferCapacity = 64

    private let streamProvider: @Sendable () async -> AsyncStream<RuntimeDelta>
    private var pump: Task<Void, Never>?
    private var subscribers: [UUID: Subscriber] = [:]

    struct Subscriber {
        let agentFilter: AgentID?
        let continuation: AsyncThrowingStream<AgentSummary, any Error>.Continuation
    }

    public init(streamProvider: @escaping @Sendable () async -> AsyncStream<RuntimeDelta>) {
        self.streamProvider = streamProvider
    }

    /// Stream provider bound to the live runtime.
    public static func provider(for runtime: AgentRuntime) -> @Sendable () async -> AsyncStream<RuntimeDelta> {
        { await runtime.deltaStream() }
    }

    /// Subscribes to `agentChanged` summaries, optionally filtered by agent.
    /// Terminating or deinitializing the returned stream detaches the
    /// subscriber via `onTermination`.
    public func subscribe(agentID: AgentID?) -> AsyncThrowingStream<AgentSummary, any Error> {
        let id = UUID()
        var continuation: AsyncThrowingStream<AgentSummary, any Error>.Continuation!
        let stream = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(Self.defaultBufferCapacity)) { cont in
            continuation = cont
        }
        subscribers[id] = Subscriber(agentFilter: agentID, continuation: continuation)
        ensurePump()

        // Detach on termination regardless of how the consumer ends it.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id: id) }
        }
        return stream
    }

    public func unsubscribe(id: UUID) {
        subscribers[id]?.continuation.finish()
        subscribers[id] = nil
        // The pump intentionally keeps running (idle) at zero subscribers;
        // see the lifecycle note in the header comment.
    }

    /// Test/diagnostics hook: number of live fan-out subscribers.
    public var liveSubscribers: Int {
        subscribers.count
    }

    private func ensurePump() {
        guard pump == nil else { return }
        let provider = streamProvider
        pump = Task { [weak self] in
            let stream = await provider()
            for await delta in stream {
                guard let self else { break }
                await dispatch(delta)
                if Task.isCancelled {
                    break
                }
            }
            // Provider stream ended (runtime gone); drop the dead pump so a
            // future subscribe can start a fresh one.
            await self?.clearPump()
        }
    }

    private func clearPump() {
        pump = nil
        // Race closed here: a subscribe() that ran between the pump loop
        // exiting and this clearPump executing saw `pump != nil` in
        // ensurePump, registered its subscriber, and returned — leaving the
        // subscriber registered with no pump to feed it. Re-arm if any such
        // late subscribers exist. Safe under actor isolation: ensurePump's
        // synchronous section only creates a Task.
        if !subscribers.isEmpty {
            ensurePump()
        }
    }

    private func dispatch(_ delta: RuntimeDelta) {
        // Zero-subscriber fast path: the idle-at-zero pump still consumes
        // (and thereby collapses) deltas — keeping bufferingNewest semantics
        // intact per the header contract — but skips all fan-out work for
        // every runtime delta nobody is listening to.
        guard !subscribers.isEmpty else { return }
        switch delta {
        case let .agentChanged(summary):
            for subscriber in subscribers.values {
                if let filter = subscriber.agentFilter, filter != summary.id {
                    continue
                }
                subscriber.continuation.yield(summary)
            }
        case .agentRemoved:
            break // Removals are surfaced by state consumers via agent.get.
        case .projectionReplaced:
            break // Not fanned out; state readers re-read via agent.get.
        }
    }
}

// MARK: - Race-closed wait (§3.16 agent.wait, steps 1–6)

/// Minimal state projection consumed by the wait algorithm — identical for
/// the initial reads (steps 1/4) and streamed events (step 5).
public struct LifecycleSnapshot: Equatable, Sendable {
    public let stateRevision: UInt64
    public let lifecycle: LifecycleTag

    public init(stateRevision: UInt64, lifecycle: LifecycleTag) {
        self.stateRevision = stateRevision
        self.lifecycle = lifecycle
    }
}

public extension AgentSummary {
    var lifecycleSnapshot: LifecycleSnapshot {
        LifecycleSnapshot(stateRevision: state.revision, lifecycle: LifecycleTag(state.lifecycle))
    }
}

public enum WaitOutcome: Equatable, Sendable {
    case matched(stateRevision: UInt64, lifecycle: LifecycleTag)
    /// Predicate stayed false until the deadline elapsed.
    case timedOut(lastKnownRevision: UInt64?)
    /// Structured cancellation (client disconnect or task cancellation).
    case cancelled
}

public enum WaitError: Error, Equatable {
    case agentNotFound
    /// The state reader itself failed — a broken runtime/store, not a
    /// missing agent. Carries the sanitized error description.
    case readerFailed(String)
}

/// The wait algorithm, implemented once and reused by the router and tests:
///
/// 1. Read the current state.
/// 2. Check the predicate against it.
/// 3. Subscribe to the event stream.
/// 4. RE-check the revision after subscribing (closes the lost-wakeup race:
///    any change between step 1's read and step 3's subscription is already
///    reflected in this second read, so no transition can be missed).
/// 5. Await a matching event or the timeout — event-driven, no polling.
/// 6. On disconnect/cancellation return structured cancellation.
///
/// - Parameters:
///   - targets: closed lifecycle vocabulary; never arbitrary predicates.
///   - minStateRevision: succeed only at revisions >= this value, so callers
///     can require seeing a transition beyond what they already observed.
public func waitForLifecycle(
    targets: Set<LifecycleTag>,
    minStateRevision: UInt64?,
    timeout: Duration?,
    reader: @escaping @Sendable () async throws -> LifecycleSnapshot?,
    events: @escaping @Sendable () async -> AsyncThrowingStream<AgentSummary, any Error>
) async -> Result<WaitOutcome, WaitError> {
    precondition(!targets.isEmpty, "wait predicate must name at least one lifecycle")

    func matches(_ snapshot: LifecycleSnapshot) -> Bool {
        guard targets.contains(snapshot.lifecycle) else { return false }
        if let minStateRevision, snapshot.stateRevision < minStateRevision {
            return false
        }
        return true
    }

    /// Reader wrapper: distinguishes "agent gone" (nil) from reader failure.
    /// Reader failure must not masquerade as agentNotFound.
    func read(_ reader: @escaping @Sendable () async throws -> LifecycleSnapshot?)
        async -> Result<LifecycleSnapshot?, WaitError>
    {
        do {
            return try await .success(reader())
        } catch {
            return .failure(.readerFailed(String(describing: error)))
        }
    }

    // Steps 1–2.
    switch await read(reader) {
    case let .success(initial?):
        if matches(initial) {
            return .success(.matched(stateRevision: initial.stateRevision, lifecycle: initial.lifecycle))
        }
    case .success(nil):
        return .failure(.agentNotFound)
    case let .failure(error):
        return .failure(error)
    }

    // Step 3.
    // Detachment on every exit path: the consuming task's cancellation (or
    // abandoning the stream) fires the broker's onTermination handler.
    let subscription = await events()

    // Step 4 — re-read AFTER subscribing.
    switch await read(reader) {
    case let .success(baseline?):
        if matches(baseline) {
            return .success(.matched(stateRevision: baseline.stateRevision, lifecycle: baseline.lifecycle))
        }
    case .success(nil):
        return .failure(.agentNotFound)
    case let .failure(error):
        return .failure(error)
    }
    // Step 5 — await match or timeout.
    return await withTaskGroup(of: Result<WaitOutcome, WaitError>.self) { group in
        group.addTask {
            do {
                for try await summary in subscription {
                    let snapshot = summary.lifecycleSnapshot
                    if matches(snapshot) {
                        return .success(.matched(
                            stateRevision: snapshot.stateRevision,
                            lifecycle: snapshot.lifecycle
                        ))
                    }
                }
                return .success(.cancelled) // stream finished underneath us
            } catch {
                return .success(.cancelled) // CancellationError et al.
            }
        }
        if let timeout {
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    var lastKnown: UInt64?
                    if let snapshot = try? await reader() {
                        lastKnown = snapshot.stateRevision
                    }
                    return .success(.timedOut(lastKnownRevision: lastKnown))
                } catch {
                    return .success(.cancelled)
                }
            }
        }
        let first = await group.next() ?? .success(.cancelled)
        group.cancelAll()
        return first
    }
}

import Foundation

// RuntimeProjection — read-only snapshots for UI/API consumers (§4.2).

public enum RuntimeProjectionBuilder {
    public static func build(
        sessions: some Collection<AgentSession>,
        generatedAt: MonotonicInstant
    ) -> RuntimeProjection {
        let summaries = sessions
            .sorted {
                $0.createdAt < $1.createdAt
                    || ($0.createdAt == $1.createdAt
                        && $0.id.rawValue.uuidString < $1.id.rawValue.uuidString)
            }
            .map(AgentSummary.init)
        return RuntimeProjection(agents: summaries, generatedAt: generatedAt)
    }
}

/// Subscription handle for RuntimeDelta streams (UI, control plane).
public final class RuntimeDeltaStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<RuntimeDelta>.Continuation?

    public init() {}

    /// Latest-wins, single-consumer subscription (§4.5): a new `stream`
    /// call replaces the stored continuation — the previous consumer stops
    /// receiving deltas but is NOT finished behind its back (only the
    /// active one gets finish()). Multi-consumer fan-out is
    /// EventStreamBroker's job.
    public var stream: AsyncStream<RuntimeDelta> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    public func yield(_ delta: RuntimeDelta) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(delta)
    }

    public func finish() {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.finish()
    }
}

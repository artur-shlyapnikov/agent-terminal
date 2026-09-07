import Foundation

// commandID-keyed recent-result cache (architecture §3.16).
//
// Every request that carries a `commandID` is idempotency-keyed: a retry with
// the same commandID returns the cached response verbatim instead of
// re-executing — most importantly, `agent.prompt` MUST NOT deliver twice.
// Bounded by both entry count and TTL; eviction is least-recently-put-first.
//
// Correctness note: request processing on a single connection is serial, but
// duplicates can arrive on OTHER connections while the original request is
// still executing. That in-flight window is closed by ControlRequestRouter's
// per-commandID in-flight guard (architecture §3.16); this cache covers
// post-response replays — once the first result is cached, later duplicates
// are answered from here verbatim.

public actor IdempotencyCache {
    struct Entry {
        let response: Data
        let insertedAt: ContinuousClock.Instant
    }

    public let capacity: Int
    public let ttl: Duration

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    /// Puts since the last exhaustive TTL sweep (see `trim`).
    private var putsSinceSweep = 0

    /// Full sweeps cost O(entries), so they run at most once per this many
    /// puts — bounding how long expired leftovers linger under capacity.
    private static let sweepInterval = 256

    public init(capacity: Int = 1024, ttl: Duration = .seconds(300)) {
        self.capacity = max(1, capacity)
        self.ttl = ttl
    }

    /// Cached encoded response line for this commandID, if fresh.
    public func get(_ commandID: String) -> Data? {
        guard let entry = entries[commandID] else { return nil }
        let now = ContinuousClock.now
        if entry.insertedAt.duration(to: now) > ttl || entry.insertedAt > now {
            remove(commandID)
            return nil
        }
        return entry.response
    }

    public func put(_ commandID: String, _ encodedResponse: Data) {
        let now = ContinuousClock.now
        if entries[commandID] == nil {
            insertionOrder.append(commandID)
        } else {
            // Refresh repositions the key at the tail: with a constant TTL,
            // recency-of-put IS expiry order, so the head of `insertionOrder`
            // is always the next entry to expire. Without this, a refreshed
            // key would keep its stale position and could be evicted while
            // still fresh — a retried commandID would then re-execute.
            insertionOrder.removeAll { $0 == commandID }
            insertionOrder.append(commandID)
        }
        entries[commandID] = Entry(response: encodedResponse, insertedAt: now)
        putsSinceSweep += 1
        trim(now: now)
    }

    public func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
    }

    public var count: Int {
        entries.count
    }

    private func remove(_ commandID: String) {
        entries[commandID] = nil
        if let index = insertionOrder.firstIndex(of: commandID) {
            insertionOrder.remove(at: index)
        }
    }

    /// Eviction policy: least-recently-put-first for capacity, TTL for freshness.
    ///
    /// The steady-state path is amortized O(1): over capacity, pop from the
    /// HEAD of `insertionOrder`. Because `put` repositions refreshed keys at
    /// the tail and the TTL is constant, insertion/put order mirrors expiry
    /// order exactly — the head is always the staler entry, so capacity
    /// eviction can never discard a still-fresh entry ahead of a staler one.
    ///
    /// Full sweeps are the exception: they cost O(entries), so they run at
    /// most once per `sweepInterval` puts, bounding how long expired
    /// leftovers linger under capacity. Replay behavior is unaffected either
    /// way: `get` enforces the TTL per entry and drops what it finds stale.
    private func trim(now: ContinuousClock.Instant) {
        var sawFreshHead = false
        while insertionOrder.count > capacity {
            let oldest = insertionOrder.removeFirst()
            if let entry = entries.removeValue(forKey: oldest),
               entry.insertedAt <= now, entry.insertedAt.duration(to: now) <= ttl
            {
                sawFreshHead = true
            }
        }
        guard sawFreshHead || putsSinceSweep >= Self.sweepInterval else { return }
        // Collect expired keys before removing: mutating `insertionOrder`
        // while iterating it would invalidate indices and skip entries.
        var expired = Set<String>()
        for key in insertionOrder {
            guard let entry = entries[key] else { continue }
            if entry.insertedAt > now || entry.insertedAt.duration(to: now) > ttl {
                expired.insert(key)
            }
        }
        guard !expired.isEmpty else { return }
        insertionOrder.removeAll { expired.contains($0) }
        for key in expired {
            entries[key] = nil
        }
    }
}

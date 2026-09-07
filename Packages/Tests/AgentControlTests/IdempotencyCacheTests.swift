@testable import AgentControl
import Foundation
import XCTest

/// Regression tests for the C3 fix: `put` on an EXISTING key must reposition
/// it in the eviction order. Before the fix, a refreshed key kept its stale
/// head position and `trim` could evict it while still fresh — a retried
/// commandID would then re-execute (exactly-once violation for agent.prompt).
final class IdempotencyCacheTests: XCTestCase {
    private func data(_ s: String) -> Data {
        Data(s.utf8)
    }

    // Refresh-then-trim: A is refreshed after B was inserted, so B must be
    // evicted when capacity overflows — never A, even though A was inserted
    // first.
    func testRefreshedEntrySurvivesCapacityEviction() async {
        let cache = IdempotencyCache(capacity: 2)
        await cache.put("a", data("ra"))
        await cache.put("b", data("rb"))
        await cache.put("a", data("ra2")) // refresh moves a to most-recent
        await cache.put("c", data("rc")) // overflow: b must be evicted

        let count = await cache.count
        XCTAssertEqual(count, 2)
        let a = await cache.get("a")
        XCTAssertEqual(a, data("ra2"), "refreshed entry must survive")
        let c = await cache.get("c")
        XCTAssertEqual(c, data("rc"))
        let b = await cache.get("b")
        XCTAssertNil(b, "staler entry must be evicted first")
    }

    /// Eviction order is deterministic least-recently-put-first: repeated
    /// refreshes of one key keep pinning it while untouched keys drain from
    /// the head in insertion order.
    func testEvictionOrderIsDeterministicLRU() async {
        let cache = IdempotencyCache(capacity: 3)
        await cache.put("k1", data("1"))
        await cache.put("k2", data("2"))
        await cache.put("k3", data("3"))
        await cache.put("k1", data("1r")) // k1 refreshed

        await cache.put("k4", data("4"))
        let k2 = await cache.get("k2")
        XCTAssertNil(k2)
        await cache.put("k5", data("5"))
        let k3 = await cache.get("k3")
        XCTAssertNil(k3)

        let k1 = await cache.get("k1")
        XCTAssertEqual(k1, data("1r"))
        let k4 = await cache.get("k4")
        XCTAssertEqual(k4, data("4"))
        let k5 = await cache.get("k5")
        XCTAssertEqual(k5, data("5"))
    }

    /// Capacity bound holds across many puts with interleaved refreshes.
    func testCountNeverExceedsCapacity() async {
        let cache = IdempotencyCache(capacity: 8)
        for i in 0 ..< 100 {
            await cache.put("key\(i % 10)", data("\(i)"))
            let count = await cache.count
            XCTAssertLessThanOrEqual(count, 8)
            XCTAssertGreaterThanOrEqual(count, 1)
        }
    }
}

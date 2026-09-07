import AgentCore
@testable import AgentTerminal
import XCTest

// Round-3 Suite K (R3-6): RealtimeClockDriver pulls the shared domain clock
// monotonically forward to real DispatchTime, and stop() halts advancement.

@MainActor
final class RealtimeClockDriverTests: XCTestCase {
    /// Bounded polling, no settles.
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

    func testDriverPullsClockForwardAndStopHaltsAdvancement() async throws {
        let clock = FakeClock()
        let driver = RealtimeClockDriver(clock: clock) // default 250 ms heartbeat
        defer { driver.stop() }

        // Monotonic FORWARD pull: an inverted or stalled driver fails here.
        let baseline = clock.now
        await waitUntil { clock.now > baseline }
        XCTAssertGreaterThan(clock.now, baseline, "driver must pull the clock forward")

        driver.stop()
        // An event already dispatched before cancel() may still land once.
        // Bounded-poll until the current sample has held steady for ≥300 ms
        // a straggler in-flight fire can land shortly after cancel() and
        // falsely read "frozen". Sustained agreement proves the in-flight
        // fire has drained and the clock is genuinely stopped (no fixed
        // sleep; the only permitted real sleep is the absence proof below).
        var frozen = clock.now
        var frozenSince = Date()
        await waitUntil(timeout: 2) {
            let sample = clock.now
            if sample != frozen {
                frozen = sample
                frozenSince = Date()
                return false
            }
            return Date().timeIntervalSince(frozenSince) >= 0.3
        }

        // Absence proof: well over one heartbeat period of real time delivers
        // nothing further from the cancelled event source (the suite's only
        // permitted sleep).
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(clock.now, frozen, "cancelled driver must not advance the clock")
    }

    func testDriverWakesSleeperNearVirtualDeadline() async {
        let clock = FakeClock()
        let driver = RealtimeClockDriver(clock: clock)
        defer { driver.stop() }

        // Let the driver pull the clock to real monotonic time first: a
        // sleeper registered against the zero epoch would be jumped over by
        // the first pull (FakeClock's domain is monotonic-since-boot).
        let baseline = clock.now
        await waitUntil { clock.now > baseline }

        // Deadline-driven wakeup: the one-shot fires at the sleeper's virtual
        // deadline (± scheduling jitter) — and crucially fires at all (a
        // broken arm/registration-hook pair would hang here forever).
        let woke = expectation(description: "sleeper resumed at virtual deadline")
        let start = Date()
        let task = Task {
            await clock.sleep(for: .seconds(1))
            woke.fulfill()
        }
        await fulfillment(of: [woke], timeout: 5)
        let elapsed = Date().timeIntervalSince(start)
        // Lower bound tolerates registering just before a heartbeat fire
        // (virtual lag ≤ one heartbeat cancels out of the wake time).
        XCTAssertGreaterThan(elapsed, 0.7, "sleeper must not resume before its virtual deadline")
        XCTAssertLessThan(elapsed, 2.5, "sleeper must resume near its deadline, not heartbeats late")
        task.cancel()
    }
}

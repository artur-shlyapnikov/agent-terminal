import AgentCore
import Foundation
import XCTest

// Deadline-driven production drivers (RealtimeClockDriver) schedule one real
// wakeup per virtual deadline: nanosecondsUntilNextWakeup() exposes the
// earliest parked deadline, and onSleeperRegistered fires when a sleeper
// joins the queue — the only event that can move that deadline earlier while
// real time flows.

final class FakeClockWakeupTests: XCTestCase {
    private final class LockedBox<T> {
        private let lock = NSLock()
        private var value: T
        init(_ initial: T) {
            value = initial
        }

        var wrapped: T {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }

    /// Bounded park-wait: fails instead of hanging when a sleeper never parks.
    private func awaitPark(count target: Int, on clock: FakeClock) async {
        var spins = 0
        while clock.parkedSleeperCount < target, spins < 10000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertEqual(clock.parkedSleeperCount, target, "sleepers must park")
    }

    func testNextWakeupTracksEarliestParkedSleeper() async {
        let clock = FakeClock()
        XCTAssertNil(clock.nanosecondsUntilNextWakeup(), "no sleepers parked yet")

        let slow = Task { await clock.sleep(for: .seconds(5)) }
        let fast = Task { await clock.sleep(for: .seconds(2)) }
        await awaitPark(count: 2, on: clock)
        XCTAssertEqual(
            clock.nanosecondsUntilNextWakeup(), 2_000_000_000,
            "the earliest deadline wins regardless of registration order"
        )

        clock.advance(by: .seconds(2))
        _ = await fast.value
        XCTAssertEqual(clock.nanosecondsUntilNextWakeup(), 3_000_000_000)

        clock.advance(by: .seconds(3))
        _ = await slow.value
        XCTAssertNil(clock.nanosecondsUntilNextWakeup(), "queue drains back to empty")
    }

    func testSleeperRegistrationFiresHookExactlyOncePerParkedSleeper() async {
        let clock = FakeClock()
        let registrations = LockedBox(0)
        clock.onSleeperRegistered = { registrations.wrapped += 1 }

        let task = Task { await clock.sleep(for: .milliseconds(10)) }
        await awaitPark(count: 1, on: clock)
        clock.advance(by: .milliseconds(10))
        _ = await task.value
        XCTAssertEqual(registrations.wrapped, 1, "one parked registration fires the hook once")

        // Already-due sleeps take the immediate-resume path and never park,
        // so they must not fire the hook.
        await clock.sleep(for: .zero)
        XCTAssertEqual(registrations.wrapped, 1)

        clock.onSleeperRegistered = nil
    }
}

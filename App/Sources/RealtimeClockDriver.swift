import AgentCore
import Foundation

// Production timing adapter (stage 8): AgentRuntime, DetectionScheduler and
// ScreenDetectionEngine all take the domain FakeClock for determinism. In the
// real app a lightweight driver advances that clock to the true monotonic
// time, so watchdogs, grace periods and detection cadences run on wall-clock
// time while tests keep full control.
//
// Deadline-driven, not fixed-cadence: one real wakeup is scheduled for the
// earliest parked sleeper (virtual sleeps mature on time), capped by a slow
// heartbeat that keeps `now()` fresh for event-driven readers when nothing
// sleeps. Idle wakeups drop from ~50/s (20 ms polling) to ≤4/s, and sleepers
// resume at their deadline instead of up to one poll interval late.
//
// DispatchTime is monotonic and never goes backwards, satisfying FakeClock's
// advance-only precondition.

final class RealtimeClockDriver: @unchecked Sendable {
    private let clock: FakeClock
    private let queue: DispatchQueue
    /// Upper bound on how long `now()` may lag real time while nothing sleeps;
    /// also the resync cadence while waiting out far deadlines.
    private let heartbeatNanoseconds: Int64

    private let stateLock = NSLock()
    private var running = true
    private var timer: DispatchSourceTimer?
    /// Real delay the armed timer was scheduled with; `.max` when disarmed.
    /// Lets the registration hook skip redundant cancel/reschedule churn.
    private var armedDelayNanoseconds = Int64.max

    /// - parameter heartbeat: resync cadence. 250 ms keeps event-driven
    ///   `now()` reads (evidence timestamps, diagnostics) accurate to a
    ///   quarter second at a quarter of the old wakeup rate.
    init(clock: FakeClock, heartbeat: DispatchTimeInterval = .milliseconds(250)) {
        self.clock = clock
        queue = DispatchQueue.global(qos: .utility)
        heartbeatNanoseconds = Self.nanoseconds(of: heartbeat)
        clock.onSleeperRegistered = { [weak self] in self?.sleeperRegistered() }
        arm()
    }

    func stop() {
        clock.onSleeperRegistered = nil
        stateLock.lock()
        running = false
        timer?.cancel()
        timer = nil
        armedDelayNanoseconds = .max
        stateLock.unlock()
    }

    // MARK: arming

    /// Schedules the next wakeup: the earlier of the earliest sleeper
    /// deadline and the heartbeat. Runs on init, after each fire, and from
    /// the registration hook; safe from any thread.
    private func arm() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running else { return }
        let delay = min(clock.nanosecondsUntilNextWakeup() ?? .max, heartbeatNanoseconds)
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(delay)))
        timer.setEventHandler { [weak self] in self?.fire() }
        timer.resume()
        self.timer = timer
        armedDelayNanoseconds = delay
    }

    /// A newly registered sleeper may mature before the currently armed
    /// wakeup; re-arm only when it actually lands earlier (steady-state
    /// registrations are no-ops here).
    private func sleeperRegistered() {
        guard let delay = clock.nanosecondsUntilNextWakeup() else { return }
        stateLock.lock()
        let armed = armedDelayNanoseconds
        stateLock.unlock()
        if delay < armed {
            arm()
        }
    }

    private func fire() {
        // Pull the virtual clock to real monotonic time; wakes every due
        // sleeper (resumed outside the clock lock, in deadline order).
        clock.advance(to: MonotonicInstant(
            nanosecondsSinceEpoch: Int64(DispatchTime.now().uptimeNanoseconds)
        ))
        arm()
    }

    private static func nanoseconds(of interval: DispatchTimeInterval) -> Int64 {
        switch interval {
        case let .seconds(s): Int64(s) * 1_000_000_000
        case let .milliseconds(ms): Int64(ms) * 1_000_000
        case let .microseconds(us): Int64(us) * 1000
        case let .nanoseconds(ns): Int64(ns)
        case .never: .max
        @unknown default: .max
        }
    }
}

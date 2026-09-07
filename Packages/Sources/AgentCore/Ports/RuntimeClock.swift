import Foundation

// Injectable monotonic clock (architecture §4.2 Ports/RuntimeClock).
//
// All timing-sensitive domain logic (debounce, hysteresis, watchdog, grace
// periods) reads time exclusively through this port so tests stay deterministic.
// The concrete type used across the domain is FakeClock: production wiring can
// wrap ContinuousClock behind the same interface later.

public protocol RuntimeClock: Sendable {
    associatedtype InstantType: Comparable & Sendable
    /// Monotonic current instant.
    func currentInstant() -> InstantType
}

/// Production clock: monotonic since boot, immune to wall-clock changes.
public struct ContinuousRuntimeClock: RuntimeClock {
    public init() {}
    public func currentInstant() -> MonotonicInstant {
        MonotonicInstant(nanosecondsSinceEpoch: Int64(DispatchTime.now().uptimeNanoseconds))
    }
}

/// Fully controllable clock for tests. `advance(by:)` moves virtual time and
/// wakes every sleeper whose deadline has arrived — no real sleeping.
public final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentNanoseconds: Int64 = 0
    private var sleepers: [Sleeper] = []
    private var sleeperSequence: UInt64 = 0

    private struct Sleeper {
        let deadlineNanoseconds: Int64
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    public init(startingAt: Duration = .zero) {
        currentNanoseconds = Self.nanoseconds(of: startingAt)
    }

    // MARK: Reading time

    public var now: MonotonicInstant {
        Self.instant(nanoseconds: current())
    }

    public var currentTime: Duration {
        .nanoseconds(current())
    }

    /// Test hook: number of sleepers currently parked awaiting a virtual advance.
    /// Lets tests verify the arm-before-advance discipline deterministically
    /// (a detached sleeper that starts late computes its deadline from the
    /// already-advanced clock and would park past the horizon forever).
    public var parkedSleeperCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sleepers.count
    }

    // MARK: Wakeup scheduling (production clock drivers)

    /// Nanoseconds until the earliest parked sleeper matures in this clock's
    /// domain, clamped at zero; nil when nothing is parked. Deadline-driven
    /// production drivers schedule one real wakeup per virtual deadline
    /// instead of polling the clock at a fixed cadence.
    public func nanosecondsUntilNextWakeup() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let first = sleepers.first else { return nil }
        return max(0, first.deadlineNanoseconds - currentNanoseconds)
    }

    /// Fired (outside the clock lock) after a sleeper joins the queue — the
    /// only event that can move the earliest deadline earlier while real time
    /// flows. Production drivers re-arm their wakeup here; tests leave it nil.
    private var registeredHook: (() -> Void)?
    public var onSleeperRegistered: (() -> Void)? {
        get { lock.withLock { registeredHook } }
        set { lock.withLock { registeredHook = newValue } }
    }

    private func current() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return currentNanoseconds
    }

    // MARK: Advancing

    /// Advances virtual time and resumes due sleepers in deadline order.
    public func advance(by duration: Duration) {
        advanceTo(current() + Self.nanoseconds(of: duration))
    }

    public func advance(to target: MonotonicInstant) {
        advanceTo(Self.nanoseconds(sinceEpoch: target))
    }

    private func advanceTo(_ target: Int64) {
        lock.lock()
        precondition(target >= currentNanoseconds, "FakeClock cannot move backwards")
        currentNanoseconds = target

        var due: [Sleeper] = []
        while let first = sleepers.first, first.deadlineNanoseconds <= target {
            sleepers.removeFirst()
            due.append(first)
        }
        lock.unlock()

        // Resume outside the lock, in deadline order.
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    // MARK: Sleeping

    /// Sleeps until the virtual deadline elapses. Deterministic under `advance`.
    public func sleep(for duration: Duration) async {
        await sleepUntil(current() + Self.nanoseconds(of: max(.zero, duration)))
    }

    public func sleep(until deadline: MonotonicInstant) async {
        await sleepUntil(Self.nanoseconds(sinceEpoch: deadline))
    }

    private func sleepUntil(_ deadline: Int64) async {
        if lock.withLock({ currentNanoseconds >= deadline }) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !registerSleeper(deadline: deadline, continuation: continuation) {
                // advance() moved time past our deadline between the fast-path
                // check and registration — resume immediately, never hang.
                continuation.resume()
            }
        }
    }

    /// Atomically enqueues a sleeper. Runs fully under the clock lock so a
    /// concurrent advance() either wakes us later or finds us already due.
    /// Synchronous on purpose: `NSLock` lock/unlock are unavailable from async
    /// contexts (Swift 6 error), and atomicity forbids dropping the lock before
    /// the sleeper is inserted into the ordered queue.
    private func registerSleeper(deadline: Int64, continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        if currentNanoseconds >= deadline {
            lock.unlock()
            return false
        }
        sleeperSequence += 1
        let sequence = sleeperSequence
        let sleeper = Sleeper(
            deadlineNanoseconds: deadline,
            sequence: sequence,
            continuation: continuation
        )
        // Keep sleepers ordered by (deadline, sequence).
        let index = sleepers.firstIndex { $0.deadlineNanoseconds > deadline } ?? sleepers.count
        sleepers.insert(sleeper, at: index)
        let hook = registeredHook
        lock.unlock()
        // Outside the lock: the driver may re-arm immediately (taking its own
        // locks). The sleeper is already visible to a concurrent advance(), so
        // a wakeup racing this hook stays correct either way.
        hook?()
        return true
    }

    // MARK: Conversion helpers

    static func nanoseconds(of duration: Duration) -> Int64 {
        let components = duration.components
        return Int64(components.seconds) &* 1_000_000_000
            &+ Int64(components.attoseconds / 1_000_000_000)
    }

    /// Nanoseconds relative to the zero epoch used by this clock. Instants are
    /// only ever produced by this same clock, so the offset is stable.
    static func nanoseconds(sinceEpoch instant: MonotonicInstant) -> Int64 {
        instant.nanosecondsSinceEpoch
    }

    static func instant(nanoseconds value: Int64) -> MonotonicInstant {
        MonotonicInstant(nanosecondsSinceEpoch: value)
    }
}

extension FakeClock: RuntimeClock {
    public typealias InstantType = MonotonicInstant
    public func currentInstant() -> MonotonicInstant {
        now
    }
}

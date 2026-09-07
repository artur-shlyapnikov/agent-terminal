import Foundation

// DetectionScheduler (architecture §3.7): debounces render events and applies
// the adaptive evaluation cadence. Actor-isolated; all timing goes through the
// injectable clock so tests are deterministic.

public actor DetectionScheduler {
    /// Debounce applied to every output revision change (§3.7 step 2).
    public static let debounceInterval: Duration = .milliseconds(150)

    /// Upper bound on a single runLoop sleep: schedules that become due
    /// earlier mid-sleep are picked up within one quantum instead of after
    /// a stale far-future target.
    static let maxSleepQuantum: Duration = .milliseconds(250)

    public enum Cadence {
        public static let visibleWorkingOrUnknownHz: Double = 4.0
        public static let hiddenWorkingOrUnknownHz: Double = 2.0
        public static let idleHz: Double = 0.5
        public static let waitingHz: Double = 1.0

        /// Maximum screen-evaluation frequency for the current state (§3.7
        /// frequency table). `nil` means detection is off (stopped agents).
        public static func hz(for lifecycle: LifecyclePhase, isVisible: Bool) -> Double? {
            switch lifecycle {
            case .stopped:
                nil
            case .idle:
                idleHz
            case .waitingForInput:
                // 1 Hz until the state changes.
                waitingHz
            case .working, .starting, .unknown, .stopping, .failed:
                isVisible ? visibleWorkingOrUnknownHz : hiddenWorkingOrUnknownHz
            }
        }

        /// Interval between periodic evaluations; nil when detection is off.
        public static func interval(for lifecycle: LifecyclePhase, isVisible: Bool) -> Duration? {
            guard let hz = hz(for: lifecycle, isVisible: isVisible) else { return nil }
            return .nanoseconds(Int64(1_000_000_000.0 / hz))
        }
    }

    private let clock: FakeClock

    /// Called on the actor when a terminal's screen should be evaluated.
    private var onEvaluationDue: (@Sendable (TerminalID) -> Void)?

    /// Per-terminal scheduling state.
    private struct ScheduleState {
        var pendingDebounce: MonotonicInstant?
        var cadenceInterval: Duration?
        var nextCadenceTick: MonotonicInstant?
    }

    private var schedules: [TerminalID: ScheduleState] = [:]
    private var loopStarted = false

    /// Non-nil exactly while the run loop is parked waiting for a schedule
    /// mutation; mutations yield to it so the loop wakes promptly instead of
    /// spinning while nothing is due.
    private var idleWake: AsyncStream<Void>.Continuation?

    public init(clock: FakeClock) {
        self.clock = clock
    }

    public func setHandler(_ handler: @escaping @Sendable (TerminalID) -> Void) {
        onEvaluationDue = handler
    }

    /// A render / process event increased the output revision: schedule a
    /// debounced evaluation (§3.7 steps 1–2).
    public func outputRevisionChanged(terminalID: TerminalID) {
        var state = schedules[terminalID] ?? ScheduleState()
        state.pendingDebounce = clock.now + Self.debounceInterval
        schedules[terminalID] = state
        signalScheduleChange()
        ensureLoop()
    }

    /// The agent lifecycle or visibility changed: recompute the cadence.
    public func lifecycleChanged(terminalID: TerminalID, lifecycle: LifecyclePhase, isVisible: Bool) {
        var state = schedules[terminalID] ?? ScheduleState()
        state.cadenceInterval = Cadence.interval(for: lifecycle, isVisible: isVisible)
        state.nextCadenceTick = state.cadenceInterval.map { clock.now + $0 }
        schedules[terminalID] = state
        signalScheduleChange()
        ensureLoop()
    }

    /// After a prompt delivery: evaluate immediately, then resume normal
    /// debounce behavior (§3.7 "После prompt").
    public func promptSent(terminalID: TerminalID) {
        var state = schedules[terminalID] ?? ScheduleState()
        if let handler = onEvaluationDue {
            handler(terminalID)
        }
        state.nextCadenceTick = state.cadenceInterval.map { clock.now + $0 }
        schedules[terminalID] = state
        signalScheduleChange()
        ensureLoop()
    }

    public func forget(terminalID: TerminalID) {
        schedules[terminalID] = nil
        signalScheduleChange()
    }

    // MARK: Loop

    private func ensureLoop() {
        guard !loopStarted else { return }
        loopStarted = true
        Task { await runLoop() }
    }

    private func runLoop() async {
        while !schedules.isEmpty {
            guard let due = nextDueInstant() else {
                // Schedules exist but nothing is due yet (e.g. cadence off):
                // park until a mutation signals new work.
                await awaitScheduleChange()
                continue
            }
            await clock.sleep(until: min(due, clock.now + Self.maxSleepQuantum))
            fireDue(now: clock.now)
        }
        // Allow a fresh loop when new schedules appear later.
        loopStarted = false
    }

    private func nextDueInstant() -> MonotonicInstant? {
        var earliest: MonotonicInstant?
        for state in schedules.values {
            for candidate in [state.pendingDebounce, state.nextCadenceTick].compactMap({ $0 }) {
                if earliest == nil || candidate < earliest! {
                    earliest = candidate
                }
            }
        }
        return earliest
    }

    private func fireDue(now: MonotonicInstant) {
        guard let handler = onEvaluationDue else { return }

        // Snapshot first: never mutate `schedules` while iterating it.
        var debounceHits: [TerminalID] = []
        var cadenceHits: [(TerminalID, Duration)] = []
        for (terminalID, state) in schedules {
            if let pending = state.pendingDebounce, pending <= now {
                debounceHits.append(terminalID)
            } else if let tick = state.nextCadenceTick, tick <= now,
                      let interval = state.cadenceInterval
            {
                cadenceHits.append((terminalID, interval))
            }
        }
        for terminalID in debounceHits {
            schedules[terminalID]?.pendingDebounce = nil
            handler(terminalID)
        }
        for (terminalID, interval) in cadenceHits {
            schedules[terminalID]?.nextCadenceTick = now + interval
            handler(terminalID)
        }
    }

    /// Parks the run loop until the next schedule mutation. A mutator that
    /// runs between the caller's `nextDueInstant() == nil` check and the
    /// installation of `idleWake` below could otherwise signal a nil
    /// continuation and lose its yield; therefore, after installing
    /// `idleWake` (atomically with respect to all other actor work), we
    /// re-check `nextDueInstant()` and return immediately when an instant
    /// is already due — the loop recomputes instead of parking on a stream
    /// nobody will signal.
    private func awaitScheduleChange() async {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { continuation = $0 }
        idleWake = continuation
        defer { idleWake = nil }
        if nextDueInstant() != nil {
            return
        }
        for await _ in stream {
            break
        }
    }

    /// Wakes the run loop when it is parked in `awaitScheduleChange()`.
    private func signalScheduleChange() {
        idleWake?.yield()
    }
}

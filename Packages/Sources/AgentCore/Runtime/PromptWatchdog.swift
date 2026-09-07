import Foundation

// PromptWatchdog (architecture §3.11).
//
// After a prompt is delivered:
// 1. record lifecycle revision and output revision;
// 2–3. deliver text + Return (the terminal port does this);
// 4. arm a 5-second watchdog;
// 5. delivery is CONFIRMED when any of:
//      - output revision changed,
//      - lifecycle transitioned to working,
//      - an integration confirmed operation start;
// 6. otherwise record `promptDeliveryUnconfirmed`;
// 7. NEVER auto-retry.

public actor PromptWatchdog {
    public static let confirmationTimeout: Duration = .seconds(5)

    public enum ConfirmSignal: Equatable, Sendable {
        case outputRevisionChanged
        case lifecycleBecameWorking
        case integrationOperationStart
    }

    public enum Outcome: Equatable, Sendable {
        case confirmed(ConfirmSignal)
        case timedOut
    }

    private struct PendingWatch {
        let commandID: CommandID
        /// Monotonic counter distinguishing successive watches for the same
        /// command ID; a superseded watch's deadline task must not resolve
        /// its replacement.
        let generation: Int
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private let clock: FakeClock
    private var pending: PendingWatch?
    private var pendingGeneration = 0
    /// Insertion-ordered cap on early confirmations: signals for command IDs
    /// that are never watched (stale/abandoned commands) must not grow the
    /// buffer without bound. Oldest entries are evicted past the cap.
    /// Entries are also bound to ONE delivery generation: a new delivery of
    /// the same command ID invalidates them (see
    /// `invalidateBufferedConfirmation`) so a late signal of a previous
    /// delivery can never falsely confirm the successor watch.
    static let earlyConfirmationBufferLimit = 16
    private var earlyConfirmations: [CommandID: ConfirmSignal] = [:]
    private var earlyConfirmationOrder: [CommandID] = []

    /// Test/diagnostic hook: how many confirmations are currently buffered.
    var bufferedEarlyConfirmationCount: Int {
        earlyConfirmations.count
    }

    public init(clock: FakeClock) {
        self.clock = clock
    }

    /// True when a watch is armed (or already satisfied) for this command.
    public func isWatching(commandID: CommandID) -> Bool {
        pending?.commandID == commandID || earlyConfirmations[commandID] != nil
    }

    /// Arms the watchdog for one delivered prompt. Suspends until a
    /// confirmation signal or the 5-second deadline elapses on the clock.
    public func watch(commandID: CommandID) async -> Outcome {
        if let signal = takeEarlyConfirmation(for: commandID) {
            return .confirmed(signal)
        }

        let clock = clock
        let deadline = clock.now + Self.confirmationTimeout

        return await withCheckedContinuation { continuation in
            // Safety net: a still-pending leftover (the runtime normally
            // supersedes via `supersedePending` before rearming) must never
            // leak its continuation.
            if let leftover = pending {
                pending = nil
                leftover.continuation.resume(returning: .timedOut)
            }
            pendingGeneration += 1
            let generation = pendingGeneration
            pending = PendingWatch(
                commandID: commandID,
                generation: generation,
                continuation: continuation
            )
            Task { [weak self] in
                await clock.sleep(until: deadline)
                await self?.resolveDeadline(commandID: commandID, generation: generation)
            }
        }
    }

    /// Runtime hook: resolves a still-pending watch as `.timedOut` and
    /// reports WHICH command it belonged to, so AgentRuntime can record
    /// §3.11 rule 6 (`promptDeliveryUnconfirmed`) for the displaced prompt
    /// BEFORE overwriting the DeliveryWatch slot — the displaced watch's own
    /// timeout resolution would be silently dropped once the slot no longer
    /// names it. Returns nil when nothing was pending.
    public func supersedePending() -> CommandID? {
        guard let leftover = pending else { return nil }
        pending = nil
        leftover.continuation.resume(returning: .timedOut)
        return leftover.commandID
    }

    /// Drops any buffered early confirmation for the command. Called when a
    /// NEW delivery of the same commandID is made (§3.11): signals buffered
    /// before that delivery belong to the PREVIOUS delivery generation and
    /// must never satisfy the upcoming watch.
    public func invalidateBufferedConfirmation(for commandID: CommandID) {
        guard earlyConfirmations[commandID] != nil else { return }
        earlyConfirmations[commandID] = nil
        earlyConfirmationOrder.removeAll { $0 == commandID }
    }

    /// Any confirmation signal confirms delivery exactly once. A signal for a
    /// watch that has not armed yet is buffered and consumed at arm time.
    public func confirm(_ signal: ConfirmSignal, for commandID: CommandID) {
        guard let watch = pending, watch.commandID == commandID else {
            bufferEarlyConfirmation(signal, for: commandID)
            return
        }
        pending = nil
        watch.continuation.resume(returning: .confirmed(signal))
    }

    private func bufferEarlyConfirmation(_ signal: ConfirmSignal, for commandID: CommandID) {
        guard earlyConfirmations[commandID] == nil else {
            earlyConfirmations[commandID] = signal
            return
        }
        earlyConfirmationOrder.append(commandID)
        if earlyConfirmationOrder.count > Self.earlyConfirmationBufferLimit {
            let evicted = earlyConfirmationOrder.removeFirst()
            earlyConfirmations[evicted] = nil
        }
        earlyConfirmations[commandID] = signal
    }

    private func takeEarlyConfirmation(for commandID: CommandID) -> ConfirmSignal? {
        guard let signal = earlyConfirmations.removeValue(forKey: commandID) else { return nil }
        earlyConfirmationOrder.removeAll { $0 == commandID }
        return signal
    }

    private func resolveDeadline(commandID: CommandID, generation: Int) {
        guard let watch = pending, watch.commandID == commandID, watch.generation == generation else { return }
        pending = nil
        // Drop any buffered early confirmation for the timed-out command:
        // a later retry of the same commandID must not be satisfied by the
        // stale signal of a prompt that was never delivered.
        earlyConfirmations[commandID] = nil
        earlyConfirmationOrder.removeAll { $0 == commandID }
        watch.continuation.resume(returning: .timedOut)
    }
}

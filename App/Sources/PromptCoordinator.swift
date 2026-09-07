import AgentCore
import Foundation

// Stage-9 prompt orchestration (architecture §3.9 initial-prompt rules,
// §3.11 watchdog surfacing). App-level coordination that the pure runtime
// deliberately does NOT own:
//
//  1. When-ready initial prompts: `createAgent(initialPrompt:)` registers an
//     EPHEMERAL pending prompt delivered through the real runtime at the
//     FIRST VALIDATED idle (projection lifecycle only becomes idle through
//     validated screen/integration evidence ingestion). The 30 s timeout
//     NEVER blind-sends — the text returns to the composer draft. The text
//     lives only in this coordinator's memory: nothing persists or logs it
//     (timeline events carry commandIDs, never text).
//
//  2. Delivery-watchdog surfacing: after a sendNow delivery the runtime arms
//     its 5-second watchdog internally; if it resolves unconfirmed it records
//     `promptDeliveryUnconfirmed` in the timeline. This coordinator polls the
//     timeline for that event and lifts the state into the UI model. There is
//     NO auto-retry anywhere (§3.11 rule 7) — surfacing is the only reaction.

@MainActor
final class PromptCoordinator {
    static let initialPromptTimeout: Duration = .seconds(30)
    /// The runtime's own watchdog times out at 5 s; poll a little past it.
    static let unconfirmedPollWindow: Duration = .seconds(6)
    /// Phase-1 bound: how long to wait for the FIRST observation of the
    /// delivery watch arming before giving up (flag stays unset).
    static let armObservationWindow: Duration = .seconds(30)

    private struct PendingInitialPrompt {
        let text: String
        let queuedAt: MonotonicInstant
    }

    private let runtime: AgentRuntime
    private let clock: FakeClock
    private weak var model: AppModel?

    /// Restore path for an undelivered initial prompt: fired when the 30 s
    /// timeout expires or when delivery throws. Either way the text returns
    /// to the composer draft (§3.9) — never a blind send.
    var onInitialPromptTimeout: ((AgentID, String) -> Void)?

    private var pendingInitial: [AgentID: PendingInitialPrompt] = [:]

    init(runtime: AgentRuntime, clock: FakeClock, model: AppModel?) {
        self.runtime = runtime
        self.clock = clock
        self.model = model
    }

    // MARK: 1. When-ready initial prompts (§3.9 bottom)

    /// Registers the ephemeral initial prompt for a freshly created agent.
    /// Delivery happens at the first VALIDATED idle; until then nothing is
    /// written to the terminal, the store, or the timeline.
    func scheduleInitialPrompt(agentID: AgentID, text: String) {
        pendingInitial[agentID] = PendingInitialPrompt(text: text, queuedAt: clock.now)
        Task { @MainActor [weak self] in
            await self?.runInitialPromptLoop(agentID)
        }
    }

    private func runInitialPromptLoop(_ agentID: AgentID) async {
        while let pending = pendingInitial[agentID] {
            if clock.now >= pending.queuedAt + Self.initialPromptTimeout {
                pendingInitial[agentID] = nil
                // Timeout: leave the text in the composer draft — never a
                // blind send into an agent that never reached validated idle.
                onInitialPromptTimeout?(agentID, pending.text)
                return
            }
            // O(1) per-agent read: building the full projection (turn-mirror
            // sync over every session + summary construction for all agents)
            // 20×/s just to watch ONE lifecycle is wasted MainActor work
            // under multi-agent load (§3.21 working-cadence budget).
            guard let state = try? await runtime.state(of: agentID) else {
                // Agent stopped/deleted during the wait window: drop the
                // pending prompt silently (§3.9) — restoring its text into
                // a composer draft for a dead agent would be wrong.
                pendingInitial[agentID] = nil
                return
            }
            if state.lifecycle == .idle {
                pendingInitial[agentID] = nil
                do {
                    _ = try await runtime.prompt(agentID, pending.text, .sendNow)
                } catch {
                    print("[PROMPT] initial prompt delivery failed for \(agentID): \(error)")
                    DiagnosticsLogRing.shared.record(
                        "initial prompt delivery failed for \(agentID); text restored to composer draft"
                    )
                    // Delivery failure: same restore semantics as the
                    // timeout path — back into the composer draft.
                    onInitialPromptTimeout?(agentID, pending.text)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: 2. Delivery-watchdog surfacing (§3.11 rule 5–7)

    /// Called by the seam after a sendNow delivery. Watches the agent's
    /// timeline for `promptDeliveryUnconfirmed(commandID)`; if it appears the
    /// state is surfaced in the UI model. No retry is ever issued.
    func surfaceDeliveryOutcome(agentID: AgentID, commandID: CommandID) {
        Task { @MainActor [weak self] in
            await self?.pollForUnconfirmed(agentID: agentID, commandID: commandID)
        }
    }

    private func pollForUnconfirmed(agentID: AgentID, commandID: CommandID) async {
        // The AppModel keeps a single [AgentID: CommandID] slot; its clear
        // is commandID-matched, so a stale poll can never wipe a newer
        // command's surfaced state (§3.11).
        // "disarmed" is only trustworthy once the watch has been SEEN armed.
        var sawArmed = false
        // Phase 1: wait until the watch is OBSERVED armed — arming may lag
        // behind this poll. A cap still applies: lag beyond this window means
        // the delivery path is broken; leaving the flag unset matches the old
        // deadline-expiry behavior instead of polling forever.
        let armDeadline = clock.now + Self.armObservationWindow
        while !sawArmed, clock.now < armDeadline {
            let events = await runtime.timeline(of: agentID)
            if events.contains(where: {
                if case let .promptDeliveryUnconfirmed(id) = $0.event {
                    return id == commandID
                }
                return false
            }) {
                model?.setUnconfirmedDelivery(agentID: agentID, commandID: commandID)
                return
            }
            if Task.isCancelled {
                return
            }
            if await runtime.isDeliveryWatchArmed(agentID) {
                sawArmed = true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Phase 2: post-arm window — the runtime's own 5 s watchdog must have
        // resolved by now; keep polling a little past it.
        let deadline = clock.now + Self.unconfirmedPollWindow
        while clock.now < deadline {
            let events = await runtime.timeline(of: agentID)
            if events.contains(where: {
                if case let .promptDeliveryUnconfirmed(id) = $0.event {
                    return id == commandID
                }
                return false
            }) {
                model?.setUnconfirmedDelivery(agentID: agentID, commandID: commandID)
                return
            }
            if await runtime.isDeliveryWatchArmed(agentID) {
                sawArmed = true
            } else if sawArmed {
                // Confirmed: watch disarmed without recording the event.
                // Clear is commandID-matched inside the model, so a poll for
                // an older command cannot wipe a newer entry (§3.11).
                model?.clearUnconfirmedDelivery(agentID: agentID, commandID: commandID)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

import AgentCore
import AgentStore
import Foundation

// MainActor UI projection (architecture §4.6): consumes RuntimeDelta and the
// stage-5 shell registry, exposes grouped sidebar rows and banner state.
//
// Grouping and row construction are pure functions (SidebarGrouping) so they
// are unit-testable without AppKit.

@MainActor
final class AppModel: ObservableObject {
    struct ShellInfo {
        let terminalID: TerminalID
        let name: String
        let cwd: String
        let startedAt: Date

        init(terminalID: TerminalID, name: String, cwd: String) {
            self.terminalID = terminalID
            self.name = name
            self.cwd = cwd
            startedAt = Date()
        }
    }

    /// Called after any observable change (sidebar, status item, chrome).
    var onChange: (() -> Void)?

    private(set) var agents: [AgentID: AgentSummary] = [:]
    private(set) var agentTerminal: [AgentID: TerminalID] = [:]
    private(set) var agentCwd: [AgentID: String] = [:]
    private(set) var shells: [TerminalID: ShellInfo] = [:]
    private(set) var degradedBanner: String?
    /// Whether degradedBanner survives a recovery to .healthy (set only by
    /// the corruption-quarantine path; see setDegradedBanner).
    private var degradedBannerIsSticky = false
    /// Stage-9 (§3.11): deliveries the runtime watchdog could not confirm.
    /// Surfacing only — nothing retries them automatically.
    private(set) var unconfirmedDeliveries: [AgentID: CommandID] = [:]
    /// Invoked when an agent leaves the model; the composition root wires it
    /// to seam-side per-agent bookkeeping cleanup (e.g. visibility tasks).
    var onAgentRemoved: ((AgentID) -> Void)?

    func upsert(agent summary: AgentSummary) {
        agents[summary.id] = summary
        emit()
    }

    func remove(agent id: AgentID) {
        agents[id] = nil
        // All per-agent associations die with the agent.
        agentTerminal[id] = nil
        agentCwd[id] = nil
        unconfirmedDeliveries[id] = nil
        onAgentRemoved?(id)
        emit()
    }

    func setUnconfirmedDelivery(agentID: AgentID, commandID: CommandID) {
        unconfirmedDeliveries[agentID] = commandID
        emit()
    }

    func clearUnconfirmedDelivery(agentID: AgentID, commandID: CommandID) {
        // Only clear when the slot still holds THIS command's entry — a
        // newer command's surfaced state must survive an older poll (§3.11).
        guard unconfirmedDeliveries[agentID] == commandID else { return }
        unconfirmedDeliveries.removeValue(forKey: agentID)
        emit()
    }

    func replaceAll(agents newAgents: [AgentSummary]) {
        // Agents present before but absent from the snapshot left the model:
        // fire the removal hook so seam-side bookkeeping (e.g. visibility
        // tasks) is cleaned up just like remove(agent:).
        let oldIDs = Set(agents.keys)
        agents = Dictionary(newAgents.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for vanished in oldIDs.subtracting(agents.keys) {
            onAgentRemoved?(vanished)
        }
        emit()
    }

    /// Associates a runtime session's terminal with an agent row (stage-8
    /// launch pipeline will own this; today only shells mount surfaces).
    func associate(terminal: TerminalID, cwd: String, for agent: AgentID) {
        agentTerminal[agent] = terminal
        agentCwd[agent] = cwd
        emit()
    }

    @discardableResult
    func add(shell: ShellInfo) -> ShellInfo {
        shells[shell.terminalID] = shell
        emit()
        return shell
    }

    func updateShell(_ terminalID: TerminalID, mutate: (inout ShellInfo) -> Void) {
        guard var info = shells[terminalID] else { return }
        mutate(&info)
        shells[terminalID] = info
        emit()
    }

    func remove(shell terminalID: TerminalID) {
        shells[terminalID] = nil
        emit()
    }

    /// `sticky: true` marks the banner as surviving persistence-health
    /// recovery to .healthy; plain degradations stay transient.
    func setDegradedBanner(_ text: String?, sticky: Bool = false) {
        degradedBanner = text
        degradedBannerIsSticky = sticky
        if let text {
            DiagnosticsLogRing.shared.record("degraded: \(text)")
        }
        emit()
    }

    /// Stage-10 hook (Review5 #3): menu-bar toggle; notification delivery
    /// consults this before raising user-facing alerts.
    private(set) var notificationsPaused = false

    func setNotificationsPaused(_ paused: Bool) {
        notificationsPaused = paused
        emit()
    }

    /// Domain-clock accessor wired by the composition root so the pure
    /// grouping can stamp relative last-activity durations at render time.
    var nowProvider: (() -> MonotonicInstant)?

    var sections: [SidebarGrouping.Section] {
        SidebarGrouping.sections(
            agents: agents.values.map { $0 },
            shells: shells.values.map { $0 },
            now: nowProvider?()
        )
    }

    func summary(for item: SidebarItem) -> RowModel? {
        sections.flatMap(\.rows).first { $0.item == item }
    }

    var attentionCount: Int {
        agents.values.filter { $0.state.attention != .none }.count
    }

    /// Menu-bar 'needs input' segment (§3.13): ONLY the typed
    /// .inputRequired state counts here — failure / completionUnread belong
    /// to the sidebar's broader 'Needs attention' bucket, not this segment.
    var inputRequiredCount: Int {
        agents.values.filter {
            if case .inputRequired = $0.state.attention {
                return true
            }
            return false
        }.count
    }

    var workingCount: Int {
        agents.values.filter {
            switch $0.state.lifecycle {
            case .working, .starting: true
            default: false
            }
        }.count
    }

    private func emit() {
        onChange?()
    }
}

// MARK: - Pure sidebar grouping (unit-tested)

/// Attention-grouped sidebar sections (§3.13): Needs attention / Working /
/// Idle / Stopped / Shells. State is never color-only: every row carries a
/// symbol + state text.
enum SidebarGrouping {
    struct Section {
        let title: String
        let rows: [RowModel]
    }

    static let sectionOrder = ["Needs attention", "Working", "Idle", "Stopped", "Shells"]

    static func sections<Shells: ShellInfoProtocol>(
        agents: [AgentSummary],
        shells: [Shells],
        now: MonotonicInstant? = nil
    ) -> [Section] {
        var buckets: [String: [RowModel]] = Dictionary(uniqueKeysWithValues: sectionOrder.map { ($0, []) })
        for agent in agents.sorted(by: { $0.displayName < $1.displayName }) {
            buckets[bucket(for: agent), default: []].append(row(for: agent, now: now))
        }
        for shell in shells.sorted(by: { $0.name < $1.name }) {
            buckets["Shells", default: []].append(row(for: shell))
        }
        return sectionOrder.compactMap { title in
            let rows = buckets[title] ?? []
            guard !rows.isEmpty else { return nil }
            return Section(title: title, rows: rows)
        }
    }

    static func bucket(for agent: AgentSummary) -> String {
        if agent.state.attention != .none {
            return "Needs attention"
        }
        switch agent.state.lifecycle {
        case .working, .starting:
            return "Working"
        case .idle:
            return "Idle"
        case .stopping, .stopped, .failed:
            return "Stopped"
        case .unknown:
            return "Idle"
        case .waitingForInput:
            return "Needs attention"
        }
    }

    /// Relative last-activity label (§3.13): compact humanized age of the
    /// agent's most recent state observation, computed against the render
    /// instant. Pure — unit-tested without AppKit.
    static func durationText(lastActivity: MonotonicInstant, now: MonotonicInstant) -> String {
        let elapsed = now.nanosecondsSinceEpoch - lastActivity.nanosecondsSinceEpoch
        guard elapsed > 0 else { return "now" }
        let seconds = elapsed / 1_000_000_000
        if seconds < 5 {
            return "now"
        }
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 48 {
            return "\(hours)h"
        }
        return "\(hours / 24)d"
    }

    static func row(for agent: AgentSummary, now: MonotonicInstant? = nil) -> RowModel {
        RowModel(
            item: .agent(agent.id),
            title: agent.displayName,
            subtitle: agent.taskSummary ?? "",
            stateSymbol: stateSymbol(agent),
            stateText: stateText(agent),
            durationText: now.map { Self.durationText(lastActivity: agent.state.observedAt, now: $0) } ?? "",
            showsQueuedBadge: agent.hasQueuedPrompt,
            tooltip: agent.taskSummary,
            attention: agent.state.attention
        )
    }

    static func row(for shell: some ShellInfoProtocol) -> RowModel {
        RowModel(
            item: .shell(shell.terminalID),
            title: shell.name,
            subtitle: shell.cwd,
            stateSymbol: "terminal",
            stateText: "shell",
            durationText: "",
            showsQueuedBadge: false,
            tooltip: shell.cwd,
            attention: .none
        )
    }

    /// State icon + text — deliberately never color-only (§3.13).
    static func stateSymbol(_ agent: AgentSummary) -> String {
        if case .inputRequired = agent.state.attention {
            return "questionmark.circle"
        }
        if case .failure = agent.state.attention {
            return "exclamationmark.triangle"
        }
        if case .completionUnread = agent.state.attention {
            return "envelope.badge"
        }
        switch agent.state.lifecycle {
        case .working, .starting: return "gearshape"
        case .waitingForInput: return "questionmark.circle"
        case .idle, .unknown: return "moon"
        case .stopping: return "hourglass"
        case .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    static func stateText(_ agent: AgentSummary) -> String {
        if case .inputRequired = agent.state.attention {
            return "Waiting for input"
        }
        if case .failure = agent.state.attention {
            return "Failure"
        }
        if case .completionUnread = agent.state.attention {
            return "Turn completed"
        }
        switch agent.state.lifecycle {
        case .working: return "Working"
        case .starting: return "Starting"
        case .waitingForInput: return "Waiting for input"
        case .idle: return "Idle"
        // Detection-unclassified agents display as Idle: bucket(for:) and
        // stateSymbol already treat .unknown as idle, and a bare "Unknown"
        // row/header next to the "IDLE" section read as three different
        // answers. The inspector keeps the precise "lifecycle: Unknown".
        case .unknown: return "Idle"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }
}

extension AppModel {
    /// §3.12A/§3.14 step 8: the ONE mapping from DatabaseWriter health
    /// transitions onto the degraded banner. Production wiring and the
    /// RuntimeWiring banner test both drive THIS path — never a manual
    /// setDegradedBanner call.
    func apply(persistenceHealth: DatabaseWriter.Health) {
        switch persistenceHealth {
        case .healthy:
            // A corruption notice is STICKY: the fresh store recovering to
            // .healthy must not erase the operator's only record that their
            // previous bytes were quarantined (stage-16 gate 6a). Only a
            // plain transient degradation clears on recovery.
            if !degradedBannerIsSticky {
                setDegradedBanner(nil)
            }
        case let .degraded(reason):
            if degradedBannerIsSticky {
                // The sticky corruption-quarantine notice is authoritative;
                // a later transient degradation must not overwrite its text
                // while inheriting stickiness. The reason still reaches the
                // diagnostics ring (same channel setDegradedBanner uses).
                DiagnosticsLogRing.shared.record("degraded: Persistence degraded — \(reason)")
            } else {
                setDegradedBanner("Persistence degraded — \(reason)", sticky: false)
            }
        }
    }
}

/// Abstraction so the pure grouper can be tested without constructing
/// AppModel.ShellInfo on non-main actors.
protocol ShellInfoProtocol {
    var terminalID: TerminalID { get }
    var name: String { get }
    var cwd: String { get }
}

extension AppModel.ShellInfo: ShellInfoProtocol {}

struct RowModel: Equatable {
    let item: SidebarItem
    let title: String
    let subtitle: String
    let stateSymbol: String
    let stateText: String
    let durationText: String
    let showsQueuedBadge: Bool
    let tooltip: String?
    /// Stage-10 (§3.4): the TYPED attention state — navigation, notifications
    /// and grouping read this, never display text.
    var attention: AttentionState = .none
    /// Review5: attention cycling keys off the typed state above.
    var isAttention: Bool {
        attention != .none
    }
}

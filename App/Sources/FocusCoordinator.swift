import AgentCore
import AppKit

// Focus coordination (§3.12E/§3.13): first responder placement, native surface
// focus and the ≥500 ms visibility timer implementing markSeen semantics
// (AttentionPolicy.visibilityClearInterval) through the runtime seam.
//
// SEAM NOTE: TerminalKit currently exposes native focus only inside mount/park
// (TerminalMountCoordinator). Focusing a pane therefore re-mounts its terminal,
// which is idempotent for same-container mounts. A public
// `GhosttySurface.setFocus` seam is reported as a TerminalKit gap.
//
// Stage-10 (§3.4): completionUnread clears only after CONTINUOUS visibility of
// at least 500 ms while the app is ACTIVE and the agent's pane holds focus.
// The decision itself is pure (VisibilityPolicy) and unit-tested; this class
// owns only the timer and the AppKit observation.

@MainActor
final class FocusCoordinator {
    private let seam: RuntimeSeam
    private weak var model: AppModel?
    private var visibilityTimer: Timer?

    /// Pure §3.4 visibility rule, split out for unit testing.
    enum VisibilityPolicy {
        /// Continuous-visibility span required before markSeen (§3.4).
        static let requiredSpan: TimeInterval = 0.5

        static func shouldMarkSeen(appActive: Bool,
                                   mainWindowVisible: Bool,
                                   focusedAgentSince: Date?,
                                   now: Date) -> Bool
        {
            guard appActive, mainWindowVisible, let since = focusedAgentSince else { return false }
            return now.timeIntervalSince(since) >= requiredSpan
        }
    }

    private(set) var focusedItem: SidebarItem?
    /// Focus ordering (coalescing mailbox): setFocused records the latest
    /// requested item here; one lazily-started drain task delivers pending
    /// items strictly one-at-a-time, always re-reading the LATEST entry, so
    /// the most recent focus request is guaranteed to land at runtime last.
    private var pendingFocusItem: SidebarItem?
    private var focusDrainTask: Task<Void, Never>?

    /// Stage-15 automation seams (AUTOAGENT probe): production reads live
    /// NSApp state; the scenario forces these so the markSeen path is provable
    /// without depending on background-launch activation semantics. The pure
    /// rule itself stays in VisibilityPolicy and unit-covered.
    var appActiveProvider: () -> Bool = { NSApp.isActive }
    var mainWindowVisibleProvider: () -> Bool = { NSApp.mainWindow?.isVisible == true }
    private(set) var focusedSince: Date?

    init(seam: RuntimeSeam, model: AppModel) {
        self.seam = seam
        self.model = model
    }

    func setFocused(item: SidebarItem?) {
        let previous = focusedItem
        guard previous != item else { return }
        focusedItem = item
        focusedSince = item == nil ? nil : Date()
        if let previous {
            seam.setVisible(previous, false)
        }
        if let item {
            // §3.4: only the runtime-visible flag lets AttentionPolicy and
            // the detection cadences see that the operator watches this pane;
            // RuntimeSeam converges out-of-order superseded tasks to the
            // newest requested value (see its desiredVisibility note).
            seam.setVisible(item, true)
            enqueueFocusRuntime(item)
        } else {
            // Deselection must also drain the mailbox: a queued request
            // delivered after focus cleared would focus a stale item.
            pendingFocusItem = nil
        }
    }

    /// Serialized focus delivery: replaces one-shot `Task { focusRuntime }`
    /// spawns whose unordered completion could leave the wrong pane focused
    /// after rapid A→B→A switches. All state is MainActor-isolated and the
    /// loop re-reads `pendingFocusItem` after every await, so a newer
    /// request made while a delivery is in flight supersedes it.
    private func enqueueFocusRuntime(_ item: SidebarItem) {
        pendingFocusItem = item
        guard focusDrainTask == nil else { return }
        focusDrainTask = Task { [weak self] in
            while let self {
                guard let item = pendingFocusItem else { break }
                pendingFocusItem = nil
                // A deselect that raced the previous in-flight delivery must not land a
                // stale focus at the runtime: skip delivery when focus is cleared.
                guard focusedItem != nil else { continue }
                await seam.focusRuntime(item)
            }
            self?.focusDrainTask = nil
        }
    }

    /// 500 ms visibility loop (§3.4 / AttentionPolicy): once the focused agent
    /// has been CONTINUOUSLY visible in the active app for the required span,
    /// markSeen runs — clearing completionUnread ONLY (runtime-side rule).
    func start() {
        guard visibilityTimer == nil else { return }
        let timer = Timer(timeInterval: VisibilityPolicy.requiredSpan, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickVisibility()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    func tickVisibility(now: Date = Date()) {
        guard let item = focusedItem, case .agent = item else { return }
        // §3.4: active app + visible window + ≥500 ms CONTINUOUS focus.
        // (focusedSince resets whenever focus moves — see setFocused.)
        let active = appActiveProvider()
        let visible = mainWindowVisibleProvider()
        guard active, visible else {
            // Continuity is broken while the app is backgrounded or the
            // window hidden: elapsed time must NOT keep accumulating across
            // the gap, or the first tick after reactivation would fire
            // markSeen without a fresh 500 ms of visible attention.
            focusedSince = nil
            return
        }
        if focusedSince == nil {
            // Span restarts now; this tick cannot count toward it.
            focusedSince = now
            return
        }
        guard VisibilityPolicy.shouldMarkSeen(
            appActive: true,
            mainWindowVisible: true,
            focusedAgentSince: focusedSince,
            now: now
        ) else { return }
        Task { await self.seam.markSeen(item) }
    }

    func stop() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }
}

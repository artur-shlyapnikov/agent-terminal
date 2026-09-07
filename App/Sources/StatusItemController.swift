import AppKit

// Menu-bar status item (§3.13): live 'N working · M needs input · K failed'
// counts from runtime deltas — failures get their own segment so a broken
// agent is visible without opening the window — plus the quick-action menu
// (open, next attention, pause-notifications toggle, quit). While Pause
// Notifications is on the button is dimmed and carries a 'notifications
// paused' suffix.

@MainActor
final class StatusItemController: NSObject {
    private var item: NSStatusItem?
    private weak var model: AppModel?
    private weak var root: AppCompositionRoot?

    /// Pure §3.13 status text ('3 working · 1 needs input'), unit-testable.
    static func statusText(working: Int, attention: Int) -> String {
        var parts: [String] = []
        if working > 0 {
            parts.append(String(
                format: NSLocalizedString("%lld working", comment: "Status item: number of agents currently working"),
                working
            ))
        }
        if attention > 0 {
            parts.append(String(
                format: NSLocalizedString("%lld needs input", comment: "Status item: number of agents needing input"),
                attention
            ))
        }
        return parts.isEmpty ? NSLocalizedString("idle", comment: "Status item: no agent activity") : parts
            .joined(separator: " · ")
    }

    /// Full rendering used by refresh(): adds failure counts and the paused-
    /// notifications suffix to the base §3.13 text. `failed` derives from the
    /// typed .failure attention state; unit-testable.
    static func statusText(
        working: Int,
        attention: Int,
        failed: Int = 0,
        notificationsPaused: Bool = false
    ) -> String {
        var text = statusText(working: working, attention: attention)
        if failed > 0 {
            let failedPart = String(
                format: NSLocalizedString("%lld failed", comment: "Status item: number of agents that hit a failure"),
                failed
            )
            // 'idle · 1 failed' reads oddly; replace idle when only failures exist.
            if text == NSLocalizedString("idle", comment: "Status item: no agent activity") {
                text = failedPart
            } else {
                text += " · " + failedPart
            }
        }
        if notificationsPaused {
            text += " · " + NSLocalizedString(
                "notifications paused",
                comment: "Status item: suffix while notification delivery is paused"
            )
        }
        return text
    }

    init(model: AppModel, createItem: Bool = true, root: AppCompositionRoot? = nil) {
        self.model = model
        self.root = root
        super.init()
        guard createItem else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        let menu = NSMenu()
        let open = NSMenuItem(
            title: NSLocalizedString("Open AgentTerminal", comment: "Status bar menu item: open the main window"),
            action: #selector(openMainWindow),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        let attention = NSMenuItem(
            title: NSLocalizedString(
                "Next Attention",
                comment: "Status bar menu item: focus next agent needing attention"
            ),
            action: #selector(nextAttention),
            keyEquivalent: ""
        )
        attention.target = self
        menu.addItem(attention)
        let pause = NSMenuItem(
            title: NSLocalizedString(
                "Pause Notifications",
                comment: "Status bar menu item: toggle notification delivery"
            ),
            action: #selector(togglePauseNotifications),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit AgentTerminal",
                                                         comment: "Status bar menu item: quit the app"),
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        // Show the item immediately: the title is otherwise only set on the
        // first model delta, and an idle launch (no deltas) left a zero-width
        // invisible status item in the menu bar.
        refresh()
    }

    @objc private func openMainWindow() {
        root?.mainWindowController.showAndKey()
    }

    @objc private func nextAttention() {
        root?.commands.nextAttention()
    }

    /// §3.13 Pause Notifications: suppresses notification delivery (#4) while
    /// checked; sidebar/status attention surfaces are unaffected.
    @objc private func togglePauseNotifications() {
        guard let model else { return }
        model.setNotificationsPaused(!model.notificationsPaused)
    }

    func refresh() {
        guard let model else { return }
        let failedCount = model.agents.values.filter {
            if case .failure = $0.state.attention {
                return true
            }
            return false
        }.count
        let status = Self.statusText(
            working: model.workingCount,
            // §3.13: the 'needs input' segment counts ONLY .inputRequired —
            // failure/completionUnread never inflate it.
            attention: model.inputRequiredCount,
            failed: failedCount,
            notificationsPaused: model.notificationsPaused
        )
        // The status bar item sits on the per-delta fan-out; an identical
        // title write still invalidates the item, and the title only changes
        // when a count flips - so skip redundant passes.
        if let button = item?.button {
            if button.title != status {
                button.title = status
            }
            // Muted style while paused so the state is visible at a glance.
            if button.appearsDisabled != model.notificationsPaused {
                button.appearsDisabled = model.notificationsPaused
            }
        }
        if let pause = item?.menu?.items.first(where: { $0.action == #selector(togglePauseNotifications) }) {
            pause.state = model.notificationsPaused ? .on : .off
        }
    }
}

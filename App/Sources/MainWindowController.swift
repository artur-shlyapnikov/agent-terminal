import AgentCore
import AppKit

// Window lifecycle (§4.6): owns the main window; close parks all visible
// surfaces (processes continue, §3.15) — never terminates them.

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let splitController: MainSplitViewController
    let model: AppModel
    let seam: RuntimeSeam
    let focusCoordinator: FocusCoordinator
    let composer: PromptComposerView
    let banner: PersistentBannerView

    init(canvas: AgentCanvasController,
         model: AppModel,
         seam: RuntimeSeam,
         focusCoordinator: FocusCoordinator)
    {
        self.model = model
        self.seam = seam
        self.focusCoordinator = focusCoordinator

        splitController = MainSplitViewController(
            canvas: canvas,
            model: model,
            seam: seam
        )
        composer = PromptComposerView(model: model, sessionManager: canvas.sessionManager)
        banner = PersistentBannerView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentTerminal"
        window.minSize = NSSize(width: 980, height: 600)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        // Banner slot on top, split in the middle, composer docked below (§3.13).
        print("[LAUNCH] window: splitController.view load")
        let stack = NSStackView(views: [banner, splitController.view, composer])
        print("[LAUNCH] window: stack made")
        stack.orientation = .vertical
        stack.alignment = .width // stretch arranged views horizontally
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            splitController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            splitController.view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            splitController.view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        composer.focusedItemProvider = { [weak self] in self?.focusedItem() }
        composer.onSend = { [weak self] text, policy, commandID in
            guard let self, let item = focusedItem() else {
                return .failed(reason: NSLocalizedString(
                    "no focused agent",
                    comment: "Composer failure reason when the send target disappeared"
                ))
            }
            return await self.seam.send(item, text: text, policy: policy, commandID: commandID)
        }
        composer.onCancelQueued = { [weak self] in
            guard let item = self?.focusedItem() else { return }
            Task { await self?.seam.cancelQueuedPrompt(item) }
        }
        composer.focusRequestHandler = { [weak canvas] in
            canvas?.refocusTerminalSurface()
        }
        splitController.composer = composer
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    private var didApplyInitialDividers = false

    func showAndKey() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Stage-10: deterministic 260 pt sidebar (§3.13) — applied on first
        // presentation only; reopens preserve user-dragged divider geometry.
        if !didApplyInitialDividers {
            splitController.applyInitialDividers()
            didApplyInitialDividers = true
        }
        refreshChrome()
        // §3.15 reopen: windowWillClose parked every mounted surface, so
        // re-mount each live pane's surface (placeholders/no-op contents are
        // skipped inside mountContent) — otherwise panes stay blank until
        // the user clicks each one.
        for leaf in splitController.canvas.planner.leaves
            where leaf.content != .placeholder
        {
            splitController.canvas.mountContent(of: leaf.paneID)
        }
    }

    func focusedItem() -> SidebarItem? {
        switch splitController.canvas.focusedContent {
        case let .agent(id): .agent(id)
        case let .terminal(id): .shell(id)
        case nil, .placeholder: nil
        }
    }

    /// Model change fan-out: sidebar, canvas headers, inspector, composer.
    func refreshChrome() {
        banner.set(message: model.degradedBanner)
        splitController.refresh()
        composer.refresh()
        // Per-delta fan-out: an identical title write still invalidates the
        // titlebar, and the title only changes when focus or names change.
        let title = Self.windowTitle(for: focusedItem(), in: model)
        if window?.title != title {
            window?.title = title
        }
    }

    /// "AgentTerminal" alone with no focused canvas; otherwise
    /// "AgentTerminal — <agent display name | shell name/cwd>".
    static func windowTitle(for item: SidebarItem?, in model: AppModel) -> String {
        let focusedName: String? = switch item {
        case let .agent(id): model.agents[id]?.displayName
        case let .shell(id):
            if let shell = model.shells[id] {
                shell.name.isEmpty ? shell.cwd : shell.name
            } else {
                nil
            }
        case nil: nil
        }
        guard let focusedName, !focusedName.isEmpty else { return "AgentTerminal" }
        return "AgentTerminal — \(focusedName)"
    }

    // MARK: NSWindowDelegate

    /// Window close parks every mounted surface — processes keep running
    /// (§3.15). The app stays alive with its status item.
    func windowWillClose(_: Notification) {
        splitController.canvas.parkAllSurfaces()
        focusCoordinator.setFocused(item: nil)
    }

    /// §3.15 Hide Window choice: park every mounted surface and hide the
    /// window WITHOUT closing it — processes keep running, the app stays in
    /// the Dock/menu bar, reopen re-keys the same window.
    func parkAndOrderOut() {
        splitController.canvas.parkAllSurfaces()
        focusCoordinator.setFocused(item: nil)
        window?.orderOut(nil)
    }

    // MARK: close-view routing (surface-initiated close requests)

    /// ⌘W equivalent for a specific terminal (e.g. ghostty close-window event).
    func closeViewForTerminal(_ terminalID: TerminalID?) {
        if let terminalID {
            // Route by the requesting terminal only. A parked surface's late
            // or duplicate close request must NEVER fall through to closing
            // an unrelated focused pane (§3.13 routing law).
            if let pane = splitController.canvas.planner.paneID(showing: .shell(terminalID)) {
                splitController.canvas.closePane(pane)
                refreshChrome()
            }
            return
        }
        closeFocusedPane()
    }

    func closeFocusedPane() {
        guard let pane = splitController.canvas.focusedPane else { return }
        splitController.canvas.closePane(pane)
        refreshChrome()
    }
}

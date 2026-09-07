import AgentCore
import AppKit

// Menu commands and the §3.13 shortcut table.
//
// ROUTING LAW (§3.13): the app intercepts ONLY these registered Command
// shortcuts; Control/Option/plain input always reaches the terminal because it
// never matches a menu key equivalent, and unclaimed Command combinations fall
// through the responder chain into the ghostty surface view. No prefix keys.
//
// Stage-15 operator polish: ⌘N opens the real New Agent sheet (stage-6 gap
// closure), and the palette covers the FULL §3.13 command set — New Agent,
// Focus Agent, Next Attention, Split Right/Down, Close View, Interrupt,
// Stop Agent, Restart/Resume, Toggle Sidebar/Inspector, Install/Repair
// Integration, Open Workspace, Export Diagnostics.

@MainActor
final class AppCommands: NSObject {
    private unowned let root: AppCompositionRoot

    /// Palette controller owns its panel; AppCommands owns the DEFINITIONS.
    private lazy var palette = CommandPaletteController(
        definitions: { [weak self] in self?.paletteEntries ?? [] },
        dispatch: { [weak self] selector in
            _ = self?.perform(selector, with: nil)
        }
    )

    init(root: AppCompositionRoot, installMenu: Bool = true) {
        self.root = root
        super.init()
        if installMenu {
            installMainMenu()
        }
    }

    private var mainWindow: MainWindowController {
        root.mainWindowController
    }

    private var canvas: AgentCanvasController {
        root.mainWindowController.splitController.canvas
    }

    private var model: AppModel {
        root.model
    }

    // MARK: menu construction

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector,
                         key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                         tag: Int = -1) -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.tag = tag
        item.setAccessibilityLabel(title)
        menu.addItem(item)
        return item
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "AgentTerminal")
        appMenu.addItem(NSMenuItem(title: "About AgentTerminal",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        _ = addItem(appMenu, "Settings…", #selector(openSettings), key: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit AgentTerminal",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let file = NSMenu(title: "File")
        _ = addItem(file, "New Agent…", #selector(newAgent), key: "n")
        _ = addItem(file, "Open Workspace…", #selector(openWorkspace))
        file.addItem(.separator())
        _ = addItem(file, "Export Diagnostics…", #selector(exportDiagnostics))
        let fileItem = NSMenuItem()
        fileItem.submenu = file
        mainMenu.addItem(fileItem)

        // Click-only items: key equivalents here would intercept ⌘C/⌘V/⌘Z
        // before they reach the terminal (§3.13 — the app intercepts ONLY
        // the registered catalog; ghostty binds its own copy/paste). Focused
        // text fields handle those keys via the field editor regardless;
        // these rows exist for discoverability and mouse users.
        let edit = NSMenu(title: "Edit")
        _ = addResponderItem(edit, "Undo", Selector(("undo:")))
        _ = addResponderItem(edit, "Redo", Selector(("redo:")))
        edit.addItem(.separator())
        _ = addResponderItem(edit, "Cut", #selector(NSText.cut(_:)))
        _ = addResponderItem(edit, "Copy", #selector(NSText.copy(_:)))
        _ = addResponderItem(edit, "Paste", #selector(NSText.paste(_:)))
        _ = addResponderItem(edit, "Select All", #selector(NSText.selectAll(_:)))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        let view = NSMenu(title: "View")
        _ = addItem(view, "Toggle Sidebar", #selector(toggleSidebar), key: "b")
        _ = addItem(view, "Toggle Inspector", #selector(toggleInspector), key: "i")
        view.addItem(.separator())
        _ = addItem(view, "Split Right", #selector(splitRight), key: "d")
        _ = addItem(view, "Split Down", #selector(splitDown), key: "d", modifiers: [.command, .shift])
        view.addItem(.separator())
        _ = addItem(view, "Command Palette", #selector(commandPalette), key: "p", modifiers: [.command, .shift])
        let viewItem = NSMenuItem()
        viewItem.submenu = view
        mainMenu.addItem(viewItem)

        let navigate = NSMenu(title: "Navigate")
        _ = addItem(navigate, "Next Attention", #selector(nextAttention),
                    key: "u", modifiers: [.command, .shift])
        navigate.addItem(.separator())
        for index in 1 ... 9 {
            _ = addItem(navigate, "Select \(index)", #selector(selectIndexed(_:)),
                        key: String(index), tag: index - 1)
        }
        let navItem = NSMenuItem()
        navItem.submenu = navigate
        mainMenu.addItem(navItem)

        let agent = NSMenu(title: "Agent")
        _ = addItem(agent, "Interrupt", #selector(interrupt), key: ".")
        _ = addItem(agent, "Stop Agent (graceful)", #selector(stopAgent))
        _ = addItem(agent, "Restart / Resume", #selector(restartResume))
        _ = addItem(agent, "Acknowledge Failure", #selector(acknowledgeFailure))
        _ = addItem(agent, "Install / Repair Integration", #selector(repairIntegration))
        _ = addItem(agent, "Close View", #selector(closeView), key: "w")
        let agentItem = NSMenuItem()
        agentItem.submenu = agent
        mainMenu.addItem(agentItem)

        let composer = NSMenu(title: "Composer")
        _ = addItem(composer, "Focus Prompt Composer", #selector(focusComposer), key: "l")
        _ = addItem(composer, "Send Prompt", #selector(sendPrompt), key: "\r")
        // Stage-9 (§3.11): the one queued prompt is cancellable from the menu
        // as well as by clicking the composer's queued indicator.
        _ = addItem(composer, "Cancel Queued Prompt", #selector(cancelQueuedPrompt))
        let composerItem = NSMenuItem()
        composerItem.submenu = composer
        mainMenu.addItem(composerItem)

        // Click-only (see the Edit menu note): ⌘M would be intercepted away
        // from the terminal. The windowsMenu registration gives the standard
        // open-window list at the bottom of the menu.
        let window = NSMenu(title: "Window")
        _ = addResponderItem(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)))
        _ = addResponderItem(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        _ = addResponderItem(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = mainMenu
    }

    /// Targetless menu item: the action rides the responder chain from the
    /// first responder. Never given a key equivalent — see §3.13.
    private func addResponderItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.setAccessibilityLabel(title)
        menu.addItem(item)
        return item
    }

    // MARK: actions

    /// ⌘N (§3.13): the REAL New Agent sheet — adapter picker with install
    /// status, folder chooser, validated request through the ticketed launch
    /// pipeline (stage-6 gap closure, DoD #1).
    @objc func newAgent() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("new agent ignored during shutdown")
            return
        }
        mainWindow.showAndKey()
        NewAgentSheetController.present(
            in: mainWindow.window,
            pipeline: root.coordinator,
            workspaceProvider: { [weak root] in root?.activeWorkspaceID },
            onSelect: { [weak self] agentID in
                self?.select(.agent(agentID))
            }
        )
    }

    /// §3.13 palette entry "Restart/Resume": stopped agents RESUME, anything
    /// else gets a fresh surface generation via restartAgent.
    @objc func restartResume() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("restart/resume ignored during shutdown")
            return
        }
        guard let item = focusedItem, case let .agent(id) = item,
              let summary = model.agents[id] else { return }
        if case .stopped = summary.state.lifecycle {
            Task { await root.runtimeSeam.resume(.agent(id)) }
        } else {
            Task { await root.runtimeSeam.restart(.agent(id)) }
        }
    }

    /// §3.13 palette entry "Install/Repair Integration": re-runs the idempotent
    /// managed-entry install for the focused agent's adapter (§3.17).
    @objc func repairIntegration() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("integration repair ignored during shutdown")
            return
        }
        guard let item = focusedItem else { return }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await root.runtimeSeam.repairIntegration(for: item)
            print("[INTEGRATION] repair outcome: \(outcome ?? "unavailable")")
            DiagnosticsLogRing.shared.record("integration repair: \(outcome ?? "unavailable")")
        }
    }

    /// §3.13 palette entry "Open Workspace": folder chooser → new workspace
    /// row + active workspace switch for subsequent New Agent launches.
    @objc func openWorkspace() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("open workspace ignored during shutdown")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a project folder to open as a workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            await self?.root.openWorkspace(rootPath: url.path)
        }
    }

    /// §3.22 diagnostic export: redacted bundle to a user-chosen file.
    @objc func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue =
            "aterm-diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        panel.message = "Redacted diagnostics — never includes prompts or output"
        guard let hostWindow = mainWindow.window else { return }
        panel.beginSheetModal(for: hostWindow) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                if let error = await self.root.diagnosticExporter.export(to: url) {
                    let alert = NSAlert()
                    alert.messageText = "Diagnostic export failed"
                    alert.informativeText = error
                    alert.runModal()
                }
            }
        }
    }

    @objc func openSettings() {
        SettingsWindowController.present(root: root)
    }

    /// Reopens the launch-time Recovery Center on demand — previously the
    /// only entry point was AppDelegate's crash-recovery path, so a dismissed
    /// center was unreachable for the rest of the session.
    @objc func presentRecoveryCenter() {
        _ = root.presentRecoveryCenter()
    }

    @objc func toggleSidebar() {
        mainWindow.splitController.toggleSidebar()
    }

    @objc func toggleInspector() {
        mainWindow.splitController.toggleInspector()
    }

    @objc func splitRight() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("split right ignored during shutdown")
            return
        }
        canvas.splitFocusedRight()
        mainWindow.refreshChrome()
    }

    @objc func splitDown() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("split down ignored during shutdown")
            return
        }
        canvas.splitFocusedDown()
        mainWindow.refreshChrome()
    }

    @objc func closeView() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("close view ignored during shutdown")
            return
        }
        mainWindow.closeFocusedPane()
    }

    @objc func interrupt() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("interrupt ignored during shutdown")
            return
        }
        guard let item = focusedItem else { return }
        Task { await root.runtimeSeam.interrupt(item) }
    }

    @objc func stopAgent() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("stop agent ignored during shutdown")
            return
        }
        guard let item = focusedItem else { return }
        Task { await root.runtimeSeam.stop(item) }
    }

    @objc func focusComposer() {
        mainWindow.composer.focusComposer()
    }

    @objc func sendPrompt() {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("send prompt ignored during shutdown")
            return
        }
        mainWindow.composer.sendViaPrimaryButton()
    }

    @objc func acknowledgeFailure() {
        guard let item = focusedItem else { return }
        Task { await root.runtimeSeam.acknowledgeFailure(item) }
    }

    @objc func cancelQueuedPrompt() {
        guard let item = focusedItem else { return }
        Task { await root.runtimeSeam.cancelQueuedPrompt(item) }
    }

    /// ⌘⇧U (§3.4/§6.10): cycles ONLY attention-flagged rows — priority
    /// (inputRequired > failure > completionUnread) first, oldest attentionSince
    /// within a group — wrapping; opens/selects/mounts/focuses the target.
    /// Works from the menu bar too: raises and keys the window first (§3.12E).
    @objc func nextAttention() {
        var attentionByItem: [SidebarItem: AttentionState] = [:]
        for row in model.rowsInOrder where row.isAttention {
            attentionByItem[row.item] = row.attention
        }
        let targets = AttentionNavigator.targets(attentionByItem: attentionByItem)
        guard let target = AttentionNavigator.next(after: focusedItem, in: targets) else { return }
        mainWindow.showAndKey()
        select(target.item)
    }

    /// ⌘1…9: select the nth row across sections (§3.13 "Agent 1…9").
    @objc func selectIndexed(_ sender: NSMenuItem) {
        if root.shutdownCoordinator.isTerminating {
            DiagnosticsLogRing.shared.record("select indexed ignored during shutdown")
            return
        }
        let rows = model.rowsInOrder
        let index = sender.tag
        guard index >= 0, index < rows.count else { return }
        select(rows[index].item)
    }

    @objc func commandPalette() {
        palette.present()
    }

    // MARK: selection plumbing shared with automation

    private var focusedItem: SidebarItem? {
        switch canvas.focusedContent {
        case let .agent(id): .agent(id)
        case let .terminal(id): .shell(id)
        case nil, .placeholder: nil
        }
    }

    func select(_ item: SidebarItem) {
        canvas.select(item: item, kind: .plain)
        mainWindow.refreshChrome()
    }

    /// Automation entry — identical path to the ⌘1…9 / sidebar click actions.
    enum Automation {
        @MainActor
        static func select(_ commands: AppCommands, _ item: SidebarItem) {
            commands.select(item)
        }
    }

    // MARK: command palette (⌘⇧P) — full §3.13 command list

    /// Static §3.13 palette catalog (title, selector name) — unit-testable
    /// WITHOUT constructing the composition root (the test host stays inert).
    static let paletteCatalog: [(title: String, actionName: String)] = [
        ("New Agent", "newAgent"),
        ("Focus Prompt Composer", "focusComposer"),
        ("Next Attention", "nextAttention"),
        ("Split Right", "splitRight"),
        ("Split Down", "splitDown"),
        ("Close View", "closeView"),
        ("Interrupt", "interrupt"),
        ("Stop Agent", "stopAgent"),
        ("Restart / Resume", "restartResume"),
        ("Acknowledge Failure", "acknowledgeFailure"),
        ("Toggle Sidebar", "toggleSidebar"),
        ("Toggle Inspector", "toggleInspector"),
        ("Install / Repair Integration", "repairIntegration"),
        ("Open Workspace", "openWorkspace"),
        ("Export Diagnostics", "exportDiagnostics"),
        ("Settings", "openSettings"),
        ("Recovery Center", "presentRecoveryCenter"),
        ("Send Prompt", "sendPrompt"),
    ]

    var paletteEntries: [CommandDefinition] {
        Self.paletteCatalog.map { title, actionName in
            CommandDefinition(
                title: title,
                shortcut: AppShortcut.registered.first { $0.title == title },
                action: Selector((actionName))
            )
        }
    }
}

extension AppModel {
    var rowsInOrder: [RowModel] {
        sections.flatMap(\.rows)
    }
}

extension RowModel {
    var needsAttention: Bool {
        isAttention
    }
}

extension AppCommands {
    /// Path of the bundled agentctl helper (control-plane diagnostics).
    func ctlHelperPath() -> String {
        if let exe = Bundle.main.executableURL {
            return exe.deletingLastPathComponent()
                .appendingPathComponent("Helpers/agentctl").path
        }
        return "/usr/bin/false"
    }
}

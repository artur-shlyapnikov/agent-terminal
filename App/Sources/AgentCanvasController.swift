import AgentCore
import AppKit
import TerminalKit

// Canvas renderer (§3.13): renders the LayoutTree as a binary split layout,
// max four leaves (enforced by LayoutTree + planner), ratio clamp visible in
// the planner, one TerminalPaneController per leaf.
//
// DIVIDER NOTE: dividers are thin custom views with native resize cursor and
// drag-to-resize clamped to LayoutTree.ratioRange. A recursive NSSplitView
// mirror is deferred (reported in the stage-5 list); geometry, invariants and
// behavior are identical.

@MainActor
final class AgentCanvasController: NSViewController, CanvasViewDelegate {
    let sessionManager: TerminalSessionManager
    let model: AppModel
    let seam: RuntimeSeam
    let focusCoordinator: FocusCoordinator

    private(set) var planner = CanvasLayoutPlanner()
    private(set) var paneControllers: [PaneID: TerminalPaneController] = [:]
    private(set) var focusedPane: PaneID?
    var onSelectionChanged: ((PaneContent?) -> Void)?

    func paneController(for pane: PaneID) -> TerminalPaneController? {
        paneControllers[pane]
    }

    /// Sidebar clicks land here via MainSplitViewController.
    func sidebarClicked(item: SidebarItem, kind: ClickKind) {
        select(item: item, kind: kind)
    }

    init(sessionManager: TerminalSessionManager,
         model: AppModel,
         seam: RuntimeSeam,
         focusCoordinator: FocusCoordinator)
    {
        self.sessionManager = sessionManager
        self.model = model
        self.seam = seam
        self.focusCoordinator = focusCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    override func loadView() {
        let canvas = CanvasView()
        canvas.delegate = self
        view = canvas
        rebuild()
    }

    private var canvasView: CanvasView {
        guard let canvas = view as? CanvasView else {
            preconditionFailure("AgentCanvasController.view is always the CanvasView built in loadView()")
        }
        return canvas
    }

    // MARK: selection & layout decisions

    func select(item: SidebarItem, kind: ClickKind) {
        let visiblePane = planner.paneID(showing: item)
        let decision = CanvasLayoutPlanner.decide(
            item: item,
            kind: kind,
            visiblePane: visiblePane,
            focusedPane: focusedPane,
            leafCount: planner.leafCount
        )

        switch decision {
        case let .focusExisting(pane):
            focusPane(pane)

        case let .replaceFocused(pane):
            _ = replace(pane: pane, with: item)

        case let .splitFocused(axis, ratio):
            guard let source = focusedPane ?? planner.leaves.first?.paneID else { return }
            // The planner's .option decision carries a placeholder axis; the
            // real axis comes from the same alternating rule optionSplit uses.
            let effectiveAxis = kind == .option ? alternatingSplitAxis(of: source) : axis
            split(pane: source, axis: effectiveAxis, ratio: ratio,
                  content: CanvasLayoutPlanner.itemContent(item))

        case .rejectedMaxLeaves:
            NSSound.beep()

        case .noSelection:
            // No focused pane: fill the first placeholder if one exists.
            if let placeholder = planner.leaves.first(where: { $0.content == .placeholder })?.paneID {
                _ = replace(pane: placeholder, with: item)
            } else {
                NSSound.beep()
            }
        }
    }

    /// Option-click: split the focused pane (axis via `alternatingSplitAxis`).
    func optionSplit(item: SidebarItem) {
        guard planner.leafCount < LayoutTree.maxLeaves else {
            NSSound.beep()
            return
        }
        guard let source = focusedPane ?? planner.leaves.first?.paneID else { return }
        split(pane: source, axis: alternatingSplitAxis(of: source), ratio: 0.5,
              content: CanvasLayoutPlanner.itemContent(item))
    }

    /// Option-driven split placement: alternate the axis relative to the
    /// parent split so grids stay balanced (2x2 emerges from repeated splits).
    private func alternatingSplitAxis(of pane: PaneID) -> SplitAxis {
        planner.parentAxis(of: pane) == .horizontal ? .vertical : .horizontal
    }

    /// ⌘D / Split right.
    func splitFocusedRight() {
        guard let source = focusedPane ?? planner.leaves.first?.paneID else { return }
        split(pane: source, axis: .horizontal, ratio: 0.5, content: .placeholder)
    }

    /// ⌘⇧D / Split down.
    func splitFocusedDown() {
        guard let source = focusedPane ?? planner.leaves.first?.paneID else { return }
        split(pane: source, axis: .vertical, ratio: 0.5, content: .placeholder)
    }

    func split(pane: PaneID, axis: SplitAxis, ratio: Double = 0.5, content: PaneContent = .placeholder) {
        do {
            let newPane = try planner.split(from: pane, axis: axis, ratio: ratio, newContent: content)
            rebuild()
            if content != .placeholder {
                mountContent(of: newPane)
            }
            focusPane(newPane)
        } catch LayoutError.tooManyLeaves {
            NSSound.beep() // max-four enforcement (§3.13)
        } catch {
            NSSound.beep()
        }
    }

    /// Hidden click / drag-drop: replace leaf content; the displaced terminal
    /// parks and keeps running (§3.13, §3.12F).
    func replace(pane: PaneID, with item: SidebarItem) -> Bool {
        guard let previous = try? planner.replace(pane: pane, with: item) else {
            NSSound.beep()
            return false
        }
        park(previous)
        rebuild()
        mountContent(of: pane)
        focusPane(pane)
        return true
    }

    /// ⌘W / close-view: parks WITHOUT signals (§3.11/§3.12F). Never stops the
    /// process; Stop Agent is a separate command.
    func closePane(_ pane: PaneID) {
        for content in planner.closePane(pane) {
            park(content)
        }
        if focusedPane == pane {
            focusedPane = nil
            if let next = planner.nextFocus(afterClosing: pane) {
                rebuild()
                focusPane(next)
                return
            }
            // Last pane closed: nothing to hand focus to, so the coordinator
            // must drop the closed item too — tickVisibility would otherwise
            // keep marking the parked agent seen.
            focusCoordinator.setFocused(item: nil)
        }
        rebuild()
    }

    func parkAllSurfaces() {
        for leaf in planner.leaves {
            park(leaf.content)
        }
    }

    private func park(_ content: PaneContent) {
        switch content {
        case let .terminal(id):
            try? sessionManager.park(terminalID: id)
        case let .agent(id):
            if let terminal = model.agentTerminal[id] {
                try? sessionManager.park(terminalID: terminal)
            }
        case .placeholder:
            break
        }
    }

    /// Mounts the surface for a pane's current content into that pane.
    func mountContent(of pane: PaneID) {
        guard let controller = paneControllers[pane],
              let content = planner.content(of: pane) else { return }
        let terminal: TerminalID? = switch content {
        case let .terminal(id): id
        case let .agent(id): model.agentTerminal[id]
        case .placeholder: nil
        }
        guard let terminal else { return }
        try? sessionManager.mount(terminalID: terminal, paneID: pane, container: controller.terminalContainer)
    }

    /// Clean-restore step 3 (§3.15): adopt a restored layout tree under its
    /// STABLE pane keys, mount only live contents (placeholders stay empty),
    /// and restore the persisted selection.
    func applyRestored(tree: LayoutTree, selectedAgentID: AgentID?) {
        planner = CanvasLayoutPlanner(tree: tree)
        focusedPane = nil
        rebuild()
        for leaf in planner.leaves where leaf.content != .placeholder {
            // Dead contents were already mapped to placeholders upstream;
            // mountContent no-ops when a terminal is not (yet) live.
            mountContent(of: leaf.paneID)
        }
        if let selected = selectedAgentID,
           let pane = planner.leaves.first(where: { $0.content == .agent(selected) })?.paneID
        {
            focusPane(pane)
        }
    }

    // MARK: focus

    func focusPane(_ pane: PaneID) {
        focusedPane = pane
        if let controller = paneControllers[pane] {
            controller.setFocused(true)
        }
        for (id, controller) in paneControllers where id != pane {
            controller.setFocused(false)
        }
        // Native surface focus via idempotent re-mount (see FocusCoordinator note).
        mountContent(of: pane)
        // Review5 #2: typed input must reach the terminal — make the mounted
        // ghostty surface view the first responder (it acceptsFirstResponder
        // and owns the keyDown path). A placeholder pane must NOT leave the
        // demoted pane's surface as first responder — keystrokes would keep
        // flowing to it — so first responder is explicitly cleared.
        refocusSurfaceView()
        if let content = planner.content(of: pane) {
            focusCoordinator.setFocused(item: sidebarItem(for: content))
            onSelectionChanged?(content)
        }
    }

    private func refocusSurfaceView() {
        guard let pane = focusedPane,
              let content = planner.content(of: pane) else { return }
        let terminalID: TerminalID? = switch content {
        case let .terminal(id): id
        case let .agent(id): model.agentTerminal[id]
        case .placeholder: nil
        }
        // TerminalKit owns presentation AND input focus; a placeholder (or a
        // closing surface) must not keep keystrokes flowing to stale panes.
        if let terminalID, sessionManager.focusInput(terminalID: terminalID) {
            return
        }
        view.window?.makeFirstResponder(nil)
    }

    func refocusTerminalSurface() {
        if let pane = focusedPane {
            focusPane(pane)
        }
    }

    private func sidebarItem(for content: PaneContent) -> SidebarItem? {
        switch content {
        case let .agent(id): .agent(id)
        case let .terminal(id): .shell(id)
        case .placeholder: nil
        }
    }

    var focusedContent: PaneContent? {
        focusedPane.flatMap { planner.content(of: $0) }
    }

    // MARK: rendering

    func rebuild() {
        let canvas = canvasView
        let existing = Set(paneControllers.keys)
        let wanted = Set(planner.leaves.map(\.paneID))

        for stale in existing.subtracting(wanted) {
            paneControllers[stale]?.view.removeFromSuperview()
            paneControllers[stale] = nil
        }
        for leaf in planner.leaves {
            if paneControllers[leaf.paneID] == nil {
                let controller = TerminalPaneController(paneID: leaf.paneID)
                controller.onClicked = { [weak self] pane in self?.focusPane(pane) }
                controller.onParkRequested = { [weak self] pane in
                    // closePane synchronously refocuses the next pane's surface;
                    // do NOT clear first responder here or typed input dies until
                    // the next click.
                    self?.closePane(pane)
                    if let window = self?.view.window, let wc = window.windowController as? MainWindowController {
                        wc.refreshChrome()
                    }
                }
                controller.onDropItem = { [weak self] pane, item in
                    self?.replace(pane: pane, with: item) ?? false
                }
                controller.onContextualAction = { [weak self] pane in
                    // §3.13 contextual header action → the SAME RuntimeSeam
                    // paths the menu commands use (Interrupt/Resume).
                    guard let self, case let .agent(id) = planner.content(of: pane) else { return }
                    switch model.agents[id]?.state.lifecycle {
                    case .working, .starting:
                        Task { await self.seam.interrupt(.agent(id)) }
                    case .stopped, .failed:
                        Task { await self.seam.resume(.agent(id)) }
                    default:
                        break
                    }
                }
                paneControllers[leaf.paneID] = controller
                canvas.addSubview(controller.view)
            }
        }
        canvas.needsLayout = true
        refreshHeaders(model: model)
        onSelectionChanged?(focusedContent)
    }

    func refreshHeaders(model: AppModel) {
        for (pane, controller) in paneControllers {
            let content = planner.content(of: pane)
            controller.update(content: content, model: model, isFocused: pane == focusedPane)
        }
    }

    // MARK: CanvasViewDelegate

    func canvasFrames() -> [CanvasFrameRequest] {
        planner.leaves.map { leaf in
            CanvasFrameRequest(paneID: leaf.paneID, content: leaf.content)
        }
    }

    func canvasLayoutSubviews() {
        let bounds = view.bounds
        for frame in planner.frames(in: bounds) {
            paneControllers[frame.paneID]?.view.frame = frame.rect
        }
    }

    func canvasDividers() -> [DividerGeometry] {
        planner.dividers(in: view.bounds)
    }

    func canvasResize(path: [Int], ratio: Double) {
        planner.setRatio(path: path, ratio)
        canvasView.needsLayout = true
    }
}

struct CanvasFrameRequest {
    let paneID: PaneID
    let content: PaneContent
}

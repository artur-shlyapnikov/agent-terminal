import AgentCore
import AppKit
import TerminalKit

// Three-pane container (§3.13): sidebar 260 pt / canvas / inspector 320 pt.

@MainActor
final class MainSplitViewController: NSSplitViewController {
    let canvas: AgentCanvasController
    let model: AppModel
    let seam: RuntimeSeam
    private let sidebar: AgentSidebarViewController
    private let inspector: AgentInspectorController
    /// Assigned by MainWindowController after split construction; selection
    /// events can fire BEFORE that assignment, so the setter replays one
    /// refresh to make up the lost early event.
    weak var composer: PromptComposerView? {
        didSet { composer?.refresh() }
    }

    init(canvas: AgentCanvasController, model: AppModel, seam: RuntimeSeam) {
        self.canvas = canvas
        self.model = model
        self.seam = seam
        sidebar = AgentSidebarViewController(model: model) { [weak canvas] item, kind in
            canvas?.sidebarClicked(item: item, kind: kind)
        }
        inspector = AgentInspectorController(model: model, seam: seam)

        super.init(nibName: nil, bundle: nil)

        canvas.onSelectionChanged = { [weak inspector, weak model, weak sidebar] pane in
            let row = pane.flatMap { model?.row(forPaneContent: $0) }
            inspector?.setSelected(row)
            sidebar?.setSelected(row?.item)
        }
        sidebar.selectionPublisher = { [weak self] _ in
            self?.composer?.refresh()
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        // Stage-10: fraction-based sizing kept fighting applyInitialDividers
        // (observed 233 pt); the deterministic 260 pt divider below owns it.
        sidebarItem.preferredThicknessFraction = 260.0 / 1440.0
        print("[LAUNCH] split: adding sidebar")
        addSplitViewItem(sidebarItem)
        print("[LAUNCH] split: sidebar added")
        let canvasItem = NSSplitViewItem(viewController: canvas)
        canvasItem.minimumThickness = 320
        print("[LAUNCH] split: adding canvas")
        addSplitViewItem(canvasItem)
        print("[LAUNCH] split: canvas added")

        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 480
        addSplitViewItem(inspectorItem)
        print("[LAUNCH] split: inspector added")

        splitView.autosaveName = "aterm.main.split"
        print("[LAUNCH] split: autosave set")
        scheduleInitialDividers()
        print("[LAUNCH] split: init done")
    }

    /// Named access to the three panes (visual acceptance + tests).
    var sidebarPaneView: NSView {
        splitView.arrangedSubviews[0]
    }

    var canvasPaneView: NSView {
        splitView.arrangedSubviews[1]
    }

    var inspectorPaneView: NSView {
        splitView.arrangedSubviews[2]
    }

    /// Review5 #3 root cause: `setFrameSize` on arranged panes is overwritten
    /// by NSSplitView's next layout pass, collapsing panes back to their
    /// minimums. Real divider geometry must go through `setPosition`.
    func applyInitialDividers() {
        view.layoutSubtreeIfNeeded()
        let total = splitView.bounds.width
        guard total > 700 else { return } // window not sized yet; skip
        splitView.setPosition(260, ofDividerAt: 0)
        splitView.setPosition(total - 320, ofDividerAt: 1)
        splitView.layoutSubtreeIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        print("[LAUNCH] split: viewDidLoad enter")
        splitView.dividerStyle = .thin
        print("[LAUNCH] split: viewDidLoad exit")
    }

    private func scheduleInitialDividers() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Autosaved geometry wins once it exists — the deterministic
            // 260/320 layout is first-launch-only, never a per-launch
            // override of the user's saved dividers.
            let defaults = UserDefaults.standard
            guard let name = splitView.autosaveName else {
                applyInitialDividers()
                return
            }
            if defaults.string(forKey: name) != nil
                || defaults.dictionaryRepresentation()["NSSplitView Subview Frames \(name)"] != nil
            {
                return
            }
            applyInitialDividers()
        }
    }

    func refresh() {
        sidebar.refresh()
        canvas.refreshHeaders(model: model)
        inspector.refresh()
    }

    // MARK: toggles

    func toggleSidebar() {
        let item = splitViewItems[0]
        item.animator().isCollapsed = !item.isCollapsed
    }

    func toggleInspector() {
        let item = splitViewItems[2]
        item.animator().isCollapsed = !item.isCollapsed
    }
}

extension AppModel {
    /// RowModel for whatever content a pane currently shows.
    @MainActor
    func row(forPaneContent content: PaneContent) -> RowModel? {
        switch content {
        case let .agent(id):
            guard let summary = agents[id] else { return nil }
            return SidebarGrouping.row(for: summary)
        case let .terminal(id):
            guard let shell = shells[id] else { return nil }
            return SidebarGrouping.row(for: shell)
        case .placeholder:
            return nil
        }
    }
}

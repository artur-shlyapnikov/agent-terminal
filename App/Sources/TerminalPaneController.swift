import AgentCore
import AppKit

// Native host for one surface (§4.6): header + terminal container.
// The pane is a drag destination for sidebar items (drag agent onto pane →
// replace content) and reports clicks for focus handling.

@MainActor
final class TerminalPaneController: NSViewController {
    let paneID: PaneID
    let terminalContainer = PaneTerminalContainer()
    private let header = PaneHeaderView()
    /// Centered guidance shown when the pane body is empty/placeholder.
    /// Copy names the click path FIRST: plain-clicking a sidebar row opens
    /// it here (§3.13) — drag is optional, ⌘N covers the no-agents case.
    private let hintLabel = NSTextField(wrappingLabelWithString:
        NSLocalizedString(
            "Click an agent in the sidebar to open it here — or press ⌘N to start one",
            comment: "Empty pane hint"
        ))

    var onClicked: ((PaneID) -> Void)?
    var onParkRequested: ((PaneID) -> Void)?
    var onDropItem: ((PaneID, SidebarItem) -> Bool)?
    /// §3.13 contextual header action (Interrupt/Resume) — routed by the
    /// canvas into the RuntimeSeam paths.
    var onContextualAction: ((PaneID) -> Void)?

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(nibName: nil, bundle: nil)
        header.onPark = { [weak self] in
            guard let self else { return }
            onParkRequested?(self.paneID)
        }
        header.onContextualAction = { [weak self] in
            guard let self else { return }
            onContextualAction?(self.paneID)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    override func loadView() {
        let container = PaneContainer()
        container.controller = self

        header.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(terminalContainer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),

            terminalContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.wantsLayer = true
        view = container
        registerForDraggedTypes()
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.preferredMaxLayoutWidth = 220
        hintLabel.isSelectable = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setAccessibilityIdentifier("pane.empty-hint")
        terminalContainer.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor),
            // Wrap to the pane: without a leading/trailing bound the ~220pt
            // intrinsic label overflows narrow panes and paints over the
            // neighboring panes (no view clips its subviews here).
            hintLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: terminalContainer.leadingAnchor, constant: 12
            ),
            hintLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: terminalContainer.trailingAnchor, constant: -12
            ),
        ])
        // Placeholder chrome must never bleed across divider lines.
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.masksToBounds = true
    }

    var paneContainer: PaneContainer {
        guard let container = view as? PaneContainer else {
            preconditionFailure("TerminalPaneController.view is always the PaneContainer built in loadView()")
        }
        return container
    }

    func setFocused(_ focused: Bool) {
        paneContainer.isFocusedPane = focused
        paneContainer.needsDisplay = true
    }

    func update(content: PaneContent?, model: AppModel, isFocused: Bool) {
        switch content {
        case let .terminal(id):
            if let shell = model.shells[id] {
                header.update(
                    title: shell.name,
                    state: NSLocalizedString("shell", comment: "Pane header state: shell surface"),
                    cwd: shell.cwd
                )
            } else {
                header.update(
                    title: NSLocalizedString("Terminal", comment: "Default shell display name"),
                    state: "",
                    cwd: nil
                )
            }
            header.setContextualAction(nil)
            header.setActionsEnabled(true)
        case let .agent(id):
            var action: PaneHeaderView.ContextualAction?
            if let summary = model.agents[id] {
                header.update(
                    title: summary.displayName,
                    state: SidebarGrouping.stateText(summary),
                    cwd: model.agentCwd[id]
                )
                // §3.13 contextual action: working → Interrupt,
                // stopped/failed → Resume; everything else none.
                switch summary.state.lifecycle {
                case .working, .starting: action = .interrupt
                case .stopped, .failed: action = .resume
                default: action = nil
                }
            } else {
                header.update(
                    title: NSLocalizedString("Unknown agent", comment: "Pane header title: agent left the model"),
                    state: "",
                    cwd: nil
                )
            }
            header.setContextualAction(action)
            header.setActionsEnabled(true)
        case nil:
            header.update(
                title: "—",
                state: NSLocalizedString("empty", comment: "Pane header state: no content"),
                cwd: nil
            )
            header.setContextualAction(nil)
            header.setActionsEnabled(false)
        case .placeholder:
            header.update(
                title: NSLocalizedString("Empty pane", comment: "Pane header title: placeholder pane"),
                state: "",
                cwd: nil
            )
            header.setContextualAction(nil)
            // Park stays live: an accidental split must be dismissible
            // without filling the pane first.
            header.setActionsEnabled(true)
        }
        hintLabel.isHidden = !(content == nil || content == .placeholder)
        setFocused(isFocused)
    }

    // MARK: drag & drop (§3.13: drag agent onto pane → replace content)

    private static let dropType = NSPasteboard.PasteboardType("dev.aterm.sidebar-item")

    private func registerForDraggedTypes() {
        terminalContainer.registerForDraggedTypes([Self.dropType])
        terminalContainer.onDrop = { [weak self] item in
            guard let self else { return false }
            // Rejected replaces (invalid target, duplicate content) must not
            // animate as a successful move.
            return onDropItem?(paneID, item) ?? false
        }
    }

    /// The single §3.13 drag payload — one writer per pasteboard carrier,
    /// so a sidebar drag and a programmatic encode are byte-identical.
    static func dropPayload(for item: SidebarItem) -> String {
        switch item {
        case let .agent(id): "agent:\(id.rawValue.uuidString)"
        case let .shell(id): "shell:\(id.rawValue.uuidString)"
        }
    }

    static func writeDrop(item: SidebarItem, into pb: NSPasteboard) {
        pb.declareTypes([dropType], owner: nil)
        pb.setString(dropPayload(for: item), forType: dropType)
    }

    /// Drag-source variant: NSDraggingItem consumes an NSPasteboardItem.
    static func writeDrop(item: SidebarItem, into pasteboardItem: NSPasteboardItem) {
        pasteboardItem.setString(dropPayload(for: item), forType: dropType)
    }

    static func encodeDrop(item: SidebarItem) -> NSPasteboard {
        let pb = NSPasteboard(name: .init(Self.dropType.rawValue + ".scratch"))
        pb.clearContents()
        writeDrop(item: item, into: pb)
        return pb
    }

    static func decodeDrop(_ pb: NSPasteboard) -> SidebarItem? {
        guard let raw = pb.string(forType: dropType) else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "agent": return .agent(AgentID(rawValue: uuid))
        case "shell": return .shell(TerminalID(rawValue: uuid))
        default: return nil
        }
    }
}

// MARK: - container views

@MainActor
final class PaneContainer: NSView {
    weak var controller: TerminalPaneController?
    var isFocusedPane = false {
        didSet { needsDisplay = true; layer?.borderWidth = 0 }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Native-style focus ring without decorative frames (§3.13).
        layer?.cornerRadius = 4
        layer?.borderWidth = 1.5
        layer?.borderColor = isFocusedPane
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        controller?.onClicked?(controller!.paneID)
        // Review5 #2: do NOT steal first responder here — the click routes
        // through focusPane, which makes the mounted surface view first
        // responder so typed input reaches the terminal.
        super.mouseDown(with: event)
    }
}

/// Terminal host view; also the drag destination and the first responder that
/// forwards unclaimed key events to the ghostty surface view chain.
@MainActor
final class PaneTerminalContainer: NSView {
    var onDrop: ((SidebarItem) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        TerminalPaneController.decodeDrop(sender.draggingPasteboard) != nil ? .move : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let item = TerminalPaneController.decodeDrop(sender.draggingPasteboard) else { return false }
        return onDrop?(item) ?? false
    }
}

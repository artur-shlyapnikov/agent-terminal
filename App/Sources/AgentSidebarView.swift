import AgentCore
import AppKit

// Attention-grouped sidebar (§3.13). Rows show state icon + state text +
// name + task summary + queued indicator; state is never color-only.
// Double-click never creates tabs (rows have no tab behavior at all).

@MainActor
final class AgentSidebarViewController: NSViewController {
    private let model: AppModel
    private let stack = NSStackView()
    private let onClick: (SidebarItem, ClickKind) -> Void
    var selectionPublisher: ((SidebarItem?) -> Void)?
    /// One refreshable sidebar entry: a section header, a row, or the
    /// polished empty state. Equality over the payload drives the §4.6 diff
    /// in refresh().
    private enum SidebarEntry: Equatable {
        case section(title: String)
        case row(RowModel)
        case emptyState
    }

    /// Entries currently displayed, with their views (parallel arrays).
    /// refresh() diffs against these instead of tearing the stack down on
    /// every model delta.
    private var displayed: [SidebarEntry] = []
    private var entryViews: [NSView] = []

    /// Canvas-focus mirror: the selected row renders a steady highlight;
    /// press/hover tints stay transient feedback on top of it.
    private var selectedItem: SidebarItem?

    /// Called with the canvas's focused pane content so the sidebar can
    /// render which agent/shell is on screen.
    func setSelected(_ item: SidebarItem?) {
        guard selectedItem != item else { return }
        selectedItem = item
        applySelection()
    }

    /// Restamps row backgrounds from selectedItem without rebuilding.
    private func applySelection() {
        for (index, entry) in displayed.enumerated() where entryViews.indices.contains(index) {
            guard case let .row(row) = entry else { continue }
            (entryViews[index] as? AgentRowView)?.setSelected(row.item == selectedItem)
        }
    }

    func refresh() {
        guard isViewLoaded else { return }
        var entries: [SidebarEntry] = []
        for section in model.sections {
            entries.append(.section(title: section.title))
            entries.append(contentsOf: section.rows.map { .row($0) })
        }
        if model.sections.isEmpty {
            entries.append(.emptyState)
        }

        // §4.6 whole-model fan-out: identical visible payload is a no-op,
        // same-structure payload changes (state text, duration tick, badge,
        // rename within a bucket) update the existing views in place, and
        // only a structural change (bucket move, add/remove) rebuilds.
        guard entries != displayed else { return }
        if entries.count == displayed.count,
           zip(entries, displayed).allSatisfy(Self.isSameKind)
        {
            for (index, entry) in entries.enumerated() where entry != displayed[index] {
                apply(entry, to: entryViews[index])
            }
            displayed = entries
            return
        }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        displayed = entries
        entryViews = entries.map { buildView(for: $0) }
        for subview in entryViews {
            stack.addArrangedSubview(subview)
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Builds the view for one entry (full-rebuild path).
    private func buildView(for entry: SidebarEntry) -> NSView {
        switch entry {
        case let .section(rawTitle):
            let title = NSTextField(labelWithString: rawTitle.uppercased())
            title.font = .systemFont(ofSize: 10, weight: .semibold)
            title.setAccessibilityLabel(String(
                format: NSLocalizedString("Section %@", comment: "Sidebar accessibility label for a section header"),
                rawTitle
            ))
            title.textColor = .secondaryLabelColor
            let titleWrap = NSView()
            titleWrap.translatesAutoresizingMaskIntoConstraints = false
            title.translatesAutoresizingMaskIntoConstraints = false
            titleWrap.addSubview(title)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: titleWrap.leadingAnchor, constant: 10),
                title.centerYAnchor.constraint(equalTo: titleWrap.centerYAnchor),
                titleWrap.heightAnchor.constraint(equalToConstant: 22),
            ])
            return titleWrap
        case let .row(row):
            let rowView = AgentRowView(model: row)
            rowView.setSelected(row.item == selectedItem)
            rowView.onClicked = { [weak self] item, kind in
                self?.onClick(item, kind)
                self?.selectionPublisher?(item)
            }
            return rowView
        case .emptyState:
            // §4.6/§3.23 polished empty state: actionable copy, VoiceOver
            // readable as one static element.
            // One instructor only: the canvas carries the launch
            // instructions; the sidebar just labels the empty list.
            let empty = NSTextField(wrappingLabelWithString:
                NSLocalizedString(
                    "No agents yet.",
                    comment: "Sidebar empty-state message"
                ))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.preferredMaxLayoutWidth = 220
            empty.setAccessibilityElement(true)
            empty.setAccessibilityLabel(NSLocalizedString(
                "No agents yet. Press Command N to launch an agent.",
                comment: "Accessibility label for the sidebar empty state"
            ))
            empty.setAccessibilityIdentifier("sidebar.empty")
            empty.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
                empty.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -10),
                empty.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
                empty.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
            ])
            return wrap
        }
    }

    /// Applies a changed entry to its existing view (in-place fast path).
    private func apply(_ entry: SidebarEntry, to view: NSView) {
        switch entry {
        case let .section(title):
            guard let label = view.subviews.first as? NSTextField else { return }
            label.stringValue = title.uppercased()
            label.setAccessibilityLabel(String(
                format: NSLocalizedString("Section %@", comment: "Sidebar accessibility label for a section header"),
                title
            ))
        case let .row(row):
            (view as? AgentRowView)?.update(row)
        case .emptyState:
            break // static polished copy
        }
    }

    private static func isSameKind(_ lhs: SidebarEntry, _ rhs: SidebarEntry) -> Bool {
        switch (lhs, rhs) {
        case (.section, .section), (.row, .row), (.emptyState, .emptyState):
            true
        default:
            false
        }
    }

    init(model: AppModel, onClick: @escaping (SidebarItem, ClickKind) -> Void) {
        self.model = model
        self.onClick = onClick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    override func loadView() {
        print("[LAUNCH] sidebar: loadView enter")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        // Top-pin the document view: an autolayout documentView shorter than
        // the viewport otherwise sinks to the BOTTOM of the scroll area.
        stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        stack.bottomAnchor.constraint(
            greaterThanOrEqualTo: scroll.contentView.bottomAnchor
        ).isActive = true

        let header = NSTextField(labelWithString: NSLocalizedString(
            "Agents",
            comment: "Sidebar section header above the agent list"
        ))
        header.font = .boldSystemFont(ofSize: 13)
        let wrap = NSView()
        wrap.addSubview(header)
        header.frame = NSRect(x: 12, y: 8, width: 200, height: 20)

        let container = NSView()
        container.addSubview(wrap)
        container.addSubview(scroll)
        wrap.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wrap.topAnchor.constraint(equalTo: container.topAnchor),
            wrap.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wrap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wrap.heightAnchor.constraint(equalToConstant: 32),

            scroll.topAnchor.constraint(equalTo: wrap.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        print("[LAUNCH] sidebar: pre-refresh")
        refresh()
        print("[LAUNCH] sidebar: loadView done")
    }
}

// MARK: - row

@MainActor
final class AgentRowView: NSView, NSDraggingSource {
    private(set) var row: RowModel
    var onClicked: ((SidebarItem, ClickKind) -> Void)?

    /// Steady selection state, driven by the canvas focus (§3.13).
    private var isSelected = false

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        layer?.backgroundColor = selected
            ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            : nil
    }

    private let symbol = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    /// Last-activity age (§3.13) — hidden when the model has no clock.
    private let durationLabel = NSTextField(labelWithString: "")
    private let queueBadge = NSTextField(labelWithString: NSLocalizedString(
        "queued",
        comment: "Badge shown when an agent holds a queued prompt"
    ))

    /// mouseDown event retained so mouseDragged can open the drag session
    /// with the ORIGINAL press event (§3.13 drag-replace source, review M-drag).
    private var pendingMouseDown: NSEvent?

    /// Drag threshold before a press becomes a drag (points).
    static let dragThreshold: CGFloat = 4

    init(model row: RowModel) {
        self.row = row
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 4

        symbol.image = NSImage(systemSymbolName: row.stateSymbol, accessibilityDescription: row.stateText)
        symbol.contentTintColor = .secondaryLabelColor

        titleLabel.stringValue = row.title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.stringValue = row.subtitle
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        durationLabel.font = .systemFont(ofSize: 9)
        durationLabel.textColor = .tertiaryLabelColor
        durationLabel.isHidden = row.durationText.isEmpty
        durationLabel.stringValue = row.durationText
        durationLabel.toolTip = NSLocalizedString(
            "Time since last activity",
            comment: "Tooltip for the last-activity duration label"
        )

        // State as text — never color-only (§3.13).
        stateLabel.stringValue = row.stateText
        stateLabel.font = .systemFont(ofSize: 9)
        stateLabel.textColor = .secondaryLabelColor
        queueBadge.isHidden = !row.showsQueuedBadge
        queueBadge.toolTip = NSLocalizedString(
            "The agent has a prompt waiting to run",
            comment: "Tooltip for the queued badge"
        )
        stateLabel.toolTip = NSLocalizedString(
            "Current lifecycle state of the agent",
            comment: "Tooltip for the lifecycle state label"
        )

        addSubview(symbol)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(durationLabel)
        addSubview(stateLabel)
        addSubview(queueBadge)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        queueBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stateLabel.leadingAnchor, constant: -6),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stateLabel.leadingAnchor, constant: -6),

            queueBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            queueBadge.centerYAnchor.constraint(equalTo: centerYAnchor),

            durationLabel.trailingAnchor.constraint(equalTo: queueBadge.leadingAnchor, constant: -6),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            stateLabel.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -6),
            stateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Closes the vertical chain (title top+4 → subtitle → bottom):
            // without a bottom pin the row's Auto Layout height is ZERO and
            // rows render invisible inside the scroll view.
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            heightAnchor.constraint(lessThanOrEqualToConstant: 44),
        ])
        toolTip = row.tooltip
        // §3.23 VoiceOver: a sidebar row reads as ONE element — name, state
        // text (never color-only), task summary.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        applyAccessibilityLabel()
        setAccessibilityIdentifier("sidebar.row")
    }

    /// §3.23 VoiceOver: a sidebar row reads as ONE element — name, state
    /// text (never color-only), task summary.
    private func applyAccessibilityLabel() {
        let subtitleSuffix = row.subtitle.isEmpty ? "" : String(
            format: NSLocalizedString(", %@", comment: "Sidebar row accessibility label: subtitle suffix"),
            row.subtitle
        )
        setAccessibilityLabel(String(
            format: NSLocalizedString("%1$@, %2$@%3$@",
                                      comment: "Sidebar row accessibility label: title, state text, optional subtitle"),
            row.title,
            row.stateText,
            subtitleSuffix
        ))
    }

    /// §4.6 in-place refresh: same row slot, new payload. Mutates labels,
    /// badge, symbol, and accessibility in place — no view replacement, no
    /// constraint churn, no layer rebuild.
    func update(_ newRow: RowModel) {
        guard newRow != row else { return }
        if newRow.stateSymbol != row.stateSymbol || newRow.stateText != row.stateText {
            symbol.image = NSImage(
                systemSymbolName: newRow.stateSymbol,
                accessibilityDescription: newRow.stateText
            )
        }
        titleLabel.stringValue = newRow.title
        subtitleLabel.stringValue = newRow.subtitle
        stateLabel.stringValue = newRow.stateText
        durationLabel.stringValue = newRow.durationText
        durationLabel.isHidden = newRow.durationText.isEmpty
        queueBadge.isHidden = !newRow.showsQueuedBadge
        toolTip = newRow.tooltip
        row = newRow
        applyAccessibilityLabel()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    override func mouseDown(with event: NSEvent) {
        // §3.13: ⌥-click means "create a split and show the agent" — the
        // decision kind is read off the press modifiers, never lost. A press
        // carrying ⌥ is ALSO excluded from the drag source: option-click
        // splits immediately and must never open a drag session.
        let kind: ClickKind = event.modifierFlags.contains(.option) ? .option : .plain
        pendingMouseDown = kind == .plain ? event : nil
        layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        onClicked?(row.item, kind)
    }

    /// §3.13 drag-replace SOURCE half: pressing a row and dragging past the
    /// threshold begins a .move drag session carrying the exact pasteboard
    /// payload TerminalPaneController.decodeDrop consumes.
    override func mouseDragged(with event: NSEvent) {
        guard let down = pendingMouseDown else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > Self.dragThreshold else { return }
        pendingMouseDown = nil

        let pbItem = NSPasteboardItem()
        TerminalPaneController.writeDrop(item: row.item, into: pbItem)
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        dragItem.draggingFrame = NSRect(
            origin: convert(down.locationInWindow, from: nil), size: bounds.size
        )
        dragItem.imageComponentsProvider = nil
        beginDraggingSession(with: [dragItem], event: down, source: self)
    }

    override func mouseUp(with _: NSEvent) {
        pendingMouseDown = nil
        restoreBaseBackground()
    }

    func draggingSession(
        _: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    override func mouseExited(with _: NSEvent) {
        restoreBaseBackground()
    }

    override func mouseEntered(with _: NSEvent) {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    /// Selected rows keep their steady highlight; unselected rows carry no
    /// layer background at rest (init sets only wantsLayer + cornerRadius) —
    /// clear any pressed/hover tint back to that state.
    private func restoreBaseBackground() {
        layer?.backgroundColor = isSelected
            ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            : nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    /// VoiceOver/keyboard activation: rows advertise as buttons (§3.23).
    override func accessibilityPerformPress() -> Bool {
        onClicked?(row.item, .plain)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Idempotent: drop this row's previous area before adding a fresh one,
        // otherwise every layout pass accumulates another NSTrackingArea.
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }
}

import AppKit
import QuartzCore

// Command palette (architecture §3.13 ⌘⇧P): searchable command dispatch over
// the FULL §3.13 command set (stage-15 completes the list — New Agent, Focus
// Agent, Next Attention, Split Right/Down, Close View, Interrupt, Stop Agent,
// Restart/Resume, Toggle Sidebar/Inspector, Install/Repair Integration,
// Open Workspace, Export Diagnostics).
//
// The palette owns NO behavior: it renders [CommandDefinition] supplied by
// AppCommands and dispatches the chosen selector back through it.
//
// UX contract: the result list is a real selectable table — ↑/↓ (and
// PageUp/PageDown) move the highlighted selection, Enter commits the SELECTED
// row (not blindly the top match), double-click commits, and a filter with no
// matches shows an explicit empty-state row instead of blank space.

@MainActor
struct CommandDefinition {
    let title: String
    /// §3.13 shortcut hint shown in the palette row (nil for menu-only extras).
    var shortcut: AppShortcut?
    let action: Selector
}

/// Search field; Enter commits the selected match, Esc dismisses. Arrow-key
/// navigation is intercepted by the controller via the field-editor delegate
/// callback (`control(_:textView:doCommandBy:)`), which sees the command
/// before the single-line field editor consumes it.
@MainActor
final class PaletteField: NSTextField {
    weak var palette: CommandPaletteController?

    override func cancelOperation(_: Any?) {
        palette?.dismiss()
    }

    override func insertNewline(_: Any?) {
        palette?.commitSelected()
    }

    override func textDidChange(_: Notification) {
        palette?.refreshList()
    }
}

/// One result row: title (truncates first) + right-aligned shortcut hint
/// (stays readable — the hint must never be the first thing clipped).
@MainActor
final class PaletteRowView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let shortcutLabel = NSTextField(labelWithString: "")

    init(rendered: CommandDefinition) {
        super.init(frame: .zero)
        titleLabel.stringValue = rendered.title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel.stringValue = rendered.shortcut?.displayText ?? ""
        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }
}

@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate {
    private let definitions: () -> [CommandDefinition]
    private let dispatch: (Selector) -> Void
    private var panel: NSPanel?
    private var field: PaletteField?
    private var table: NSTableView?
    /// Block-based didResignKey observer token; removed in dismiss()/deinit.
    private var resignKeyToken: NSObjectProtocol?
    /// Time the palette was last presented (CACurrentMediaTime). Menu-bar
    /// invocations trigger a key-storm for ~2 s (menu teardown re-keys the
    /// previously-key window); the resign handler uses this to distinguish
    /// that storm from a genuine click-away.
    private var presentedAt: CFTimeInterval = 0
    private(set) var matches: [CommandDefinition] = []
    /// Index into `matches` of the highlighted row; nil when nothing matches.
    private var selectedIndex: Int?
    /// Viewport height of the result list — always a whole number of rows.
    private var listHeightConstraint: NSLayoutConstraint?

    /// Row geometry shared by the table and the panel sizing math.
    private static let rowHeight: CGFloat = 26
    private static let chromeHeight: CGFloat = 48 // 10 top + 22 field + 8 gap + 8 bottom
    private static let minListRows: CGFloat = 2
    private static let maxListRows: CGFloat = 12

    init(definitions: @escaping () -> [CommandDefinition],
         dispatch: @escaping (Selector) -> Void)
    {
        self.definitions = definitions
        self.dispatch = dispatch
        super.init()
    }

    // MARK: Presentation

    func present() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: Self.chromeHeight + Self.minListRows * Self.rowHeight),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // Accessibility (§3.23): the palette is a named dialog with a labelled
        // search field and an announcement-friendly result list.
        panel.setAccessibilityLabel(NSLocalizedString(
            "Command Palette",
            comment: "Accessibility label for the command palette panel"
        ))

        let field = PaletteField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.palette = self
        field.delegate = self
        field.placeholderString = NSLocalizedString(
            "Type a command…",
            comment: "Placeholder for the palette search field"
        )
        field.setAccessibilityLabel(NSLocalizedString(
            "Search commands",
            comment: "Accessibility label for the palette search field"
        ))
        field.setAccessibilityIdentifier("palette.search")

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.setAccessibilityLabel(NSLocalizedString(
            "Matching commands",
            comment: "Accessibility label for the palette result list"
        ))
        table.setAccessibilityIdentifier("palette.results")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("palette.command"))
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
        ])
        // Whole-row viewport: a partial row at the bottom reads as a
        // rendering glitch, not as a scroll affordance.
        listHeightConstraint = scroll.heightAnchor.constraint(
            equalToConstant: Self.minListRows * Self.rowHeight
        )
        listHeightConstraint?.isActive = true

        if let window = NSApp.mainWindow {
            // Anchor the palette's TOP edge in the window's upper fifth:
            // resizePanelToFit() pins the top-left while growing, so the
            // grown list extends DOWNWARD from here (Spotlight-style).
            // Centering the initial 110-pt panel made the grown panel
            // drift into the bottom half of the window.
            let top = window.frame.maxY - window.frame.height * 0.2
            panel.setFrameOrigin(NSPoint(
                x: window.frame.midX - 260, y: top - panel.frame.height
            ))
        }
        self.panel?.orderOut(nil)
        self.panel = panel
        self.field = field
        self.table = table
        // Dismiss when the panel loses key status (e.g. the user clicks into
        // the main window or another app) so it never floats indefinitely.
        presentedAt = CACurrentMediaTime()
        if let resignKeyToken {
            NotificationCenter.default.removeObserver(resignKeyToken)
        }
        resignKeyToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel === panel, panel.isVisible else { return }
                if CACurrentMediaTime() - self.presentedAt < 2.5 {
                    // Menu teardown re-keyed the previous key window; take
                    // key back until the storm passes.
                    panel.makeKeyAndOrderFront(nil)
                    panel.makeFirstResponder(self.field)
                } else {
                    self.dismiss()
                }
            }
        }
        selectedIndex = nil
        refreshList()
        // Take key one tick later: a menu-bar invocation returns key focus
        // to the previously-key window when menu tracking ends, and doing
        // it synchronously inside the action gets overridden — the
        // didResignKey observer then dismisses the palette before it ever
        // renders. After tracking has fully ended, nothing re-keys and the
        // panel keeps key (keyboard ⌘⇧P path unaffected).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel === panel else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
        }
    }

    // MARK: List state

    func refreshList() {
        guard let field, let table else { return }
        let query = field.stringValue.lowercased()
        // Keep the highlight on the previously selected command when it still
        // matches; otherwise fall back to the top match.
        let previousTitle = selectedIndex.flatMap {
            matches.indices.contains($0) ? matches[$0].title : nil
        }
        // This toolchain's Foundation returns NIL/false for empty-string
        // containment (regex-comparison semantics), which rendered
        // "No matching commands" on open — an empty query must list ALL
        // commands, so it bypasses the search entirely.
        matches = query.isEmpty
            ? definitions()
            : definitions().filter {
                $0.title.range(of: query, options: .caseInsensitive) != nil
            }
        selectedIndex = matches.firstIndex { $0.title == previousTitle }
            ?? (matches.isEmpty ? nil : 0)
        table.reloadData()
        if let selected = selectedIndex {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        }
        table.setAccessibilityValue(String(
            format: NSLocalizedString("%lld matching commands", comment: "Announced count of palette results"),
            matches.count
        ))
        resizePanelToFit()
    }

    /// Panel hugs its content: grows with results up to a page, shrinks back
    /// down. Top-left stays pinned so growth reads as the list extending.
    private func resizePanelToFit() {
        guard let panel else { return }
        let rows = CGFloat(max(matches.count, 1))
        let visibleRows = min(max(rows, Self.minListRows), Self.maxListRows)
        let height = Self.chromeHeight + visibleRows * Self.rowHeight
        let target = NSSize(width: 520, height: height)
        guard abs((panel.contentView?.frame.height ?? 0) - height) > 0.5 else { return }
        listHeightConstraint?.constant = visibleRows * Self.rowHeight
        let oldTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(target)
        panel.setFrameTopLeftPoint(oldTopLeft)
    }

    /// Move the highlight by `delta` rows, clamping at both ends (no silent
    /// wrap-around: the user always knows where the selection is).
    func moveSelection(_ delta: Int) {
        guard !matches.isEmpty, let current = selectedIndex else { return }
        let next = min(max(current + delta, 0), matches.count - 1)
        guard next != current else { return }
        selectedIndex = next
        table?.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table?.scrollRowToVisible(next)
    }

    func commitSelected() {
        if let selected = selectedIndex, matches.indices.contains(selected) {
            dispatch(matches[selected].action)
        }
        dismiss()
    }

    @objc private func rowDoubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0, matches.indices.contains(sender.clickedRow) else { return }
        selectedIndex = sender.clickedRow
        commitSelected()
    }

    func dismiss() {
        if let resignKeyToken {
            NotificationCenter.default.removeObserver(resignKeyToken)
            self.resignKeyToken = nil
        }
        panel?.orderOut(nil)
        panel = nil
        field = nil
        table = nil
        selectedIndex = nil
    }

    deinit {
        if let resignKeyToken {
            NotificationCenter.default.removeObserver(resignKeyToken)
        }
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension CommandPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    /// One row always renders: either a match, or the explicit empty state.
    func numberOfRows(in _: NSTableView) -> Int {
        max(matches.count, 1)
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard !matches.isEmpty, row < matches.count else {
            // Explicit no-matches state — muted, never selectable.
            let empty = NSTextField(labelWithString: NSLocalizedString(
                "No matching commands",
                comment: "Palette empty state when the filter matches nothing"
            ))
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .tertiaryLabelColor
            empty.lineBreakMode = .byTruncatingTail
            empty.translatesAutoresizingMaskIntoConstraints = false
            let holder = NSView()
            holder.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 2),
                empty.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -2),
                empty.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            ])
            return holder
        }
        let rowView = PaletteRowView(rendered: matches[row])
        rowView.identifier = NSUserInterfaceItemIdentifier("palette.row.\(row)")
        return rowView
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
        // The empty-state row is informational only.
        !matches.isEmpty
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === self.table else { return }
        let row = table.selectedRow
        selectedIndex = (row >= 0 && matches.indices.contains(row)) ? row : nil
    }
}

// MARK: - Field-editor command interception

extension CommandPaletteController {
    /// The field editor consults the delegate BEFORE handling a command
    /// itself, so ↑/↓/PageUp/PageDown steer the list instead of moving a
    /// caret that has nowhere to go in a single-line field.
    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // NSTextView implements insertNewline itself, so the selector
            // never bubbles to PaletteField.insertNewline — commit here or
            // Enter is a silent no-op.
            commitSelected()
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.pageUp(_:)):
            moveSelection(-10)
            return true
        case #selector(NSResponder.pageDown(_:)):
            moveSelection(10)
            return true
        default:
            return false
        }
    }
}

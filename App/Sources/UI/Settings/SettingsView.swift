import AgentCore
import AppKit

// Settings window (architecture §4.6 / stage 15): Appearance (ghostty config
// keys per §3.8), Shortcuts (the §3.13 registered table with READ-ONLY conflict
// detection), Integrations (per-adapter install + integration health with
// Repair buttons).
//
// Full shortcut REMAPPING is out of MVP scope; §3.13 only requires that
// Settings DETECTS conflicts at remap time — detection ships here pure and
// unit-tested (ShortcutConflictDetector).

@MainActor
final class SettingsWindowController: NSWindowController {
    private let root: AppCompositionRoot
    /// Retained so tab VCs outlive init; NSTabViewItem keeps only their views.
    private let appearanceTabRef: AppearanceTab
    private let shortcutsTabRef: ShortcutsTab
    private var integrationsTabRef: IntegrationsTab?
    /// Token for the block-based did-become-key observer, removed in deinit.
    private var didBecomeKeyToken: NSObjectProtocol?
    private var willCloseToken: NSObjectProtocol?

    static var shared: SettingsWindowController?

    static func present(root: AppCompositionRoot) {
        if let existing = shared, existing.window != nil {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController(root: root)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init(root: AppCompositionRoot) {
        self.root = root

        let appearance = AppearanceTab(configPath: AppCompositionRoot.makeGhosttyConfig())
        let shortcuts = ShortcutsTab()
        let integrations = IntegrationsTab(installer: root.integrationInstaller)

        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        for (label, tab) in [
            (NSLocalizedString("Appearance", comment: "Settings tab for ghostty appearance keys"), appearance.view),
            (NSLocalizedString("Shortcuts", comment: "Settings tab listing registered shortcuts"), shortcuts.view),
            (
                NSLocalizedString("Integrations", comment: "Settings tab for adapter integration health"),
                integrations.view
            )
        ] {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = tab
            tabView.addTabViewItem(item)
        }

        // Plain content view, NOT contentViewController: with a content view
        // controller the window re-fits its size to the content's constraints,
        // and the Integrations tab's ~813-pt monospaced status paths grew the
        // fixed 540-pt window to 961 pt on first refresh. A masked host view
        // keeps the window at its set size for good.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = tabView
        // The controller owns the window under ARC; without this, closing
        // over-releases it while `shared` keeps a dangling reference.
        window.isReleasedWhenClosed = false
        window.title = NSLocalizedString("AgentTerminal Settings", comment: "Settings window title")
        appearanceTabRef = appearance
        shortcutsTabRef = shortcuts
        integrationsTabRef = integrations
        super.init(window: window)
        window.initialFirstResponder = appearanceTabRef.initialKeyView

        // Refresh integration health whenever the window becomes visible.
        didBecomeKeyToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.integrationsTabRef?.refresh() }
        }
        // A closed Settings window must not linger in `shared`; the next
        // present() call then builds a fresh controller instead of reusing a
        // window that no longer exists on screen.
        willCloseToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Clear only if `shared` still points at this closing instance;
                // otherwise a newer controller was already installed and clearing
                // would orphan it.
                if SettingsWindowController.shared === self {
                    SettingsWindowController.shared = nil
                }
            }
        }
    }

    deinit {
        if let didBecomeKeyToken {
            NotificationCenter.default.removeObserver(didBecomeKeyToken)
        }
        if let willCloseToken {
            NotificationCenter.default.removeObserver(willCloseToken)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }
}

// MARK: - Appearance (§3.8 ghostty config keys)

@MainActor
final class AppearanceTab: NSViewController, NSTextFieldDelegate {
    private let configPath: String
    private let fontField = NSTextField(string: "")
    private let fontSizeField = NSTextField(string: "")
    private let themeField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(
        title: NSLocalizedString("Save Appearance", comment: "Button saving the appearance settings"),
        target: nil,
        action: nil
    )

    /// The §3.8 app-config key surface shown to the operator.
    static let supportedKeys = [
        "font-family", "font-size", "theme", "cursor-style",
        "cursor-style-blink", "text-brightness", "scrollback-limit",
        "ligatures", "shell-integration",
    ]

    /// First key target when the Settings window opens (the tab strip
    /// otherwise renders a stray focus ring on first open).
    var initialKeyView: NSView {
        fontField
    }

    init(configPath: String) {
        self.configPath = configPath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))

        func row(_ label: String, _ field: NSTextField) -> NSView {
            let title = NSTextField(labelWithString: label)
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.setAccessibilityLabel(label)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.delegate = self
            field.setAccessibilityIdentifier("settings.appearance.\(label)")
            let stack = NSStackView(views: [title, field])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            return stack
        }

        let keysLabel = NSTextField(wrappingLabelWithString: String(
            format: NSLocalizedString(
                "Managed ghostty keys: %@",
                comment: "List of managed ghostty configuration keys shown under the appearance fields"
            ),
            Self.supportedKeys.joined(separator: ", ")
        ))
        keysLabel.font = .systemFont(ofSize: 10)
        keysLabel.textColor = .secondaryLabelColor
        keysLabel.preferredMaxLayoutWidth = 440
        keysLabel.setAccessibilityLabel(NSLocalizedString(
            "Supported ghostty configuration keys",
            comment: "Accessibility label for the managed-keys list"
        ))
        saveButton.setAccessibilityLabel(NSLocalizedString(
            "Save appearance settings",
            comment: "Accessibility label for the save button"
        ))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel(NSLocalizedString(
            "Appearance save status",
            comment: "Accessibility label for the appearance save status"
        ))
        // Placeholders make "unset" legible for empty fields.
        fontField.placeholderString = NSLocalizedString(
            "system default", comment: "Placeholder for the unset font-family field"
        )
        fontSizeField.placeholderString = "13"
        themeField.placeholderString = NSLocalizedString(
            "e.g. Dracula", comment: "Placeholder for the unset theme field"
        )

        let stack = NSStackView(views: [
            row(NSLocalizedString("Font family", comment: "Label for the font-family field"), fontField),
            row(NSLocalizedString("Font size", comment: "Label for the font-size field"), fontSizeField),
            row(NSLocalizedString("Theme", comment: "Label for the theme field"), themeField),
            keysLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            // Vertical centering: the tab is much taller than the 3-row form,
            // and a top-pinned form left a ~200-pt dead band above the footer.
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])

        // Footer: status left, Save rightmost — the default action lives on
        // the trailing edge per HIG.
        let footer = NSStackView(views: [statusLabel, NSView(), saveButton])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)
        // Sub-required priority: tall content may push past the footer rather
        // than break constraints.
        let stackBottom = stack.bottomAnchor.constraint(
            lessThanOrEqualTo: footer.topAnchor, constant: -14
        )
        stackBottom.priority = NSLayoutConstraint.Priority.defaultHigh
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stackBottom,
        ])
        view = container
        loadCurrent()
        refreshValidation()
    }

    private func loadCurrent() {
        let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        // Unset keys render as EMPTY fields with placeholders — never as a
        // fallback value from the wrong domain (a font-size number used to
        // pre-fill the family field, one Save away from being written back).
        fontField.stringValue = Self.value(of: "font-family", in: text) ?? ""
        fontSizeField.stringValue = Self.value(of: "font-size", in: text) ?? ""
        themeField.stringValue = Self.value(of: "theme", in: text) ?? ""
    }

    static func value(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)="),
               let equals = trimmed.firstIndex(of: "=")
            {
                return trimmed[trimmed.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    @objc private func saveClicked() {
        // Live validation keeps the button disabled while fields are invalid;
        // re-check anyway so a stale key-equivalent activation can never touch
        // the config file (§3.8).
        if let error = validationError() {
            renderValidationError(error)
            return
        }

        var lines: [String] = []
        if let existing = try? String(contentsOfFile: configPath, encoding: .utf8) {
            lines = existing.split(separator: "\n").map(String.init)
        }
        func upsert(key: String, value: String?) {
            // An emptied field DELETES the managed key line (§3.8 clearing);
            // only a nil value leaves the existing line untouched.
            let existing = lines
                .firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key) ") || $0
                        .trimmingCharacters(in: .whitespaces)
                        .hasPrefix("\(key)=")
                })
            if let value, !value.isEmpty {
                if let existing {
                    lines[existing] = "\(key) = \(value)"
                } else {
                    lines.append("\(key) = \(value)")
                }
            } else if value != nil, let existing {
                lines.remove(at: existing)
            }
        }
        upsert(key: "font-family", value: fontField.stringValue)
        upsert(key: "font-size", value: fontSizeField.stringValue)
        upsert(key: "theme", value: themeField.stringValue)

        do {
            try lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
            statusLabel.textColor = .systemGreen
            statusLabel.stringValue = NSLocalizedString(
                "Saved. New surfaces pick it up.",
                comment: "Status after appearance settings were saved"
            )
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = String(
                format: NSLocalizedString("Save failed: %@", comment: "Status when saving appearance settings errors"),
                String(describing: error)
            )
        }
    }

    // MARK: - Live validation

    /// Localized description of the first problem with the current field
    /// contents, or nil when a save would succeed. Shared by the live
    /// controlTextDidChange pass and saveClicked so the rules cannot drift.
    private func validationError() -> String? {
        let fontSizeText = fontSizeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let parsedSize = Double(fontSizeText), parsedSize.isFinite, parsedSize > 0 else {
            return NSLocalizedString(
                "Font size must be a positive number.",
                comment: "Live-validation error when the appearance font-size input is invalid"
            )
        }
        let textFields = [
            ("font-family", fontField.stringValue),
            ("theme", themeField.stringValue),
        ]
        for (key, value) in textFields where value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "=" }) {
            return String(
                format: NSLocalizedString(
                    "%@ must not contain newlines or '='.",
                    comment: "Live-validation error when an appearance field contains characters that would break the config format"
                ),
                key
            )
        }
        return nil
    }

    private func renderValidationError(_ error: String) {
        saveButton.isEnabled = false
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = error
    }

    private func refreshValidation() {
        if let error = validationError() {
            renderValidationError(error)
        } else {
            saveButton.isEnabled = true
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = ""
        }
    }

    func controlTextDidChange(_: Notification) {
        refreshValidation()
    }
}

// MARK: - Shortcuts (read-only table + conflict detection)

@MainActor
final class ShortcutsTab: NSViewController {
    private let stack = NSStackView()

    override func loadView() {
        // Static interception note pinned ABOVE the scroller: context that
        // must always be visible, never at the mercy of scroll position.
        let note = NSTextField(wrappingLabelWithString:
            NSLocalizedString("The app intercepts ONLY these registered shortcuts; " +
                "Control/Option/plain input always reaches the terminal.",
                comment: "Shortcuts tab note about which shortcuts are intercepted"))
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 440

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The stack IS the document view: top-pinned autolayout content that
        // grows the scrollable area (a fixed-height frame document used to
        // clip the first rows out of view).
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 12).isActive = true
        stack.bottomAnchor.constraint(
            greaterThanOrEqualTo: scroll.contentView.bottomAnchor
        ).isActive = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        container.addSubview(note)
        container.addSubview(scroll)
        note.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            note.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let conflicts = ShortcutConflictDetector.conflicts(in: AppShortcut.registered)
        if !conflicts.isEmpty {
            let warning = NSTextField(wrappingLabelWithString:
                NSLocalizedString("Detected conflicts:\n", comment: "Header above the list of shortcut conflicts") +
                    conflicts.map(ShortcutConflictDetector.describe).joined(separator: "\n"))
            warning.font = .systemFont(ofSize: 11, weight: .semibold)
            warning.textColor = .systemOrange
            warning.setAccessibilityLabel(NSLocalizedString(
                "Shortcut conflicts detected",
                comment: "Accessibility label for the shortcut-conflict warning"
            ))
            warning.preferredMaxLayoutWidth = 440
            stack.addArrangedSubview(warning)
        } else {
            let ok = NSTextField(labelWithString: NSLocalizedString(
                "No shortcut conflicts detected.",
                comment: "Shortcuts tab status when no conflicts exist"
            ))
            ok.textColor = .secondaryLabelColor
            ok.setAccessibilityLabel(NSLocalizedString(
                "No shortcut conflicts",
                comment: "Accessibility label for the no-conflicts status"
            ))
            stack.addArrangedSubview(ok)
        }

        for shortcut in AppShortcut.registered {
            let keyLabel = NSTextField(labelWithString: shortcut.displayText)
            keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let titleLabel = NSTextField(labelWithString: shortcut.title)
            titleLabel.font = .systemFont(ofSize: 12)
            titleLabel.textColor = .secondaryLabelColor
            // Fixed-width key column keeps every title aligned at the same x
            // (a tab character used to leave the title column ragged).
            let row = NSStackView(views: [keyLabel, titleLabel])
            row.orientation = .horizontal
            row.spacing = 12
            keyLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.staticText)
            row.setAccessibilityLabel(String(
                format: NSLocalizedString("%@, %@",
                                          comment: "Shortcut row accessibility label: title and key combination"),
                shortcut.title,
                shortcut.displayText
            ))
            row.setAccessibilityIdentifier("settings.shortcut.\(shortcut.id)")
            stack.addArrangedSubview(row)
        }
    }
}

// MARK: - Integrations (per-adapter health + Repair)

@MainActor
final class IntegrationsTab: NSViewController {
    private let installer: IntegrationInstaller
    private let catalog = AgentCatalog.standard()
    private var statusLabels: [String: NSTextField] = [:]
    private var repairButtons: [String: NSButton] = [:]
    /// Latest per-row repair availability; repairClicked's completion consults
    /// this instead of blindly re-enabling everything.
    private var canRepairByAdapter: [String: Bool] = [:]
    // Tab-level guard: installer.install() (backup/copy/rollback) must never
    // run concurrently for two adapters.
    private var repairInFlight = false
    private let stack = NSStackView()
    // Monotonic generation so a stale diagnose pass can never clobber a label
    // that a newer pass (or a just-completed repair) has already updated.
    private var refreshGeneration = 0

    struct RowState {
        var installedText: String
        var healthText: String
        // Without the adapter CLI there is nothing to repair: the shim
        // install would "succeed" while the adapter stays unusable.
        var cliPresent: Bool
        var canRepair: Bool
    }

    init(installer: IntegrationInstaller) {
        self.installer = installer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The stack IS the document view: top-pinned autolayout content that
        // grows the scrollable area. A fixed-height frame document used to put
        // the content at the document's far top while the scroller showed the
        // origin (bottom) corner — a blank tab until you scrolled blind.
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 12).isActive = true
        stack.bottomAnchor.constraint(
            greaterThanOrEqualTo: scroll.contentView.bottomAnchor
        ).isActive = true
        view = scroll
        buildSkeleton()
        Task { await refresh() }
    }

    private func buildSkeleton() {
        let header = NSTextField(labelWithString: NSLocalizedString(
            "Integration health (live diagnose per adapter)",
            comment: "Integrations tab section header"
        ))
        header.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(header)
        for adapter in catalog.allAdapters {
            let title = NSTextField(labelWithString: adapter.displayName)
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            let status = NSTextField(labelWithString: NSLocalizedString(
                "checking…",
                comment: "Placeholder while adapter integration detection runs"
            ))
            status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            status.textColor = .secondaryLabelColor
            // Detected CLI paths are ~90-char temp dirs: without a width cap
            // they overflowed the tab, clipped hard, and pushed the health
            // text and Repair button out of view.
            status.lineBreakMode = .byTruncatingMiddle
            status.cell?.truncatesLastVisibleLine = true
            status.setAccessibilityLabel(String(
                format: NSLocalizedString("%@ integration status",
                                          comment: "Accessibility label for an adapter's integration status row"),
                adapter.displayName
            ))
            statusLabels[adapter.id] = status

            let repair = NSButton(
                title: NSLocalizedString("Repair", comment: "Button repairing an adapter integration"),
                target: self,
                action: #selector(repairClicked(_:))
            )
            repair.bezelStyle = .rounded
            repair.controlSize = .small
            repair.identifier = NSUserInterfaceItemIdentifier(adapter.id)
            repairButtons[adapter.id] = repair
            let column = NSStackView(views: [title, status])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            // Expanding spacer + full-width row: every Repair button lands on
            // the same trailing x instead of floating ragged after text of
            // varying length.
            let row = NSStackView(views: [column, NSView(), repair])
            row.orientation = .horizontal
            row.spacing = 12
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            // Activate only after the row joins the stack's tree: constraining
            // a still-orphaned status label throws "no common ancestor" and
            // aborts the whole tab build.
            // CONSTANT width, not a relative cap: the window's fitting pass
            // satisfies optional compression resistance (750) by growing the
            // whole non-resizable window — the label's ~813-pt intrinsic path
            // inflated 540 pt to 961 pt. A pinned constant leaves nothing for
            // the solver to grow; middle truncation handles overflow.
            status.widthAnchor.constraint(equalToConstant: 400).isActive = true
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        for adapter in catalog.allAdapters {
            var installedText = NSLocalizedString(
                "CLI not found on PATH",
                comment: "Integration status when the adapter CLI was not found"
            )
            var cliPresent = false
            if case let .installed(path, _) = await adapter.detectInstallation() {
                installedText = path
                cliPresent = true
            }
            let health = installer.diagnose(plan: adapter.integrationInstallPlan())
            let state = RowState(
                installedText: installedText,
                healthText: RuntimeSeam.healthText(for: health),
                cliPresent: cliPresent,
                canRepair: health != .healthy && cliPresent
            )
            apply(state: state, for: adapter.id, generation: generation)
        }
    }

    private func apply(state: RowState, for id: String, generation: Int) {
        // A newer refresh pass (or repair) superseded this one; drop the result.
        guard generation == refreshGeneration,
              let label = statusLabels[id] else { return }
        label.stringValue = String(
            format: NSLocalizedString("%@ · integration: %@",
                                      comment: "Integration status row: install state and health"),
            state.installedText,
            state.healthText
        )
        label.textColor = state.healthText == "healthy" ? .secondaryLabelColor : .systemOrange
        let button = repairButtons[id]
        button?.isEnabled = state.canRepair
        button?.toolTip = state.cliPresent ? nil : NSLocalizedString(
            "Install the adapter CLI first — there is no integration to repair.",
            comment: "Tooltip for the disabled Repair button when the adapter CLI is missing"
        )
        // repairClicked's completion re-enables every button; it must respect
        // rows whose Repair is permanently unavailable.
        canRepairByAdapter[id] = state.canRepair
    }

    @objc private func repairClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let adapter = catalog.adapter(id: id),
              let label = statusLabels[id] else { return }
        // install() does file I/O and may spawn dry-run child processes; it must
        // never run synchronously on the main thread, and it must not double-run
        // on a second click. Bump the generation so an in-flight refresh pass
        // cannot clobber the repair outcome afterwards.
        let plan = adapter.integrationInstallPlan()
        guard !repairInFlight else { return }
        repairInFlight = true
        refreshGeneration += 1
        let generation = refreshGeneration
        for button in repairButtons.values {
            button.isEnabled = false
        }
        Task { @MainActor in
            defer {
                repairInFlight = false
                for (buttonID, button) in repairButtons {
                    button.isEnabled = canRepairByAdapter[buttonID] ?? true
                }
            }
            do {
                let installer = self.installer
                let report = try await Task.detached(priority: .userInitiated) {
                    try installer.install(plan: plan)
                }.value
                guard generation == refreshGeneration else { return }
                label.stringValue = String(
                    format: NSLocalizedString(
                        "repair outcome: %@",
                        comment: "Integration status after a repair attempt"
                    ),
                    RuntimeSeam.outcomeText(for: report.outcome)
                )
            } catch {
                guard generation == refreshGeneration else { return }
                label.stringValue = String(
                    format: NSLocalizedString("repair failed: %@", comment: "Integration status when a repair errors"),
                    String(describing: error)
                )
            }
            await refresh()
        }
    }
}

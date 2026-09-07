import AgentControl
import AgentCore
import AppKit

// New Agent sheet (architecture §4.6) + the §3.13 ⌘N command — stage-6 gap
// closure (DoD #1: launching real CLIs from the app without terminal prefix
// shortcuts; §6.6 gate: a missing CLI yields an actionable error).
//
// Split for testability:
//   * `NewAgentSheetModel` — pure form state + validation + install detection.
//     No AppKit beyond ObservableObject; unit-testable and scenario-provable
//     (ATERM_SCENARIO=new-agent).
//   * `NewAgentSheetController` — the AppKit sheet: adapter picker with
//     install status, folder chooser, display name, task summary, inline
//     actionable error label.

@MainActor
final class NewAgentSheetModel: ObservableObject {
    struct AdapterOption: Identifiable, Equatable {
        let id: String
        let kind: AgentKind
        let displayName: String
        /// nil = detection still running; otherwise install presence.
        var installed: Bool?
        var executablePath: String?

        var menuTitle: String {
            switch installed {
            case .some(true):
                if let path = executablePath {
                    return String(
                        format: NSLocalizedString("%@ — %@",
                                                  comment: "Adapter picker row: display name and executable path"),
                        displayName,
                        path
                    )
                }
                return displayName
            case .some(false):
                return String(
                    format: NSLocalizedString("%@ — not installed",
                                              comment: "Adapter picker row when the CLI was not found"),
                    displayName
                )
            case .none:
                return displayName
            }
        }
    }

    enum ValidationError: Equatable, Error {
        case emptyDisplayName
        case missingWorkingDirectory
        case workingDirectoryNotFound(String)
        /// The chosen adapter's CLI is absent; message carries install hints.
        case missingExecutable(AgentKind)

        var actionableMessage: String {
            switch self {
            case .emptyDisplayName:
                NSLocalizedString(
                    "Give the agent a display name (for example \"frontend\").",
                    comment: "Validation error: display name must not be empty"
                )
            case .missingWorkingDirectory:
                NSLocalizedString(
                    "Choose a workspace folder — the agent starts inside it.",
                    comment: "Validation error: working directory must not be empty"
                )
            case let .workingDirectoryNotFound(path):
                String(
                    format: NSLocalizedString("Folder does not exist: %@. Pick an existing directory.",
                                              comment: "Validation error naming the missing folder"),
                    path
                )
            case let .missingExecutable(kind):
                AgentExecutionCoordinator.missingExecutableMessage(for: kind)
            }
        }
    }

    private(set) var options: [AdapterOption] = []
    /// Executable discovery seam: production resolves through the launch
    /// pipeline's PATH scan; tests/scenarios inject lookups against stub dirs.
    /// Nonisolated + Sendable so refreshInstallStatus can run it off the
    /// MainActor — a long PATH must never freeze the sheet.
    private let resolveExecutable: @Sendable (AgentKind) -> String?

    init(catalog: AgentCatalog = .standard(),
         resolveExecutable: @escaping @Sendable (AgentKind)
             -> String? = { AgentExecutionCoordinator.resolveExecutable(for: $0) })
    {
        self.resolveExecutable = resolveExecutable
        options = catalog.allAdapters.compactMap { adapter in
            guard let kind = adapter.bundledAgentKind else { return nil }
            // Shell first — it always exists and is the MVP fallback row.
            return AdapterOption(
                id: adapter.id,
                kind: kind,
                displayName: adapter.displayName,
                installed: nil,
                executablePath: nil
            )
        }
        options.sort { lhs, rhs in
            if (lhs.kind == .genericShell) != (rhs.kind == .genericShell) {
                return lhs.kind == .genericShell
            }
            return lhs.displayName < rhs.displayName
        }
    }

    /// §4.6: per-adapter install detection feeds the picker labels so an
    /// operator sees availability BEFORE committing. Uses the SAME resolver
    /// seam as Create (`executableCandidates` + PATH scan) so the label can
    /// never disagree with the gate; this also sidesteps the package-side
    /// `detectInstallation` quirk with ABSOLUTE candidates (generic shells).
    func refreshInstallStatus() async {
        // Snapshot the kinds, resolve OFF the MainActor (PATH scan + probes
        // are synchronous and can be slow), then hop back to publish. A
        // concurrent refresh may have reloaded options meanwhile — a count
        // mismatch means this snapshot is stale, so drop it.
        let kinds = options.map(\.kind)
        let resolver = resolveExecutable
        let resolved: [String?] = await Task.detached(priority: .userInitiated) {
            kinds.map(resolver)
        }.value
        guard resolved.count == options.count else { return }
        for index in options.indices {
            if let path = resolved[index] {
                options[index].installed = true
                options[index].executablePath = path
            } else {
                options[index].installed = false
                options[index].executablePath = nil
            }
        }
        objectWillChange.send()
    }

    var defaultWorkingDirectory: String {
        NSHomeDirectory()
    }

    /// Pure validation → a runtime-ready request, or the actionable error.
    /// Does NOT touch the runtime; creation goes through the pipeline after.
    func validate(
        kind: AgentKind, displayName: String, taskSummary: String, workingDirectory: String
    ) -> Result<AgentLaunchRequest, ValidationError> {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.emptyDisplayName) }
        let trimmedCwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else { return .failure(.missingWorkingDirectory) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedCwd, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .failure(.workingDirectoryNotFound(trimmedCwd))
        }
        guard resolveExecutable(kind) != nil else { return .failure(.missingExecutable(kind)) }
        let summary = taskSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(AgentLaunchRequest(
            agentKind: kind,
            workingDirectory: trimmedCwd,
            displayName: trimmedName,
            taskSummary: summary.isEmpty ? nil : summary
        ))
    }
}

// MARK: - Sheet controller

/// Reference box shared between the sheet and its in-flight create Task
/// (architecture §4.6): cancelling the sheet must not suppress the real
/// agent creation, but it must stop the late `onSelect` from selecting an
/// agent in a dialog the operator dismissed.
@MainActor
private final class NewAgentSheetCancellationFlag {
    var isCancelled = false
}

@MainActor
final class NewAgentSheetController: NSViewController, NSWindowDelegate {
    private let model: NewAgentSheetModel
    private let onCreate: (AgentLaunchRequest, @escaping (String?) -> Void) -> Void
    private let onCancelled: (() -> Void)?

    private let adapterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(frame: .zero)
    private let summaryField = NSTextField(frame: .zero)
    private let cwdField = NSTextField(frame: .zero)
    private let chooseFolderButton = NSButton(
        title: NSLocalizedString("Choose…", comment: "Button opening the working-folder chooser"),
        target: nil,
        action: nil
    )
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let createButton = NSButton(
        title: NSLocalizedString("Create Agent", comment: "Button committing the new-agent form"),
        target: nil,
        action: nil
    )
    private var creating = false

    /// Layout width of the wrapping error label (see loadView).
    private static let errorAreaWidth: CGFloat = 260
    /// Height the error row adds to the window while an error is visible,
    /// tracked so clearing the error restores the exact previous size.
    private var errorHeightDelta: CGFloat = 0

    static func present(
        in window: NSWindow?,
        pipeline: AgentExecutionCoordinator,
        workspaceProvider: @escaping () -> WorkspaceID?,
        onSelect: ((AgentID) -> Void)? = nil
    ) {
        guard let window else { return }
        let cancelled = NewAgentSheetCancellationFlag()
        let controller = NewAgentSheetController(
            model: NewAgentSheetModel(),
            onCreate: { [weak pipeline] request, completion in
                guard let pipeline, let workspace = workspaceProvider() else {
                    completion(NSLocalizedString(
                        "No active workspace — wait for bootstrap to finish.",
                        comment: "Error shown when creating an agent before a workspace exists"
                    ))
                    return
                }
                Task { @MainActor in
                    do {
                        let agentID = try await pipeline.createAgent(request, in: workspace)
                        completion(nil)
                        // The creation itself is real and completes even if the
                        // operator cancelled meanwhile; only the late selection
                        // of the dismissed dialog's agent is suppressed.
                        if !cancelled.isCancelled {
                            onSelect?(agentID)
                        }
                    } catch {
                        completion(Self.actionableText(for: error))
                    }
                }
            },
            onCancelled: { cancelled.isCancelled = true }
        )
        let panel = NSWindow(contentViewController: controller)
        panel.styleMask = [.titled]
        panel.title = NSLocalizedString("New Agent", comment: "New Agent sheet window title")
        panel.setContentSize(NSSize(width: 460, height: 250))
        window.beginSheet(panel)
    }

    /// ControlFailure messages are already operator-facing; anything else gets
    /// a generic prefix instead of raw internals.
    static func actionableText(for error: Error) -> String {
        if let failure = error as? ControlFailure {
            return failure.message
        }
        return String(
            format: NSLocalizedString("Could not create the agent: %@",
                                      comment: "Generic prefix for unexpected agent-creation failures"),
            String(describing: error)
        )
    }

    init(
        model: NewAgentSheetModel,
        onCreate: @escaping (AgentLaunchRequest, @escaping (String?) -> Void) -> Void,
        onCancelled: (() -> Void)? = nil
    ) {
        self.model = model
        self.onCreate = onCreate
        self.onCancelled = onCancelled
        super.init(nibName: nil, bundle: nil)
        // Each presentation starts with a clean dedupe slate (§3.23): the same
        // error must announce again on a re-presented sheet.
        AccessibilityAnnouncer.reset()
    }

    /// Sheets presented via beginSheet get their first responder here: the
    /// operator can type the display name immediately without an extra click.
    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.makeFirstResponder(nameField)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 250))

        func labeled(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [label, control])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 3
            stack.translatesAutoresizingMaskIntoConstraints = false
            return stack
        }

        adapterPopup.controlSize = .regular
        nameField.placeholderString = NSLocalizedString("frontend", comment: "Example value in the display-name field")
        summaryField.placeholderString = NSLocalizedString(
            "What should this agent work on? (optional)",
            comment: "Placeholder for the task-summary field"
        )
        cwdField.placeholderString = model.defaultWorkingDirectory

        chooseFolderButton.bezelStyle = .rounded
        chooseFolderButton.controlSize = .small
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolderClicked)
        chooseFolderButton.setAccessibilityLabel(NSLocalizedString(
            "Choose working folder",
            comment: "Accessibility label for the folder chooser button"
        ))

        let cwdRow = NSStackView(views: [cwdField, chooseFolderButton])
        cwdRow.orientation = .horizontal
        cwdRow.spacing = 6
        cwdRow.translatesAutoresizingMaskIntoConstraints = false
        cwdField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.lineBreakMode = .byWordWrapping
        // Fixed layout width so long, actionable messages (e.g. the §6.6
        // missing-executable guidance) wrap into multiple fully readable
        // lines instead of clipping mid-sentence.
        errorLabel.preferredMaxLayoutWidth = Self.errorAreaWidth
        errorLabel.setAccessibilityIdentifier("new-agent.error")
        errorLabel.widthAnchor.constraint(equalToConstant: Self.errorAreaWidth).isActive = true

        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(createClicked)
        createButton.setAccessibilityLabel(NSLocalizedString(
            "Create Agent",
            comment: "Accessibility label for the create button"
        ))

        let cancelButton = NSButton(
            title: NSLocalizedString("Cancel", comment: "Button dismissing the sheet without creating an agent"),
            target: self,
            action: #selector(cancelClicked)
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [errorLabel, NSView(), cancelButton, createButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let form = NSStackView(views: [
            labeled(NSLocalizedString("Adapter", comment: "Label for the adapter picker"), adapterPopup),
            labeled(NSLocalizedString("Display Name", comment: "Label for the display-name field"), nameField),
            labeled(NSLocalizedString("Task Summary", comment: "Label for the task-summary field"), summaryField),
            labeled(NSLocalizedString("Working Folder", comment: "Label for the working-folder field"), cwdRow),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(form)
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            summaryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            // The form stack stretches the other rows to the sheet width but
            // leaves this one at its minimum — pin it to the name field so
            // every input row reads as the same grid.
            summaryField.widthAnchor.constraint(equalTo: nameField.widthAnchor),
            // Same grid for the working-folder row: without a pin the field
            // stays at its ~1-char intrinsic minimum, hiding any real path.
            cwdField.widthAnchor.constraint(equalTo: nameField.widthAnchor),
        ])

        // Accessibility (§3.23): every field carries a label + identifier.
        adapterPopup.setAccessibilityLabel(NSLocalizedString(
            "Adapter",
            comment: "Accessibility label for the adapter picker"
        ))
        adapterPopup.setAccessibilityIdentifier("new-agent.adapter")
        nameField.setAccessibilityLabel(NSLocalizedString(
            "Display Name",
            comment: "Accessibility label for the display-name field"
        ))
        nameField.setAccessibilityIdentifier("new-agent.name")
        summaryField.setAccessibilityLabel(NSLocalizedString(
            "Task Summary",
            comment: "Accessibility label for the task-summary field"
        ))
        summaryField.setAccessibilityIdentifier("new-agent.summary")
        cwdField.setAccessibilityLabel(NSLocalizedString(
            "Working Folder",
            comment: "Accessibility label for the working-folder field"
        ))
        cwdField.setAccessibilityIdentifier("new-agent.cwd")
        createButton.setAccessibilityIdentifier("new-agent.create")

        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(NSLocalizedString(
            "New Agent",
            comment: "Accessibility label for the whole New Agent sheet"
        ))

        self.view = view
        rebuildAdapterMenu()
        cwdField.stringValue = model.defaultWorkingDirectory

        Task { await refreshInstallStatusAndRebuild() }
    }

    private func refreshInstallStatusAndRebuild() async {
        await model.refreshInstallStatus()
        rebuildAdapterMenu()
    }

    /// Picker rows carry the install verdict: "not installed" rows stay
    /// selectable so Create produces the §6.6 actionable error inline instead
    /// of silently hiding the adapter.
    private func rebuildAdapterMenu() {
        // Keep the operator's in-progress selection across rebuilds: the
        // deferred refreshInstallStatusAndRebuild() must not silently revert
        // the picker to row 0 and validate/launch the wrong adapter kind.
        let previousKind = selectedKind
        adapterPopup.removeAllItems()
        for option in model.options {
            adapterPopup.addItem(withTitle: option.menuTitle)
            adapterPopup.lastItem?.representedObject = option.kind
        }
        if let previousKind,
           let index = model.options.firstIndex(where: { $0.kind == previousKind })
        {
            adapterPopup.selectItem(at: index)
        }
    }

    private var selectedKind: AgentKind? {
        adapterPopup.selectedItem?.representedObject as? AgentKind
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: cwdField.stringValue.isEmpty
            ? model.defaultWorkingDirectory : cwdField.stringValue)
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.cwdField.stringValue = url.path
        }
    }

    @objc private func cancelClicked() {
        onCancelled?()
        dismiss(with: nil)
    }

    @objc private func createClicked() {
        guard !creating, let kind = selectedKind else { return }
        clearError()

        switch model.validate(
            kind: kind,
            displayName: nameField.stringValue,
            taskSummary: summaryField.stringValue,
            workingDirectory: cwdField.stringValue
        ) {
        case let .failure(error):
            showError(error.actionableMessage)
        case let .success(request):
            creating = true
            createButton.isEnabled = false
            onCreate(request) { [weak self] errorMessage in
                guard let self else { return }
                creating = false
                createButton.isEnabled = true
                if let errorMessage {
                    showError(errorMessage)
                } else {
                    dismiss(with: nil)
                }
            }
        }
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
        adjustWindowForErrorVisibility()
        errorLabel.setAccessibilityValue(text)
        AccessibilityAnnouncer.announce(text)
    }

    private func clearError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
        adjustWindowForErrorVisibility()
    }

    /// Sizes the sheet from the label's actual wrapped height instead of
    /// hardcoded totals: one short line fits without any resize (the button
    /// row already leaves headroom); only genuinely long text grows the
    /// sheet, downward from its top edge, and clearing restores it exactly.
    private func adjustWindowForErrorVisibility() {
        guard let window = view.window, window.sheetParent != nil || window.isVisible else {
            return
        }
        errorLabel.layoutSubtreeIfNeeded()
        let fittedHeight = errorLabel.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: Self.errorAreaWidth, height: .greatestFiniteMagnitude)
        ).height ?? 0
        // A hidden (or single-line-fitting) label needs nothing beyond the
        // existing button-row slack.
        let needed = errorLabel.isHidden ? 0 : max(0, ceil(fittedHeight) - 16)
        guard needed != errorHeightDelta else { return }
        var frame = window.frame
        frame.size.height += needed - errorHeightDelta
        frame.origin.y -= needed - errorHeightDelta
        errorHeightDelta = needed
        window.setFrame(frame, display: true, animate: true)
    }

    private func dismiss(with _: AgentID?) {
        view.window?.sheetParent?.endSheet(view.window!)
    }
}

/// VoiceOver announcement helper for transient inline errors (§3.23).
@MainActor
enum AccessibilityAnnouncer {
    private static var lastAnnouncement = ""

    static func announce(_ text: String) {
        guard text != lastAnnouncement else { return }
        lastAnnouncement = text

        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text]
        )
    }

    /// Clears dedupe state so a fresh presentation re-announces a repeat error.
    static func reset() {
        lastAnnouncement = ""
    }
}

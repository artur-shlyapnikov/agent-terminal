import AgentCore
import AppKit

// Onboarding (architecture §4.6, stage 15): first-run window shown when no
// workspaces exist. Three jobs:
//   1. folder picker → the first workspace root;
//   2. agent detection summary (per-adapter CLI presence);
//   3. integration setup entry points (Settings → Integrations / Repair).
//
// Completion hands the chosen root back to the composition root, which creates
// the workspace and keys the normal shell.

@MainActor
protocol OnboardingDelegate: AnyObject {
    func onboardingDidFinish(rootPath: String)
}

@MainActor
final class OnboardingController: NSWindowController {
    private let catalog = AgentCatalog.standard()
    weak var onboardingDelegate: OnboardingDelegate?

    private let detectionLabel = NSTextField(labelWithString: NSLocalizedString(
        "Scanning for agent CLIs…",
        comment: "Onboarding status before agent detection finishes"
    ))
    private let folderButton = NSButton(
        title: NSLocalizedString("Choose Folder…", comment: "Button opening the workspace-folder picker"),
        target: nil,
        action: nil
    )
    private let folderLabel = NSTextField(labelWithString: NSLocalizedString(
        "No folder selected",
        comment: "Onboarding status before a workspace folder is chosen"
    ))
    private var selectedRoot: String?
    private let startButton = NSButton(
        title: NSLocalizedString("Start", comment: "Button finishing onboarding and starting the app"),
        target: nil,
        action: nil
    )
    /// Root content stack; retained so the window can be re-fitted to the
    /// real content height once detection fills the summary label.
    private var contentStack: NSStackView?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("Welcome to AgentTerminal", comment: "Onboarding window title")
        window.center()
        super.init(window: window)

        // -- layout ----------------------------------------------------------
        let title = NSTextField(wrappingLabelWithString:
            NSLocalizedString("AgentTerminal runs Claude Code, Codex, OpenCode or a plain shell " +
                "inside native terminal panes — pick a project folder to start.", comment: "Onboarding welcome text"))
        title.font = .systemFont(ofSize: 12)
        title.preferredMaxLayoutWidth = 460
        title.setAccessibilityLabel(NSLocalizedString(
            "Welcome text",
            comment: "Accessibility label for the onboarding welcome text"
        ))

        detectionLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detectionLabel.setAccessibilityLabel(NSLocalizedString(
            "Detected agent CLIs",
            comment: "Accessibility label for the agent-detection summary"
        ))
        detectionLabel.setAccessibilityIdentifier("onboarding.detection")

        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor

        let integrationButton = NSButton(
            title: NSLocalizedString("Integration Setup…", comment: "Button opening integration setup"),
            target: self,
            action: #selector(integrationSetupClicked)
        )
        integrationButton.bezelStyle = .rounded
        integrationButton.setAccessibilityLabel(NSLocalizedString(
            "Open integration setup",
            comment: "Accessibility label for the integration-setup button"
        ))

        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startClicked)
        startButton.isEnabled = false
        startButton.identifier = NSUserInterfaceItemIdentifier("onboarding.start")
        startButton.setAccessibilityLabel(NSLocalizedString(
            "Start using AgentTerminal",
            comment: "Accessibility label for the start button"
        ))

        folderButton.bezelStyle = .rounded
        folderButton.target = self
        folderButton.action = #selector(chooseFolderClicked)
        folderButton.setAccessibilityLabel(NSLocalizedString(
            "Choose workspace folder",
            comment: "Accessibility label for the folder-picker button"
        ))
        // Return starts the flow the user is in: before a folder exists,
        // Return opens the picker; afterwards it starts the app. The visual
        // default (accent tint) moves with it.
        folderButton.keyEquivalent = "\r"

        // Escape hatch: an operator who cannot or will not pick a folder
        // still reaches the normal shell instead of a dead-end window.
        let skipButton = NSButton(
            title: NSLocalizedString("Skip", comment: "Button skipping onboarding folder selection"),
            target: self,
            action: #selector(skipClicked)
        )
        skipButton.bezelStyle = .rounded
        skipButton.setAccessibilityLabel(NSLocalizedString(
            "Skip onboarding",
            comment: "Accessibility label for the skip onboarding button"
        ))

        // HIG order: Integration Setup leads, then Skip opens the trailing
        // group; Start is always rightmost as the final action (disabled
        // until a folder is chosen — no mid-row jumping).
        let buttons = NSStackView(
            views: [integrationButton, NSView(), skipButton, folderButton, startButton]
        )
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        window.initialFirstResponder = folderButton

        let stack = NSStackView(views: [title, detectionLabel, folderLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentStack = stack

        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        Task { await detectAdapters() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    /// §4.6 agent detection summary — live `detectInstallation` per adapter.
    /// Each probe runs detached and its result reaches us only through an
    /// AsyncStream consumed under a 5 s deadline. On timeout the consumer is
    /// cancelled (AsyncStream honours cancellation, so its `next()` returns
    /// nil promptly) and the detached probe is simply abandoned — it is never
    /// awaited, because a synchronous PATH/FileManager scan has no suspension
    /// points to interrupt. Abandonment is safe: the probe is a read-only
    /// scan that finishes in the background whenever it finishes.
    private func detectAdapters() async {
        var lines: [String] = []
        for adapter in catalog.allAdapters {
            let outcome = await withTaskGroup(
                of: InstallationStatus?.self
            ) { group -> InstallationStatus in
                let (stream, continuation) =
                    AsyncStream.makeStream(of: InstallationStatus.self)
                group.addTask {
                    Task.detached(priority: .userInitiated) {
                        let status = await adapter.detectInstallation()
                        continuation.yield(status)
                        continuation.finish()
                    }
                    return await stream.first { _ in true }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? .notInstalled
            }
            let line = switch outcome {
            case let .installed(path, _):
                // Presence is the operator's decision input; the resolved
                // path is integration detail (often a session temp shim) and
                // never reads well in a welcome window.
                String(
                    format: NSLocalizedString("✓ %@: installed (%@)",
                                              comment: "Detection summary row for an installed agent CLI"),
                    adapter.displayName,
                    (path as NSString).lastPathComponent
                )
            case .notInstalled:
                String(
                    format: NSLocalizedString("✗ %@: not installed",
                                              comment: "Detection summary row when an agent CLI was not found"),
                    adapter.displayName
                )
            }
            lines.append(line)
        }
        lines.append(NSLocalizedString(
            "(a plain shell is always available)",
            comment: "Detection summary footnote about the built-in shell"
        ))
        detectionLabel.stringValue = lines.joined(separator: "\n")
        // The window was sized for the "Scanning…" placeholder; re-fit it to
        // the real content once the detection summary has landed.
        if let stack = contentStack, let window {
            let height = stack.fittingSize.height + 48
            window.setContentSize(NSSize(width: 520, height: max(height, 220)))
        }
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard let window else { return }
        // Sheet, not runModal: the window stays responsive while picking.
        // The completion handler inherits @MainActor isolation here (the
        // parameter closure is not @Sendable), so the old flow continues
        // unchanged.
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            selectedRoot = url.path
            folderLabel.stringValue = url.path
            startButton.isEnabled = true
            // Start takes over as the default action once it can actually
            // run; Return now starts instead of reopening the picker.
            folderButton.keyEquivalent = ""
            startButton.keyEquivalent = "\r"
        }
    }

    @objc private func integrationSetupClicked() {
        // Entry point only; the composition root wires the real controller.
        NotificationCenter.default.post(name: .atermOpenIntegrationSettings, object: nil)
    }

    @objc private func skipClicked() {
        window?.orderOut(nil)
        // Home root: the plain shell is always available and the workspace
        // root can be changed later; skipping must never strand the app in
        // onboardingPending with no workspace.
        onboardingDelegate?.onboardingDidFinish(rootPath: NSHomeDirectory())
    }

    @objc private func startClicked() {
        guard let selectedRoot else { return }
        window?.orderOut(nil)
        onboardingDelegate?.onboardingDidFinish(rootPath: selectedRoot)
    }
}

extension Notification.Name {
    static let atermOpenIntegrationSettings =
        Notification.Name("aterm.openIntegrationSettings")
}

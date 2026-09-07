import AgentCore
import AgentStore
import AppKit

// Recovery Center (architecture §3.15 crash recovery): shown INSTEAD of the
// normal window content when the previous run terminated uncleanly. NOTHING
// starts automatically — every previously-running agent waits for an explicit
// operator decision:
//
//   Resume      — only for adapters with a valid session reference; executes
//                 the adapter-generated resume command through the launch
//                 pipeline. The OLD session reference is preserved until a
//                 successful new launch, so a failed resume keeps it intact.
//   Start Fresh — brand-new session of the same kind via the normal pipeline.
//   Archive     — sets archived_at on the persisted agents row.
//
// Sessions whose adapter cannot resume appear as start-fresh-only rows
// (§3.15 unsupported-session surfacing).

/// Top-anchored scroll document: a plain NSView documentView anchors content
/// to the bottom of the clip view, floating the headline in dead space above;
/// flipped coordinates pin it under the title bar where the eye lands first.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

@MainActor
final class RecoveryCenterController: NSObject {
    private let plan: CrashRecoveryPlan
    private weak var root: AppCompositionRoot?
    private var window: NSWindow?
    private var remaining: [RecoveryCandidate] = []
    /// Row widgets keyed by agent id so per-row buttons can be disabled.
    private var rowViews: [AgentID: [NSButton]] = [:]

    /// Scroll-content stack built by buildContent(); kept so resolved rows can
    /// be removed individually without replacing window contentView (which
    /// would orphan any presented sheet).
    private var contentStack: NSStackView?

    /// Disables or re-enables every action button for a candidate's row.
    /// Re-enabling is guarded: the row may already have been torn down.
    private func setRowEnabled(_ agentID: AgentID, enabled: Bool) {
        for button in rowViews[agentID] ?? [] {
            button.isEnabled = enabled
        }
    }

    init(plan: CrashRecoveryPlan, root: AppCompositionRoot) {
        self.plan = plan
        self.root = root
        remaining = plan.candidates
    }

    // MARK: Presentation

    func present() {
        let content = buildContent()
        // Fit the window to the real content height. The old formula
        // (120 + min(count,4) * 56) ignored wrapped status lines: it
        // overestimated for short rows (dead band above the headline) and
        // underestimated for wrapped ones (clipped last row).
        let stackFitting = contentStack?.fittingSize.height ?? 240
        let height = min(max(stackFitting + 52, 220), 560)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("AgentTerminal Recovery", comment: "Recovery Center window title")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = content
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Dock-icon reopen while recovery is pending: re-key the existing
    /// window (never build a second one).
    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() -> NSView {
        let container = NSStackView(views: headerViews())
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        contentStack = container
        for candidate in remaining {
            container.addArrangedSubview(row(for: candidate))
        }
        // Fixed design width: keeps fittingSize height width-independent
        // (measurable before the window exists) and rows wrapping identically
        // at fitting and layout time.
        container.widthAnchor.constraint(equalToConstant: 600).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            container.topAnchor.constraint(equalTo: document.topAnchor),
            container.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
        ])
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return content
    }

    private func headerViews() -> [NSView] {
        let title = NSTextField(labelWithString: NSLocalizedString(
            "The last session ended unexpectedly.",
            comment: "Recovery Center headline"
        ))
        title.font = .boldSystemFont(ofSize: 15)
        // Code-level plural branch: "1 agent was running" beats the "1
        // agent(s)" parenthesis hack; both variants stay full sentences so
        // the catalog carries them verbatim.
        let running: String = plan.candidates.count == 1
            ? NSLocalizedString(
                "1 agent was running.",
                comment: "Recovery Center subtitle: exactly one interrupted agent"
            )
            : String(
                format: NSLocalizedString(
                    "%lld agents were running.",
                    comment: "Recovery Center subtitle: count of interrupted agents"
                ),
                plan.candidates.count
            )
        let subtitle = NSTextField(labelWithString: running + " " + NSLocalizedString(
            "Nothing has been restarted — choose what to do with each one.",
            comment: "Recovery Center subtitle: no automatic restarts"
        ))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.setFrameSize(NSSize(width: 600, height: 30))
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.preferredMaxLayoutWidth = 580
        return [title, subtitle]
    }

    private func row(for candidate: RecoveryCandidate) -> NSView {
        var status = candidate.kind.displayName
        if let reason = candidate.unsupportedReasonText {
            status += String(
                format: NSLocalizedString(" — cannot resume (%@)",
                                          comment: "Row status suffix when resume is unsupported, naming the reason"),
                reason
            )
        } else if candidate.canResume {
            status += NSLocalizedString(" — can resume", comment: "Row status suffix when the session can resume")
        }

        let label = NSTextField(labelWithString: String(
            format: NSLocalizedString("%@\n%@", comment: "Recovery row: agent name and status"),
            candidate.displayName,
            status
        ))
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byWordWrapping
        label.setFrameSize(NSSize(width: 300, height: 34))
        label.preferredMaxLayoutWidth = 300
        // Fixed column so the Resume/Start Fresh/Archive buttons align
        // across rows regardless of how long each status line is.
        label.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let resume = NSButton(
            title: NSLocalizedString("Resume", comment: "Button resuming the recovered agent session"),
            target: self,
            action: #selector(resumeClicked(_:))
        )
        resume.bezelStyle = .rounded
        resume.isEnabled = candidate.canResume
        resume.identifier = NSUserInterfaceItemIdentifier(candidate.agentID.rawValue.uuidString)

        let fresh = NSButton(
            title: NSLocalizedString("Start Fresh", comment: "Button starting a new session for the recovered agent"),
            target: self,
            action: #selector(startFreshClicked(_:))
        )
        fresh.bezelStyle = .rounded
        fresh.identifier = NSUserInterfaceItemIdentifier(candidate.agentID.rawValue.uuidString)

        let archive = NSButton(
            title: NSLocalizedString("Archive", comment: "Button archiving the recovered agent without starting it"),
            target: self,
            action: #selector(archiveClicked(_:))
        )
        archive.bezelStyle = .rounded
        archive.identifier = NSUserInterfaceItemIdentifier(candidate.agentID.rawValue.uuidString)

        rowViews[candidate.agentID] = [resume, fresh, archive]

        let row = NSStackView(views: [label, resume, fresh, archive])
        row.orientation = .horizontal
        row.spacing = 8
        row.identifier = NSUserInterfaceItemIdentifier(candidate.agentID.rawValue.uuidString)
        return row
    }

    // MARK: Actions (§3.15)

    @objc func resumeClicked(_ sender: NSButton) {
        guard let root,
              let candidate = remaining.first(where: { $0.agentID.rawValue.uuidString == sender.identifier?.rawValue })
        else { return }
        guard let workspace = root.activeWorkspaceID else {
            // Bootstrap not finished yet: never fail silently.
            presentFailure(
                NSLocalizedString("Resume failed", comment: "Alert title when resuming a recovered session errors"),
                RecoveryActionUnavailableError()
            )
            return
        }
        Task { @MainActor in
            setRowEnabled(candidate.agentID, enabled: false)
            do {
                guard let reference = candidate.sessionReference else {
                    setRowEnabled(candidate.agentID, enabled: true)
                    return
                }
                let action = RestoreResumeAction(
                    persistedAgentID: candidate.agentID,
                    workspaceID: workspace,
                    kind: candidate.kind,
                    displayName: candidate.displayName,
                    cwd: candidate.cwd,
                    sessionReference: reference,
                    resumeSpec: .init(argv: [], workingDirectory: "")
                )
                // executeResume rebuilds the spec from the adapter; the stub
                // argv here is never used when a valid reference exists.
                _ = try await root.coordinator.executeResume(action, in: workspace)
                self.dismiss(candidate: candidate)
            } catch {
                setRowEnabled(candidate.agentID, enabled: true)
                // Old session reference preserved until successful launch.
                self.presentFailure(
                    NSLocalizedString("Resume failed", comment: "Alert title when resuming a recovered session errors"),
                    error
                )
            }
        }
    }

    @objc func startFreshClicked(_ sender: NSButton) {
        guard let root,
              let candidate = remaining.first(where: { $0.agentID.rawValue.uuidString == sender.identifier?.rawValue })
        else { return }
        guard let workspace = root.activeWorkspaceID else {
            // Bootstrap not finished yet: never fail silently.
            presentFailure(
                NSLocalizedString("Start Fresh failed",
                                  comment: "Alert title when starting a fresh session errors"),
                RecoveryActionUnavailableError()
            )
            return
        }
        Task { @MainActor in
            setRowEnabled(candidate.agentID, enabled: false)
            do {
                let agentID = try await root.coordinator.createAgent(
                    AgentLaunchRequest(
                        agentKind: candidate.kind,
                        workingDirectory: candidate.cwd.isEmpty ? NSHomeDirectory() : candidate.cwd,
                        displayName: candidate.displayName,
                        taskSummary: NSLocalizedString(
                            "fresh start after crash recovery",
                            comment: "Task summary recorded for an agent started fresh after a crash"
                        )
                    ),
                    in: workspace
                )
                // Match the New Agent sheet: the operator picked an explicit
                // recovery action, so the new session becomes the focused
                // pane instead of leaving the canvas on its empty state.
                root.focusAgentInUI(agentID)
                self.dismiss(candidate: candidate)
            } catch {
                setRowEnabled(candidate.agentID, enabled: true)
                self.presentFailure(
                    NSLocalizedString("Start Fresh failed",
                                      comment: "Alert title when starting a fresh session errors"),
                    error
                )
            }
        }
    }

    @objc func archiveClicked(_ sender: NSButton) {
        guard let candidate = remaining.first(where: { $0.agentID.rawValue.uuidString == sender.identifier?.rawValue })
        else { return }
        // Archive permanently abandons the crashed session (archived_at is
        // set; the session reference can never be resumed) — confirm before
        // discarding, the row sits right next to Resume/Start Fresh.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString(
                "Archive \"%@\"?",
                comment: "Archive confirmation title naming the agent"
            ),
            candidate.displayName
        )
        alert.informativeText = NSLocalizedString(
            "The crashed session will not be restarted and can no longer be resumed.",
            comment: "Archive confirmation detail"
        )
        alert.addButton(withTitle: NSLocalizedString(
            "Archive", comment: "Confirmation button archiving the crashed session"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "Cancel", comment: "Button cancelling the archive"
        ))
        alert.buttons.first?.hasDestructiveAction = true
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    self?.runArchive(candidate, confirmed: response == .alertFirstButtonReturn)
                }
            }
        } else {
            let response = alert.runModal()
            runArchive(candidate, confirmed: response == .alertFirstButtonReturn)
        }
    }

    /// Runs the archive only after explicit confirmation from the alert.
    private func runArchive(_ candidate: RecoveryCandidate, confirmed: Bool) {
        guard confirmed else { return }
        Task { @MainActor in
            setRowEnabled(candidate.agentID, enabled: false)
            do {
                guard let repository = self.root?.agentRepository else {
                    // Repository missing means the archive did NOT happen;
                    // never dismiss as if it succeeded.
                    throw RecoveryActionUnavailableError()
                }
                try await repository.archive(candidate.agentID)
                self.dismiss(candidate: candidate)
            } catch {
                setRowEnabled(candidate.agentID, enabled: true)
                // Keep the row visible so the candidate stays actionable.
                self.presentFailure(
                    NSLocalizedString("Archive Failed", comment: "Recovery center alert title"),
                    error
                )
            }
        }
    }

    private func dismiss(candidate: RecoveryCandidate) {
        remaining.removeAll { $0.agentID == candidate.agentID }
        rowViews[candidate.agentID] = nil
        if remaining.isEmpty {
            finish()
        } else {
            let rowID = NSUserInterfaceItemIdentifier(candidate.agentID.rawValue.uuidString)
            if let row = contentStack?.arrangedSubviews.first(where: { $0.identifier == rowID }) {
                contentStack?.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
        }
    }

    /// Every candidate resolved: hand control back to the normal shell.
    private func finish() {
        window?.orderOut(nil)
        window = nil
        root?.recoveryCenterDidFinish()
    }

    private func presentFailure(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert dismissal button"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Error surfaced when a recovery action cannot run because the app shell has
/// not finished bootstrapping (composition root or active workspace missing).
private struct RecoveryActionUnavailableError: LocalizedError, CustomStringConvertible {
    var errorDescription: String? {
        NSLocalizedString(
            "This action is unavailable because the app is still starting up. Try again in a moment.",
            comment: "Recovery center message when bootstrap has not finished"
        )
    }

    var description: String {
        errorDescription ?? ""
    }
}

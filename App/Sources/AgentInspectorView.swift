import AgentCore
import AppKit

// Inspector (§3.13): identity / task summary / lifecycle & attention /
// authority / PID / cwd / session ref / timeline + Stop/Restart/Resume actions.

/// One labelled block of inspector text. The text view always renders
/// exactly what these sections hold, so async probes replace their section
/// in the model and the text re-renders — no string surgery on the
/// rendered result.
private struct InspectorSection {
    enum ID {
        case identity, task, lifecycle, runtime, cwd, session, queue, timeline
        case integration
        case shell, actions
        case emptyState, repair
    }

    let id: ID
    var title: String?
    var lines: [String]

    var renderedText: String? {
        var out: [String] = []
        if let title {
            out.append(title)
        }
        out.append(contentsOf: lines)
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}

@MainActor
final class AgentInspectorController: NSViewController {
    private let model: AppModel
    private let seam: RuntimeSeam
    private let text = NSTextView()
    private let stopButton = NSButton(
        title: NSLocalizedString("Stop agent", comment: "Inspector button: gracefully stop the agent process"),
        target: nil,
        action: nil
    )
    private let restartButton = NSButton(
        title: NSLocalizedString("Restart", comment: "Inspector button: restart the agent"),
        target: nil,
        action: nil
    )
    private let resumeButton = NSButton(
        title: NSLocalizedString("Resume", comment: "Inspector button: resume the agent"),
        target: nil,
        action: nil
    )
    /// §3.17 Repair flow (review item 6): enabled when the integration
    /// diagnostics report anything other than healthy.
    private let repairButton = NSButton(
        title: NSLocalizedString("Repair integration",
                                 comment: "Inspector button: re-install managed integration config"),
        target: nil,
        action: nil
    )
    private let actionButtonsStack = NSStackView()

    private var selectedContent: PaneContent?
    private(set) var selectedRow: RowModel?

    /// Monotonic token for async refresh work: a Task spawned by an older
    /// refresh pass abandons its mutations once a newer pass has started.
    private var refreshGeneration = 0

    /// §3.17 Repair flow: last repair outcome, kept so it survives the
    /// full text rebuild in refresh(); shown only while its agent stays
    /// selected.
    private var lastRepairOutcome: (item: SidebarItem, message: String)?

    /// Last resolved §3.17 diagnostics for the currently inspected agent.
    /// Kept across refresh ticks so the Repair button reflects the last
    /// known health instead of flickering disabled/enabled on every model
    /// tick; dropped as soon as the selection moves to another row.
    private var cachedDiagnostics: (item: SidebarItem, diag: RuntimeSeam.IntegrationDiagnostics)?

    /// The rendered inspector content; `render()` writes exactly this into
    /// the text view.
    private var sections: [InspectorSection] = []

    init(model: AppModel, seam: RuntimeSeam) {
        self.model = model
        self.seam = seam
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    /// Teardown: never leave the liveness poll running against a dead
    /// controller; the tick's `weak self` guard also self-invalidates.
    deinit {
        livenessTimer?.invalidate()
        livenessTimer = nil
    }

    override func loadView() {
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isRichText = false

        for item in [stopButton, restartButton, resumeButton, repairButton] {
            item.bezelStyle = .rounded
            item.controlSize = .small
            item.setButtonType(.momentaryPushIn)
        }
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        restartButton.target = self
        restartButton.action = #selector(restartClicked)
        resumeButton.target = self
        resumeButton.action = #selector(resumeClicked)
        repairButton.target = self
        repairButton.action = #selector(repairClicked)
        repairButton.isEnabled = false
        stopButton.toolTip = NSLocalizedString(
            "Stops the agent's process; it can be restarted afterwards.",
            comment: "Tooltip for the Stop agent button"
        )
        repairButton.toolTip = NSLocalizedString(
            "Re-installs the integration's managed configuration.",
            comment: "Tooltip for the Repair integration button"
        )

        // Two rows: four small buttons exceed the 320 pt inspector width and
        // the trailing button clipped at the window edge. Lifecycle actions
        // lead; integration repair gets its own row.
        actionButtonsStack.addArrangedSubview(NSStackView(views: [stopButton, restartButton, resumeButton]))
        actionButtonsStack.addArrangedSubview(NSStackView(views: [repairButton]))
        actionButtonsStack.orientation = .vertical
        actionButtonsStack.alignment = .leading
        actionButtonsStack.spacing = 6

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let container = NSView()
        container.addSubview(actionButtonsStack)
        container.addSubview(scroll)
        actionButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actionButtonsStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            actionButtonsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            text.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // Selection-dependent top anchor: with a selection the text sits
        // below the action stack; without one the stack hides and the text
        // takes the whole container (a disabled-only button row reads as
        // broken UI).
        scrollBelowButtons = scroll.topAnchor.constraint(equalTo: actionButtonsStack.bottomAnchor, constant: 8)
        scrollBelowButtons.isActive = true
        scrollTopToContainer = scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8)
        view = container
    }

    func setSelected(_ row: RowModel?) {
        selectedRow = row
        refresh()
    }

    /// Inputs that fully determine the built sections. Unchanged inputs let
    /// refresh() skip the rebuild and the async probe spawn — the hot path
    /// while deltas stream (§4.6). Async section replacements (timeline,
    /// integration diagnostics) bypass this gate, so they stay live.
    private struct BuildInputs: Equatable {
        var selection: SidebarItem?
        var agentSummary: AgentSummary?
        var agentCwd: String?
        var shellName: String?
        var shellCwd: String?
        var repairItem: SidebarItem?
        var repairMessage: String?
        /// Rendered pid line: process liveness changes must invalidate the
        /// build even when the model payload is unchanged, or the inspector
        /// shows a stale "pid (alive)" and a dead Stop button.
        var pidLine: String?
    }

    private var buildInputs: BuildInputs?

    /// Polls foreground-pid liveness while a selection claims a live
    /// process: orphaned exits never arrive as model deltas, so without
    /// this watch the inspector would keep saying "Running" until an
    /// unrelated refresh. One kill() per tick.
    private var livenessTimer: Timer?
    /// Mutually exclusive scroll top anchors (selection-dependent layout).
    private var scrollBelowButtons: NSLayoutConstraint!
    private var scrollTopToContainer: NSLayoutConstraint!

    /// Static agent sections for refresh(): identity/task/lifecycle/PID/CWD/
    /// session/queued-prompt plus the timeline + integration placeholders
    /// (async probes replace those two wholesale through the section model).
    private func agentStaticSections(
        summary: AgentSummary,
        agentID id: AgentID,
        inputs: BuildInputs
    ) -> [InspectorSection] {
        [
            InspectorSection(
                id: .identity,
                title: NSLocalizedString("AGENT IDENTITY", comment: "Inspector section header"),
                lines: [
                    String(
                        format: NSLocalizedString("  name: %@", comment: "Inspector: agent display name"),
                        summary.displayName
                    ),
                    String(
                        format: NSLocalizedString("  kind: %@", comment: "Inspector: agent kind"),
                        summary.kind.displayName
                    ),
                    String(
                        format: NSLocalizedString("  id: %@", comment: "Inspector: agent identifier prefix"),
                        String(id.rawValue.uuidString.prefix(8))
                    ),
                ]
            ),
            InspectorSection(
                id: .task,
                title: NSLocalizedString("TASK SUMMARY", comment: "Inspector section header"),
                lines: [
                    String(
                        format: NSLocalizedString("  %@", comment: "Inspector detail line"),
                        summary.taskSummary ?? "—"
                    ),
                ]
            ),
            InspectorSection(
                id: .lifecycle,
                title: NSLocalizedString("LIFECYCLE & ATTENTION", comment: "Inspector section header"),
                lines: {
                    var lines = [
                        String(
                            format: NSLocalizedString("  process: %@", comment: "Inspector: process phase"),
                            processText(summary.state.process, item: .agent(id))
                        ),
                        String(
                            format: NSLocalizedString("  lifecycle: %@", comment: "Inspector: lifecycle state"),
                            describe(summary.state.lifecycle)
                        ),
                        String(
                            format: NSLocalizedString("  attention: %@", comment: "Inspector: attention state"),
                            describe(summary.state.attention)
                        ),
                        String(
                            format: NSLocalizedString(
                                "  turn active: %@",
                                comment: "Inspector: whether a turn is running"
                            ),
                            summary.turnActive
                                ? NSLocalizedString("yes", comment: "Inspector: affirmative")
                                : NSLocalizedString("no", comment: "Inspector: negative")
                        ),
                    ]
                    if case let .waitingForInput(descriptor) = summary.state.lifecycle,
                       let request = descriptor.summary
                    {
                        lines.append(String(
                            format: NSLocalizedString(
                                "  request: %@",
                                comment: "Inspector: pending input request summary"
                            ),
                            request
                        ))
                    }
                    return lines
                }()
            ),
            pidSection(lines: inputs.pidLine.map { [$0] } ?? []),
            InspectorSection(
                id: .cwd,
                title: NSLocalizedString("CWD", comment: "Inspector section header"),
                lines: [
                    String(
                        format: NSLocalizedString("  %@", comment: "Inspector detail line"),
                        model.agentCwd[id] ?? "—"
                    ),
                ]
            ),
            InspectorSection(
                id: .session,
                title: NSLocalizedString("SESSION REFERENCE", comment: "Inspector section header"),
                lines: [
                    summary.hasSessionReference
                        ? NSLocalizedString("  captured", comment: "Inspector: session reference exists")
                        : NSLocalizedString("  none", comment: "Inspector: no session reference"),
                ]
            ),
            InspectorSection(
                id: .queue,
                title: NSLocalizedString("QUEUED PROMPT", comment: "Inspector section header"),
                lines: [
                    summary.hasQueuedPrompt
                        ? NSLocalizedString("  yes", comment: "Inspector: queued prompt exists")
                        : NSLocalizedString("  no", comment: "Inspector: no queued prompt"),
                ]
            ),
            InspectorSection(
                id: .timeline,
                title: NSLocalizedString("TIMELINE", comment: "Inspector section header"),
                lines: []
            ),
        ]
    }

    private func pidSection(lines: [String]) -> InspectorSection {
        InspectorSection(
            id: .runtime,
            title: NSLocalizedString("PID", comment: "Inspector section header"),
            lines: lines
        )
    }

    func refresh() {
        guard isViewLoaded else { return }
        // Skip-gate: nothing the sections render changed since the last
        // build — keep the current text (async section swaps included) and
        // skip the rebuild plus the probe task spawn.
        var inputs = BuildInputs(
            selection: selectedRow?.item,
            agentSummary: nil,
            agentCwd: nil,
            shellName: nil,
            shellCwd: nil,
            repairItem: lastRepairOutcome?.item,
            repairMessage: lastRepairOutcome?.message
        )
        switch selectedRow?.item {
        case let .agent(id):
            inputs.agentSummary = model.agents[id]
            inputs.agentCwd = model.agentCwd[id]
        case let .shell(terminalID):
            inputs.shellName = model.shells[terminalID]?.name
            inputs.shellCwd = model.shells[terminalID]?.cwd
        case nil:
            break
        }
        inputs.pidLine = selectedRow.map { pidLine(for: $0.item) }
        updateLivenessWatch()
        if inputs == buildInputs {
            return
        }
        buildInputs = inputs
        // Actions target a selection; with none, the stack hides and the
        // text view reclaims the container top.
        let showsActions = selectedRow?.item != nil
        actionButtonsStack.isHidden = !showsActions
        if showsActions {
            scrollTopToContainer.isActive = false
            scrollBelowButtons.isActive = true
        } else {
            scrollBelowButtons.isActive = false
            scrollTopToContainer.isActive = true
        }
        refreshGeneration += 1
        let generation = refreshGeneration

        var built: [InspectorSection] = []
        var agentLifecycle: LifecyclePhase?

        if let row = selectedRow {
            switch row.item {
            case let .agent(id):
                if let summary = model.agents[id] {
                    // Diagnostic health is remembered per agent: a routine
                    // model tick must not flip Repair back to disabled while
                    // the async probe re-runs (the probe re-arms it below).
                    if cachedDiagnostics?.item != row.item {
                        cachedDiagnostics = nil
                    }
                    agentLifecycle = summary.state.lifecycle
                    built += agentStaticSections(summary: summary, agentID: id, inputs: inputs)
                    // Executable + version + §3.17 diagnostics resolve
                    // asynchronously (PATH scan, version probe, install-plan
                    // diagnose). Until they land, the trailing section shows
                    // placeholders; the probe replaces it WHOLESALE through
                    // the section model — no string surgery.
                    let knownDiagnostics = cachedDiagnostics?.diag
                    built.append(InspectorSection(
                        id: .integration,
                        title: NSLocalizedString("INTEGRATION DIAGNOSTICS", comment: "Inspector section header"),
                        lines: knownDiagnostics.map { diagnosticsLines($0, agentID: id) }
                            ?? [
                                NSLocalizedString(
                                    "  executable: resolving…",
                                    comment: "Inspector: executable probe pending"
                                ),
                                NSLocalizedString("  probing…", comment: "Inspector: diagnostics pending"),
                            ]
                    ))
                    if let knownDiagnostics {
                        repairButton.isEnabled = knownDiagnostics.canRepair
                    } else {
                        // Fresh selection: no health known yet — stay
                        // disabled until the probe reports.
                        repairButton.isEnabled = false
                    }
                    let timelineID = id
                    let diagnosticsID = id
                    // ONE serialized task: section order must not depend on
                    // which probe resolves first. Both results land through
                    // the section model — each replaces its own section and
                    // the text re-renders atomically.
                    Task { [weak self] in
                        let timeline = await self?.seam.timelineLines(for: timelineID, limit: 12) ?? []
                        let diag = await self?.seam.integrationDiagnostics(for: .agent(diagnosticsID))
                        guard let self, generation == refreshGeneration,
                              selectedRow?.item == .agent(timelineID),
                              isViewLoaded else { return }
                        if !timeline.isEmpty {
                            updateSection(.timeline) { section in
                                section.lines = timeline.map { String(
                                    format: NSLocalizedString("  • %@", comment: "Inspector timeline entry"),
                                    $0
                                ) }
                            }
                        } else {
                            // A bare TIMELINE heading reads as a rendering
                            // bug; say why it is empty instead.
                            updateSection(.timeline) { section in
                                section.lines = [NSLocalizedString(
                                    "  No activity recorded yet.",
                                    comment: "Inspector: agent timeline is empty"
                                )]
                            }
                        }
                        guard let diag else { return }
                        cachedDiagnostics = (item: .agent(diagnosticsID), diag: diag)
                        updateSection(.integration) { section in
                            section.lines = self.diagnosticsLines(diag, agentID: diagnosticsID)
                        }
                        repairButton.isEnabled = diag.canRepair
                    }
                }
                repairButton.isHidden = false
            case let .shell(terminalID):
                let shell = model.shells[terminalID]
                built += [
                    InspectorSection(
                        id: .shell,
                        title: NSLocalizedString("SHELL", comment: "Inspector section header"),
                        lines: [
                            String(
                                format: NSLocalizedString("  name: %@", comment: "Inspector: shell name"),
                                shell?.name ?? NSLocalizedString("Terminal", comment: "Default shell display name")
                            ),
                            String(
                                format: NSLocalizedString("  id: %@", comment: "Inspector: shell identifier prefix"),
                                String(terminalID.rawValue.uuidString.prefix(8))
                            ),
                        ]
                    ),
                    pidSection(lines: inputs.pidLine.map { [$0] } ?? []),
                    InspectorSection(
                        id: .cwd,
                        title: NSLocalizedString("CWD", comment: "Inspector section header"),
                        lines: [
                            String(
                                format: NSLocalizedString("  %@", comment: "Inspector detail line"),
                                shell?.cwd ?? "—"
                            ),
                        ]
                    ),
                    InspectorSection(
                        id: .actions,
                        title: NSLocalizedString("ACTIONS", comment: "Inspector section header"),
                        lines: [
                            NSLocalizedString(
                                "  Stop sends SIGTERM to this shell's process group.",
                                comment: "Inspector: explanation of the Stop action for shells"
                            ),
                        ]
                    ),
                ]
                repairButton.isEnabled = false
            }
        } else if !model.agents.isEmpty {
            // §4.6/§3.23 no-selection state: actionable, VoiceOver readable.
            // Suppressed when the sidebar has no agents at all — the canvas
            // already carries the launch instructions and three simultaneous
            // hints read as noise.
            built.append(InspectorSection(
                id: .emptyState,
                title: nil,
                lines: [
                    NSLocalizedString("No agent selected.", comment: "Inspector empty state headline"),
                    "",
                    NSLocalizedString(
                        "Select an agent in the sidebar to see identity, lifecycle,",
                        comment: "Inspector empty state instructions, line 1"
                    ),
                    NSLocalizedString(
                        "authority, timeline and actions here.",
                        comment: "Inspector empty state instructions, line 2"
                    ),
                ]
            ))
            repairButton.isEnabled = false
        } else {
            repairButton.isEnabled = false
        }

        if let outcome = lastRepairOutcome,
           selectedRow?.item == outcome.item
        {
            built.append(InspectorSection(
                id: .repair,
                title: NSLocalizedString("REPAIR", comment: "Inspector section header"),
                lines: [
                    String(
                        format: NSLocalizedString("%@", comment: "Inspector detail line"),
                        outcome.message
                    ),
                ]
            ))
        }

        sections = built
        render()

        // §3.23: the inspector reads as one labelled text region.
        view.setAccessibilityLabel(NSLocalizedString(
            "Agent Inspector",
            comment: "Accessibility label for the inspector panel"
        ))

        text.setAccessibilityLabel(NSLocalizedString(
            "Inspector details",
            comment: "Accessibility label for the inspector detail text"
        ))
        stopButton.setAccessibilityLabel(NSLocalizedString(
            "Stop agent gracefully",
            comment: "Accessibility label for the Stop agent button"
        ))
        restartButton.setAccessibilityLabel(NSLocalizedString(
            "Restart agent",
            comment: "Accessibility label for the Restart button"
        ))
        resumeButton.setAccessibilityLabel(NSLocalizedString(
            "Resume agent",
            comment: "Accessibility label for the Resume button"
        ))
        repairButton.setAccessibilityLabel(NSLocalizedString(
            "Repair integration",
            comment: "Accessibility label for the Repair integration button"
        ))

        let isAgent = if case .agent? = selectedRow?.item {
            true
        } else {
            false
        }
        let hasSelection = selectedRow != nil
        stopButton.isEnabled = hasSelection && seam.foregroundPID(selectedRow!.item).map { $0 > 0 } == true
        // Lifecycle-gated actions (model exposes the state here): Restart is
        // meaningless while a start/stop transition is already running, and
        // for a stopped agent Resume is the correct action — the same
        // routing AppCommands applies.
        var restartable = false
        var resumable = false
        if isAgent, let lifecycle = agentLifecycle {
            switch lifecycle {
            case .starting, .stopping, .stopped:
                break
            default:
                restartable = true
            }
            switch lifecycle {
            case .stopped, .failed: resumable = true
            default: break
            }
        }
        restartButton.isEnabled = restartable
        resumeButton.isEnabled = resumable
        // Repair enablement is NOT force-reset here: it follows the cached
        // (or freshly probed) diagnostic health of the inspected agent.
    }

    @objc private func repairClicked() {
        guard let item = selectedRow?.item else { return }
        Task {
            let outcome = await seam.repairIntegration(for: item)
            lastRepairOutcome = (item: item, message: String(
                format: NSLocalizedString("%@", comment: "Inspector detail line"),
                outcome ?? "no outcome"
            ))
            self.refresh()
        }
    }

    @objc private func stopClicked() {
        guard let item = selectedRow?.item else { return }
        Task {
            await seam.stop(item)
            self.refresh()
        }
    }

    @objc private func restartClicked() {
        guard let item = selectedRow?.item else { return }
        Task {
            await seam.restart(item)
            self.refresh()
        }
    }

    @objc private func resumeClicked() {
        guard let item = selectedRow?.item else { return }
        Task {
            await seam.resume(item)
            self.refresh()
        }
    }

    // MARK: - Rendering

    private func render() {
        text.string = sections.compactMap(\.renderedText).joined(separator: "\n\n")
    }

    /// Replaces one section's content in the model and re-renders the text
    /// view from the model.
    private func updateSection(_ id: InspectorSection.ID, mutate: (inout InspectorSection) -> Void) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sections[index])
        render()
    }

    private func pidLine(for item: SidebarItem) -> String {
        if let pid = seam.foregroundPID(item), pid > 0 {
            // The exit pipeline can miss orphaned children (a spawned
            // helper that dies before claiming its PTY leaves nothing
            // waitpid-able), so "alive" is verified against the OS here —
            // a dead pid must never render as live.
            if seam.isProcessAlive(item) {
                return String(
                    format: NSLocalizedString("  pid: %lld (alive)", comment: "Inspector: live process id"),
                    Int(pid)
                )
            }
            return String(
                format: NSLocalizedString("  pid: %lld (gone)", comment: "Inspector: process id no longer exists"),
                Int(pid)
            )
        }
        return NSLocalizedString("  pid: —", comment: "Inspector: no live process")
    }

    /// Re-arms the liveness poll whenever a selection has a live foreground
    /// pid. The previous item's timer is always invalidated first so rapid
    /// selection changes never stack timers or leave one watching a stale
    /// item; the tick re-renders once the pid vanishes (pidLine feeds the
    /// build gate, so the flip rebuilds the sections) and disarms.
    private func updateLivenessWatch() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        guard let item = selectedRow?.item,
              let pid = seam.foregroundPID(item), pid > 0,
              seam.isProcessAlive(item)
        else {
            return
        }
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                // A selection change replaced this timer; never act on a
                // stale item.
                guard self.selectedRow?.item == item else { return }
                if !self.seam.isProcessAlive(item) {
                    self.livenessTimer?.invalidate()
                    self.livenessTimer = nil
                    self.refresh()
                }
            }
        }
    }

    private func diagnosticsLines(_ diag: RuntimeSeam.IntegrationDiagnostics, agentID: AgentID) -> [String] {
        var lines = [
            String(
                format: NSLocalizedString("  executable: %@", comment: "Inspector: resolved executable path"),
                diag.resolvedPath ?? diag.program
            ),
            String(
                format: NSLocalizedString("  version: %@", comment: "Inspector: executable version"),
                diag.version ?? NSLocalizedString("unknown", comment: "Inspector: version unknown")
            ),

            String(
                format: NSLocalizedString("  health: %@", comment: "Inspector: integration health"),
                diag.healthText
            ),
        ]
        // Stage-16 gate 6c: adapter-version fallback warning.
        if let reason = seam.versionFallbackReason(for: agentID) {
            lines.append("  " + String(
                format: NSLocalizedString("WARNING: screen detection fallback — %@",
                                          comment: "Inspector: manifest version-range demotion"),
                reason
            ))
        }
        return lines
    }

    // MARK: - Human-readable state

    /// Maps a process phase to a short operator-facing phrase; raw debug
    /// tuples (`code=1 sig=nil user=false`) never reach the text view.
    private func describe(_ phase: ProcessPhase) -> String {
        switch phase {
        case .notStarted:
            return NSLocalizedString("Not started", comment: "Process state: not yet launched")
        case .launching:
            return NSLocalizedString("Launching", comment: "Process state: launch in progress")
        case .exiting:
            return NSLocalizedString("Shutting down", comment: "Process state: shutting down")
        case let .running(pid, _):
            if let pid, pid > 0 {
                return String(
                    format: NSLocalizedString("Running (pid %@)", comment: "Process state: running, with process id"),
                    String(pid)
                )
            }
            return NSLocalizedString("Running", comment: "Process state: running")
        case let .exited(code, signal, userInitiated):
            return describeExit(code: code, signal: signal, userInitiated: userInitiated)
        case let .launchFailed(errorDescriptor):
            return String(
                format: NSLocalizedString("Launch failed: %@", comment: "Process state: launch failed"),
                errorDescriptor
            )
        }
    }

    /// Liveness-aware rendering of a `.running` phase: the model can keep
    /// claiming "running" after an unobserved exit (orphaned child, missed
    /// poll), so the OS is asked before the claim reaches the text view.
    private func processText(_ phase: ProcessPhase, item: SidebarItem) -> String {
        if case let .running(pid, _) = phase, let pid, pid > 0,
           !seam.isProcessAlive(item)
        {
            return String(
                format: NSLocalizedString(
                    "Process gone (pid %@)",
                    comment: "Process state: model says running but the pid no longer exists"
                ),
                String(pid)
            )
        }
        return describe(phase)
    }

    private func describeExit(code: Int32?, signal: Int32?, userInitiated: Bool) -> String {
        if let signal, signal != 0 {
            return String(
                format: NSLocalizedString("Terminated by signal %@", comment: "Process state: killed by a signal"),
                String(signal)
            )
        }
        switch code {
        case 0:
            return userInitiated
                ? NSLocalizedString("Stopped by you", comment: "Process state: user-requested clean exit")
                : NSLocalizedString("Finished", comment: "Process state: exited cleanly on its own")
        case let code?:
            return String(
                format: NSLocalizedString(
                    "Exited with code %@",
                    comment: "Process state: exited with a nonzero status"
                ),
                String(code)
            )
        case nil:
            return NSLocalizedString("Exited", comment: "Process state: exited with unknown status")
        }
    }

    /// Lifecycle phases read as short status phrases, aligned with the
    /// sidebar's wording (`SidebarGrouping.stateText`).
    private func describe(_ lifecycle: LifecyclePhase) -> String {
        switch lifecycle {
        case .unknown:
            NSLocalizedString("Unknown", comment: "Lifecycle: state cannot be determined")
        case .starting:
            NSLocalizedString("Starting", comment: "Lifecycle: coming up")
        case .idle:
            NSLocalizedString("Idle", comment: "Lifecycle: ready, no turn running")
        case .working:
            NSLocalizedString("Working", comment: "Lifecycle: a turn is running")
        case let .waitingForInput(descriptor):
            switch descriptor.kind {
            case .approval:
                NSLocalizedString("Waiting for your approval", comment: "Lifecycle: an approval prompt is pending")
            case .selection:
                NSLocalizedString("Waiting for your selection", comment: "Lifecycle: a choice prompt is pending")
            case .freeText, .unknown:
                NSLocalizedString("Waiting for your input", comment: "Lifecycle: the agent asked for input")
            }
        case .stopping:
            NSLocalizedString("Stopping", comment: "Lifecycle: stop in progress")
        case .stopped:
            NSLocalizedString("Stopped", comment: "Lifecycle: process has exited")
        case .failed:
            NSLocalizedString("Failed", comment: "Lifecycle: ended in failure")
        }
    }

    private func describe(_ attention: AttentionState) -> String {
        switch attention {
        case .none:
            NSLocalizedString("None", comment: "Attention: nothing needs the operator")
        case .completionUnread:
            NSLocalizedString("Unread completion", comment: "Attention: a finished turn has not been reviewed")
        case .inputRequired:
            NSLocalizedString("Needs your input", comment: "Attention: the agent requested input")
        case .failure:
            NSLocalizedString("Failure to review", comment: "Attention: a failure needs review")
        }
    }
}

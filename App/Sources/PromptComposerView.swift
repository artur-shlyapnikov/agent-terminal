import AgentCore
import AppKit
import TerminalKit

// Prompt composer (§3.13/§3.11), bound to the focused agent:
// - working → primary "Queue after current turn" + explicit "Send now" dropdown
// - waitingForInput(terminalOnly) → input replaced by "Answer in terminal" CTA;
//   sending is blocked at the UI boundary (§5.1 critical law)
// - unknown → automatic queue disabled (explicit send only)
// - queued prompt indicator → click cancels via cancelQueuedPrompt
// - unconfirmed delivery notice surfaced from the runtime watchdog
// - Esc returns focus to the terminal; ⌘L focuses the composer.
//
// Every agent send carries a client-generated commandID so retries replay
// instead of double-delivering (stage-9 duplicate protection).

@MainActor
final class PromptComposerView: NSView {
    private weak var model: AppModel?
    private weak var sessionManager: TerminalSessionManager?

    private let field = NSTextField()
    private let primaryButton = NSButton(
        title: NSLocalizedString("Send now", comment: "Composer button: send the prompt immediately"),
        target: nil,
        action: nil
    )
    private let queueMenuButton = NSButton(
        title: NSLocalizedString("Send now ▾", comment: "Composer button: opens the prompt delivery options menu"),
        target: nil,
        action: nil
    )
    private let ctaButton = NSButton(
        title: NSLocalizedString("Answer in terminal", comment: "Composer button: hand input back to the terminal"),
        target: nil,
        action: nil
    )
    /// Click-to-cancel indicator shown while the focused agent holds a queued
    /// prompt (§3.11: exactly one queued prompt, cancellable).
    private let queuedIndicator = NSButton(
        title: NSLocalizedString("⏸ Queued — click to cancel",
                                 comment: "Composer indicator: a queued prompt exists; clicking cancels it"),
        target: nil,
        action: nil
    )
    /// Watchdog surfacing: delivery not confirmed within 5 s (no auto-retry).
    private let unconfirmedNotice = NSTextField(labelWithString: "")
    /// Explicit USER-initiated retry for the surfaced unconfirmed delivery;
    /// replays the SAME commandID so stage-9 idempotency prevents double
    /// delivery. §3.11's "no auto-retry" law is untouched: nothing retries
    /// without a click.
    private let retryUnconfirmedButton = NSButton(
        title: NSLocalizedString("Retry", comment: "Composer button: re-send the unconfirmed prompt"),
        target: nil,
        action: nil
    )
    /// Inline send-failure feedback (muted red). Shown when the seam reports
    /// a rejected dispatch; the draft text stays in the field.
    private let errorNotice = NSTextField(labelWithString: "")
    var onSend: ((String, PromptPolicy, CommandID) async -> PromptSendOutcome)?
    var onCancelQueued: (() -> Void)?
    var focusRequestHandler: (() -> Void)?

    /// Last dispatched prompt per agent, kept so the unconfirmed-delivery
    /// notice can offer an idempotent Retry (same commandID).
    private struct SentPrompt {
        let text: String
        let policy: PromptPolicy
        let commandID: CommandID
    }

    private var lastSentByAgent: [AgentID: SentPrompt] = [:]

    /// Composer row grows with the wrapped draft up to `maxRowLines`, then
    /// the scrollable field editor takes over.
    static let baseRowHeight: CGFloat = 52
    static let maxRowLines = 6
    private(set) var rowHeightConstraint: NSLayoutConstraint!

    /// Focused item is pushed in by MainWindowController on selection change.
    var focusedItemProvider: (() -> SidebarItem?)?

    /// Lifecycle bucket the composer was last configured for; drives the
    /// §5.1 send-blocking rules independent of button titles.
    private(set) var configuredLifecycle: String?

    /// Delivery policy of the visible primary button, derived from the
    /// lifecycle bucket — never from the localized button title.
    private var primaryPolicy: PromptPolicy {
        configuredLifecycle == "working" ? .queueWhenIdle : .sendNow
    }

    init(model: AppModel, sessionManager: TerminalSessionManager?) {
        self.model = model
        self.sessionManager = sessionManager
        super.init(frame: .zero)

        field.font = .systemFont(ofSize: 12)
        // Multiline composer: a wrapping, scrollable field editor accepts real
        // newlines (Shift/Option/Ctrl+Enter); the row height follows the
        // content up to maxRowLines.
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        (field.cell as? NSTextFieldCell)?.wraps = true
        (field.cell as? NSTextFieldCell)?.isScrollable = true
        field.placeholderString = NSLocalizedString(
            "Prompt for focused agent…",
            comment: "Composer text field placeholder"
        )
        field.setAccessibilityIdentifier("composer.field")
        primaryButton.setAccessibilityLabel(NSLocalizedString(
            "Send prompt",
            comment: "Accessibility label for the primary send button"
        ))
        queueMenuButton.setAccessibilityLabel(NSLocalizedString(
            "Prompt delivery options",
            comment: "Accessibility label for the delivery options button"
        ))
        ctaButton.setAccessibilityLabel(NSLocalizedString(
            "Answer in terminal",
            comment: "Accessibility label for the terminal-only CTA button"
        ))
        queuedIndicator.setAccessibilityLabel(NSLocalizedString(
            "Prompt queued — click to cancel",
            comment: "Accessibility label for the queued prompt indicator"
        ))
        unconfirmedNotice.setAccessibilityLabel(NSLocalizedString(
            "Delivery unconfirmed, not retried",
            comment: "Accessibility label for the unconfirmed delivery notice"
        ))
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .regular
        primaryButton.setButtonType(.momentaryPushIn)
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.keyEquivalentModifierMask = .command

        queueMenuButton.controlSize = .regular
        queueMenuButton.setButtonType(.momentaryPushIn)
        queueMenuButton.target = self
        queueMenuButton.action = #selector(menuClicked)
        // Hidden until the first configure(for:) pass: the init titles
        // ("Send now" / "Send now ▾") otherwise flash next to the
        // "Select an agent to prompt it" placeholder on a fresh launch.
        primaryButton.isHidden = true
        queueMenuButton.isHidden = true

        ctaButton.bezelStyle = .rounded
        ctaButton.controlSize = .large
        ctaButton.setButtonType(.momentaryPushIn)
        ctaButton.target = self
        ctaButton.action = #selector(ctaClicked)

        queuedIndicator.controlSize = .small
        queuedIndicator.setButtonType(.momentaryPushIn)
        queuedIndicator.bezelStyle = .rounded
        queuedIndicator.target = self
        queuedIndicator.action = #selector(queuedIndicatorClicked)
        queuedIndicator.isHidden = true

        retryUnconfirmedButton.controlSize = .small
        retryUnconfirmedButton.bezelStyle = .rounded
        retryUnconfirmedButton.setButtonType(.momentaryPushIn)
        retryUnconfirmedButton.target = self
        retryUnconfirmedButton.action = #selector(retryUnconfirmedClicked)
        retryUnconfirmedButton.setContentHuggingPriority(.required, for: .horizontal)
        retryUnconfirmedButton.isHidden = true
        retryUnconfirmedButton.setAccessibilityLabel(NSLocalizedString(
            "Retry last prompt",
            comment: "Accessibility label for the unconfirmed-delivery retry button"
        ))

        unconfirmedNotice.textColor = .systemOrange
        unconfirmedNotice.font = .systemFont(ofSize: 11, weight: .semibold)
        unconfirmedNotice.lineBreakMode = .byTruncatingTail
        unconfirmedNotice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorNotice.textColor = .systemRed
        errorNotice.font = .systemFont(ofSize: 11)
        errorNotice.lineBreakMode = .byTruncatingTail
        errorNotice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorNotice.isHidden = true
        errorNotice.setAccessibilityLabel(NSLocalizedString(
            "Send failed",
            comment: "Accessibility label for the composer inline send-failure message"
        ))
        unconfirmedNotice.isHidden = true

        let stack = NSStackView(views: [queuedIndicator, unconfirmedNotice, retryUnconfirmedButton,
                                        errorNotice, field, primaryButton, queueMenuButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(ctaButton)
        rowHeightConstraint = heightAnchor.constraint(equalToConstant: Self.baseRowHeight)
        NSLayoutConstraint.activate([
            rowHeightConstraint,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 560),

            ctaButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            ctaButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    /// Inputs that fully determine every write `refresh()` makes. The
    /// composer sits on the per-delta refresh fan-out, and a redundant pass
    /// still invalidates ~10 constant-string/flag properties per delta —
    /// identical inputs produce identical outputs, so the pass is skipped.
    /// Draft-driven state (send-enabled) is intentionally outside the gate:
    /// every draft mutator (textDidChange, sendResult, restoreDraft)
    /// re-derives it via updateSendEnabled itself.
    private struct ComposerState: Equatable {
        var item: SidebarItem?
        var lifecycle: String?
        var hasQueued: Bool
        var unconfirmed: Bool
        var retryVisible: Bool
    }

    private var lastComposerState: ComposerState?

    func refresh() {
        let item = focusedItemProvider?()
        var lifecycle: String?
        var hasQueued = false
        if case let .agent(id) = item, let summary = model?.agents[id] {
            lifecycle = stateName(summary)
            hasQueued = summary.hasQueuedPrompt
        }
        let agentIDValue = item.flatMap(agentID(of:))
        let unconfirmed = agentIDValue.map { model?.unconfirmedDeliveries[$0] != nil } ?? false
        let retryVisible = if let id = agentIDValue,
                              let surfacedCommandID = model?.unconfirmedDeliveries[id],
                              lastSentByAgent[id]?.commandID == surfacedCommandID
        {
            true
        } else {
            false
        }
        let state = ComposerState(item: item, lifecycle: lifecycle, hasQueued: hasQueued,
                                  unconfirmed: unconfirmed, retryVisible: retryVisible)
        if state == lastComposerState {
            return
        }
        lastComposerState = state

        guard item != nil else {
            // Route through configure's 'no item' pass so the FIELD is also
            // disabled and configuredLifecycle resets to nil — otherwise a
            // stale bucket leaves send() able to clear the draft right before
            // MainWindowController.onSend drops it (focus already gone).
            configure(for: nil)
            queuedIndicator.isHidden = true
            unconfirmedNotice.isHidden = true
            retryUnconfirmedButton.isHidden = true
            errorNotice.isHidden = true
            return
        }
        configure(for: lifecycle)
        // §3.23: composer STATE is announced, never conveyed by color alone.
        setAccessibilityLabel(NSLocalizedString("Prompt composer", comment: "Accessibility label for the composer") +
            (lifecycle.map { String(
                format: NSLocalizedString(", agent %@", comment: "Composer accessibility label: lifecycle suffix"),
                $0
            ) } ?? "") +
            (hasQueued ? NSLocalizedString(", prompt queued", comment: "Composer accessibility label: queued suffix") :
                ""))
        queuedIndicator.isHidden = !hasQueued
        unconfirmedNotice.stringValue = NSLocalizedString(
            "Delivery unconfirmed — not retried",
            comment: "Watchdog notice shown when delivery was not confirmed"
        )
        unconfirmedNotice.isHidden = !unconfirmed
        // Offer Retry only when we still hold the exact prompt whose commandID
        // is surfaced as unconfirmed — replaying it is idempotent (stage-9).
        retryUnconfirmedButton.isHidden = !retryVisible
    }

    /// Scenario/test observability for §3.13/§5.1 states.
    var ctaVisible: Bool {
        !ctaButton.isHidden
    }

    var fieldEnabled: Bool {
        field.isEnabled
    }

    var draftText: String {
        field.stringValue
    }

    var queuedIndicatorVisible: Bool {
        !queuedIndicator.isHidden
    }

    private func agentID(of item: SidebarItem) -> AgentID? {
        if case let .agent(id) = item {
            return id
        }
        return nil
    }

    private func stateName(_ summary: AgentSummary) -> String? {
        if case .inputRequired = summary.state.attention {
            // The typed attention mirrors the lifecycle; only a
            // terminalOnly request blocks the composer (§3.4/§5.1).
            if case let .waitingForInput(d) = summary.state.lifecycle,
               !d.composerPermitted
            {
                return "waitingForInput"
            }
            return "idle"
        }
        switch summary.state.lifecycle {
        case .working: return "working"
        case .starting: return "working"
        case .idle: return "idle"
        case .unknown: return "unknown"
        case let .waitingForInput(d):
            return d.composerPermitted ? "waitingComposerAllowed" : "waitingForInput"
        default: return nil
        }
    }

    /// §3.13/§3.11 policy-aware button states.
    func configure(for lifecycle: String?) {
        configuredLifecycle = lifecycle
        ctaButton.isHidden = true
        primaryButton.isHidden = false
        queueMenuButton.isHidden = false
        field.isEnabled = true
        // Idempotent state: every pass recomputes the enabled states so a
        // previous disabling pass (no item, "unknown") never latches off.
        // Send is additionally gated on a non-empty draft (updateSendEnabled).
        queueMenuButton.isEnabled = true
        switch lifecycle {
        case "waitingForInput":
            // Composer replaced by the terminal-only CTA; input is BLOCKED
            // (§5.1 critical law — waiting states never receive auto or
            // composer replies).
            primaryButton.isHidden = true
            queueMenuButton.isHidden = true
            ctaButton.isHidden = false
            primaryButton.title = NSLocalizedString("Send now", comment: "Composer button: send the prompt immediately")
            field.isEnabled = false
            field.placeholderString = NSLocalizedString(
                "Answer in terminal…",
                comment: "Composer placeholder while terminal-only input is required"
            )
        case "waitingComposerAllowed":
            // freeText + composerAllowed: the composer STAYS (§3.4) — the
            // runtime delivers immediately, so only "Send now" applies.
            primaryButton.title = NSLocalizedString("Send now", comment: "Composer button: send the prompt immediately")
            queueMenuButton.isHidden = true
            field.placeholderString = NSLocalizedString(
                "Prompt for focused agent…",
                comment: "Composer text field placeholder"
            )
        case "working":
            primaryButton.title = NSLocalizedString(
                "Queue after current turn",
                comment: "Composer button: queue the prompt behind the running turn"
            )
            queueMenuButton.title = NSLocalizedString(
                "Send now ▾",
                comment: "Composer button: opens the prompt delivery options menu"
            )
            field.placeholderString = NSLocalizedString(
                "Prompt for focused agent…",
                comment: "Composer text field placeholder"
            )
        case "unknown":
            primaryButton.title = NSLocalizedString("Send now", comment: "Composer button: send the prompt immediately")
            queueMenuButton.title = NSLocalizedString(
                "Queue ▾",
                comment: "Composer button: opens queue-only delivery options"
            )
            queueMenuButton.isEnabled = false // automatic queue disabled (§3.13)
            field.placeholderString = NSLocalizedString(
                "Prompt for focused agent…",
                comment: "Composer text field placeholder"
            )
        case "idle":
            primaryButton.title = NSLocalizedString("Send now", comment: "Composer button: send the prompt immediately")
            queueMenuButton.title = NSLocalizedString(
                "Queue ▾",
                comment: "Composer button: opens queue-only delivery options"
            )
            field.placeholderString = NSLocalizedString(
                "Prompt for focused agent…",
                comment: "Composer text field placeholder"
            )
        case .none:
            // No agent selected: nothing can ever send, so the whole
            // composer is inert — not just the buttons. The buttons hide
            // entirely: two disabled "Send now" controls next to a
            // "select an agent" placeholder invite clicks that would drop.
            primaryButton.isHidden = true
            queueMenuButton.isHidden = true
            primaryButton.isEnabled = false
            queueMenuButton.isEnabled = false
            field.isEnabled = false
            field.placeholderString = NSLocalizedString(
                "Select an agent to prompt it",
                comment: "Composer placeholder when no agent is focused"
            )
        default:
            primaryButton.title = NSLocalizedString("Send now", comment: "Composer button: send the prompt immediately")
            field.placeholderString = NSLocalizedString(
                "Prompt for focused agent…",
                comment: "Composer text field placeholder"
            )
        }
        updateSendEnabled()
    }

    // MARK: actions

    @objc private func primaryClicked() {
        send(policy: primaryPolicy)
    }

    @objc private func menuClicked() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: NSLocalizedString("Send now", comment: "Delivery menu item: send the prompt immediately"),
            action: #selector(sendNowClicked),
            keyEquivalent: ""
        ).target = self
        menu.addItem(withTitle: NSLocalizedString("Queue after current turn",
                                                  comment: "Delivery menu item: queue the prompt behind the running turn"),
                     action: #selector(queueClicked), keyEquivalent: "").target = self
        queueMenuButton.menu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: queueMenuButton.bounds.height), in: queueMenuButton)
    }

    @objc private func sendNowClicked() {
        send(policy: .sendNow)
    }

    @objc private func queueClicked() {
        send(policy: .queueWhenIdle)
    }

    @objc private func ctaClicked() {
        focusRequestHandler?() // Answer in terminal → hand keyboard back
    }

    @objc private func queuedIndicatorClicked() {
        onCancelQueued?()
    }

    /// Explicit user-initiated retry of the surfaced unconfirmed delivery:
    /// replays the SAME commandID, so stage-9 idempotency makes a duplicate
    /// delivery impossible even if the first attempt actually landed.
    @objc private func retryUnconfirmedClicked() {
        guard case let .agent(id)? = focusedItemProvider?(),
              let sent = lastSentByAgent[id] else { return }
        retryUnconfirmedButton.isHidden = true // one click, one replay
        dispatch(sent.text, policy: sent.policy, commandID: sent.commandID)
    }

    private func send(policy: PromptPolicy) {
        // §5.1 critical: a waitingForInput(terminalOnly) state never gets a
        // composer reply, no matter which button was pressed.
        if configuredLifecycle == "waitingForInput" {
            focusRequestHandler?()
            return
        }
        let textValue = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty-draft sends are disabled in the UI; this is a backstop only.
        guard !textValue.isEmpty else { return }
        dispatch(textValue, policy: policy, commandID: CommandID())
    }

    /// Single dispatch path (button, menu, retry, programmatic). The draft is
    /// cleared ONLY after the seam accepts the prompt, so a rejected send
    /// never loses text; the failure is surfaced inline instead.
    private func dispatch(_ text: String, policy: PromptPolicy, commandID: CommandID) {
        guard let onSend else { return }
        if case let .agent(id)? = focusedItemProvider?() {
            lastSentByAgent[id] = SentPrompt(text: text, policy: policy, commandID: commandID)
        }
        Task { @MainActor in
            await self.handleDispatchOutcome(onSend(text, policy, commandID), sentText: text)
        }
    }

    private func handleDispatchOutcome(_ outcome: PromptSendOutcome, sentText: String) {
        switch outcome {
        case .accepted:
            errorNotice.isHidden = true
            // Clear only when the user has not started a new draft meanwhile.
            if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == sentText {
                field.stringValue = ""
                updateRowHeight()
            }
        case let .failed(reason):
            errorNotice.stringValue = String(
                format: NSLocalizedString(
                    "Couldn't send — %@",
                    comment: "Composer inline send failure; %@ carries the rejection reason"
                ),
                reason
            )
            errorNotice.isHidden = false
        }
        updateSendEnabled()
    }

    /// Send stays disabled while the trimmed draft is empty; the tooltip
    /// explains why it is inert. Queue-menu semantics are untouched.
    private func updateSendEnabled() {
        let hasDraft = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = hasDraft && configuredLifecycle != nil && configuredLifecycle != "waitingForInput"
        primaryButton.isEnabled = canSend && field.isEnabled
        primaryButton.toolTip = canSend ? nil : NSLocalizedString(
            "Type a prompt before sending",
            comment: "Composer tooltip explaining why Send is inert"
        )
    }

    /// Programmatic dispatch path (menu shortcuts, tests). Carries an explicit
    /// commandID so callers control idempotency.
    func sendFocusedPrompt(text: String, policy: PromptPolicy, commandID: CommandID? = nil) {
        // The §5.1 block applies to EVERY dispatch path, programmatic included.
        if configuredLifecycle == "waitingForInput" {
            focusRequestHandler?()
            return
        }
        dispatch(text, policy: policy, commandID: commandID ?? CommandID())
    }

    /// §3.9: a when-ready initial prompt that timed out returns HERE as a
    /// draft — it is never blind-sent. The draft is user-visible text only.
    func restoreDraft(_ text: String) {
        field.stringValue = text
        updateRowHeight()
        updateSendEnabled()
    }

    func focusComposer() {
        window?.makeFirstResponder(field)
    }

    /// ⌘Enter / Composer▸Send Prompt: dispatches with the primary button's
    /// currently visible policy.
    func sendViaPrimaryButton() {
        send(policy: primaryPolicy)
    }

    // MARK: growing row

    override func layout() {
        super.layout()
        updateRowHeight()
    }

    /// A usable minimum width. The window's stack leaves this view hugging
    /// its intrinsic size (~146 pt: the field compressed below its own
    /// required 300 pt, the buttons squeezed to slivers, the row docked to
    /// the trailing corner), and the resulting degenerate internal layout
    /// makes the surrounding constraint system infeasible — the solver then
    /// breaks required constraints at random, including the stack's own
    /// alignment pins and (when anything ties this view's width) the
    /// WINDOW's size. Advertising an intrinsic width that fits every
    /// internal requirement keeps the whole system feasible.
    override var intrinsicContentSize: NSSize {
        NSSize(width: 640, height: NSView.noIntrinsicMetric)
    }

    /// Grows the row with the wrapped draft up to `maxRowLines`; past that the
    /// scrollable field editor takes over. Re-run from layout() so width-driven
    /// re-wraps (window resize, split drag) recompute too.
    private func updateRowHeight() {
        guard let rowHeightConstraint else { return }
        let font = field.font ?? .systemFont(ofSize: 12)
        let singleLine = ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height)
        guard !field.stringValue.isEmpty else {
            rowHeightConstraint.constant = Self.baseRowHeight
            return
        }
        // Wrap at the current field width (the field editor insets ~2pt/side).
        let wrapWidth = max(field.bounds.width - 8, 40)
        let bound = (field.stringValue as NSString).boundingRect(
            with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        )
        let lines = max(1, Int(ceil(bound.height / singleLine)))
        let capped = min(lines, Self.maxRowLines)
        rowHeightConstraint.constant = Self.baseRowHeight + singleLine * CGFloat(capped - 1)
    }
}

extension PromptComposerView: NSTextFieldDelegate {
    func controlTextDidChange(_ _: Notification) {
        // Editing dismisses the stale failure message and re-derives Send.
        errorNotice.isHidden = true
        updateSendEnabled()
        updateRowHeight()
    }

    func controlTextDidEndEditing(_: Notification) {
        // Enter sends with the visible primary policy; Esc handled below.
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift/Option/Ctrl+Enter inserts a real newline into the wrapping
            // field editor; plain Enter and ⌘Enter send with the visible
            // primary policy.
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if flags.contains(.shift) || flags.contains(.option) || flags.contains(.control) {
                return false
            }
            send(policy: primaryPolicy)
            return true
        case #selector(NSResponder.cancelOperation(_:)): // Esc → focus terminal (§3.13)
            focusRequestHandler?()
            return true
        default:
            return false
        }
    }
}

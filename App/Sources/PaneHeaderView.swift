import AgentCore
import AppKit

// Minimal pane header (§3.13): name / lifecycle / cwd / park (close-view) /
// contextual actions. Park NEVER signals the process.

@MainActor
final class PaneHeaderView: NSView {
    /// Contextual lifecycle action phase (§3.13): working → interrupt,
    /// stopped/failed → resume. Keyed by phase, not display string, so
    /// localization can never break the tooltip mapping.
    enum ContextualAction {
        case interrupt
        case resume
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let cwdLabel = NSTextField(labelWithString: "")
    /// Contextual lifecycle action (§3.13): working → Interrupt,
    /// stopped/failed → Resume. Routed through RuntimeSeam paths.
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let parkButton = NSButton(
        title: NSLocalizedString("Close view",
                                 comment: "Pane header button: park the surface without stopping the process"),
        target: nil,
        action: nil
    )

    var onPark: (() -> Void)?
    var onContextualAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .boldSystemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateLabel.font = .systemFont(ofSize: 10)
        stateLabel.textColor = .secondaryLabelColor

        cwdLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        cwdLabel.textColor = .tertiaryLabelColor
        cwdLabel.lineBreakMode = .byTruncatingMiddle
        cwdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.bezelStyle = .inline
        actionButton.controlSize = .mini
        actionButton.font = .systemFont(ofSize: 9)
        actionButton.setButtonType(.momentaryPushIn)
        actionButton.target = self
        actionButton.action = #selector(contextualActionClicked)
        actionButton.setAccessibilityLabel(NSLocalizedString(
            "Contextual agent action",
            comment: "Accessibility label for the contextual lifecycle action button"
        ))
        parkButton.setAccessibilityLabel(NSLocalizedString(
            "Close view",
            comment: "Accessibility label for the park button"
        ))
        actionButton.isHidden = true

        parkButton.bezelStyle = .inline
        parkButton.controlSize = .mini
        parkButton.font = .systemFont(ofSize: 9)
        parkButton.setButtonType(.momentaryPushIn)
        parkButton.target = self
        parkButton.action = #selector(parkClicked)
        parkButton.toolTip = NSLocalizedString(
            "Closes this view; the process keeps running.",
            comment: "Tooltip for the park (close view) button"
        )

        let stack = NSStackView(views: [titleLabel, stateLabel, NSStackView(), cwdLabel, actionButton, parkButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.4).cgColor

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    /// Last applied content: the model fan-out refreshes every pane header
    /// on every delta, so identical updates are a no-op (no label writes,
    /// no accessibility re-formatting).
    private var applied: (title: String, state: String, cwd: String)?

    func update(title: String, state: String, cwd: String?) {
        let cwdText = cwd ?? ""
        if let applied, applied.title == title, applied.state == state, applied.cwd == cwdText {
            return
        }
        applied = (title, state, cwdText)
        titleLabel.stringValue = title
        stateLabel.stringValue = state
        cwdLabel.stringValue = cwdText
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let cwdSuffix = cwd.map { String(
            format: NSLocalizedString(", %@", comment: "Pane header accessibility label: cwd suffix"),
            $0
        ) } ?? ""
        setAccessibilityLabel(String(
            format: NSLocalizedString("Pane: %1$@, %2$@%3$@",
                                      comment: "Pane header accessibility label: title, state, optional cwd"),
            title,
            state,
            cwdSuffix
        ))
        setAccessibilityIdentifier("pane.header")
    }

    /// Contextual action (§3.13): `nil` hides the button; a phase shows it
    /// with its localized title.
    func setContextualAction(_ action: ContextualAction?) {
        switch action {
        case .interrupt:
            actionButton.title = NSLocalizedString(
                "Interrupt",
                comment: "Pane header button: interrupt the working agent"
            )
            actionButton.isHidden = false
        case .resume:
            actionButton.title = NSLocalizedString(
                "Resume",
                comment: "Pane header button: resume a stopped or failed agent"
            )
            actionButton.isHidden = false
        case nil:
            actionButton.title = ""
            actionButton.isHidden = true
        }
        actionButton.toolTip = Self.contextualToolTip(for: action)
    }

    func setActionsEnabled(_ enabled: Bool) {
        parkButton.isEnabled = enabled
        actionButton.isEnabled = enabled
    }

    /// Lifecycle-dependent tooltip, keyed off the action phase (§3.13).
    private static func contextualToolTip(for action: ContextualAction?) -> String? {
        switch action {
        case .interrupt:
            NSLocalizedString(
                "Stop the agent's current work",
                comment: "Tooltip for the Interrupt action"
            )
        case .resume:
            NSLocalizedString(
                "Start this stopped agent again",
                comment: "Tooltip for the Resume action"
            )
        case nil:
            nil
        }
    }

    @objc private func contextualActionClicked() {
        onContextualAction?()
    }

    @objc private func parkClicked() {
        onPark?()
    }
}

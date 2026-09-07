import AppKit

// Persistent banner slot for degraded states (§4.6): store/integration
// degradation surfaces here and stays until cleared.

@MainActor
final class PersistentBannerView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: NSLocalizedString(
                                 "Degraded",
                                 comment: "Banner icon accessibility label: a degradation is active"
                             ))
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("unsupported")
    }

    func set(message: String?) {
        // Sits on the per-delta refresh fan-out; identical writes still
        // invalidate the label, so skip redundant passes.
        let text = message ?? ""
        if label.stringValue != text {
            label.stringValue = text
            // The 24pt banner truncates long degradation text; hover must
            // still reveal the full message.
            toolTip = text.isEmpty ? nil : text
        }
        let hidden = (message == nil)
        if isHidden != hidden {
            isHidden = hidden
        }
    }
}

import Foundation

// Safe reply semantics for input requests (architecture §3.4).
//
// Safety rules:
// - screen manifests default to `terminalOnly`;
// - composer is allowed ONLY for `freeText` + `composerAllowed`;
// - approval/selection prompts are never answered automatically;
// - queued prompts are never delivered while the agent waits for terminal input;
// - lifecycle `unknown` never triggers automatic delivery.

public enum InputRequestKind: Equatable, Sendable, Codable {
    case freeText
    case approval
    case selection
    case unknown
}

public enum SafeReplyMode: Equatable, Sendable, Codable {
    case composerAllowed
    case terminalOnly
}

public struct InputRequestDescriptor: Equatable, Sendable, Codable {
    public let kind: InputRequestKind
    public let summary: String?
    public let safeReplyMode: SafeReplyMode
    public let source: EvidenceSource

    public init(
        kind: InputRequestKind,
        summary: String? = nil,
        safeReplyMode: SafeReplyMode = .terminalOnly,
        source: EvidenceSource
    ) {
        self.kind = kind
        self.summary = summary
        self.safeReplyMode = safeReplyMode
        self.source = source
    }

    /// Screen-sourced request descriptors always default to `terminalOnly`.
    public static func screenSourced(kind: InputRequestKind, summary: String?) -> InputRequestDescriptor {
        InputRequestDescriptor(kind: kind, summary: summary, safeReplyMode: .terminalOnly, source: .screen)
    }

    /// The composer may be used only when this returns true (§3.4 safety rules).
    public var composerPermitted: Bool {
        safeReplyMode == .composerAllowed && kind == .freeText
    }
}

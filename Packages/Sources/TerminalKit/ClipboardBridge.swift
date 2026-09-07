import AppKit
import GhosttyBridge

// Clipboard policy bridge (architecture §3.20): terminal-initiated clipboard
// access is policy-gated. Writes to the standard pasteboard are allowed;
// programmatic reads (OSC 52) and the selection clipboard are denied by
// default. The synchronous read-policy value is captured by the callback
// router so it can be evaluated on any thread without an actor hop.

public enum ClipboardKind: Int32, Sendable {
    case standard = 0
    case selection = 1
}

public enum ClipboardRequestKind: Int32, Sendable {
    case paste = 0
    case osc52Read = 1
    case osc52Write = 2
}

@MainActor public final class ClipboardBridge {
    public struct Policy: Sendable, Equatable {
        /// Allow the child to READ the pasteboard programmatically (OSC 52
        /// read / paste request). Off by default: clipboard reads can exfiltrate.
        public var allowProgrammaticRead = false
        /// Allow the child to WRITE the pasteboard (OSC 52 write).
        public var allowProgrammaticWrite = true
        /// Mirror writes into the (X11-style) selection clipboard.
        public var allowSelectionClipboard = false

        public init(
            allowProgrammaticRead: Bool = false,
            allowProgrammaticWrite: Bool = true,
            allowSelectionClipboard: Bool = false
        ) {
            self.allowProgrammaticRead = allowProgrammaticRead
            self.allowProgrammaticWrite = allowProgrammaticWrite
            self.allowSelectionClipboard = allowSelectionClipboard
        }
    }

    public let policy: Policy

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Immutable snapshot evaluated by the callback router on any thread.
    public var readPolicyClosure: @Sendable (ClipboardKind) -> Bool {
        let allowRead = policy.allowProgrammaticRead
        let allowSelection = policy.allowSelectionClipboard
        return { kind in
            guard allowRead else { return false }
            return kind == .standard || (kind == .selection && allowSelection)
        }
    }

    func shouldAllowRead(kind: ClipboardKind) -> Bool {
        readPolicyClosure(kind)
    }

    /// Child wrote clipboard content (OSC 52 or copy). Applies the policy and
    /// mirrors onto NSPasteboard when permitted.
    public func write(kind: ClipboardKind?, mime: String?, data: String?) {
        guard let kind,
              policy.allowProgrammaticWrite,
              kind != .selection || policy.allowSelectionClipboard else { return }
        // MVP accepts plain text payloads only. A nil mime counts as text
        // (pinned by TerminalMountCoordinatorTests' DropNilPayloads law):
        // libghostty's own copy path always tags an explicit text/plain
        // mime, so nil means "unspecified legacy sender", not foreign
        // content — rejecting it would break the accepted write path.
        if let mime, mime != "text/plain;charset=utf-8", mime != "text/plain" {
            return
        }
        guard let data else { return }
        let pasteboard = kind == .selection
            ? NSPasteboard(name: .init("org.agentterminal.selection"))
            : NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(data, forType: .string)
    }

    /// Confirmation prompt for a clipboard read. Default policy denies; this
    /// hook is where a user-facing consent dialog would complete the request
    /// via `ghostty_surface_complete_clipboard_request` in later stages.
    public func confirmRead(prompt _: String?, request _: ClipboardRequestKind?) {
        // Deny silently at MVP: no consent UI exists yet (§3.19 degraded mode).
    }
}

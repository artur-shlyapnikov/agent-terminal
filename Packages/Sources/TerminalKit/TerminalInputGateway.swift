import Foundation
import GhosttyBridge

// Text/key delivery (architecture §3.11): prompt text goes through the
// bracketed-paste-compatible path so multi-line prompts are delivered as a
// single paste (no line-by-line auto-execution), with an explicit Return when
// submission is requested. `sendKeys` delivers hardware-style key pairs.

@MainActor public struct TerminalInputGateway {
    /// Bracketed paste is on by default: modern shells/agents enable it and it
    /// makes multi-line prompts safe. Turn off only for programs that break on
    /// the escape sequences.
    public var bracketedPaste: Bool

    private let target: any NativeTerminalSurface

    public init(target: any NativeTerminalSurface, bracketedPaste: Bool = true) {
        self.target = target
        self.bracketedPaste = bracketedPaste
    }

    /// Delivers `text` via the paste-safe path; appends Return when `submit`.
    public func sendPrompt(_ text: String, submit: Bool) {
        if text.isEmpty {
            // Nothing to paste; still honor explicit submit.
        } else if bracketedPaste {
            target.sendText("\u{1B}[200~" + Self.sanitizedPastePayload(text) + "\u{1B}[201~")
        } else {
            target.sendText(text)
        }
        if submit {
            sendReturn()
        }
    }

    private static let pasteStart = "\u{1B}[200~"
    private static let pasteEnd = "\u{1B}[201~"

    /// Strips bracketed-paste markers so embedded `\u{1B}[201~` in pasted
    /// content cannot terminate the paste early (architecture §3.11).
    private static func sanitizedPastePayload(_ text: String) -> String {
        text
            .replacingOccurrences(of: pasteStart, with: "")
            .replacingOccurrences(of: pasteEnd, with: "")
    }

    /// Return key as a hardware key event (\r encoded).
    public func sendReturn() {
        var press = GhosttyKeyEvent(action: .press, keycode: 0x24)
        press.text = "\r"
        press.unshiftedCodepoint = 0x0D
        _ = target.sendKey(press)
        var release = press
        release.action = .release
        release.text = nil
        _ = target.sendKey(release)
    }

    /// Delivers named keys ("ctrl+c", "enter", "up", …) as press/release
    /// pairs. Unknown names are skipped; the returned array reports which
    /// names were actually delivered.
    @discardableResult
    public func sendKeys(_ names: [String]) -> [String] {
        var delivered: [String] = []
        for name in names {
            let pair = InputTranslator.namedKeyPair(name)
            guard pair.count == 2 else { continue }
            _ = target.sendKey(pair[0])
            _ = target.sendKey(pair[1])
            delivered.append(name)
        }
        return delivered
    }
}

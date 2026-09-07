import AppKit
import GhosttyBridge

// NSEvent → ghostty key-event translation (architecture §4.3).
//
// libghostty on macOS expects macOS virtual keycodes plus UTF-8 text (spike
// finding 4); press and release are delivered as separate events, and the
// text pointer must be pinned for the call duration (handled by the surface
// handle). Modifier translation maps NSEvent.ModifierFlags onto AGTMods bits.

enum InputTranslator {
    static func modifiers(_ event: NSEvent) -> KeyModifiers {
        var result: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) {
            result.insert(.shift)
        }
        if flags.contains(.control) {
            result.insert(.control)
        }
        if flags.contains(.option) {
            result.insert(.option)
        }
        if flags.contains(.command) {
            result.insert(.command)
        }
        if flags.contains(.capsLock) {
            result.insert(.capsLock)
        }
        if flags.contains(.numericPad) {
            result.insert(.numericPad)
        }
        return result
    }

    /// Translates a keyDown/keyUp into a bridge key event; nil when the event
    /// carries no keycode.
    static func translate(_ event: NSEvent, action: KeyEventAction) -> GhosttyKeyEvent? {
        guard event.type == .keyDown || event.type == .keyUp else {
            return nil
        }
        // Only presses deliver fresh UTF-8 text/codepoint; autorepeat
        // (.repeatKey) carries no text and unshiftedCodepoint 0, keycode and
        // modifiers still pass through.
        let text = action == .press ? event.characters : nil
        let codepoint = action == .press
            ? UInt32(event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0)
            : 0
        return GhosttyKeyEvent(
            action: action,
            modifiers: modifiers(event),
            consumedModifiers: [],
            keycode: UInt32(event.keyCode),
            text: text,
            unshiftedCodepoint: codepoint,
            composing: false
        )
    }

    /// macOS virtual keycodes (kVK_ANSI_* values).
    private static let namedKeys: [String: UInt32] = [
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "escape": 0x35, "esc": 0x35,
        "delete": 0x33, "backspace": 0x33,
        "forwarddelete": 0x75,
        "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
        "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pagedown": 0x79,
        // Letters.
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        // Digits row + punctuation.
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
        "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
        "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E,
        ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C,
        "\\": 0x2A, "`": 0x32,
    ]

    static func namedKey(_ name: String) -> GhosttyKeyEvent? {
        let lowered = name.lowercased()
        guard !lowered.isEmpty else { return nil }
        var modifiers: KeyModifiers = []
        // Split on "+" rejecting empty segments: "ctrl+", "+t", and "cmd++"
        // are all malformed (no literal-plus convention).
        let parts = lowered.split(separator: "+", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains("") else { return nil }
        let base = String(parts.last!)
        for token in parts.dropLast() {
            switch token {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "cmd", "super": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }

        guard let keycode = namedKeys[base] else {
            return nil // unknown names are rejected; callers fall back to text
        }
        return GhosttyKeyEvent(
            action: .press,
            modifiers: modifiers,
            keycode: keycode
        )
    }

    /// Press+release pair for a named key.
    static func namedKeyPair(_ name: String) -> [GhosttyKeyEvent] {
        guard let press = namedKey(name) else { return [] }
        var release = press
        release.action = .release
        release.text = nil
        release.unshiftedCodepoint = 0
        return [press, release]
    }
}

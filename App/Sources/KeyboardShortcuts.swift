import AppKit
import Foundation

// §3.13 keyboard law: ONE catalog of registered app shortcuts drives menu
// construction AND the Settings shortcut sheet AND conflict detection.
// The app intercepts ONLY these; everything else falls through to ghostty.

struct AppShortcut: Equatable, Identifiable {
    let id: String // stable identifier (settings/conflict reports)
    let title: String
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    /// Human-readable rendering ("⌘⇧P") for Settings/palette rows.
    var displayText: String {
        var text = ""
        if modifiers.contains(.command) {
            text += "⌘"
        }
        if modifiers.contains(.shift) {
            text += "⇧"
        }
        if modifiers.contains(.option) {
            text += "⌥"
        }
        if modifiers.contains(.control) {
            text += "⌃"
        }
        // Special equivalents render as symbols; plain keys keep uppercasing.
        switch keyEquivalent {
        case "\r": return text + "⏎"
        case "\u{1b}": return text + "⎋"
        case " ": return text + "␣"
        default: return text + keyEquivalent.uppercased()
        }
    }
}

extension AppShortcut {
    /// The §3.13 registered shortcut table. Order matches the architecture doc.
    static let registered: [AppShortcut] = [
        .init(id: "new-agent", title: "New Agent", keyEquivalent: "n", modifiers: .command),
        .init(id: "focus-composer", title: "Focus Prompt Composer", keyEquivalent: "l", modifiers: .command),
        .init(id: "split-right", title: "Split Right", keyEquivalent: "d", modifiers: .command),
        .init(id: "split-down", title: "Split Down", keyEquivalent: "d", modifiers: [.command, .shift]),
        .init(id: "next-attention", title: "Next Attention", keyEquivalent: "u", modifiers: [.command, .shift]),
        .init(id: "palette", title: "Command Palette", keyEquivalent: "p", modifiers: [.command, .shift]),
        .init(id: "inspector", title: "Toggle Inspector", keyEquivalent: "i", modifiers: .command),
        .init(id: "sidebar", title: "Toggle Sidebar", keyEquivalent: "b", modifiers: .command),
        .init(id: "send-prompt", title: "Send Prompt", keyEquivalent: "\r", modifiers: .command),
        .init(id: "interrupt", title: "Interrupt", keyEquivalent: ".", modifiers: .command),
        .init(id: "open-settings", title: "Settings", keyEquivalent: ",", modifiers: .command),
        .init(id: "close-view", title: "Close View", keyEquivalent: "w", modifiers: .command),
    ]
}

/// Pure conflict detection (§3.13: "Settings обнаруживает конфликты при
/// remap"). MVP ships read-only detection: two registered shortcuts that bind
/// the SAME key+modifier combination are reported as a conflict pair.
enum ShortcutConflictDetector {
    struct Conflict: Equatable {
        let first: AppShortcut
        let second: AppShortcut
    }

    static func conflicts(in shortcuts: [AppShortcut]) -> [Conflict] {
        var seen: [String: AppShortcut] = [:]
        var result: [Conflict] = []
        for shortcut in shortcuts {
            let combo = comboKey(shortcut)
            if let previous = seen[combo] {
                result.append(.init(first: previous, second: shortcut))
            } else {
                seen[combo] = shortcut
            }
        }
        return result
    }

    static func comboKey(_ shortcut: AppShortcut) -> String {
        // Normalize modifier ORDER so ⇧⌘D == ⌘⇧D.
        let flags = shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
        let parts = [
            flags.contains(.command) ? "cmd" : "",
            flags.contains(.shift) ? "shift" : "",
            flags.contains(.option) ? "opt" : "",
            flags.contains(.control) ? "ctrl" : "",
        ].filter { !$0.isEmpty }
        return parts.joined(separator: "+") + "|" + shortcut.keyEquivalent.lowercased()
    }

    static func describe(_ conflict: Conflict) -> String {
        "\(conflict.first.title) and \(conflict.second.title) both use \(conflict.first.displayText)"
    }
}

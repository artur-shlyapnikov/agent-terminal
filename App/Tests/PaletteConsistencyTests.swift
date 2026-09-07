@testable import AgentTerminal
import XCTest

// §3.13 palette/shortcut coupling: the palette looks each row's shortcut hint
// up with `AppShortcut.registered.first { $0.title == title }` — an EXACT
// title match. If a registered shortcut's title drifts from the palette
// catalog, the hint silently vanishes with no error anywhere. Pin the
// invariant: every registered shortcut (except the deliberate "Command
// Palette" self-exclusion) must resolve in the catalog.

@MainActor
final class PaletteConsistencyTests: XCTestCase {
    func testEveryRegisteredShortcutTitleResolvesInPalette() {
        let paletteTitles = Set(AppCommands.paletteCatalog.map(\.title))
        for shortcut in AppShortcut.registered where shortcut.id != "palette" {
            XCTAssertTrue(
                paletteTitles.contains(shortcut.title),
                "registered shortcut '\(shortcut.title)' (\(shortcut.id)) has no palette entry — its hint would silently vanish"
            )
        }
    }
}

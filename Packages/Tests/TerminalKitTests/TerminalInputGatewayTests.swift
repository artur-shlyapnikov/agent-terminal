import AppKit
@testable import TerminalKit
import XCTest

// Input gateway (§3.11): bracketed-paste prompt delivery, Return submission,
// named-key translation — all against a recording fake surface.

@MainActor final class TerminalInputGatewayTests: XCTestCase {
    func testPromptWrappedInBracketedPasteAndSubmitted() {
        let fake = FakeNativeSurface()
        let gateway = TerminalInputGateway(target: fake, bracketedPaste: true)

        gateway.sendPrompt("echo hi", submit: true)

        XCTAssertEqual(fake.lastText, "\u{1B}[200~echo hi\u{1B}[201~")
        let keyCalls = fake.calls.filter { $0.kind == "sendKey" }
        XCTAssertEqual(keyCalls.count, 2, "Return press + release")
        XCTAssertTrue(keyCalls.contains { $0.detail.contains("action=press") && $0.detail.contains("code=36") })
        XCTAssertTrue(keyCalls.contains { $0.detail.contains("action=release") && $0.detail.contains("code=36") })
    }

    func testPlainModeWhenBracketedPasteDisabled() {
        let fake = FakeNativeSurface()
        let gateway = TerminalInputGateway(target: fake, bracketedPaste: false)

        gateway.sendPrompt("plain", submit: false)
        XCTAssertEqual(fake.lastText, "plain")
        XCTAssertFalse(fake.calls.contains { $0.kind == "sendKey" })
    }

    func testNamedKeysDeliveredAsPressReleasePairs() {
        let fake = FakeNativeSurface()
        let gateway = TerminalInputGateway(target: fake)

        let delivered = gateway.sendKeys(["ctrl+c", "up", "not-a-key"])

        XCTAssertEqual(delivered, ["ctrl+c", "up"])
        let keyEvents = fake.calls.filter { $0.kind == "sendKey" }
        // ctrl+c press/release + up press/release.
        XCTAssertEqual(keyEvents.count, 4)
        XCTAssertTrue(keyEvents[0].detail.contains("code=8")) // c keycode 0x08
        XCTAssertTrue(keyEvents[1].detail.contains("code=8"))
        XCTAssertTrue(keyEvents[2].detail.contains("code=126")) // up 0x7E
    }

    func testEmptySubmitStillSendsReturnOnly() {
        let fake = FakeNativeSurface()
        let gateway = TerminalInputGateway(target: fake)
        gateway.sendPrompt("", submit: true)
        XCTAssertNil(fake.lastText)
        XCTAssertEqual(fake.calls.filter { $0.kind == "sendKey" }.count, 2)
    }

    func testTranslatorModifierParsing() {
        let key = InputTranslator.namedKey("cmd+shift+t")
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.keycode, 0x11) // t
        XCTAssertTrue(key?.modifiers.contains(.command) ?? false)
        XCTAssertTrue(key?.modifiers.contains(.shift) ?? false)

        let pair = InputTranslator.namedKeyPair("ctrl+a")
        // Press half: 'a' is kVK_ANSI_A (0x00), press action.
        XCTAssertEqual(pair[0].keycode, 0x00)
        // Release half: production pins action .release, no text, no codepoint.
        XCTAssertEqual(pair[1].action, .release)
        XCTAssertNil(pair[1].text)
        XCTAssertEqual(pair[1].keycode, 0x00)
        XCTAssertEqual(pair[1].unshiftedCodepoint, 0)
    }

    /// R11-D: the mapping contract GhosttySurfaceView's `isARepeat`
    /// ternary relies on — `.repeatKey` must NOT look like a press (no
    /// fresh text, no codepoint) or a release downstream, while keycode
    /// and modifiers pass through verbatim. The `.press` control on the
    /// SAME fabricated event proves the divergence is the action
    /// parameter, not event-fabrication artifacts.
    func testTranslateRepeatKeyDeliversRepeatActionWithoutTextOrCodepoint() throws {
        let fabricated = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 0x11 // 't'
        ))

        let repeatEvent = try XCTUnwrap(
            InputTranslator.translate(fabricated, action: .repeatKey)
        )
        XCTAssertEqual(repeatEvent.action, .repeatKey)
        XCTAssertNil(repeatEvent.text, "autorepeats carry no fresh text")
        XCTAssertEqual(repeatEvent.unshiftedCodepoint, 0)
        XCTAssertEqual(repeatEvent.keycode, UInt32(fabricated.keyCode))
        XCTAssertTrue(repeatEvent.modifiers.contains(.option))

        let press = try XCTUnwrap(
            InputTranslator.translate(fabricated, action: .press)
        )
        XCTAssertEqual(press.action, .press)
        XCTAssertEqual(press.text, "t")
        XCTAssertEqual(press.unshiftedCodepoint, UInt32(("t" as Unicode.Scalar).value))
    }

    /// R12-D: the release leg takes the ELSE arms of BOTH action-gated
    /// ternaries — a keyUp translated with `.release` carries NO text and NO
    /// codepoint (libghostty would treat it as a phantom press and double-
    /// insert characters), while keycode and modifiers pass through verbatim.
    func testTranslateKeyUpReleaseCarriesNoTextOrCodepointButPreservesKeycodeAndModifiers() throws {
        let fabricated = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.option, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false, // inert for keyUp fabrication
            keyCode: 0x11 // 't'
        ))

        let release = try XCTUnwrap(
            InputTranslator.translate(fabricated, action: .release)
        )
        XCTAssertEqual(release.action, .release)
        XCTAssertNil(release.text, "releases must carry no text")
        XCTAssertEqual(release.unshiftedCodepoint, 0, "releases must carry no codepoint")
        XCTAssertFalse(release.composing)
        XCTAssertEqual(release.keycode, UInt32(fabricated.keyCode), "keycode preserved verbatim")
        XCTAssertTrue(release.modifiers.contains(.option), "modifiers walk must survive the release leg")
        XCTAssertTrue(release.modifiers.contains(.command))
    }

    /// R13-D3: namedKeyPair's derivation law — release shares keycode and
    /// modifiers with the press but carries `.release`, NO text, NO
    /// unshiftedCodepoint (a phantom press per keystroke otherwise). Also
    /// pins the direct parser rejection table: the legacy probe ASSIGNED
    /// `.release` to `namedKeyPair(...)[1]` and then asserted it —
    /// tautological; the actual derivation was unpinned.
    func testNamedKeyPairDerivesReleaseVerbatimAndParserRejectsMalformedNames() throws {
        let pair = InputTranslator.namedKeyPair("ctrl+a")
        XCTAssertEqual(pair.count, 2)
        let press = try XCTUnwrap(pair.first)
        let release = try XCTUnwrap(pair.last)
        XCTAssertEqual(press.action, .press)
        XCTAssertEqual(release.action, .release)
        XCTAssertEqual(press.keycode, 0x00) // 'a'
        XCTAssertEqual(release.keycode, 0x00, "keycode shared verbatim across the pair")
        XCTAssertTrue(press.modifiers.contains(.control))
        XCTAssertTrue(release.modifiers.contains(.control), "modifiers shared verbatim")
        XCTAssertNil(press.text, "the named-key path never attaches text")
        XCTAssertNil(release.text, "release carries no text")
        XCTAssertEqual(release.unshiftedCodepoint, 0, "release carries no codepoint")

        // Positive casing control: whole-name case-insensitivity via lowercased().
        let cased = try XCTUnwrap(InputTranslator.namedKey("Cmd+Shift+T"))
        XCTAssertEqual(cased.keycode, 0x11) // 't'
        XCTAssertTrue(cased.modifiers.contains(.command))
        XCTAssertTrue(cased.modifiers.contains(.shift))

        // Parser rejections: unknown modifier token, empty base after '+',
        // unknown key name.
        XCTAssertNil(InputTranslator.namedKey("bogus+t"), "unknown modifier token must reject")
        XCTAssertNil(InputTranslator.namedKey("ctrl+"), "empty base after '+' must reject")
        XCTAssertNil(InputTranslator.namedKey("not-a-key"), "unknown key name must reject")
    }

    /// R13-D4: the type guard admits ONLY .keyDown/.keyUp. R12-D2's optional
    /// `.flagsChanged` secondary was dropped because NSEvent.keyEvent(with:)
    /// cannot fabricate it — but NSEvent.otherEvent(with:) constructs a REAL
    /// event of type .applicationDefined, exercising the same guard with
    /// zero fabrication hacks.
    func testTranslateRejectsNonKeyEventTypesWithoutFabrication() throws {
        let other = try XCTUnwrap(NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ))
        XCTAssertNotEqual(other.type, .keyDown)
        XCTAssertNotEqual(other.type, .keyUp)
        XCTAssertNil(
            InputTranslator.translate(other, action: .press),
            "non-key events must never reach the bridge as garbage key input"
        )
        XCTAssertNil(InputTranslator.translate(other, action: .release))
    }

    /// R20-IT1: complement to R13-D3's rejection table — the remaining
    /// malformed shapes (leading '+', doubled '++', empty whole), alias
    /// pairs resolving to the SAME keycode, and total case-folding
    /// equality. A refactor to default `split(separator:)` omission would
    /// silently accept "ctrl+" as bare ctrl (stuck-modifier chords).
    func testNamedKeyMalformedChordVariantsAliasesAndCaseFolding() {
        // Malformed chords the empty-segment guard must reject.
        XCTAssertNil(InputTranslator.namedKey("+t"), "leading '+' leaves an empty segment")
        XCTAssertNil(InputTranslator.namedKey("cmd++"), "'++' yields an empty middle segment")
        XCTAssertNil(InputTranslator.namedKey(""), "the empty chord rejects outright")
        XCTAssertNil(InputTranslator.namedKey("f9x"), "unknown base names reject")

        // A rejected name yields an EMPTY pair — never a phantom press/release.
        XCTAssertTrue(InputTranslator.namedKeyPair("cmd++").isEmpty)

        // Alias pairs resolve to identical keycodes.
        XCTAssertEqual(InputTranslator.namedKey("return")?.keycode, 0x24)
        XCTAssertEqual(InputTranslator.namedKey("enter")?.keycode, 0x24)
        XCTAssertEqual(InputTranslator.namedKey("esc")?.keycode, 0x35)
        XCTAssertEqual(InputTranslator.namedKey("escape")?.keycode, 0x35)
        XCTAssertEqual(InputTranslator.namedKey("delete")?.keycode, 0x33)
        XCTAssertEqual(InputTranslator.namedKey("backspace")?.keycode, 0x33)

        // Case-folding is total: both casings parse field-for-field equal.
        let upper = InputTranslator.namedKey("CMD+SHIFT+T")
        let lower = InputTranslator.namedKey("cmd+shift+t")
        XCTAssertEqual(upper?.keycode, lower?.keycode)
        XCTAssertEqual(upper?.modifiers, lower?.modifiers)
        XCTAssertEqual(upper?.action, lower?.action)
    }
}

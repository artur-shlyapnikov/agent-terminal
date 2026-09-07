import AgentCore
@testable import AgentTerminal
import XCTest

// Stage-15 operator polish (§3.13/§3.22/§4.6): pure-rule coverage for the
// shortcut conflict detector, the diagnostic redaction/redaction-rendering,
// the §3.13 palette command catalog and the New Agent sheet model validation.
// These run against the INERT test host — no engine, no runtime.

@MainActor
final class Stage15PolishTests: XCTestCase {
    // MARK: - §3.13 shortcut conflict detection

    func testConflictDetectorFindsDuplicateKeyCombination() {
        let a = AppShortcut(id: "a", title: "A", keyEquivalent: "d", modifiers: .command)
        let b = AppShortcut(id: "b", title: "B", keyEquivalent: "d", modifiers: [.shift, .command])
        let c = AppShortcut(id: "c", title: "C", keyEquivalent: "d", modifiers: .command)
        let conflicts = ShortcutConflictDetector.conflicts(in: [a, b, c])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.first.id, "a")
        XCTAssertEqual(conflicts.first?.second.id, "c")
    }

    func testRegisteredShortcutsHaveNoConflicts() {
        XCTAssertTrue(ShortcutConflictDetector.conflicts(in: AppShortcut.registered).isEmpty,
                      "the shipped §3.13 table must be conflict-free")
    }

    func testRegisteredTableCoversArchitectureKeyboardLaw() {
        let ids = Set(AppShortcut.registered.map(\.id))
        for required in ["new-agent", "focus-composer", "split-right", "split-down",
                         "next-attention", "palette", "inspector", "sidebar",
                         "send-prompt", "interrupt", "open-settings", "close-view"]
        {
            XCTAssertTrue(ids.contains(required), "missing §3.13 shortcut \(required)")
        }
        // ⌘N MUST be live (stage-6 gap closure).
        XCTAssertEqual(AppShortcut.registered.first { $0.id == "new-agent" }?.keyEquivalent, "n")
    }

    // MARK: - Round 14 D2: displayText symbol law (89af72d \r → ⏎ fix)

    func testShortcutDisplayTextRendersSymbolsAndReturnAsEnterGlyph() {
        // THE regression: "\r" must render as the return glyph, not a
        // control-character glyph in menus/settings.
        let send = AppShortcut(id: "send", title: "", keyEquivalent: "\r", modifiers: .command)
        XCTAssertEqual(send.displayText, "⌘⏎")

        // Modifier order is fixed ⌘⇧⌥⌃ regardless of Set iteration order.
        XCTAssertEqual(
            AppShortcut(id: "d", title: "", keyEquivalent: "d", modifiers: [.command, .shift]).displayText,
            "⌘⇧D"
        )

        // Special-equivalent symbols.
        XCTAssertEqual(
            AppShortcut(id: "esc", title: "", keyEquivalent: "\u{1b}", modifiers: .control).displayText,
            "⌃⎋"
        )
        XCTAssertEqual(
            AppShortcut(id: "space", title: "", keyEquivalent: " ", modifiers: .option).displayText,
            "⌥␣"
        )

        // Plain keys uppercase.
        XCTAssertEqual(
            AppShortcut(id: "n", title: "", keyEquivalent: "n", modifiers: []).displayText,
            "N"
        )

        // The real §3.13 row carries the fixed rendering.
        XCTAssertEqual(AppShortcut.registered.first { $0.id == "send-prompt" }?.displayText, "⌘⏎")
    }

    // MARK: - §3.13 command palette completeness

    func testPaletteCoversSection313CommandList() {
        let titles = AppCommands.paletteCatalog.map(\.title)
        for required in ["New Agent", "Next Attention", "Split Right", "Split Down",
                         "Close View", "Interrupt", "Stop Agent", "Restart / Resume",
                         "Toggle Sidebar", "Toggle Inspector",
                         "Install / Repair Integration", "Open Workspace",
                         "Export Diagnostics"]
        {
            XCTAssertTrue(titles.contains(required), "palette missing §3.13 entry \(required)")
        }
    }

    // MARK: - §6.6 gate copy

    func testMissingExecutableMessageIsActionable() {
        let message = AgentExecutionCoordinator.missingExecutableMessage(for: .claudeCode)
        XCTAssertTrue(message.contains("not found"))
        XCTAssertTrue(message.lowercased().contains("install"),
                      "actionable copy tells the operator how to fix it")
    }

    // MARK: - §3.22 redaction

    func testRedactorScrubsSensitiveEnvAssignments() {
        let line = "launch env ATERM_TOKEN=abc123 HOME=/Users/x PATH=/bin"
        let sanitized = DiagnosticRedactor.sanitize(line)
        XCTAssertFalse(sanitized.contains("abc123"), sanitized)
        XCTAssertTrue(sanitized.contains("ATERM_TOKEN=<redacted>"), sanitized)
        XCTAssertTrue(sanitized.contains("HOME=/Users/x"), "non-sensitive values stay")
    }

    func testRenderDropsPromptAndOutputPayloads() {
        let lines = [
            "turn opened",
            "prompt: meet me at 5pm and bring the report",
            "output: see you then",
            "state→working (screen)",
        ]
        let rendered = DiagnosticRedactor.render(lines: lines)
        XCTAssertTrue(rendered.contains { $0.contains("<redacted>") })
        XCTAssertFalse(rendered.contains { $0.contains("bring the report") })
        XCTAssertFalse(rendered.contains { $0.contains("see you then") })
        XCTAssertTrue(rendered.contains { $0.contains("state→working") },
                      "content-free transition lines survive")
    }

    func testBundleRenderOmitsPromptAndOutputContent() {
        var snapshot = DiagnosticsSnapshot(
            appVersion: "0.1.0 (1)",
            ghosttyDescription: "vendored libghostty",
            bridgeABIVersion: 1,
            adapters: [],
            manifestHashes: ["claude-code": "deadbeef"],
            schemaVersion: "agentstore-v1",
            fingerprints: [],
            agents: [],
            timelineLines: [:],
            logLines: ["PROMPT=super-secret-text", "normal line"]
        )
        snapshot.timelineLines = [:]

        let text = DiagnosticBundleBuilder.render(snapshot)

        // Required §3.22 sections present.
        XCTAssertTrue(text.contains("app: 0.1.0 (1)"))
        XCTAssertTrue(text.contains("vendored libghostty"))
        XCTAssertTrue(text.contains("claude-code: deadbeef"))
        XCTAssertTrue(text.contains("schema version: agentstore-v1"))

        // DoD #14: prompt/env/output strings absent.
        XCTAssertFalse(text.contains("super-secret-text"))
        XCTAssertTrue(text.contains("PROMPT=<redacted>"))
    }

    // MARK: - §4.6 New Agent sheet model

    @MainActor
    func testSheetModelValidatesRequestAndRejectsBadInput() {
        let model = NewAgentSheetModel(resolveExecutable: { kind in
            kind == .genericShell ? "/bin/zsh" : nil
        })

        guard case let .success(request) = model.validate(
            kind: .genericShell, displayName: "frontend",
            taskSummary: " ship it ", workingDirectory: "/tmp"
        ) else {
            return XCTFail("valid input must validate")
        }
        XCTAssertEqual(request.agentKind, .genericShell)
        XCTAssertEqual(request.displayName, "frontend")
        XCTAssertEqual(request.workingDirectory, "/tmp")
        XCTAssertEqual(request.taskSummary, "ship it")

        if case .success = model.validate(kind: .genericShell, displayName: "",
                                          taskSummary: "", workingDirectory: "/tmp")
        {
            XCTFail("empty name must be rejected")
        }
        if case let .failure(error) = model.validate(kind: .genericShell, displayName: "x",
                                                     taskSummary: "", workingDirectory: "")
        {
            XCTAssertTrue(error == .missingWorkingDirectory)
        } else {
            XCTFail("empty cwd must be rejected")
        }
        if case let .failure(error) = model.validate(kind: .claudeCode, displayName: "x",
                                                     taskSummary: "",
                                                     workingDirectory: "/tmp")
        {
            XCTAssertTrue(error == NewAgentSheetModel.ValidationError.missingExecutable(.claudeCode))
            XCTAssertTrue(error.actionableMessage.lowercased().contains("install"))
        } else {
            XCTFail("missing CLI must be rejected")
        }
    }

    @MainActor
    func testSheetModelListsAllBundledAdapters() {
        let model = NewAgentSheetModel(resolveExecutable: { _ in nil })
        let kinds = Set(model.options.map(\.kind))
        XCTAssertEqual(kinds, [.claudeCode, .codex, .openCode, .genericShell])
    }

    // MARK: - schema version reader

    func testSchemaVersionReaderHandlesMissingDatabase() {
        let missing = URL(fileURLWithPath: "/tmp/at-s15-no-such-db-\(UUID().uuidString).sqlite")
        XCTAssertNil(DiagnosticExporter.readSchemaVersion(databaseURL: missing))
    }

    // MARK: - §3.22 quoted-value redaction

    /// Round 7: a QUOTED multi-word sensitive value loses the ENTIRE span —
    /// the old space-splitting token pass kept everything after the first
    /// space (` two secrets"`). Non-sensitive quoted values survive, and the
    /// sanitized line still passes render() (no over-redaction swing).
    func testRedactorScrubsQuotedSensitiveValuesEntirely() {
        let doubleQuoted = DiagnosticRedactor.sanitize(
            "export MY_API_KEY=\"hunter two secrets\""
        )
        XCTAssertFalse(doubleQuoted.contains("hunter"), doubleQuoted)
        XCTAssertFalse(doubleQuoted.contains("two"), doubleQuoted)
        XCTAssertFalse(doubleQuoted.contains("secrets"), doubleQuoted)
        XCTAssertTrue(doubleQuoted.contains("MY_API_KEY=<redacted>"), doubleQuoted)

        let singleQuoted = DiagnosticRedactor.sanitize("TOKEN='ab cd'")
        XCTAssertFalse(singleQuoted.contains("ab"), singleQuoted)
        XCTAssertFalse(singleQuoted.contains("cd"), singleQuoted)
        XCTAssertTrue(singleQuoted.contains("TOKEN=<redacted>"), singleQuoted)

        let sanitized = DiagnosticRedactor.sanitize(
            "export MY_API_KEY=\"hunter two secrets\" HOME=\"my home dir\""
        )
        XCTAssertTrue(
            sanitized.contains("HOME=\"my home dir\""),
            "non-sensitive quoted values must survive intact: \(sanitized)"
        )

        let rendered = DiagnosticRedactor.render(lines: [sanitized])
        XCTAssertEqual(rendered.count, 1, "the <redacted> line must survive render")
    }

    // MARK: - §3.22 escape-aware quoted redaction

    /// Round 11: a quoted sensitive value containing BACKSLASH-ESCAPED
    /// quotes loses the WHOLE span — the quoted regex treats `\"` atomically
    /// (`(?:[^"\\]|\\.)*`). The pre-fix `"[^"]*"` regex ended the match at
    /// the first escape, leaking the tail of the secret into the output.
    func testRedactorScrubsQuotedValuesContainingEscapedQuotesEntirely() {
        let escaped = DiagnosticRedactor.sanitize(
            #"export MY_API_KEY="say \"hi\" then wipe""#
        )
        XCTAssertTrue(escaped.contains("MY_API_KEY=<redacted>"), escaped)
        XCTAssertFalse(escaped.contains("hi"), escaped)
        XCTAssertFalse(escaped.contains("wipe"), escaped)
        XCTAssertFalse(escaped.contains("\\"), "the escaped fragment \\\"hi\\\" must appear nowhere: \(escaped)")

        // Control: no over-redaction swing for plain quoted forms.
        let control = DiagnosticRedactor.sanitize("MY_API_KEY=\"plain value\" HOME=/x")
        XCTAssertTrue(control.contains("MY_API_KEY=<redacted>"), control)
        XCTAssertTrue(control.contains("HOME=/x"), control)

        let rendered = DiagnosticRedactor.render(lines: [escaped])
        XCTAssertEqual(rendered.count, 1, "the <redacted> placeholder carries no secret")
    }

    // MARK: - §3.22 escape-aware single quotes + case-insensitive keys

    /// Round 12: the SINGLE-quote arm treats `\'` atomically exactly as the
    /// double-quote arm proved for `\"` (`'(?:[^'\\]|\\.)*'`), and the
    /// sensitive-KEY match is case-insensitive on BOTH paths (`(?i:)` group
    /// in the quoted pre-pass; `uppercased()` in isSensitive for the token
    /// path) while `$1` preserves the ORIGINAL key casing in the output.
    func testRedactorScrubsEscapedSingleQuotedValuesAndCaseInsensitiveKeysEntirely() {
        // A [^']* regression ends the span at `don\`, leaking `'t stop'`.
        let escapedSingle = DiagnosticRedactor.sanitize(#"TOKEN='don\'t stop'"#)
        XCTAssertTrue(escapedSingle.contains("TOKEN=<redacted>"), escapedSingle)
        XCTAssertFalse(escapedSingle.contains("stop"), escapedSingle)
        XCTAssertFalse(escapedSingle.contains("\\"), "the escaped fragment \\' must appear nowhere: \(escapedSingle)")

        let mixedCaseQuoted = DiagnosticRedactor.sanitize(#"my_Api_Key="s3cr3t words""#)
        XCTAssertTrue(mixedCaseQuoted.contains("my_Api_Key=<redacted>"), mixedCaseQuoted)
        XCTAssertFalse(mixedCaseQuoted.contains("s3cr3t"), mixedCaseQuoted)
        XCTAssertFalse(mixedCaseQuoted.contains("words"), mixedCaseQuoted)

        // Unquoted control pins isSensitive's case-folding on the token path.
        let mixedCasePlain = DiagnosticRedactor.sanitize("my_api_key=plainsecret")
        XCTAssertTrue(mixedCasePlain.contains("my_api_key=<redacted>"), mixedCasePlain)
        XCTAssertFalse(mixedCasePlain.contains("plainsecret"), mixedCasePlain)

        // Idempotence: sanitized placeholders carry no secret through render().
        let rendered = DiagnosticRedactor.render(lines: [
            escapedSingle, mixedCaseQuoted, mixedCasePlain,
        ])
        XCTAssertEqual(rendered.count, 3, "every <redacted> line must survive render")
    }

    // MARK: - §3.22 colon-form redaction

    /// Round 12 (orchestrator-authorized defect fix): the docstring promises
    /// "`KEY: value` assignments with sensitive keys lose the value" but only
    /// `=`-form was implemented. The colon pass scrubs the VALUE TO END OF
    /// LINE (colon payloads are free text — a token-scoped split on spaces
    /// would leak the tail, mirroring the prompt:/output: marker truncation),
    /// matches keys CASE-INSENSITIVELY while `$1` preserves their original
    /// casing, and leaves non-sensitive keys untouched.
    func testRedactorScrubsColonFormSensitiveValuesToEndOfLine() {
        let simple = DiagnosticRedactor.sanitize("API_KEY: hunter2")
        XCTAssertTrue(simple.contains("API_KEY: <redacted>"), simple)
        XCTAssertFalse(simple.contains("hunter2"), simple)

        // End-of-line law: multi-word free-text values lose EVERYTHING.
        let freeText = DiagnosticRedactor.sanitize("MY_SessionToken: abc def")
        XCTAssertFalse(freeText.contains("abc"), freeText)
        XCTAssertFalse(freeText.contains("def"), freeText)

        let mixedCase = DiagnosticRedactor.sanitize("my_Api_Key: s3cr3t")
        XCTAssertTrue(mixedCase.contains("my_Api_Key: <redacted>"), mixedCase)
        XCTAssertFalse(mixedCase.contains("s3cr3t"), mixedCase)

        // Control: non-sensitive keys are untouched.
        XCTAssertEqual(DiagnosticRedactor.sanitize("count: 42"), "count: 42")

        // Idempotence: placeholders carry no secret through render().
        let rendered = DiagnosticRedactor.render(lines: [simple, freeText, mixedCase])
        XCTAssertEqual(rendered.count, 3)
    }

    // MARK: - §3.22 colon-form adjacent shapes

    /// Round 13: shapes ADJACENT to the C3 colon pass that its landing test
    /// leaves unpinned — zero-space separator, colon payloads inside quoted
    /// free text, marker/colon PASS ORDER (load-bearing in BOTH directions),
    /// leftmost-sensitive-match consumption, and render() idempotence.
    func testColonFormAdjacentShapesScrubWithoutOverRedaction() {
        // 1. NO SPACE form: `\s*:\s*` is zero-width-tolerant.
        let noSpace = DiagnosticRedactor.sanitize("API_KEY:hunter2")
        XCTAssertTrue(noSpace.contains("API_KEY: <redacted>"), noSpace)
        XCTAssertFalse(noSpace.contains("hunter2"), noSpace)

        // 2. Colon form INSIDE quoted free text: the quoted pre-pass requires
        //    `=` immediately before the quote so it is correctly INERT here;
        //    the colon pass alone carries the whole protection to end of line.
        let inQuotes = DiagnosticRedactor.sanitize(#"note "msg TOKEN: abc def""#)
        XCTAssertFalse(inQuotes.contains("abc"), inQuotes)
        XCTAssertFalse(inQuotes.contains("def"), inQuotes)

        // 3. Marker BEFORE the sensitive colon key: the marker truncation runs
        //    FIRST, so the sensitive fragment never even reaches the colon pass.
        XCTAssertEqual(
            DiagnosticRedactor.sanitize("output: run API_TOKEN: zzz"),
            "output: <redacted>"
        )

        // 4. Marker AFTER the sensitive colon key: marker pass truncates the
        //    tail, colon pass scrubs the head — pass order is load-bearing.
        let markerAfter = DiagnosticRedactor.sanitize("API_TOKEN: zzz prompt: help")
        XCTAssertFalse(markerAfter.contains("zzz"), markerAfter)
        XCTAssertFalse(markerAfter.contains("help"), markerAfter)

        // 5. Non-sensitive prefix preserved: the colon scrub consumes only the
        //    LEFTMOST SENSITIVE match to end of line.
        let mixed = DiagnosticRedactor.sanitize("count: 42 SESSION: sid")
        XCTAssertTrue(mixed.contains("count: 42"), mixed)
        XCTAssertFalse(mixed.contains("sid"), mixed)

        // 6. Idempotence: every sanitized form survives render() unchanged in
        //    count — placeholders carry no secret.
        let rendered = DiagnosticRedactor.render(lines: [noSpace, inQuotes, markerAfter, mixed])
        XCTAssertEqual(rendered.count, 4)
    }

    // MARK: - §3.22 unterminated-quote redaction (orchestrator-authorized C5)

    /// A truncated log line can cut a quoted value BEFORE its closing quote;
    /// the quoted pre-pass needs the full span, so the rest of the line must
    /// be treated as the value (same end-of-line law as the colon pass).
    func testRedactorScrubsUnterminatedQuotedValuesToEndOfLine() {
        let double = DiagnosticRedactor.sanitize("TOKEN=\"hunter2 and friends")
        XCTAssertFalse(double.contains("hunter2"), double)
        XCTAssertFalse(double.contains("friends"), double)
        let single = DiagnosticRedactor.sanitize("ApiToken='s3cr3t words")
        XCTAssertFalse(single.contains("s3cr3t"), single)
        XCTAssertFalse(single.contains("words"), single)
        // Control: non-sensitive unterminated quotes stay untouched.
        XCTAssertEqual(DiagnosticRedactor.sanitize("note=\"hello world"), "note=\"hello world")
    }

    // MARK: - §3.22 redaction pass composition

    /// Round 26 (R1): sanitize()'s passes must COMPOSE on compound lines —
    /// the quoted pre-pass replaces a TERMINATED span while the unterminated
    /// pass takes the rest of the line for a TRUNCATED one; a truncated
    /// quoted secret inside a colon-form tail is erased by pass precedence
    /// (unterminated rewrites it, then the colon pass truncates from the
    /// leftmost sensitive key to end of line); non-sensitive unterminated
    /// quotes stay untouched even alongside sensitive content.
    func testRedactorComposesTerminatedTruncatedAndColonFormPassesOnOneLine() {
        // (a) terminated + truncated quoted secrets share one line.
        let mixed = DiagnosticRedactor.sanitize(#"TOKEN="a" API_KEY="b c d"#)
        XCTAssertTrue(mixed.contains("TOKEN=<redacted>"), mixed)
        XCTAssertTrue(mixed.contains("API_KEY=<redacted>"), mixed)
        // The whole line collapses to the two placeholders — no secret
        // fragment (single letters would also match "<redacted>" itself).
        XCTAssertEqual(mixed, "TOKEN=<redacted> API_KEY=<redacted>")

        // (b) truncated quoted secret INSIDE a colon-form value's tail:
        //     the colon pass truncates everything from SESSION onward.
        let colonTail = DiagnosticRedactor.sanitize(#"SESSION: alpha TOKEN="beta gamma"#)
        XCTAssertFalse(colonTail.contains("alpha"), colonTail)
        XCTAssertFalse(colonTail.contains("beta"), colonTail)
        XCTAssertFalse(colonTail.contains("gamma"), colonTail)
        XCTAssertTrue(colonTail.contains("SESSION: <redacted>"), colonTail)

        // (c) control: non-sensitive unterminated quotes stay untouched.
        XCTAssertEqual(
            DiagnosticRedactor.sanitize(#"note="keep" msg="cut off"#),
            #"note="keep" msg="cut off"#
        )

        // Idempotence: sanitize is an exact fixpoint on its own output —
        // each rendered line must EQUAL the re-sanitized input (these
        // inputs are already sanitized outputs, so this pins the
        // render→sanitize roundtrip as a non-corrupting fixpoint, not a
        // fresh-sanitization pass), and all three lines survive render().
        let control = DiagnosticRedactor.sanitize(#"note="keep" msg="cut off"#)
        let rendered = DiagnosticRedactor.render(lines: [mixed, colonTail, control])
        XCTAssertEqual(rendered.count, 3)
        XCTAssertEqual(
            rendered,
            [mixed, colonTail, control].map { DiagnosticRedactor.sanitize($0) }
        )
    }
}

@testable import AgentCore
import XCTest

// §4.8: manifest parsing, rule evaluation, equal-priority conflicts,
// hysteresis/stability, bundled resources, and the detection cadence table.

@MainActor
final class ScreenManifestTests: XCTestCase {
    private let agent = AgentID()

    // MARK: Bundled resources

    func testBundledManifestsParseAndCompile() throws {
        for name in ["claude-code", "codex", "opencode"] {
            let manifest = try ScreenManifestLoader.loadBundled(named: name)
            XCTAssertEqual(manifest.manifestVersion, 1, name)
            XCTAssertFalse(manifest.foregroundExecutables.isEmpty, name)
            XCTAssertFalse(manifest.rules.isEmpty, name)

            for rule in manifest.rules {
                if case .waitingForInput = rule.resultingLifecycle {
                    XCTAssertNotNil(rule.requestKind, "\(name)/\(rule.id): waiting rules classify the request")
                }
                for matcher in rule.allMatchers + rule.anyMatchers + rule.noneMatchers {
                    if matcher.kind == .regex {
                        XCTAssertNoThrow(
                            try CompiledPatternCache.validate(pattern: matcher.pattern),
                            "\(name)/\(rule.id)"
                        )
                    }
                }
            }
        }
    }

    func testBundledManifestKindsMatchAdapters() throws {
        XCTAssertEqual(try ScreenManifestLoader.loadBundled(named: "claude-code").agentKind, .claudeCode)
        XCTAssertEqual(try ScreenManifestLoader.loadBundled(named: "codex").agentKind, .codex)
        XCTAssertEqual(try ScreenManifestLoader.loadBundled(named: "opencode").agentKind, .openCode)
    }

    /// §3.7 regression: the free-text-question rule used to demand "?…" AND a
    /// bare "❯" on the SAME lastLine — mutually exclusive, so realistic
    /// question screens classified as unknown. The corrected rule requires a
    /// question ending one of the last two rows plus an empty composer marker
    /// on the last row.
    func testBundledFreeTextQuestionRuleFiresOnRealisticSnapshot() throws {
        let manifest = try ScreenManifestLoader.loadBundled(named: "claude-code")
        let snapshotText = """
        ? Should I proceed with installing dependencies?
        ❯
        """
        let result = ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: snapshotText)
        XCTAssertEqual(result.matchedRuleID, "free-text-question")
        guard case let .waitingForInput(descriptor) = result.resultingLifecycle else {
            return XCTFail("expected waitingForInput, got \(result.resultingLifecycle)")
        }
        XCTAssertEqual(descriptor.kind, .freeText)
        XCTAssertEqual(descriptor.safeReplyMode, .terminalOnly,
                       "screen-sourced free-text stays terminalOnly (§3.4 safety)")

        // Conservatism: neither signal alone classifies as free-text input.
        XCTAssertNil(
            ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: "ok?\nsome output").matchedRuleID,
            "a stray question mark without a composer marker must not fire"
        )
        XCTAssertNil(
            ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: "plain output\n❯").matchedRuleID,
            "a bare composer marker without a question must not fire"
        )
    }

    func testNonPositiveLastLinesCountIsRejected() {
        for bad in [0, -3] {
            let source = """
            manifestVersion = 1
            agentKind = "claude-code"
            foregroundExecutables = ["claude"]
            [[rules]]
            id = "x"
            resultingLifecycle = "working"
            priority = 1
            allMatchers = [{ kind = "literal", pattern = "p", region = "lastLines", lines = \(bad) }]
            """
            XCTAssertThrowsError(try ScreenManifestLoader.parse(source), "lines = \(bad)") { error in
                XCTAssertEqual(error as? ManifestError, .invalidLastLinesCount(bad))
            }
        }
    }

    // MARK: Parsing

    func testParseMinimalManifest() throws {
        let source = """
        # comment line
        manifestVersion = 1
        agentKind = "claude-code"
        foregroundExecutables = ["claude"]
        snapshotRows = 16

        [[rules]]
        id = "working"
        resultingLifecycle = "working"
        priority = 10
        allMatchers = [{ kind = "literal", pattern = "esc to interrupt", region = "lastLine" }]
        """
        let manifest = try ScreenManifestLoader.parse(source)
        XCTAssertEqual(manifest.agentKind, .claudeCode)
        XCTAssertEqual(manifest.snapshotRows, 16)
        XCTAssertEqual(manifest.rules.count, 1)
        XCTAssertEqual(manifest.rules[0].priority, 10)
    }

    func testUnsupportedManifestVersionIsRejected() {
        let source = """
        manifestVersion = 99
        agentKind = "claude-code"
        foregroundExecutables = ["claude"]
        [[rules]]
        id = "x"
        resultingLifecycle = "idle"
        priority = 1
        """
        XCTAssertThrowsError(try ScreenManifestLoader.parse(source)) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedManifestVersion(99))
        }
    }

    func testWaitingRuleWithoutRequestKindIsRejected() {
        let source = """
        manifestVersion = 1
        agentKind = "claude-code"
        foregroundExecutables = ["claude"]
        [[rules]]
        id = "bad"
        resultingLifecycle = "waitingForInput"
        priority = 5
        allMatchers = []
        """
        XCTAssertThrowsError(try ScreenManifestLoader.parse(source)) { error in
            guard case let ManifestError.waitingRuleWithoutRequestKind(id) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(id, "bad")
        }
    }

    func testInvalidRegexFailsAtLoadNotAtEvaluationTime() {
        let source = """
        manifestVersion = 1
        agentKind = "claude-code"
        foregroundExecutables = ["claude"]
        [[rules]]
        id = "broken"
        resultingLifecycle = "working"
        priority = 1
        allMatchers = [{ kind = "regex", pattern = "(unclosed" }]
        """
        XCTAssertThrowsError(try ScreenManifestLoader.parse(source)) { error in
            guard case ManifestError.invalidRegex = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: Rule evaluation

    private func manifestWith(rules: [ScreenRule]) -> ScreenManifest {
        ScreenManifest(
            manifestVersion: 1,
            agentKind: .claudeCode,
            foregroundExecutables: ["claude"],
            rules: rules
        )
    }

    func testHigherPriorityWinsOverLower() {
        let manifest = manifestWith(rules: [
            ScreenRule(id: "low-idle", resultingLifecycle: .idle, priority: 10,
                       anyMatchers: [ScreenMatcher(kind: .literal, pattern: "❯")]),
            ScreenRule(id: "high-working", resultingLifecycle: .working, priority: 50,
                       anyMatchers: [ScreenMatcher(kind: .literal, pattern: "thinking")]),
        ])

        let result = ScreenManifestEvaluator.evaluate(
            manifest: manifest,
            snapshotText: "thinking…\n❯"
        )
        XCTAssertEqual(result.matchedRuleID, "high-working")
        XCTAssertEqual(result.resultingLifecycle, .working)
    }

    func testNoneMatcherSuppressesPositiveMatch() {
        let manifest = manifestWith(rules: [
            ScreenRule(id: "idle", resultingLifecycle: .idle, priority: 10,
                       allMatchers: [ScreenMatcher(kind: .literal, pattern: ">")],
                       noneMatchers: [ScreenMatcher(kind: .regex, pattern: "Do you want")]),
        ])

        let suppressed = ScreenManifestEvaluator.evaluate(
            manifest: manifest,
            snapshotText: "Do you want to proceed?\n>"
        )
        XCTAssertNil(suppressed.matchedRuleID)

        let allowed = ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: "done.\n>")
        XCTAssertEqual(allowed.matchedRuleID, "idle")
    }

    func testAllMatchersRequireEveryPattern() {
        let manifest = manifestWith(rules: [
            ScreenRule(id: "both", resultingLifecycle: .working, priority: 10,
                       allMatchers: [
                           ScreenMatcher(kind: .literal, pattern: "alpha"),
                           ScreenMatcher(kind: .literal, pattern: "beta"),
                       ]),
        ])
        XCTAssertNil(ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: "alpha only").matchedRuleID)
        XCTAssertEqual(
            ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: "alpha beta").matchedRuleID,
            "both"
        )
    }

    func testCaseSensitivityRespected() {
        let sensitive = manifestWith(rules: [
            ScreenRule(id: "sensitive", resultingLifecycle: .working, priority: 10,
                       allMatchers: [ScreenMatcher(kind: .literal, pattern: "WORKING", caseSensitive: true)]),
        ])
        XCTAssertNil(ScreenManifestEvaluator.evaluate(manifest: sensitive, snapshotText: "working").matchedRuleID)
        XCTAssertEqual(
            ScreenManifestEvaluator.evaluate(manifest: sensitive, snapshotText: "WORKING").matchedRuleID,
            "sensitive"
        )

        let insensitive = manifestWith(rules: [
            ScreenRule(id: "insensitive", resultingLifecycle: .working, priority: 10,
                       allMatchers: [ScreenMatcher(kind: .literal, pattern: "WORKING")]),
        ])
        XCTAssertEqual(
            ScreenManifestEvaluator.evaluate(manifest: insensitive, snapshotText: "working").matchedRuleID,
            "insensitive"
        )
    }

    func testRegionsLastLineAndLastNLines() {
        let lastLineOnly = manifestWith(rules: [
            ScreenRule(id: "ll", resultingLifecycle: .working, priority: 10,
                       allMatchers: [ScreenMatcher(kind: .literal, pattern: "RUN", region: .lastLine)]),
        ])
        // "RUN" exists only on a non-last line → no match with region=lastLine.
        XCTAssertNil(ScreenManifestEvaluator.evaluate(manifest: lastLineOnly, snapshotText: "RUN\nprompt>")
            .matchedRuleID)

        let lastThree = manifestWith(rules: [
            ScreenRule(id: "l3", resultingLifecycle: .working, priority: 10,
                       allMatchers: [ScreenMatcher(kind: .literal, pattern: "RUN", region: .lastNLines(3))]),
        ])
        XCTAssertEqual(
            ScreenManifestEvaluator.evaluate(manifest: lastThree, snapshotText: "RUN\nx\nprompt>").matchedRuleID,
            "l3"
        )
    }

    func testEqualPriorityConflictingResultsYieldUnknown() {
        let manifest = manifestWith(rules: [
            ScreenRule(id: "says-working", resultingLifecycle: .working, priority: 50,
                       anyMatchers: [ScreenMatcher(kind: .literal, pattern: "spinner")]),
            ScreenRule(id: "says-idle", resultingLifecycle: .idle, priority: 50,
                       anyMatchers: [ScreenMatcher(kind: .literal, pattern: "prompt")]),
        ])
        let result = ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: "spinner prompt")
        XCTAssertEqual(result.resultingLifecycle, .unknown, "equal-priority conflicts are never randomly resolved")
        XCTAssertEqual(Set(result.conflictingRules), ["says-working", "says-idle"])
    }

    func testEqualPriorityAgreementIsFine() {
        let manifest = manifestWith(rules: [
            ScreenRule(id: "a", resultingLifecycle: .working, priority: 50,
                       anyMatchers: [ScreenMatcher(kind: .literal, pattern: "spin")]),
            ScreenRule(id: "b", resultingLifecycle: .working, priority: 50,
                       anyMatchers: [ScreenMatcher(kind: .literal, pattern: "wheel")]),
        ])
        let result = ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: "spin wheel")
        XCTAssertEqual(result.matchedRuleID, "a")
        XCTAssertEqual(Set(result.supportingRules), ["a", "b"])
    }

    func testFallbackToUnknownWhenNothingMatches() {
        let manifest = manifestWith(rules: [
            ScreenRule(id: "never", resultingLifecycle: .working, priority: 10,
                       allMatchers: [ScreenMatcher(kind: .literal, pattern: "zzz-never")]),
        ])
        let result = ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: "nothing here")
        XCTAssertNil(result.matchedRuleID)
        XCTAssertTrue(result.conflictingRules.isEmpty)
        XCTAssertEqual(result.resultingLifecycle, .unknown)
    }

    // MARK: Hysteresis / flicker protection (§3.5, §3.7 step 9)

    private func engine(_ clock: FakeClock) -> ScreenDetectionEngine {
        ScreenDetectionEngine(clock: clock)
    }

    private func context(lifecycle: LifecyclePhase) -> ScreenDetectionEngine.EvaluationContext {
        ScreenDetectionEngine.EvaluationContext(
            agentID: agent,
            currentLifecycle: lifecycle,
            manifest: manifestWith(rules: [
                ScreenRule(id: "ask-permission", resultingLifecycle: waitingPhase(), priority: 100,
                           requestKind: .approval,
                           anyMatchers: [ScreenMatcher(kind: .literal, pattern: "Do you want")]),
                ScreenRule(id: "idle", resultingLifecycle: .idle, priority: 10,
                           anyMatchers: [ScreenMatcher(kind: .literal, pattern: "❯")]),
            ])
        )
    }

    func testWaitingRequiresTwoMatchingSnapshotsAtLeast150msApart() async {
        let clock = FakeClock()
        let detector = engine(clock)
        let text = "Do you want to proceed? ❯"

        // First sighting: pending, nothing emitted.
        var result = await detector.evaluate(snapshot(0, text), context: context(lifecycle: .working))
        XCTAssertNil(result, "first waiting sighting must not emit")

        // Second sighting too early (50 ms): still pending.
        clock.advance(by: .milliseconds(50))
        result = await detector.evaluate(snapshot(0, text), context: context(lifecycle: .working))
        XCTAssertNil(result, "confirmation window is 150 ms")

        // Third sighting past the interval: confirmed.
        clock.advance(by: .milliseconds(100))
        result = await detector.evaluate(snapshot(0, text), context: context(lifecycle: .working))
        XCTAssertEqual(result?.resultingLifecycle, waitingPhase())
        XCTAssertEqual(result?.matchedRuleID, "ask-permission")
    }

    func testIdleAfterWorkingNeeds400msStableRevision() async {
        let clock = FakeClock()
        let detector = engine(clock)
        let idleText = "done ❯"

        // Candidate at revision 5.
        var result = await detector.evaluate(snapshot(5, idleText), context: context(lifecycle: .working))
        XCTAssertNil(result, "idle candidate starts its stability window")

        // Still within the window.
        clock.advance(by: .milliseconds(399))
        result = await detector.evaluate(snapshot(5, idleText), context: context(lifecycle: .working))
        XCTAssertNil(result)

        // Window elapsed without new output → emit.
        clock.advance(by: .milliseconds(1))
        result = await detector.evaluate(snapshot(5, idleText), context: context(lifecycle: .working))
        XCTAssertEqual(result?.resultingLifecycle, .idle)
    }

    func testNewOutputRevisionResetsIdleStabilityWindow() async {
        let clock = FakeClock()
        let detector = engine(clock)
        let idleText = "done ❯"

        _ = await detector.evaluate(snapshot(5, idleText), context: context(lifecycle: .working))
        clock.advance(by: .milliseconds(300))
        // New render arrives mid-window → reset.
        _ = await detector.evaluate(snapshot(6, idleText), context: context(lifecycle: .working))
        clock.advance(by: .milliseconds(200))
        let tooEarly = await detector.evaluate(snapshot(6, idleText), context: context(lifecycle: .working))
        XCTAssertNil(tooEarly, "window restarted at the newer revision")

        clock.advance(by: .milliseconds(201))
        let stable = await detector.evaluate(snapshot(6, idleText), context: context(lifecycle: .working))
        XCTAssertEqual(stable?.resultingLifecycle, .idle)
    }

    func testConflictEmitsUnknownImmediatelyWithoutHysteresis() async {
        let clock = FakeClock()
        let detector = engine(clock)
        let conflicting = manifestWith(rules: [
            ScreenRule(id: "w", resultingLifecycle: .working, priority: 50,
                       anyMatchers: [ScreenMatcher(kind: .literal, pattern: "x")]),
            ScreenRule(id: "i", resultingLifecycle: .idle, priority: 50,
                       anyMatchers: [ScreenMatcher(kind: .literal, pattern: "y")]),
        ])
        let ctx = ScreenDetectionEngine.EvaluationContext(
            agentID: agent,
            currentLifecycle: .working,
            manifest: conflicting
        )

        let result = await detector.evaluate(snapshot(1, "x y"), context: ctx)
        XCTAssertEqual(result?.resultingLifecycle, .unknown)
        XCTAssertEqual(Set(result?.conflictingRules ?? []), ["w", "i"])
    }

    func testInvalidateDropsHysteresisMemory() async {
        let clock = FakeClock()
        let detector = engine(clock)
        let text = "Do you want to proceed? ❯"

        _ = await detector.evaluate(snapshot(0, text), context: context(lifecycle: .working))
        await detector.invalidate(agentID: agent)

        // After invalidation (restart), the first sighting is pending again.
        let result = await detector.evaluate(snapshot(9, text), context: context(lifecycle: .starting))
        XCTAssertNil(result)
    }

    private func snapshot(_ revision: UInt64, _ text: String) -> TerminalSnapshot {
        TerminalSnapshot(text: text, outputRevision: revision, generation: .initial)
    }

    // MARK: Rule-declared stabilityRequirement drives hysteresis windows

    private func stabilityManifest() throws -> ScreenManifest {
        try ScreenManifestLoader.parse("""
        manifestVersion = 1
        agentKind = "claude-code"
        foregroundExecutables = ["claude"]
        [[rules]]
        id = "ask"
        resultingLifecycle = "waitingForInput"
        requestKind = "approval"
        priority = 100
        stabilityMilliseconds = 2000
        allMatchers = [{ kind = "literal", pattern = "Do you want", region = "wholeSnapshot" }]
        [[rules]]
        id = "calm"
        resultingLifecycle = "idle"
        priority = 10
        stabilityMilliseconds = 2500
        allMatchers = [{ kind = "literal", pattern = "done", region = "wholeSnapshot" }]
        """)
    }

    func testWaitingWindowUsesWinningRuleStabilityMilliseconds() async throws {
        let clock = FakeClock()
        let detector = engine(clock)
        let manifest = try stabilityManifest()
        let ctx = ScreenDetectionEngine.EvaluationContext(
            agentID: agent, currentLifecycle: .working, manifest: manifest
        )
        let text = "Do you want to continue?"

        var result = await detector.evaluate(snapshot(0, text), context: ctx)
        XCTAssertNil(result, "first sighting starts the rule's own window")

        clock.advance(by: .milliseconds(150))
        result = await detector.evaluate(snapshot(0, text), context: ctx)
        XCTAssertNil(result, "the legacy 150 ms constant must NOT confirm a 2000 ms rule")

        clock.advance(by: .milliseconds(1850))
        result = await detector.evaluate(snapshot(0, text), context: ctx)
        XCTAssertEqual(result?.matchedRuleID, "ask")
    }

    func testIdleAfterWorkingWindowUsesIdleRuleStabilityMilliseconds() async throws {
        let clock = FakeClock()
        let detector = engine(clock)
        let manifest = try stabilityManifest()
        let ctx = ScreenDetectionEngine.EvaluationContext(
            agentID: agent, currentLifecycle: .working, manifest: manifest
        )
        let text = "all done"

        var result = await detector.evaluate(snapshot(7, text), context: ctx)
        XCTAssertNil(result, "idle candidate starts the idle rule's declared window")

        clock.advance(by: .milliseconds(400))
        result = await detector.evaluate(snapshot(7, text), context: ctx)
        XCTAssertNil(result, "the legacy 400 ms constant must NOT confirm a 2500 ms idle rule")

        clock.advance(by: .milliseconds(2100))
        result = await detector.evaluate(snapshot(7, text), context: ctx)
        XCTAssertEqual(result?.resultingLifecycle, .idle)
    }

    func testRulesWithoutDeclarationKeepLegacyWindows() async {
        // Hand-built rules carry stabilityRequirement = .none; they fall back to
        // the legacy constants — exactly today's bundled-manifest values.
        let clock = FakeClock()
        let detector = engine(clock)
        let ctx = ScreenDetectionEngine.EvaluationContext(
            agentID: agent, currentLifecycle: .working,
            manifest: manifestWith(rules: [
                ScreenRule(id: "idle-nodeclared", resultingLifecycle: .idle, priority: 10,
                           anyMatchers: [ScreenMatcher(kind: .literal, pattern: "❯")]),
            ])
        )

        _ = await detector.evaluate(snapshot(3, "❯"), context: ctx)
        clock.advance(by: .milliseconds(399))
        let early = await detector.evaluate(snapshot(3, "❯"), context: ctx)
        XCTAssertNil(early)
        clock.advance(by: .milliseconds(1))
        let confirmed = await detector.evaluate(snapshot(3, "❯"), context: ctx)
        XCTAssertEqual(confirmed?.resultingLifecycle, .idle)
    }

    // MARK: Detection cadence table (§3.7)

    func testCadenceTableMatchesArchitecture() {
        XCTAssertEqual(DetectionScheduler.Cadence.hz(for: .working, isVisible: true), 4.0)
        XCTAssertEqual(DetectionScheduler.Cadence.hz(for: .unknown, isVisible: true), 4.0)
        XCTAssertEqual(DetectionScheduler.Cadence.hz(for: .working, isVisible: false), 2.0)
        XCTAssertEqual(DetectionScheduler.Cadence.hz(for: .idle, isVisible: true), 0.5)
        XCTAssertEqual(DetectionScheduler.Cadence.hz(for: waitingPhase(), isVisible: true), 1.0)
        XCTAssertNil(
            DetectionScheduler.Cadence.hz(for: .stopped(.completed), isVisible: true),
            "stopped agents: detection off"
        )

        // Debounce constant.
        XCTAssertEqual(DetectionScheduler.debounceInterval, .milliseconds(150))

        // Post-prompt immediate evaluation happens synchronously via handler.
        let expectation = expectation(description: "immediate post-prompt evaluation")
        let clock = FakeClock()
        let terminal = TerminalID()
        Task {
            let scheduler = DetectionScheduler(clock: clock)
            await scheduler.setHandler { fired in
                if fired == terminal {
                    expectation.fulfill()
                }
            }
            await scheduler.promptSent(terminalID: terminal)
        }
        wait(for: [expectation], timeout: 2)
    }

    // MARK: TOML subset strictness

    func testTOMLSubsetStrictness() {
        XCTAssertThrowsError(try TOMLParser.parse("key = \"\"\"multi\"\"\""))
        XCTAssertThrowsError(try TOMLParser.parse("a = 1\na = 2"))
        XCTAssertThrowsError(try TOMLParser.parse("dotted.key = 1"))
        XCTAssertThrowsError(try TOMLParser.parse("n = 0x1F"))
        XCTAssertThrowsError(try TOMLParser.parse("s = \"unterminated"))
        XCTAssertThrowsError(try TOMLParser.parse("v = tru"))

        XCTAssertNoThrow(try TOMLParser.parse("a = \"tab\\t newline\\n quote\\\" backslash\\\\ unicode\\u00E9\""))
        let parsed = try? TOMLParser.parse("neg = -42\nflt = 3.5\nflag = true\narr = [\n 1,\n 2,\n]")
        XCTAssertEqual(parsed?.integer("neg"), -42)
        if case let .float(f)? = parsed?.value("flt") {
            XCTAssertEqual(f, 3.5)
        } else {
            XCTFail()
        }
        XCTAssertEqual(parsed?.bool("flag"), true)
        XCTAssertEqual(parsed?.array("arr")?.count, 2)
    }

    // MARK: Round 6 — new parser strictness guards

    func testTOMLStrictnessDuplicateTablesKeysAndIntegerOverflow() {
        // Duplicate explicit table header throws.
        XCTAssertThrowsError(try TOMLParser.parse("[a]\nx=1\n[a]\ny=2"))
        // Duplicate key inside an inline table throws.
        XCTAssertThrowsError(try TOMLParser.parse("t = { x = 1, x = 2 }"))
        // Integer literal beyond Int64.max throws instead of degrading to a float.
        XCTAssertThrowsError(try TOMLParser.parse("big = 9223372036854775808"))
        // Contrast: array-of-tables remain legal on their own (the
        // duplicate-table guard must not over-fire). SPEC CORRECTION vs
        // test-design-6.md R4: `[a]` followed by `[[a]]` THROWS in the
        // current tree ("cannot redefine 'a' as array-of-tables",
        // appendArrayElement default branch) — correct TOML 1.0 semantics,
        // so the legal-usage contrast pins repeated [[a]] headers instead.
        XCTAssertNoThrow(try TOMLParser.parse("[[a]]\n[[a]]\nx=1"))

        func assertParseError(_ source: String, contains needle: String,
                              file: StaticString = #filePath, line: UInt = #line)
        {
            do {
                _ = try TOMLParser.parse(source)
                XCTFail("expected TOMLParseError for '\(source)'", file: file, line: line)
            } catch let error as TOMLParseError {
                XCTAssertTrue(
                    error.message.contains(needle),
                    "error message '\(error.message)' lacks '\(needle)'",
                    file: file, line: line
                )
            } catch {
                XCTFail("unexpected error type: \(error)", file: file, line: line)
            }
        }
        assertParseError("[a]\nx=1\n[a]\ny=2", contains: "duplicate")
        assertParseError("t = { x = 1, x = 2 }", contains: "duplicate")
        assertParseError("big = 9223372036854775808", contains: "out of range")
    }

    // MARK: Round 14 A1 — waiting confirmation window is REVISION-scoped

    func testWaitingConfirmationWindowRestartsWhenOutputRevisionAdvances() async {
        let clock = FakeClock()
        let detector = engine(clock)
        let text = "Do you want to proceed? ❯"
        let ctx = context(lifecycle: .working)

        // t0: first sighting @ rev 1 — pending.
        var result = await detector.evaluate(snapshot(1, text), context: ctx)
        XCTAssertNil(result, "first sighting must not emit")

        // +100 ms: window open.
        clock.advance(by: .milliseconds(100))
        result = await detector.evaluate(snapshot(1, text), context: ctx)
        XCTAssertNil(result)

        // Leg 1: a revision change RESTARTS the window even though 150 ms
        // have elapsed since firstSeen@rev1 (spinner redraws keep bumping
        // outputRevision; elapsed wall time alone must never confirm).
        clock.advance(by: .milliseconds(50))
        result = await detector.evaluate(snapshot(2, text), context: ctx)
        XCTAssertNil(result, "newer outputRevision restarts the confirmation window")

        // Leg 2: confirmation counts FROM THE REV-2 RESTART, not from t0:
        // 150 ms after the restart it confirms.
        clock.advance(by: .milliseconds(150))
        result = await detector.evaluate(snapshot(2, text), context: ctx)
        XCTAssertEqual(result?.resultingLifecycle, waitingPhase())

        // Leg 3 — SPINNER IMMUNITY (the regression this pins): a fresh
        // detector where each sighting arrives at a DIFFERENT revision with
        // more than a full window of wall time between them must NEVER emit.
        let freshClock = FakeClock()
        let freshDetector = engine(freshClock)
        _ = await freshDetector.evaluate(snapshot(7, text), context: ctx)
        freshClock.advance(by: .milliseconds(200))
        result = await freshDetector.evaluate(snapshot(8, text), context: ctx)
        XCTAssertNil(result, "time-only keying would falsely confirm across redraws")
    }

    // MARK: Round 15 D2 — a non-matching snapshot clears a pending candidate

    /// The DEFAULT leg emits immediately for any non-waiting evaluation AND
    /// wipes lastWaitingMatch + idleCandidate. An unmatched snapshot landing
    /// mid-window therefore RESETS confirmation: the next waiting sighting
    /// starts a FRESH window instead of confirming off the stale firstSeen.
    func testNonMatchingSnapshotClearsAPendingWaitingCandidateMidWindow() async {
        let clock = FakeClock()
        let detector = engine(clock)
        let ctx = context(lifecycle: .working)
        let text = "Do you want to proceed? ❯"

        // t0: first waiting sighting — pending, nothing emitted.
        var result = await detector.evaluate(snapshot(0, text), context: ctx)
        XCTAssertNil(result, "first waiting sighting must not emit")

        // +50 ms: an UNMATCHED snapshot falls through to the default leg —
        // no competing rules, so not the conflict leg — and emits .unknown
        // immediately. This emission is the CLEAR.
        clock.advance(by: .milliseconds(50))
        result = await detector.evaluate(snapshot(0, "unrelated output"), context: ctx)
        XCTAssertEqual(
            result?.resultingLifecycle, .unknown,
            "the unmatched snapshot must take the default leg and clear hysteresis state"
        )

        // +100 ms (150 ms since the FIRST sighting ≥ the full window): the
        // re-sighting must still be PENDING. A regression keeping the cleared
        // candidate would confirm HERE off the t0 firstSeen.
        clock.advance(by: .milliseconds(100))
        result = await detector.evaluate(snapshot(0, text), context: ctx)
        XCTAssertNil(result, "the intervening non-matching snapshot must reset the confirmation window")

        // +150 ms more from the POST-CLEAR re-sighting: now it confirms.
        clock.advance(by: .milliseconds(150))
        result = await detector.evaluate(snapshot(0, text), context: ctx)
        XCTAssertEqual(result?.resultingLifecycle, waitingPhase())
    }
}

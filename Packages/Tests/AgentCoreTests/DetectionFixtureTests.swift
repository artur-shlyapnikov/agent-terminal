@testable import AgentCore
import XCTest

// Stage 7 fixture gate (architecture §3.23 snapshot fixtures, §6.7):
// every bundled manifest must classify hand-crafted, anonymized agent screen
// snapshots into the expected lifecycle — and must NEVER invent a
// waitingForInput state on working/idle/noise screens. Fixtures live in
// Tests/Fixtures/Detection/<agent>/<state>.txt and are evaluated through the
// REAL ScreenManifestLoader → ScreenManifestEvaluator → ScreenDetectionEngine
// stack against the REAL bundled TOMLs.

final class DetectionFixtureTests: XCTestCase {
    // MARK: Fixture inventory

    /// What a fixture is expected to produce once hysteresis completes.
    private struct Expectation: Equatable {
        let ruleID: String?
        let lifecycle: LifecyclePhase
        /// Equal-priority conflicting rule IDs — non-empty means `unknown`.
        let conflicting: Set<String>

        static func rule(_ id: String, _ lifecycle: LifecyclePhase) -> Expectation {
            Expectation(ruleID: id, lifecycle: lifecycle, conflicting: [])
        }

        static func waiting(_ id: String, _ kind: InputRequestKind) -> Expectation {
            .rule(id, .waitingForInput(.screenSourced(kind: kind, summary: nil)))
        }

        static func unknown(_ conflicting: Set<String>) -> Expectation {
            Expectation(ruleID: nil, lifecycle: .unknown, conflicting: conflicting)
        }
    }

    private struct FixtureSpec {
        let agentDirectory: String
        let fileName: String
        let manifestName: String
        /// Lifecycle the engine should be in when the fixture is first seen.
        let currentLifecycle: LifecyclePhase
        let expectation: Expectation

        var path: String {
            "\(agentDirectory)/\(fileName)"
        }
    }

    /// §3.23 list plus the extra states called out by the stage-7 ticket
    /// (codex idle/working, claude free-text question, opencode idle, and
    /// ambiguity/noise screens that must resolve to unknown).
    private static let fixtures: [FixtureSpec] = [
        FixtureSpec(agentDirectory: "claude", fileName: "idle.txt", manifestName: "claude-code",
                    currentLifecycle: .working, expectation: .rule("idle-prompt", .idle)),
        FixtureSpec(agentDirectory: "claude", fileName: "working.txt", manifestName: "claude-code",
                    currentLifecycle: .idle, expectation: .rule("spinner-working", .working)),
        FixtureSpec(agentDirectory: "claude", fileName: "permission.txt", manifestName: "claude-code",
                    currentLifecycle: .working, expectation: .waiting("permission-prompt", .approval)),
        FixtureSpec(agentDirectory: "claude", fileName: "question.txt", manifestName: "claude-code",
                    currentLifecycle: .working, expectation: .waiting("free-text-question", .freeText)),
        FixtureSpec(agentDirectory: "claude", fileName: "ambiguous.txt", manifestName: "claude-code",
                    currentLifecycle: .working, expectation: .unknown(["permission-prompt", "trust-dialog"])),

        FixtureSpec(agentDirectory: "codex", fileName: "idle.txt", manifestName: "codex",
                    currentLifecycle: .working, expectation: .rule("codex-idle", .idle)),
        FixtureSpec(agentDirectory: "codex", fileName: "working.txt", manifestName: "codex",
                    currentLifecycle: .idle, expectation: .rule("codex-working", .working)),
        FixtureSpec(agentDirectory: "codex", fileName: "approval.txt", manifestName: "codex",
                    currentLifecycle: .working, expectation: .waiting("approval-prompt", .approval)),
        FixtureSpec(agentDirectory: "codex", fileName: "plan.txt", manifestName: "codex",
                    currentLifecycle: .working, expectation: .waiting("plan-approval", .selection)),
        FixtureSpec(agentDirectory: "codex", fileName: "noise.txt", manifestName: "codex",
                    currentLifecycle: .working, expectation: .unknown([])),

        FixtureSpec(agentDirectory: "opencode", fileName: "idle.txt", manifestName: "opencode",
                    currentLifecycle: .working, expectation: .rule("opencode-idle", .idle)),
        FixtureSpec(agentDirectory: "opencode", fileName: "working.txt", manifestName: "opencode",
                    currentLifecycle: .idle, expectation: .rule("opencode-working", .working)),
        FixtureSpec(agentDirectory: "opencode", fileName: "permission.txt", manifestName: "opencode",
                    currentLifecycle: .working, expectation: .waiting("permission-request", .approval)),
        FixtureSpec(agentDirectory: "opencode", fileName: "question.txt", manifestName: "opencode",
                    currentLifecycle: .working, expectation: .waiting("question-prompt", .freeText)),
    ]

    // MARK: Loading

    /// Repo-root Tests/Fixtures/Detection, resolved from this file's compile
    /// path (Packages/Tests/AgentCoreTests → repo root).
    private static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../..")
        .appendingPathComponent("Tests/Fixtures/Detection")
        .standardizedFileURL

    private func loadFixture(_ spec: FixtureSpec) throws -> String {
        let url = Self.fixturesRoot.appendingPathComponent(spec.path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func evaluate(_ spec: FixtureSpec, text: String) throws -> ScreenEvidencePayload {
        let manifest = try ScreenManifestLoader.loadBundled(named: spec.manifestName)
        return ScreenManifestEvaluator.evaluate(manifest: manifest, snapshotText: text)
    }

    // MARK: Snapshot normalization bounds (§3.7 step 4)

    func testFixturesStayWithinSnapshotLimits() throws {
        for spec in Self.fixtures {
            let text = try loadFixture(spec)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertLessThanOrEqual(lines.count, 32, "\(spec.path): exceeds snapshotRows bound")
            XCTAssertLessThanOrEqual(text.utf8.count, 16 * 1024, "\(spec.path): exceeds 16 KiB bound")
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, spec.path)
        }
    }

    /// §3.23 names six mandatory fixture files; extras may exist alongside.
    func testArchitectureMinimumFixtureSetIsPresent() {
        let required = [
            "claude/idle.txt", "claude/permission.txt", "claude/working.txt",
            "codex/idle.txt", "codex/approval.txt", "opencode/working.txt",
        ]
        let present = Set(Self.fixtures.map(\.path))
        for path in required {
            XCTAssertTrue(present.contains(path), "missing architecture fixture \(path)")
        }
    }

    // MARK: Pure evaluation over bundled manifests

    func testEveryFixtureClassifiesToExpectedLifecycle() throws {
        for spec in Self.fixtures {
            let text = try loadFixture(spec)
            let result = try evaluate(spec, text: text)
            XCTAssertEqual(
                result.resultingLifecycle, spec.expectation.lifecycle,
                "\(spec.path): expected \(spec.expectation.lifecycle), got \(result.resultingLifecycle)"
            )
            XCTAssertEqual(result.matchedRuleID, spec.expectation.ruleID, spec.path)
            XCTAssertEqual(Set(result.conflictingRules), spec.expectation.conflicting, spec.path)
        }
    }

    // MARK: Hysteresis over the real engine (§3.5, §3.7 step 9)

    private func makeEngine() -> (ScreenDetectionEngine, FakeClock) {
        let clock = FakeClock()
        return (ScreenDetectionEngine(clock: clock), clock)
    }

    private func context(
        _ spec: FixtureSpec, manifest: ScreenManifest? = nil, lifecycle: LifecyclePhase? = nil
    ) throws -> ScreenDetectionEngine.EvaluationContext {
        try ScreenDetectionEngine.EvaluationContext(
            agentID: AgentID(),
            currentLifecycle: lifecycle ?? spec.currentLifecycle,
            manifest: manifest ?? ScreenManifestLoader.loadBundled(named: spec.manifestName)
        )
    }

    private func snapshot(_ text: String, revision: UInt64 = 0) -> TerminalSnapshot {
        TerminalSnapshot(text: text, outputRevision: revision, generation: .initial)
    }

    /// waitingForInput rules declare 150 ms stability: first sighting is
    /// pending, confirmation needs a second match ≥150 ms later.
    func testWaitingFixturesConfirmOnlyAfterDeclaredStability() async throws {
        for spec in Self.fixtures where spec.expectation.conflicting.isEmpty {
            guard case .waitingForInput = spec.expectation.lifecycle else { continue }
            let text = try loadFixture(spec)
            let (engine, clock) = makeEngine()
            let ctx = try context(spec)

            var result = await engine.evaluate(snapshot(text), context: ctx)
            XCTAssertNil(result, "\(spec.path): first waiting sighting must not emit")

            clock.advance(by: .milliseconds(50))
            result = await engine.evaluate(snapshot(text), context: ctx)
            XCTAssertNil(result, "\(spec.path): 50 ms is inside the 150 ms window")

            clock.advance(by: .milliseconds(100))
            result = await engine.evaluate(snapshot(text), context: ctx)
            XCTAssertEqual(result?.resultingLifecycle, spec.expectation.lifecycle, spec.path)
            XCTAssertEqual(result?.matchedRuleID, spec.expectation.ruleID, spec.path)
            if case let .waitingForInput(descriptor)? = result?.resultingLifecycle {
                XCTAssertEqual(descriptor.safeReplyMode, .terminalOnly,
                               "\(spec.path): screen-sourced requests stay terminalOnly (§3.4)")
            } else {
                XCTFail("\(spec.path): expected a waitingForInput descriptor")
            }
        }
    }

    func testWorkingFixturesEmitImmediatelyWithoutHysteresis() async throws {
        for spec in Self.fixtures where spec.expectation.lifecycle == .working {
            let text = try loadFixture(spec)
            let (engine, _) = makeEngine()
            let result = try await engine.evaluate(snapshot(text), context: context(spec))
            XCTAssertEqual(result?.resultingLifecycle, .working, spec.path)
            XCTAssertEqual(result?.matchedRuleID, spec.expectation.ruleID, spec.path)
        }
    }

    /// Idle rules declare 400 ms stability; idle-after-working additionally
    /// requires no newer output revision inside the window.
    func testIdleFixturesRequireStableScreenBeforeEmitting() async throws {
        for spec in Self.fixtures where spec.expectation.lifecycle == .idle {
            let text = try loadFixture(spec)
            let (engine, clock) = makeEngine()
            let ctx = try context(spec)

            var result = await engine.evaluate(snapshot(text, revision: 4), context: ctx)
            XCTAssertNil(result, "\(spec.path): idle candidate starts its stability window")

            clock.advance(by: .milliseconds(399))
            result = await engine.evaluate(snapshot(text, revision: 4), context: ctx)
            XCTAssertNil(result, "\(spec.path): 399 ms is inside the 400 ms window")

            clock.advance(by: .milliseconds(1))
            result = await engine.evaluate(snapshot(text, revision: 4), context: ctx)
            XCTAssertEqual(result?.resultingLifecycle, .idle, spec.path)
        }
    }

    /// Ambiguity resolves to unknown immediately — hysteresis never rescues a
    /// conflicting or unmatched screen (§3.7 step 8, §6.7).
    func testUnknownFixturesEmitImmediatelyWithoutGuessing() async throws {
        for spec in Self.fixtures where spec.expectation.lifecycle == .unknown {
            let text = try loadFixture(spec)
            let (engine, _) = makeEngine()
            let result = try await engine.evaluate(snapshot(text), context: context(spec))
            XCTAssertEqual(result?.resultingLifecycle, .unknown, spec.path)
            XCTAssertEqual(Set(result?.conflictingRules ?? []), spec.expectation.conflicting, spec.path)
            XCTAssertNil(result?.matchedRuleID, spec.path)
        }
    }

    // MARK: §6.7 gate — no false waiting state on fixtures

    /// Sweeps every non-waiting fixture through a full hysteresis timeline
    /// (well past the 150 ms confirmation interval, with and without new
    /// output revisions). No screen may ever classify as waitingForInput.
    func testNoFalseWaitingForInputOnAnyNonWaitingFixture() async throws {
        let waitingPaths = Set(Self.fixtures.compactMap { spec -> String? in
            if case .waitingForInput = spec.expectation.lifecycle {
                return spec.path
            }
            return nil
        })
        for spec in Self.fixtures where !waitingPaths.contains(spec.path) {
            let text = try loadFixture(spec)
            let (engine, clock) = makeEngine()
            let ctx = try context(spec)

            var revision: UInt64 = 10
            for step in 0 ..< 8 {
                if step % 3 == 2 {
                    revision += 1
                } // fresh renders interleaved
                let result = await engine.evaluate(snapshot(text, revision: revision), context: ctx)
                if case .waitingForInput = result?.resultingLifecycle {
                    XCTFail("\(spec.path): false waitingForInput at timeline step \(step)")
                }
                clock.advance(by: .milliseconds(100))
            }
        }
    }

    // MARK: StabilityRequirement semantics (fd3a135) — hand-built manifests

    private func handBuiltManifest(_ rule: ScreenRule) -> ScreenManifest {
        ScreenManifest(
            manifestVersion: ScreenManifest.supportedManifestVersion,
            agentKind: .genericShell,
            foregroundExecutables: [],
            rules: [rule]
        )
    }

    /// E1: an EXPLICIT `.none` emits on the FIRST matching snapshot for both
    /// the waiting leg and the idle-after-working leg, with no confirmation
    /// pair consumed and no clock movement. Collapsing `.none` back into
    /// `.unspecified` would silently regain a 150–400 ms two-sighting delay.
    func testExplicitNoneStabilityEmitsOnFirstMatchingSnapshotForBothPhases() async {
        let waitingRule = ScreenRule(
            id: "continue-none",
            resultingLifecycle: .waitingForInput(.screenSourced(kind: .freeText, summary: nil)),
            priority: 1,
            requestKind: .freeText,
            stabilityRequirement: .none,
            allMatchers: [ScreenMatcher(kind: .regex, pattern: "CONTINUE\\?")]
        )
        let (engine, clock) = makeEngine()
        let ctx = ScreenDetectionEngine.EvaluationContext(
            agentID: AgentID(),
            currentLifecycle: .working,
            manifest: handBuiltManifest(waitingRule)
        )

        // Waiting phase: first matching snapshot emits immediately…
        let first = await engine.evaluate(snapshot("> CONTINUE?"), context: ctx)
        XCTAssertEqual(first?.matchedRuleID, waitingRule.id)
        guard case .waitingForInput = first?.resultingLifecycle else {
            return XCTFail("expected waitingForInput, got \(String(describing: first?.resultingLifecycle))")
        }
        XCTAssertEqual(clock.now, MonotonicInstant.zero, "no virtual time may be needed")
        // …and a second identical call also emits (no confirmation pair).
        let second = await engine.evaluate(snapshot("> CONTINUE?"), context: ctx)
        XCTAssertEqual(second?.matchedRuleID, waitingRule.id)

        // Idle-after-working phase with .none: zero stabilization wait.
        let idleRule = ScreenRule(
            id: "idle-none",
            resultingLifecycle: .idle,
            priority: 1,
            stabilityRequirement: .none,
            allMatchers: [ScreenMatcher(kind: .regex, pattern: "CONTINUE\\?")]
        )
        let (idleEngine, idleClock) = makeEngine()
        let idleCtx = ScreenDetectionEngine.EvaluationContext(
            agentID: AgentID(),
            currentLifecycle: .working,
            manifest: handBuiltManifest(idleRule)
        )
        let idleResult = await idleEngine.evaluate(snapshot("done. CONTINUE?"), context: idleCtx)
        XCTAssertEqual(idleResult?.resultingLifecycle, .idle)
        XCTAssertEqual(idleResult?.matchedRuleID, idleRule.id)
        XCTAssertEqual(idleClock.now, MonotonicInstant.zero, "idle .none emits with zero elapsed virtual time")
    }

    /// E2: the OTHER half of the split — default-init rules (`.unspecified`)
    /// keep the legacy two-sighting windows; an explicit `.stable(Duration)`
    /// overrides the fallback per winning rule; and a revision bump restarts
    /// the window.
    func testUnspecifiedStabilityKeepsLegacyTwoSightingWindowWhileStableHonorsDeclaredDuration() async {
        func manifest(_ requirement: StabilityRequirement) -> ScreenManifest {
            handBuiltManifest(ScreenRule(
                id: "ask",
                resultingLifecycle: .waitingForInput(.screenSourced(kind: .approval, summary: nil)),
                priority: 1,
                requestKind: .approval,
                stabilityRequirement: requirement,
                allMatchers: [ScreenMatcher(kind: .literal, pattern: "APPROVE?")]
            ))
        }
        let text = "apply? APPROVE?"

        // Leg 1 — .unspecified keeps the legacy 150 ms two-sighting window.
        let (legacy, legacyClock) = makeEngine()
        let legacyCtx = ScreenDetectionEngine.EvaluationContext(
            agentID: AgentID(), currentLifecycle: .working, manifest: manifest(.unspecified)
        )
        var result = await legacy.evaluate(snapshot(text), context: legacyCtx)
        XCTAssertNil(result, "first sighting stays pending")
        legacyClock.advance(by: .milliseconds(100))
        result = await legacy.evaluate(snapshot(text), context: legacyCtx)
        XCTAssertNil(result, "+100 ms is inside the legacy 150 ms window")
        legacyClock.advance(by: .milliseconds(50))
        result = await legacy.evaluate(snapshot(text), context: legacyCtx)
        XCTAssertEqual(result?.matchedRuleID, "ask", "+150 ms cumulative confirms the pair")

        // Leg 2 — declared .stable(.milliseconds(40)) wins over the constant.
        let (tuned, tunedClock) = makeEngine()
        let tunedCtx = ScreenDetectionEngine.EvaluationContext(
            agentID: AgentID(), currentLifecycle: .working, manifest: manifest(.stable(.milliseconds(40)))
        )
        result = await tuned.evaluate(snapshot(text), context: tunedCtx)
        XCTAssertNil(result, "the declared window still starts at the first sighting")
        tunedClock.advance(by: .milliseconds(40))
        result = await tuned.evaluate(snapshot(text), context: tunedCtx)
        XCTAssertEqual(result?.matchedRuleID, "ask", "declared duration overrides the constant")

        // Leg 3 — a newer output revision restarted the window.
        tunedClock.advance(by: .milliseconds(160))
        result = await tuned.evaluate(snapshot(text, revision: 2), context: tunedCtx)
        XCTAssertNil(result, "revision bump must reset the confirmation pair")
    }
}

@testable import AgentCore
import XCTest

// Stage-14 integration assets: hook shims and the OpenCode plugin must pass
// shell syntax checks, honor the dry-run contract (well-formed NDJSON, no raw
// token leak) and produce monotonic sequence numbers per agent (§3.6), plus
// validator coverage for corrupted configs (§3.17 steps 6 & 9).

final class IntegrationScriptTests: XCTestCase {
    // MARK: Resource locations

    private static let integrationsRoot = Bundle.module.resourcePath! + "/Integrations"
    private var claudeShimPath: String {
        Self.integrationsRoot + "/claude/session-hook.sh"
    }

    private var codexShimPath: String {
        Self.integrationsRoot + "/codex/session-hook.sh"
    }

    private var openCodePluginPath: String {
        Self.integrationsRoot + "/opencode/lifecycle-plugin.js"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: claudeShimPath),
            "claude shim missing from resource bundle"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexShimPath), "codex shim missing from resource bundle")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: openCodePluginPath),
            "opencode plugin missing from resource bundle"
        )
    }

    // MARK: Environment helpers

    /// Every minted scratch dir is recorded so tearDownWithError can remove
    /// it even when an assertion fails mid-test.
    private var createdStateDirs: [String] = []

    private var scratchStateDir: String {
        let dir = NSTemporaryDirectory() + "/aterm-seq-test-\(UUID().uuidString)"
        createdStateDirs.append(dir)
        return dir
    }

    override func tearDownWithError() throws {
        for dir in createdStateDirs {
            try? FileManager.default.removeItem(atPath: dir)
        }
        createdStateDirs.removeAll()
        try super.tearDownWithError()
    }

    private func shimEnvironment(agentID: String = "agent-it", generation: String = "7",
                                 token: String? = "test-token") -> [String: String]
    {
        var env = [
            "AGENT_TERMINAL_AGENT_ID": agentID,
            "AGENT_TERMINAL_SURFACE_GENERATION": generation,
            "AGENT_TERMINAL_SEQ_STATE_DIR": scratchStateDir,
            "AGENT_TERMINAL_DRY_RUN": "1",
        ]
        if let token {
            env["AGENT_TERMINAL_TOKEN"] = token
        }
        return env
    }

    @discardableResult
    private func runShell(_ argv: [String], environment: [String: String],
                          stdin: String? = nil) throws -> (exitCode: Int32, stdout: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        if let stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            stdinPipe.fileHandleForWriting.closeFile()
        } else if #available(macOS 11.0, *) {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func parseNDJSONLines(_ output: String, file: StaticString = #filePath,
                                  line: UInt = #line) throws -> [[String: Any]]
    {
        let lines = output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertFalse(lines.isEmpty, "expected NDJSON output", file: file, line: line)
        return try lines.map { rawLine in
            let object = try JSONSerialization.jsonObject(with: Data(rawLine.utf8))
            guard let report = object as? [String: Any] else {
                XCTFail("line is not a JSON object: \(rawLine)", file: file, line: line)
                return [:]
            }
            return report
        }
    }

    // MARK: Shell syntax basics (shellcheck-style gate: sh -n)

    func testHookScriptsPassSyntaxCheck() throws {
        for path in [claudeShimPath, codexShimPath] {
            let result = try runShell(["/bin/sh", "-n", path], environment: [:])
            XCTAssertEqual(result.exitCode, 0, "sh -n failed for \(path)")
        }
    }

    func testPluginParsesWithNodeCheck() throws {
        guard IntegrationValidator.validateSyntax("// probe", format: .javaScript).diagnostics
            .contains(where: { $0.contains("node not found") }) == false
        else {
            throw XCTSkip("node unavailable; structural checks already covered by validator tests")
        }
        let validation = IntegrationValidator.validateFile(at: openCodePluginPath, format: .javaScript)
        XCTAssertTrue(validation.isValid, "plugin must parse: \(validation.diagnostics)")
    }

    // MARK: Dry-run NDJSON reports (no socket touched)

    func testClaudeShimDryRunEmitsWellFormedLifecycleReport() throws {
        let result = try runShell(
            ["/bin/sh", claudeShimPath],
            environment: shimEnvironment(),
            stdin: #"{"hook_event_name":"Stop","session_id":"s-1"}"#
        )
        XCTAssertEqual(result.exitCode, 0)
        let reports = try parseNDJSONLines(result.stdout)
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report["agentID"] as? String, "agent-it")
        XCTAssertEqual(report["source"] as? String, "claude-hook")
        XCTAssertEqual(report["lifecycle"] as? String, "idle")
        XCTAssertEqual(report["surfaceGeneration"] as? Int, 7)
        XCTAssertEqual(report["tokenPresent"] as? Bool, true)
        XCTAssertNil(report["token"], "dry-run must never leak the raw token")

        // SessionStart maps to a session-identity report instead.
        let identityRun = try runShell(
            ["/bin/sh", claudeShimPath],
            environment: shimEnvironment(),
            stdin: #"{"hook_event_name":"SessionStart","session_id":"abc-123"}"#
        )
        let identityReports = try parseNDJSONLines(identityRun.stdout)
        let reference = try XCTUnwrap(identityReports.first?["sessionReference"] as? [String: Any])
        XCTAssertEqual(reference["agentKind"] as? String, "claude-code")
        XCTAssertEqual(reference["opaquePayload"] as? String, "abc-123")
    }

    func testCodexShimDryRunMapsTurnCompleteAndCapturesThreadIdentity() throws {
        let result = try runShell(
            ["/bin/sh", codexShimPath, #"{"type":"agent-turn-complete","thread-id":"t-9"}"#],
            environment: shimEnvironment()
        )
        XCTAssertEqual(result.exitCode, 0)
        let reports = try parseNDJSONLines(result.stdout)
        // §3.10 regression: a known notification carries lifecycle AND the
        // thread identity in the SAME report.
        let combined = try XCTUnwrap(reports.first?["sessionReference"] as? [String: Any])
        XCTAssertEqual(combined["agentKind"] as? String, "codex")
        XCTAssertEqual(combined["opaquePayload"] as? String, "t-9")
        XCTAssertEqual(reports.first?["lifecycle"] as? String, "idle",
                       "lifecycle and identity ship together, not instead of each other")

        let unknownType = try runShell(
            ["/bin/sh", codexShimPath, #"{"type":"something-new","thread-id":"t-9"}"#],
            environment: shimEnvironment()
        )
        let unknownReports = try parseNDJSONLines(unknownType.stdout)
        let reference = try XCTUnwrap(unknownReports.first?["sessionReference"] as? [String: Any])
        XCTAssertEqual(reference["agentKind"] as? String, "codex")
        XCTAssertEqual(reference["opaquePayload"] as? String, "t-9")
    }

    func testOpenCodePluginDirectExecutionEmitsIdentityReport() throws {
        let result = try runShell(
            ["/usr/bin/env", "node", openCodePluginPath],
            environment: shimEnvironment()
        )
        XCTAssertEqual(result.exitCode, 0)
        let reports = try parseNDJSONLines(result.stdout)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report["agentID"] as? String, "agent-it")
        XCTAssertEqual(report["source"] as? String, "opencode-plugin")
        let reference = try XCTUnwrap(report["sessionReference"] as? [String: Any])
        XCTAssertEqual(reference["agentKind"] as? String, "opencode")
    }

    func testMissingTokenOmitsTokenPresentFlag() throws {
        let result = try runShell(
            ["/bin/sh", claudeShimPath],
            environment: shimEnvironment(token: nil),
            stdin: #"{"hook_event_name":"Stop"}"#
        )

        let reports = try parseNDJSONLines(result.stdout)
        XCTAssertNil(reports.first?["tokenPresent"])
    }

    // MARK: Real mode — parsed session id MUST reach agentctl (§3.10)

    /// Installs a stub `agentctl` that appends its argv one-per-line to the
    /// file named by $ATERM_TEST_ARGV_CAPTURE, then runs the shim in REAL
    /// mode (no DRY_RUN) through it.
    private func runShimCapturingArgv(
        _ shimPath: String,
        environment: [String: String],
        payloadArgument: String? = nil,
        stdin: String? = nil
    ) throws -> [String] {
        let stubPath = NSTemporaryDirectory() + "/stub-agentctl-\(UUID().uuidString).sh"
        try "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"$ATERM_TEST_ARGV_CAPTURE\"\ndone\n"
            .write(toFile: stubPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
        defer { try? FileManager.default.removeItem(atPath: stubPath) }

        let capturePath = NSTemporaryDirectory() + "/argv-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: capturePath) }

        var env = environment.filter { $0.key != "AGENT_TERMINAL_DRY_RUN" }
        env["AGENT_TERMINAL_AGENTCTL"] = stubPath
        env["ATERM_TEST_ARGV_CAPTURE"] = capturePath

        let argv = payloadArgument != nil ? ["/bin/sh", shimPath, payloadArgument!] : ["/bin/sh", shimPath]
        let result = try runShell(argv, environment: env, stdin: stdin)
        XCTAssertEqual(result.exitCode, 0, "shim must always exit 0; stdout: \(result.stdout)")
        guard FileManager.default.fileExists(atPath: capturePath) else { return [] }
        return String(decoding: FileManager.default.contents(atPath: capturePath)!, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    func testClaudeShimForwardsSessionReferenceToRealAgentctl() throws {
        let argv = try runShimCapturingArgv(
            claudeShimPath,
            environment: shimEnvironment(),
            stdin: #"{"hook_event_name":"Stop","session_id":"sess-42"}"#
        )
        // agentctl parses --session-reference as JSON (a bare id is rejected),
        // so the shim must forward the same object shape the dry-run builds.
        let referenceIndex = try XCTUnwrap(argv.firstIndex(of: "--session-reference"))
        let referenceValue = argv[argv.index(after: referenceIndex)]
        let reference = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(referenceValue.utf8)) as? [String: Any],
            "session reference must be a JSON object: \(referenceValue)"
        )
        XCTAssertEqual(reference["agentKind"] as? String, "claude-code")
        XCTAssertEqual(reference["opaquePayload"] as? String, "sess-42")
        XCTAssertEqual(reference["capturedAtRevision"] as? Int, 0)
        // Lifecycle still forwarded alongside identity.
        let lifecycleIndex = try XCTUnwrap(argv.firstIndex(of: "--lifecycle"))
        XCTAssertEqual(argv[argv.index(after: lifecycleIndex)], "idle")
    }

    func testCodexShimForwardsSessionReferenceToRealAgentctlAndCombinesLifecycle() throws {
        let argv = try runShimCapturingArgv(
            codexShimPath,
            environment: shimEnvironment(),
            payloadArgument: #"{"type":"agent-turn-complete","thread-id":"thr-7"}"#
        )
        let referenceIndex = try XCTUnwrap(argv.firstIndex(of: "--session-reference"))
        let referenceValue = argv[argv.index(after: referenceIndex)]
        let reference = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(referenceValue.utf8)) as? [String: Any],
            "session reference must be a JSON object: \(referenceValue)"
        )
        XCTAssertEqual(reference["agentKind"] as? String, "codex")
        XCTAssertEqual(reference["opaquePayload"] as? String, "thr-7",
                       "identity and lifecycle travel in the SAME report (§3.10)")
        XCTAssertEqual(reference["capturedAtRevision"] as? Int, 0)
        let lifecycleIndex = try XCTUnwrap(argv.firstIndex(of: "--lifecycle"))
        XCTAssertEqual(argv[argv.index(after: lifecycleIndex)], "idle")
    }

    // MARK: Monotonic seq rules (§3.6)

    func testSequenceCounterIsMonotonicPerAgentAcrossInvocations() throws {
        // One shared state dir across invocations — that's the whole point.
        let sharedStateDir = scratchStateDir
        func env(agentID: String) -> [String: String] {
            var environment = shimEnvironment(agentID: agentID)
            environment["AGENT_TERMINAL_SEQ_STATE_DIR"] = sharedStateDir
            return environment
        }
        for expected in [1, 2, 3] {
            let result = try runShell(
                ["/bin/sh", claudeShimPath],
                environment: env(agentID: "agent-it"),
                stdin: #"{"hook_event_name":"Stop"}"#
            )
            XCTAssertEqual(result.exitCode, 0)
            let reports = try parseNDJSONLines(result.stdout)
            XCTAssertEqual(reports.first?["seq"] as? Int, expected)
        }
        // A different agent gets its own counter.
        let other = try runShell(
            ["/bin/sh", codexShimPath, "{}"],
            environment: env(agentID: "agent-two")
        )
        let otherReports = try parseNDJSONLines(other.stdout)
        XCTAssertEqual(otherReports.first?["seq"] as? Int, 1)
    }

    func testShimExitsZeroEvenWithoutAgentContext() throws {
        // Safety law: the shim must never break the host CLI.
        let result = try runShell(["/bin/sh", claudeShimPath], environment: ["AGENT_TERMINAL_DRY_RUN": "1"], stdin: "")
        XCTAssertEqual(result.exitCode, 0)
        _ = try parseNDJSONLines(result.stdout)
    }

    // MARK: Validator — self-test execution (§3.17 step 9)

    func testValidatorSelfTestPassesOnRealShimsAndFailsOnGarbage() throws {
        let good = IntegrationValidator.runSelfTest(scriptPath: claudeShimPath, environment: shimEnvironment())
        XCTAssertTrue(good.succeeded, "\(good.diagnostics)")
        XCTAssertEqual(good.reports.count, 1)

        let garbageScript = NSTemporaryDirectory() + "/garbage-\(UUID().uuidString).sh"
        try "#!/bin/sh\necho definitely-not-json\n".write(toFile: garbageScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: garbageScript) }

        let failing = IntegrationValidator.runSelfTest(scriptPath: garbageScript, environment: [:])
        XCTAssertFalse(failing.succeeded)
        XCTAssertTrue(failing.diagnostics.contains { $0.contains("non-JSON") })
    }

    // MARK: Validator — corrupted config rejection (§3.17 step 6)

    func testValidatorRejectsCorruptedConfigsOfEveryFormat() {
        XCTAssertFalse(IntegrationValidator.validateSyntax(#"{"broken": "#,
                                                           format: .json).isValid)
        XCTAssertFalse(IntegrationValidator.validateSyntax("[table\nkey =", format: .toml).isValid)
        XCTAssertFalse(IntegrationValidator.validateSyntax("function f( {", format: .javaScript).isValid)
        XCTAssertFalse(IntegrationValidator.validateSyntax("", format: .javaScript).isValid)

        XCTAssertTrue(IntegrationValidator.validateSyntax(#"{"fine": []}"#, format: .json).isValid)
        XCTAssertTrue(IntegrationValidator.validateSyntax("[a]\nb = 1\n", format: .toml).isValid)

        let unbalanced = IntegrationValidator.validateSyntax("export const x = (() => {", format: .javaScript)
        XCTAssertFalse(unbalanced.isValid)
        XCTAssertTrue(unbalanced.diagnostics.contains { $0.contains("unclosed") || $0.contains("node") })
    }

    func testValidatorSelfTestDetectsTokenLeak() throws {
        let leakyScript = NSTemporaryDirectory() + "/leaky-\(UUID().uuidString).sh"
        try "#!/bin/sh\nprintf '%s\\n' '{\"token\":\"super-secret\"}'\n".write(
            toFile: leakyScript,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: leakyScript) }

        let result = IntegrationValidator.runSelfTest(
            scriptPath: leakyScript,
            environment: ["AGENT_TERMINAL_TOKEN": "super-secret"]
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("token") })
    }

    // MARK: Round 17 — JS comment-scanner FSM (7dfa094)

    /// E1: inside `inBlockComment` everything is skipped until `*/`; the
    /// opener is armed ONLY by `previous == "/"` + `*`. Under the pre-fix FSM
    /// the closer OPENED the comment state, so this input yielded
    /// `"unclosed (("` from a bracket-scanned interior.
    ///
    /// Assertion discipline: never `isValid` — the node --check block folds
    /// machine-dependent noise into the verdict; the structural diagnostics
    /// are computed unconditionally before it.
    func testBlockCommentInteriorIsNeverBracketScanned() {
        let result = IntegrationValidator.validateSyntax("/* (( */", format: .javaScript)
        XCTAssertFalse(
            result.diagnostics.contains { $0.hasPrefix("unclosed") },
            "comment interior was bracket-scanned: \(result.diagnostics)"
        )
        XCTAssertFalse(
            result.diagnostics.contains { $0.contains("unbalanced") },
            "comment interior was bracket-scanned: \(result.diagnostics)"
        )
    }

    /// E2: after `*/` consumes the closer, scanning RESUMES — real brackets
    /// after a block comment are depth-tracked. Line comments stay immune to
    /// the same class of drift.
    func testCodeAfterBlockCommentIsScannedAndLineCommentsStayImmune() {
        // Pre-fix FSM skipped everything after `*/` and produced no
        // diagnostic here — the exact silent-skip defect.
        let afterBlock = IntegrationValidator.validateSyntax("/* header */ function f( {", format: .javaScript)
        XCTAssertTrue(
            afterBlock.diagnostics.contains { $0.hasPrefix("unclosed ") },
            "post-comment code was skipped by the scanner: \(afterBlock.diagnostics)"
        )

        // Line-comment control: interior ignored, post-comment code counted.
        let afterLine = IntegrationValidator.validateSyntax("// (( \n function g( {", format: .javaScript)
        XCTAssertTrue(
            afterLine.diagnostics.contains { $0.hasPrefix("unclosed ") },
            "line-comment arm drifted: \(afterLine.diagnostics)"
        )
    }

    // MARK: P1 — opencode plugin seq lock: bounded retry, nil-seq fallback

    /// Locates node the same opportunistic way IntegrationValidator does.
    private func locateNode() -> String? {
        for candidate in ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
            where FileManager.default.isExecutableFile(atPath: candidate)
        {
            return candidate
        }
        for directory in ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? [] {
            let candidate = directory + "/node"
            if FileManager.default.isExecutableFile(atPath: String(candidate)) {
                return String(candidate)
            }
        }
        return nil
    }

    /// When `<agentID>.lock` already exists, the plugin's five `wx` attempts
    /// fail and the report OMITS `seq` entirely (nil sequences bypass the
    /// ledger duplicate rule; a 0-fallback would get real reports silently
    /// dropped). Critically, the `finally` unlink belongs ONLY to the acquired
    /// branch — a foreign holder's lock file must survive the plugin run.
    func testHeldSeqLockFallsBackToNilSeqAndNeverDeletesForeignLock() throws {
        guard let node = locateNode() else {
            throw XCTSkip("node unavailable; the plugin's seq-lock behavior cannot be executed")
        }
        let stateDir = scratchStateDir
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let lockPath = stateDir + "/agent-it.lock"
        try Data("foreign-holder".utf8).write(to: URL(fileURLWithPath: lockPath))

        var environment = shimEnvironment(agentID: "agent-it")
        environment["AGENT_TERMINAL_SEQ_STATE_DIR"] = stateDir
        let result = try runShell([node, openCodePluginPath], environment: environment)

        XCTAssertEqual(result.exitCode, 0, "contention must never break the host: stdout \(result.stdout)")
        let reports = try parseNDJSONLines(result.stdout)
        let report = try XCTUnwrap(reports.first)

        XCTAssertNil(
            report["seq"],
            "seq must be OMITTED under contention (not 0, not 1), got \(String(describing: report["seq"]))"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath), "the foreign lock must survive")
        XCTAssertEqual(
            try String(contentsOfFile: lockPath, encoding: .utf8),
            "foreign-holder",
            "the plugin must never delete or rewrite a lock it does not own"
        )
    }

    // MARK: MED — seq lock ownership: pid-marked release, stale-break safety

    /// A stale lock (mtime beyond the 10s grace window) now carries the old
    /// holder's pid marker, so the breaker must remove the WHOLE directory —
    /// a plain rmdir would fail on the non-empty dir and permanently wedge
    /// ordering. After the break the shim must acquire, increment and
    /// release cleanly.
    func testStaleLockWithPidMarkerIsBrokenAsWholeDirAndOrderingResumes() throws {
        let stateDir = scratchStateDir
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let lockPath = stateDir + "/agent-it.lock"
        try FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: true)
        try Data("999999\n".utf8).write(to: URL(fileURLWithPath: lockPath + "/pid"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lockPath
        )

        var environment = shimEnvironment(agentID: "agent-it")
        environment["AGENT_TERMINAL_SEQ_STATE_DIR"] = stateDir
        let result = try runShell(
            ["/bin/sh", claudeShimPath],
            environment: environment,
            stdin: #"{"hook_event_name":"Stop"}"#
        )

        XCTAssertEqual(result.exitCode, 0)
        let reports = try parseNDJSONLines(result.stdout)
        XCTAssertEqual(reports.first?["seq"] as? Int, 1, "breaking the stale lock must restore ordering")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath),
                       "the reacquired-and-released lock dir must be gone")
    }

    /// A LIVE-looking holder (fresh mtime, foreign pid marker) must survive
    /// the shim run untouched: budget-out degrades to omit-seq and the shim
    /// never deletes a lock it does not own — otherwise a holder whose lock
    /// merely LOOKS stale would clobber the breaker's replacement.
    func testLiveForeignLockSurvivesShimRunWithOmitSeq() throws {
        let stateDir = scratchStateDir
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let lockPath = stateDir + "/agent-it.lock"
        try FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: true)
        try Data("424242\n".utf8).write(to: URL(fileURLWithPath: lockPath + "/pid"))

        var environment = shimEnvironment(agentID: "agent-it")
        environment["AGENT_TERMINAL_SEQ_STATE_DIR"] = stateDir
        let result = try runShell(
            ["/bin/sh", claudeShimPath],
            environment: environment,
            stdin: #"{"hook_event_name":"Stop"}"#
        )

        XCTAssertEqual(result.exitCode, 0, "contention must never break the host CLI")
        let reports = try parseNDJSONLines(result.stdout)
        XCTAssertNil(
            reports.first?["seq"],
            "budget-out must omit seq, got \(String(describing: reports.first?["seq"]))"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath), "the foreign lock must survive")
        XCTAssertEqual(try String(contentsOfFile: lockPath + "/pid", encoding: .utf8),
                       "424242\n", "the foreign holder's pid marker must be untouched")
    }
}

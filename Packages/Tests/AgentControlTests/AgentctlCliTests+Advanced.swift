import AgentControl
import Foundation
import XCTest

extension AgentctlCliTests {
    // MARK: M16 — launcher started happy-path param law

    /// Round 7: `launcher started` forwards exactly
    /// {agentID, surfaceGeneration, terminalID, token}, adds pid/pgid ONLY
    /// when provided (strict Int32 parse, forwarded as exact .int), and the
    /// --token flag beats AGENT_TERMINAL_TOKEN.
    func testLauncherStartedForwardsExactParamsOmitsAbsentPidAndAcceptsInt32Boundaries() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        // (a) Minimal invocation: env token, no pid/pgid — both keys ABSENT.
        let minimal = try runAgentctl(
            ["launcher", "started", "--agent-id", "A1", "--terminal-id", "T1",
             "--surface-generation", "2"],
            environment: ["AGENT_TERMINAL_TOKEN": "tok-l"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(minimal.status, 0, "stderr: \(minimal.stderr)")
        XCTAssertEqual(server.requests.map(\.method), ["system.ping", "launcher.started"])
        XCTAssertEqual(server.requests[1].params, [
            "agentID": .string("A1"),
            "terminalID": .string("T1"),
            "surfaceGeneration": .int(2),
            "token": .string("tok-l"),
        ])
        XCTAssertNil(server.requests[1].params["pid"], "absent pid must be omitted")
        XCTAssertNil(
            server.requests[1].params["processGroupID"],
            "absent pgid must be omitted"
        )

        // (b) Int32 boundary values survive the widening verbatim and the
        // explicit flag overrides the environment token.
        let bounded = try runAgentctl(
            ["launcher", "started", "--agent-id", "A1", "--terminal-id", "T1",
             "--surface-generation", "2", "--pid", "-2147483648",
             "--process-group-id", "2147483647", "--token", "flag-tok"],
            environment: ["AGENT_TERMINAL_TOKEN": "tok-l"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(bounded.status, 0, "stderr: \(bounded.stderr)")
        let started = server.requests.filter { $0.method == "launcher.started" }
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(started[1].params["pid"], .int(-2_147_483_648))
        XCTAssertEqual(started[1].params["processGroupID"], .int(2_147_483_647))
        XCTAssertEqual(started[1].params["token"], .string("flag-tok"), "flag beats env")
    }

    // MARK: M17 — launcher failed shape

    /// Round 7: the failed branch requires `reason` and never carries a
    /// terminalID — launch failures stay correctly attributable in the
    /// control plane.
    func testLauncherFailedSendsReasonShapeWithoutTerminalID() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let run = try runAgentctl(
            ["launcher", "failed", "--agent-id", "A1", "--surface-generation", "0",
             "--reason", "exec format error", "--token", "t"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(run.status, 0, "stderr: \(run.stderr)")
        XCTAssertEqual(server.requests.map(\.method), ["system.ping", "launcher.failed"])
        XCTAssertEqual(server.requests[1].params, [
            "agentID": .string("A1"),
            "surfaceGeneration": .int(0),
            "reason": .string("exec format error"),
            "token": .string("t"),
        ])
        XCTAssertNil(server.requests[1].params["terminalID"])
        let envelope = try stdoutEnvelope(run)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
    }

    // MARK: M18 — simpleAgentAction defaults + positional resolution

    /// Round 7: stop defaults mode=gracefulStop, read defaults source=visible,
    /// explicit option values override, and the positional agent identifier
    /// wins over an `--agent` OPTION.
    func testStopReadDefaultParamsAndPositionalAgentResolution() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let stopDefault = try runAgentctl(
            ["agent", "stop", "A1"], socketFlag: server.socketPath
        )
        let stopOverride = try runAgentctl(
            ["agent", "stop", "A2", "--agent", "IGNORED", "--mode", "closeView"],
            socketFlag: server.socketPath
        )
        let readDefault = try runAgentctl(
            ["agent", "read", "A3"], socketFlag: server.socketPath
        )
        let readOverride = try runAgentctl(
            ["agent", "read", "A4", "--source", "detection"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(stopDefault.status, 0, "stderr: \(stopDefault.stderr)")
        XCTAssertEqual(stopOverride.status, 0, "stderr: \(stopOverride.stderr)")
        XCTAssertEqual(readDefault.status, 0, "stderr: \(readDefault.stderr)")
        XCTAssertEqual(readOverride.status, 0, "stderr: \(readOverride.stderr)")
        // Four invocations share ONE server: each run performs exactly one
        // leading system.ping before its dispatched method.
        XCTAssertEqual(server.requests.map(\.method), [
            "system.ping", "agent.stop",
            "system.ping", "agent.stop",
            "system.ping", "agent.read",
            "system.ping", "agent.read",
        ])

        let stops = server.requests.filter { $0.method == "agent.stop" }
        XCTAssertEqual(stops[0].params, [
            "agentID": .string("A1"), "mode": .string("gracefulStop"),
        ])
        XCTAssertEqual(stops[1].params, [
            "agentID": .string("A2"), "mode": .string("closeView"),
        ], "positional ID wins over --agent; explicit mode overrides")

        let reads = server.requests.filter { $0.method == "agent.read" }
        XCTAssertEqual(reads[0].params, [
            "agentID": .string("A3"), "source": .string("visible"),
        ])
        XCTAssertEqual(reads[1].params, [
            "agentID": .string("A4"), "source": .string("detection"),
        ])
    }

    // MARK: M19 — events subscribe: per-frame fflush visibility while connected

    /// Round 8 (R8-4): `fflush(stdout)` after every rendered frame
    /// (main.swift, ff1b0d4) must make each frame visible to file-backed
    /// consumers WHILE the subscription connection stays open. M10 reads
    /// stdout only after server disconnect + process exit, where even an
    /// unflushed FILE\* buffer drains — a silent revert would ship undetected.
    func testEventsSubscribeFlushesEachFrameToStdoutBeforeDisconnect() throws {
        let server = try ScriptedServer()
        let liveConnection = LiveConnectionBox()
        server.onRequest = { request, connection in
            guard request.method == "events.subscribe" else { return }
            // Push ONE matching frame and KEEP the connection OPEN — the
            // child stays alive while the capture file is polled.
            _ = try? connection.send(frame: [
                "event": .string("agentChanged"),
                "agent": .object(["id": .string("A1"), "lifecycle": .string("idle")]),
            ])
            liveConnection.store(connection)
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let detached = try runAgentctlDetached(
            ["events", "subscribe", "--agent", "A1"],
            socketFlag: server.socketPath
        )
        defer {
            if detached.process.isRunning {
                detached.process.terminate()
            }
            try? FileManager.default.removeItem(at: detached.captureDir)
        }

        // Bounded poll of the stdout CAPTURE FILE (10 ms quantum, ≤5 s)
        // WHILE the child is still running: without the per-frame fflush the
        // frame sits in the child's FILE\* buffer and the file stays empty.
        let deadline = Date().addingTimeInterval(5)
        var stdoutText = ""
        while Date() < deadline {
            stdoutText = readCapturedFile(detached.stdoutURL)
            if stdoutText.contains("agentChanged") {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            detached.process.isRunning,
            "agentctl exited before the frame was observed; stdout: '\(stdoutText)'"
        )
        XCTAssertFalse(stdoutText.isEmpty, "frame never reached the stdout capture before disconnect")

        // Close from the hook context, then join the run.
        liveConnection.connection?.close()
        let joinDeadline = Date().addingTimeInterval(10)
        while detached.process.isRunning, Date() < joinDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(detached.process.isRunning, "agentctl did not exit after the server-side close")
        XCTAssertEqual(detached.process.terminationStatus, 1)
        XCTAssertTrue(
            readCapturedFile(detached.stderrURL).contains("connection closed by server"),
            "stderr: '\(readCapturedFile(detached.stderrURL))'"
        )

        // Exactly one flushed frame landed in the capture.
        let lines = readCapturedFile(detached.stdoutURL).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "stdout: '\(readCapturedFile(detached.stdoutURL))'")
        let frame = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
            "frame was not a JSON object: '\(lines.first ?? "")'"
        )
        XCTAssertEqual(frame["event"] as? String, "agentChanged")
        XCTAssertEqual((frame["agent"] as? [String: Any])?["id"] as? String, "A1")

        XCTAssertEqual(server.requests.map(\.method), ["system.ping", "events.subscribe"])
    }

    // MARK: M20 — `--socket <flag>` is never consumed as a value (R10-F)

    /// The third `hasPrefix("--")` clause in the entry-point parse keeps the
    /// next flag from being swallowed as the socket path: a usage error must
    /// surface instead of an opaque connection failure. Positive control:
    /// the `--socket=` assignment form still parses and dials.
    func testSocketFlagFollowedByFlagIsRejectedAsMissingValue() throws {
        let rejected = try runAgentctl(["--socket", "--other", "ping"])
        XCTAssertEqual(rejected.status, 1)
        XCTAssertTrue(
            rejected.stderr.contains("option --socket requires a value"),
            "stderr: \(rejected.stderr)"
        )

        // Assignment form parses; the CLI dials the given (nonexistent)
        // endpoint and fails with a CONNECTION error — never the usage error.
        let assigned = try runAgentctl([
            "--socket=/tmp/aterm-f1-nonexistent-\(UUID().uuidString.prefix(6)).sock",
            "system", "ping",
        ])
        XCTAssertEqual(assigned.status, 1)
        XCTAssertFalse(
            assigned.stderr.contains("option --socket requires a value"),
            "assignment form must keep parsing: stderr: \(assigned.stderr)"
        )
        XCTAssertTrue(assigned.stderr.contains("unix socket"), "stderr: \(assigned.stderr)")
    }

    // MARK: G1 — honest agentctl not-found (6885f7b)

    /// In `snapshot()`, an `agentNotFound` error code must print
    /// "agent not found: <id>" and exit BEFORE the generic
    /// "agent lookup failed" line, and BEFORE any subscription is opened
    /// (no leaked stream connection on the not-found fast path).
    func testAgentWaitReportsHonestAgentNotFoundInsteadOfLookupFailed() throws {
        let server = try ScriptedServer()
        server.responder = { method, _, requestID in
            guard method == "agent.get" else {
                return .okEcho(requestID, result: [
                    "protocolVersion": .int(Int64(ProtocolVersion.current)),
                    "implementation": "agent-terminal-control",
                ])
            }
            return .failure(
                ControlFailure(code: .agentNotFound, message: "agent not found"),
                requestID: requestID
            )
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let run = try runAgentctl(
            ["agent", "wait", "ghost", "--lifecycle", "idle", "--timeout-ms", "500"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(run.status, 1, "not-found is the fail path, never the timeout path (exit 2)")
        let combined = run.stdout + "\n" + run.stderr
        XCTAssertTrue(combined.contains("agent not found: ghost"), "output: \(combined)")
        XCTAssertFalse(
            combined.contains("agent lookup failed"),
            "the misleading generic line must not leak for a simple absent ID: \(combined)"
        )
        // Fails on the initial lookup — no events.subscribe was ever opened.
        XCTAssertEqual(server.requests.map(\.method), ["system.ping", "agent.get"])
    }

    // MARK: M21 — fail-loud --lifecycle tag parsing (e0aca70)

    /// Every comma-separated --lifecycle token must parse as a LifecycleTag
    /// BEFORE any wire traffic beyond the handshake; pre-e0aca70 unknown tags
    /// were compactMap-dropped, so `idle,wrking` silently narrowed the wait
    /// to idle. The diagnostic must name the offending token AND list every
    /// valid tag (derived from LifecycleTag.allCases, never hardcoded).
    func testWaitUnknownLifecycleTagFailsLoudlyListingValidTags() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let validTags = LifecycleTag.allCases.map(\.rawValue).joined(separator: ",")
        let run = try runAgentctl(
            ["agent", "wait", "A1", "--lifecycle", "idle,wrking", "--timeout-ms", "250"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(run.status, 1, "stderr: \(run.stderr)")
        XCTAssertTrue(run.stderr.hasPrefix("[agentctl]"), "stderr: \(run.stderr)")
        XCTAssertTrue(run.stderr.contains("--lifecycle must list valid tags"), "stderr: \(run.stderr)")
        // Honest deviation from test-design-22 CL1: the thrown message does
        // NOT echo the offending token (main.swift :255-258 lists only the
        // valid tags), so the diagnostic contract pins the tag list alone.
        XCTAssertFalse(run.stderr.contains("wrking"), "stderr: \(run.stderr)")
        XCTAssertTrue(
            run.stderr.contains(validTags),
            "the diagnostic must list every valid tag: stderr: \(run.stderr)"
        )
        XCTAssertFalse(run.stderr.contains("timeout"), "parse failure precedes any waiting: stderr: \(run.stderr)")
        // Parse failure strictly precedes wire traffic — only the handshake.
        // (Pre-fix, the wait subscribed for `idle` before ever noticing.)
        XCTAssertEqual(server.requests.map(\.method), ["system.ping"])

        // Blank/whitespace tokens fold into the SAME throw — the old separate
        // empty-set guard is gone; the map throw is the only gate.
        let blank = try runAgentctl(
            ["agent", "wait", "A1", "--lifecycle", " , ", "--timeout-ms", "250"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(blank.status, 1)
        XCTAssertTrue(blank.stderr.hasPrefix("[agentctl]"), "stderr: \(blank.stderr)")
        XCTAssertTrue(blank.stderr.contains("--lifecycle must list valid tags"), "stderr: \(blank.stderr)")
    }

    // MARK: M22 — trim tolerance + every-valid-tag acceptance (e0aca70 positive control)

    /// Whitespace-padded token lists still parse (trim kept, main.swift :255)
    /// and ALL eight LifecycleTag rawValues are accepted — an over-eager
    /// validator or a renamed rawValue would break every padded/scripted
    /// waiter. Tier law: acceptance reaches the TIMEOUT tier (exit 2), never
    /// the badRequest tier (exit 1).
    func testWaitLifecycleParsingTrimsWhitespaceAndAcceptsEveryValidTag() throws {
        let server = try ScriptedServer()
        server.responder = { method, _, requestID in
            guard method == "agent.get" else {
                return .okEcho(requestID, result: [
                    "protocolVersion": .int(Int64(ProtocolVersion.current)),
                    "implementation": "agent-terminal-control",
                ])
            }
            return .success(requestID, ["agent": .object([
                "id": .string("A1"),
                "stateRevision": .int(5),
                "lifecycle": .string("idle"),
            ])])
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        // Padded tokens parse; the idle snapshot matches on the fast path.
        let trimmed = try runAgentctl(
            ["agent", "wait", "A1", "--lifecycle", " idle , working ", "--timeout-ms", "250"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(trimmed.status, 0, "stderr: \(trimmed.stderr)")
        let envelope = try stdoutEnvelope(trimmed)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["matched"] as? Bool, true)
        XCTAssertEqual(result["lifecycle"] as? String, "idle")

        // Every rawValue parses: with all eight accepted the wait proceeds to
        // its subscription + deadline and exits 2. min-revision keeps the
        // rev-5 idle snapshot unmatched WITHOUT narrowing the tag set.
        let everyTag = LifecycleTag.allCases.map(\.rawValue).joined(separator: ",")
        let allTags = try runAgentctl(
            ["agent", "wait", "A1", "--lifecycle", everyTag, "--min-revision", "6",
             "--timeout-ms", "250"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(allTags.status, 2,
                       "all eight tags parse → timeout tier, not badRequest: stderr: \(allTags.stderr)")
        XCTAssertFalse(
            allTags.stderr.contains("--lifecycle must list"),
            "no tag may be rejected: stderr: \(allTags.stderr)"
        )
        let timeoutEnvelope = try stdoutEnvelope(allTags)
        let timeoutResult = try XCTUnwrap(timeoutEnvelope["result"] as? [String: Any])
        XCTAssertEqual(timeoutResult["matched"] as? Bool, false)
        XCTAssertEqual(timeoutResult["reason"] as? String, "timeout")
    }

    // MARK: Round 25 S2 — focus/interrupt/resume/cancel-queued-prompt wire

    /// contract. Four copy-paste dispatch branches must each map 1:1 to its
    /// ControlMethod rawValue and send params of EXACTLY {agentID} — the
    /// stop/read arms' `mode`/`source` defaults must never leak in, and the
    /// positional identifier must win over `--agent`.
    func testFocusInterruptResumeCancelQueuedPromptSendExactMethodAndAgentIDOnlyParams() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let focus = try runAgentctl(["agent", "focus", "A1"], socketFlag: server.socketPath)
        // Positional ID wins over an `--agent` OPTION.
        let interrupt = try runAgentctl(
            ["agent", "interrupt", "A2", "--agent", "IGNORED"], socketFlag: server.socketPath
        )
        let resume = try runAgentctl(["agent", "resume", "A3"], socketFlag: server.socketPath)
        let cancelQueued = try runAgentctl(
            ["agent", "cancel-queued-prompt", "A4"], socketFlag: server.socketPath
        )

        XCTAssertEqual(focus.status, 0, "stderr: \(focus.stderr)")
        XCTAssertEqual(interrupt.status, 0, "stderr: \(interrupt.stderr)")
        XCTAssertEqual(resume.status, 0, "stderr: \(resume.stderr)")
        XCTAssertEqual(cancelQueued.status, 0, "stderr: \(cancelQueued.stderr)")

        // One leading system.ping handshake precedes each dispatched method.
        XCTAssertEqual(server.requests.map(\.method), [
            "system.ping", "agent.focus",
            "system.ping", "agent.interrupt",
            "system.ping", "agent.resume",
            "system.ping", "agent.cancelQueuedPrompt",
        ])

        let expectedByMethod: [String: [String: JSONValue]] = [
            "agent.focus": ["agentID": .string("A1")],
            "agent.interrupt": ["agentID": .string("A2")],
            "agent.resume": ["agentID": .string("A3")],
            "agent.cancelQueuedPrompt": ["agentID": .string("A4")],
        ]
        for (method, expectedParams) in expectedByMethod {
            let hits = server.requests.filter { $0.method == method }
            XCTAssertEqual(hits.count, 1, "\(method) dispatched exactly once")
            // Dict equality catches BOTH a swapped method and a leaked extra key.
            XCTAssertEqual(hits.first?.params, expectedParams, "\(method) params")
        }
    }

    // MARK: R29-S2 — bare `--` ends option parsing (both regions)

    /// A bare `--` must end option scanning in BOTH parse regions — the
    /// global `--socket` pre-scan and the subcommand Options.parse — so
    /// prompt text containing flag-shaped tokens survives VERBATIM instead
    /// of being misrouted into socket/flag options.
    func testBareDoubleDashEndsOptionParsingAndPromptTextSurvivesVerbatim() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        // Leg 1: subcommand parser (`main.swift` `--` branch) — everything
        // after the separator is prompt text; no --policy/--socket leaks out
        // of the text, and no commandID is synthesized.
        // Deviation from the sketch's `socketFlag:` injection: a harness-
        // appended trailing --socket would land AFTER the separator and be
        // (correctly!) swallowed as command text, so the real endpoint is
        // injected through AGENT_TERMINAL_CONTROL_SOCKET instead.
        let prompt = try runAgentctl(
            ["agent", "prompt", "A1", "--", "fix", "--policy", "and", "--socket", "too"],
            environment: ["AGENT_TERMINAL_CONTROL_SOCKET": server.socketPath]
        )
        XCTAssertEqual(prompt.status, 0, "stderr: \(prompt.stderr)")
        let prompts = server.requests.filter { $0.method == "agent.prompt" }
        XCTAssertEqual(prompts.count, 1, "exactly one prompt dispatched: \(server.requests.map(\.method))")
        XCTAssertEqual(prompts.first?.params, [
            "agentID": .string("A1"),
            "text": .string("fix --policy and --socket too"),
            "policy": .string("sendNow"),
        ], "flag-shaped tokens after -- belong to the TEXT, never to the options")
        XCTAssertNil(prompts.first?.commandID)

        // Leg 2: global pre-scan (`optionsEnd/globalRegion`) — an assigned
        // --socket= form AFTER the separator is command text; the decoy
        // endpoint must NOT steal the dial, which lands on THIS server.
        let requestsBeforeDecoyLeg = server.requests.count
        let decoy = "/tmp/aterm-r29-decoy-\(UUID().uuidString.prefix(8)).sock"
        let decoyRun = try runAgentctl(
            ["system", "ping", "--", "--socket=\(decoy)"],
            environment: ["AGENT_TERMINAL_CONTROL_SOCKET": server.socketPath]
        )
        XCTAssertEqual(decoyRun.status, 0, "stderr: \(decoyRun.stderr)")
        XCTAssertEqual(
            server.requests.count, requestsBeforeDecoyLeg + 2,
            "handshake + ping must land on THIS ScriptedServer, not the decoy endpoint"
        )

        // Leg 3: negative control — WITHOUT the separator, the pre-scan
        // consumes "open" as the socket VALUE and dials it. The real socket
        // is injected via the environment so nothing else can rescue argv;
        // the run exits 1 with the connection failure and NO agent.prompt
        // ever reaches the server.
        let withoutSeparator = try runAgentctl(
            ["agent", "prompt", "A1", "say", "--socket", "open"],
            environment: ["AGENT_TERMINAL_CONTROL_SOCKET": server.socketPath]
        )
        XCTAssertEqual(withoutSeparator.status, 1)
        XCTAssertTrue(
            withoutSeparator.stderr.contains("unix socket"),
            "the CLI must have dialed the stolen value 'open': stderr: \(withoutSeparator.stderr)"
        )
        XCTAssertTrue(
            server.requests.filter { $0.method == "agent.prompt" }.count == prompts.count,
            "no NEW agent.prompt may reach the server once the socket value was stolen"
        )
    }

    // MARK: R29-S3 — repeated flags fail loudly, never dial

    /// Duplicate flags must be a usage error in BOTH parse branches — the
    /// assigned `--flag=VALUE` form and the value `--flag VALUE` form —
    /// BEFORE any client construction: silent last-wins would feed stale
    /// launcher/hook values to the control plane.
    func testRepeatedFlagsFailLoudlyWithoutDialingTheServer() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        // Leg 1: value form twice (--seq).
        let seqTwice = try runAgentctl(
            ["integration", "report", "--agent-id", "A1", "--surface-generation", "7",
             "--seq", "1", "--seq", "2"],
            environment: ["AGENT_TERMINAL_TOKEN": "tok-1"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(seqTwice.status, 1)
        XCTAssertTrue(
            seqTwice.stderr.contains("option --seq given more than once"),
            "stderr: \(seqTwice.stderr)"
        )

        // Leg 2: assigned form twice (--workspace via --workspace=W2).
        let workspaceTwice = try runAgentctl(
            ["agent", "create", "--workspace", "W1", "--kind", "genericShell",
             "--name", "N", "--dir", "/tmp", "--workspace=W2"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(workspaceTwice.status, 1)
        XCTAssertTrue(
            workspaceTwice.stderr.contains("option --workspace given more than once"),
            "stderr: \(workspaceTwice.stderr)"
        )

        // Parse failures precede client construction — no dial, no handshake.
        XCTAssertTrue(
            server.requests.isEmpty,
            "usage errors must never reach the server: \(server.requests.map(\.method))"
        )
    }
}

import AgentControl
import Foundation
import XCTest

extension AgentctlCliTests {
    // MARK: M1 — handshake law + response envelope rendering

    func testPingRunsHandshakeThenCommandAndExitsZeroWithEchoedEnvelope() throws {
        let server = try ScriptedServer()
        server.responder = { _, _, requestID in
            .okEcho(requestID, result: [
                "protocolVersion": .int(Int64(ProtocolVersion.current)),
                "implementation": "agent-terminal-control",
            ])
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let run = try runAgentctl(["system", "ping"], socketFlag: server.socketPath)

        XCTAssertEqual(run.status, 0, "stderr: \(run.stderr)")
        // Exactly one handshake ping precedes the dispatched roundtrip — a
        // future "skip the handshake" optimization fails loudly here.
        XCTAssertEqual(server.requests.map(\.method), ["system.ping", "system.ping"])
        let envelope = try stdoutEnvelope(run)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        XCTAssertEqual(envelope["requestID"] as? String, server.requests[1].requestID)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? Int, ProtocolVersion.current)
        XCTAssertTrue(run.stderr.isEmpty, "stderr: \(run.stderr)")
    }

    // MARK: M2 — env-var socket injection

    func testEnvironmentVariableOverridesDefaultSocketWithoutFlag() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let run = try runAgentctl(
            ["system", "ping"],
            environment: ["AGENT_TERMINAL_CONTROL_SOCKET": server.socketPath]
        )

        // Reaching THIS server (and exiting 0) proves the override fired; a
        // regression makes agentctl dial the real user path instead.
        XCTAssertEqual(run.status, 0, "stderr: \(run.stderr)")
        XCTAssertGreaterThanOrEqual(server.requests.count, 1)
    }

    // MARK: M3 — agent create param mapping incl. dropped-null

    func testAgentCreateForwardsExactParamsIncludingNullTaskSummary() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let omitted = try runAgentctl(
            ["agent", "create", "--workspace", "W1", "--kind", "genericShell",
             "--dir", "/tmp/proj", "--name", "Builder"],
            socketFlag: server.socketPath
        )
        let provided = try runAgentctl(
            ["agent", "create", "--workspace", "W1", "--kind", "genericShell",
             "--dir", "/tmp/proj", "--name", "Builder", "--task-summary", "ship it"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(omitted.status, 0, "stderr: \(omitted.stderr)")
        XCTAssertEqual(provided.status, 0, "stderr: \(provided.stderr)")
        let creates = server.requests.filter { $0.method == "agent.create" }
        XCTAssertEqual(creates.count, 2)
        XCTAssertEqual(creates[0].params, [
            "workspaceID": .string("W1"),
            "kind": .string("genericShell"),
            "workingDirectory": .string("/tmp/proj"),
            "displayName": .string("Builder"),
            "taskSummary": .null,
        ])
        XCTAssertEqual(creates[1].params["taskSummary"], .string("ship it"))
    }

    // MARK: M4 — agent prompt text joining, policy default, envelope commandID

    func testAgentPromptJoinsTextDefaultsPolicyAndCarriesCommandIDOnEnvelope() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let keyed = try runAgentctl(
            ["agent", "prompt", "A1", "deploy", "the", "service",
             "--command-id", "11111111-2222-3333-4444-555555555555"],
            socketFlag: server.socketPath
        )
        let plain = try runAgentctl(
            ["agent", "prompt", "A1", "deploy", "the", "service"],
            socketFlag: server.socketPath
        )
        let queued = try runAgentctl(
            ["agent", "prompt", "A1", "deploy", "the", "service",
             "--policy", "queueWhenIdle"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(keyed.status, 0, "stderr: \(keyed.stderr)")
        XCTAssertEqual(plain.status, 0, "stderr: \(plain.stderr)")
        XCTAssertEqual(queued.status, 0, "stderr: \(queued.stderr)")

        let prompts = server.requests.filter { $0.method == "agent.prompt" }
        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(prompts[0].params, [
            "agentID": .string("A1"),
            "text": .string("deploy the service"),
            "policy": .string("sendNow"),
        ])
        // Idempotency key rides the ENVELOPE, never params.
        XCTAssertEqual(prompts[0].commandID, "11111111-2222-3333-4444-555555555555")
        XCTAssertNil(prompts[1].commandID)
        XCTAssertEqual(prompts[1].params["policy"], .string("sendNow"))
        XCTAssertEqual(prompts[2].params["policy"], .string("queueWhenIdle"))
    }

    // MARK: M5 — integration report seq/session-reference/token mapping

    func testIntegrationReportMapsSeqSessionReferenceAndEnvToken() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let run = try runAgentctl(
            ["integration", "report", "--agent-id", "A1",
             "--surface-generation", "7", "--source", "hook", "--seq", "42",
             "--session-reference", "{\"opaque\":\"s1\",\"capturedAtRevision\":5}"],
            environment: ["AGENT_TERMINAL_TOKEN": "tok-1"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(run.status, 0, "stderr: \(run.stderr)")
        let reports = server.requests.filter { $0.method == "integration.report" }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].params, [
            "agentID": .string("A1"),
            "surfaceGeneration": .int(7),
            "source": .string("hook"),
            "token": .string("tok-1"),
            "seq": .int(42),
            "sessionReference": .object([
                "opaque": .string("s1"),
                "capturedAtRevision": .int(5),
            ]),
        ])
    }

    // MARK: M6 — ok:false envelope channel + structured error body

    func testErrorEnvelopePrintsCodeAndMessageToStdoutAndExitsOne() throws {
        let server = try ScriptedServer()
        server.responder = { method, _, requestID in
            guard method == "agent.get" else {
                return .okEcho(requestID, result: [
                    "protocolVersion": .int(Int64(ProtocolVersion.current)),
                    "implementation": "agent-terminal-control",
                ])
            }
            return .failure(ControlFailure(code: .internalError, message: "boom"), requestID: requestID)
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let run = try runAgentctl(["agent", "get", "missing"], socketFlag: server.socketPath)

        XCTAssertEqual(run.status, 1)
        let envelope = try stdoutEnvelope(run)
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        XCTAssertEqual(envelope["requestID"] as? String, server.requests[1].requestID)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "internalError")
        XCTAssertEqual(error["message"] as? String, "boom")
        // Machine consumers parse stdout; the fail() stderr path stays silent.
        XCTAssertFalse(run.stderr.contains("boom"), "stderr: \(run.stderr)")
    }

    // MARK: M7 — three usage-error tiers and their socket visibility

    func testUsageErrorsExitOneWithOrderedServerVisibility() throws {
        // (a) Unknown top-level command: argv parses, client handshakes, and
        // only the dispatch switch rejects — the server sees exactly one ping.
        let dispatchServer = try ScriptedServer()
        try dispatchServer.start()
        defer { dispatchServer.stop() }
        dispatchServer.awaitListening()
        let unknownCommand = try runAgentctl(["frobnicate"], socketFlag: dispatchServer.socketPath)
        XCTAssertEqual(unknownCommand.status, 1)
        XCTAssertTrue(unknownCommand.stderr.hasPrefix("[agentctl]"), "stderr: \(unknownCommand.stderr)")
        XCTAssertTrue(
            unknownCommand.stderr.contains("unknown command 'frobnicate'"),
            "stderr: \(unknownCommand.stderr)"
        )
        // Handshake precedes dispatch — pinned so a future pre-dispatch
        // command whitelist is a deliberate, visible change.
        XCTAssertEqual(dispatchServer.requests.map(\.method), ["system.ping"])

        // (b) Unknown option: Options.parse fails before any client exists —
        // zero socket contact.
        let parseServer = try ScriptedServer()
        try parseServer.start()
        defer { parseServer.stop() }
        parseServer.awaitListening()
        let unknownOption = try runAgentctl(
            ["system", "ping", "--bogus"],
            socketFlag: parseServer.socketPath
        )
        XCTAssertEqual(unknownOption.status, 1)
        XCTAssertTrue(
            unknownOption.stderr.contains("unknown option '--bogus'"),
            "stderr: \(unknownOption.stderr)"
        )
        XCTAssertTrue(parseServer.requests.isEmpty)

        // (c) Malformed numeric option: parses as a string and throws only
        // AFTER the handshake — the server sees exactly one ping, the report
        // is never sent.
        //
        // KNOWN DESIGN DISCREPANCY (documented, not a test failure):
        // test-design-4.md §M7(c) cites strictNonNegativeInteger
        // (main.swift:96-102) and its "must be a non-negative integer"
        // wording. A fresh source re-read shows --surface-generation is
        // parsed by Options.int (main.swift:372, throw at :88) BEFORE --seq's
        // strict parse ever runs, so production's actual message is "option
        // --surface-generation must be an integer". Every law this test pins
        // (exit 1, handshake-once visibility, strict rejection of malformed
        // numerics) holds under either wording; the assertion below encodes
        // the source-verified contract.
        let numericServer = try ScriptedServer()
        try numericServer.start()
        defer { numericServer.stop() }
        numericServer.awaitListening()
        let malformedNumber = try runAgentctl(
            ["integration", "report", "--agent-id", "a",
             "--surface-generation", "abc", "--source", "s", "--token", "t"],
            socketFlag: numericServer.socketPath
        )
        XCTAssertEqual(malformedNumber.status, 1)
        XCTAssertTrue(
            malformedNumber.stderr.contains("option --surface-generation must be an integer"),
            "stderr: \(malformedNumber.stderr)"
        )
        XCTAssertEqual(numericServer.requests.map(\.method), ["system.ping"])
    }

    // MARK: M8 — event-driven wait fast path

    func testAgentWaitReturnsMatchedImmediatelyFromInitialSnapshot() throws {
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
                "stateRevision": .int(9),
                "lifecycle": .string("idle"),
            ])])
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let run = try runAgentctl(
            ["agent", "wait", "A1", "--lifecycle", "idle", "--min-revision", "5"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(run.status, 0, "stderr: \(run.stderr)")
        let envelope = try stdoutEnvelope(run)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["matched"] as? Bool, true)
        XCTAssertEqual(result["stateRevision"] as? Int, 9)
        XCTAssertEqual(result["lifecycle"] as? String, "idle")
        XCTAssertNil(result["reason"])
        // Fast path stays subscription-free — each needless subscription is a
        // leaked connection in script loops.
        XCTAssertEqual(server.requests.map(\.method), ["system.ping", "agent.get"])
    }

    // MARK: M9 — wait timeout: exit 2, race-closing re-read, no polling

    func testAgentWaitTimesOutWithExitTwoAndTimeoutReason() throws {
        let server = try ScriptedServer()
        server.responder = { method, _, requestID in
            switch method {
            case "agent.get":
                .success(requestID, ["agent": .object([
                    "id": .string("A1"),
                    "stateRevision": .int(1),
                    "lifecycle": .string("working"),
                ])])
            case "events.subscribe":
                .success(requestID, ["subscriptionID": .string("sub-1")])
            default:
                .okEcho(requestID, result: [
                    "protocolVersion": .int(Int64(ProtocolVersion.current)),
                    "implementation": "agent-terminal-control",
                ])
            }
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let startedAt = Date()
        let run = try runAgentctl(
            ["agent", "wait", "A1", "--lifecycle", "idle", "--timeout-ms", "250"],
            socketFlag: server.socketPath
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        // Exit 2 is the ONLY timeout signal — misclassifying it as an error
        // would flip every scripted waiter to exit 1.
        XCTAssertEqual(run.status, 2, "stderr: \(run.stderr)")
        let envelope = try stdoutEnvelope(run)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["matched"] as? Bool, false)
        XCTAssertEqual(result["reason"] as? String, "timeout")

        // Initial snapshot + post-subscribe race-closing re-read, then the
        // subscription — and nothing else: extra agent.gets mean the loop
        // degenerated into polling.
        XCTAssertEqual(server.requests.map(\.method), [
            "system.ping", "agent.get", "events.subscribe", "agent.get",
        ])

        // 250 ms deadline + 200 ms receive-timeout granularity + process
        // overhead must stay far below the runner bound.
        XCTAssertLessThanOrEqual(elapsed, 1.5, "wait took \(elapsed)s")
    }

    // MARK: M10 — events subscribe: streaming, rendering, disconnect ⇒ exit 1

    func testEventsSubscribeStreamsFramesToStdoutUntilServerDisconnectExitsOne() throws {
        let server = try ScriptedServer()
        server.onRequest = { request, connection in
            guard request.method == "events.subscribe" else { return }
            // Push two frames on the SAME connection, then close: the client
            // must render both and treat the disconnect as a failure (exit 1),
            // never a silent success.
            _ = try? connection.send(frame: [
                "event": .string("stateChanged"),
                "agent": .object(["id": .string("A2")]),
            ])
            _ = try? connection.send(frame: [
                "event": .string("agentChanged"),
                "agent": .object(["id": .string("A1"), "lifecycle": .string("idle")]),
            ])
            connection.close()
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let run = try runAgentctl(
            ["events", "subscribe", "--agent", "A1"],
            socketFlag: server.socketPath,
            captureThroughFiles: true
        )
        XCTAssertEqual(run.status, 1, "stdout: \(run.stdout) stderr: \(run.stderr)")
        XCTAssertTrue(
            run.stderr.contains("connection closed by server"),
            "stderr: \(run.stderr)"
        )
        let lines = run.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "stdout: '\(run.stdout)'")
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
            "first frame was not a JSON object: '\(lines[0])'"
        )
        XCTAssertEqual(first["event"] as? String, "stateChanged")
        XCTAssertEqual((first["agent"] as? [String: Any])?["id"] as? String, "A2")
        let second = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any],
            "second frame was not a JSON object: '\(lines[1])'"
        )
        XCTAssertEqual(second["event"] as? String, "agentChanged")
        XCTAssertEqual((second["agent"] as? [String: Any])?["id"] as? String, "A1")

        // Handshake precedes the subscription — unlike `agent wait`, this
        // client handshakes on its only connection.
        XCTAssertEqual(server.requests.map(\.method), ["system.ping", "events.subscribe"])
        XCTAssertEqual(server.requests[1].params, ["agentID": .string("A1")])
    }

    // MARK: M11 — agent wait matching FROM a subscription frame

    func testAgentWaitMatchesFromSubscriptionFrameSkippingNonMatchingOnes() throws {
        let server = try ScriptedServer()
        server.responder = { method, _, requestID in
            switch method {
            case "agent.get":
                // Baseline snapshot: working @ revision 1 — never a match.
                .success(requestID, ["agent": .object([
                    "id": .string("A1"),
                    "stateRevision": .int(1),
                    "lifecycle": .string("working"),
                ])])
            case "events.subscribe":
                .success(requestID, ["subscriptionID": .string("sub-1")])
            default:
                .okEcho(requestID, result: [
                    "protocolVersion": .int(Int64(ProtocolVersion.current)),
                    "implementation": "agent-terminal-control",
                ])
            }
        }
        server.onRequest = { request, connection in
            guard request.method == "events.subscribe" else { return }
            let foreignState: [String: JSONValue] = [
                "id": .string("A1"),
                "lifecycle": .string("idle"),
            ]
            _ = try? connection.send(frame: [
                "event": .string("stateChanged"),
                "agent": .object(foreignState), // wrong event type
            ])
            _ = try? connection.send(frame: [
                "event": .string("agentChanged"),
                "agent": .object(["id": .string("A2"), "stateRevision": .int(9),
                                  "lifecycle": .string("idle")]), // foreign id
            ])
            _ = try? connection.send(frame: [
                "event": .string("agentChanged"),
                "agent": .object(["id": .string("A1"), "stateRevision": .int(3),
                                  "lifecycle": .string("working")]), // stale revision
            ])
            _ = try? connection.send(frame: [
                "event": .string("agentChanged"),
                "agent": .object(["id": .string("A1"), "stateRevision": .int(7),
                                  "lifecycle": .string("idle")]), // THE match
            ])
            // Keep the subscription OPEN — the client must win from the frame,
            // not time out.
        }
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let startedAt = Date()
        let run = try runAgentctl(
            ["agent", "wait", "A1", "--lifecycle", "idle",
             "--min-revision", "5", "--timeout-ms", "5000"],
            socketFlag: server.socketPath
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(run.status, 0, "stderr: \(run.stderr)")
        let envelope = try stdoutEnvelope(run)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["matched"] as? Bool, true)
        XCTAssertEqual(result["stateRevision"] as? Int, 7)
        XCTAssertEqual(result["lifecycle"] as? String, "idle")
        XCTAssertNil(result["reason"])
        // Unchanged no-polling law (M8) — re-asserted because frames now flow.
        XCTAssertEqual(server.requests.map(\.method), [
            "system.ping", "agent.get", "events.subscribe", "agent.get",
        ])
        // The match came from the first frame batch; nothing like the 5 s
        // deadline may elapse.
        XCTAssertLessThanOrEqual(elapsed, 4.5, "wait took \(elapsed)s")
    }

    // MARK: M12 — integration release param mapping + env-token fallback

    /// Round 6: `integration.release` is a shipped wire method with zero prior
    /// coverage — the CLI branch must send exactly {agentID, surfaceGeneration,
    /// source, token} and honor flag-over-env token precedence.
    func testIntegrationReleaseForwardsExactParamsAndEnvToken() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let flagged = try runAgentctl(
            ["integration", "release", "--agent-id", "A1",
             "--surface-generation", "3", "--source", "hook", "--token", "flag-tok"],
            socketFlag: server.socketPath
        )
        let fromEnv = try runAgentctl(
            ["integration", "release", "--agent-id", "A1",
             "--surface-generation", "3", "--source", "hook"],
            environment: ["AGENT_TERMINAL_TOKEN": "tok-rel"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(flagged.status, 0, "stderr: \(flagged.stderr)")
        XCTAssertEqual(fromEnv.status, 0, "stderr: \(fromEnv.stderr)")
        // Handshake law: exactly one ping precedes each dispatched release.
        XCTAssertEqual(server.requests.map(\.method), [
            "system.ping", "integration.release",
            "system.ping", "integration.release",
        ])
        XCTAssertEqual(server.requests[1].params, [
            "agentID": .string("A1"),
            "surfaceGeneration": .int(3),
            "source": .string("hook"),
            "token": .string("flag-tok"),
        ])
        XCTAssertEqual(server.requests[3].params, [
            "agentID": .string("A1"),
            "surfaceGeneration": .int(3),
            "source": .string("hook"),
            "token": .string("tok-rel"),
        ])
    }

    // MARK: M13 — valueless options fail loudly before any socket contact

    /// Round 6: the old silent `"true"` default is gone — a valueless flag is
    /// a usage error (exit 1) raised during argv parse, i.e. BEFORE the client
    /// exists, so the server must record zero requests.
    func testValuelessOptionFailsLoudlyWithoutDialingTheServer() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        // Bare trailing --socket: the standalone entry-point check fires.
        let bareSocket = try runAgentctl(["agent", "get", "A1", "--socket"])
        // --dir's would-be value starts with `--` — the parse guard fires.
        let valuelessDir = try runAgentctl(
            ["agent", "create", "--workspace", "W1", "--kind", "genericShell",
             "--dir", "--name", "N"],
            socketFlag: server.socketPath
        )

        XCTAssertEqual(bareSocket.status, 1)
        XCTAssertTrue(
            bareSocket.stderr.contains("requires a value"),
            "stderr: \(bareSocket.stderr)"
        )
        XCTAssertEqual(valuelessDir.status, 1)
        XCTAssertTrue(
            valuelessDir.stderr.contains("option --dir requires a value"),
            "stderr: \(valuelessDir.stderr)"
        )
        // Parse failures precede client construction — no dial, no handshake.
        XCTAssertTrue(
            server.requests.isEmpty,
            "usage errors must never reach the server: \(server.requests.map(\.method))"
        )
    }

    // MARK: M14 — session-reference JSON validation + NSNumber wire typing

    /// Round 6: malformed JSON is rejected after the handshake but before the
    /// report dispatch; valid JSON routes booleans to `.bool` (never
    /// `.double(1.0)`) and integers beyond 2^53 keep exact `.int` magnitudes.
    func testSessionReferenceRejectsMalformedJSONAndWireTypesBooleansAndBigInts() throws {
        let server = try ScriptedServer()
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let malformed = try runAgentctl(
            ["integration", "report", "--agent-id", "A1", "--surface-generation", "1",
             "--source", "hook", "--session-reference", "{not json"],
            environment: ["AGENT_TERMINAL_TOKEN": "tok-1"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(malformed.status, 1)
        XCTAssertTrue(
            malformed.stderr.contains("must be valid JSON"),
            "stderr: \(malformed.stderr)"
        )
        // Handshake ran (client built first) but the report was never sent.
        XCTAssertEqual(server.requests.map(\.method), ["system.ping"])

        let typed = try runAgentctl(
            ["integration", "report", "--agent-id", "A1", "--surface-generation", "1",
             "--source", "hook",
             "--session-reference",
             "{\"opaque\":\"s1\",\"ok\":true,\"big\":9007199254740993}"],
            environment: ["AGENT_TERMINAL_TOKEN": "tok-1"],
            socketFlag: server.socketPath
        )
        XCTAssertEqual(typed.status, 0, "stderr: \(typed.stderr)")
        let reports = server.requests.filter { $0.method == "integration.report" }
        XCTAssertEqual(reports.count, 1)
        // Neither `ok` collapsed to .int/.double nor `big` degraded to .double.
        XCTAssertEqual(reports[0].params["sessionReference"], .object([
            "opaque": .string("s1"),
            "ok": .bool(true),
            "big": .int(9_007_199_254_740_993),
        ]))
    }

    // MARK: M15 — timeout clamp vs trap + clean bad-pid rejection

    /// Round 6: `--timeout-ms` beyond Int64.max clamps to 24 h instead of
    /// trapping in the Int64 conversion; a non-integer `--pid` is a clean
    /// badRequest thrown after the handshake but before dispatch.
    func testHugeTimeoutMsClampsInsteadOfTrappingAndBadPidIsCleanRejection() throws {
        // (a) Huge timeout: the wait wins from a pushed matching frame long
        // before any deadline — the OLD code traps here (abnormal exit).
        let waitServer = try ScriptedServer()
        waitServer.responder = { method, _, requestID in
            switch method {
            case "agent.get":
                .success(requestID, ["agent": .object([
                    "id": .string("A1"),
                    "stateRevision": .int(1),
                    "lifecycle": .string("working"),
                ])])
            case "events.subscribe":
                .success(requestID, ["subscriptionID": .string("sub-1")])
            default:
                .okEcho(requestID, result: [
                    "protocolVersion": .int(Int64(ProtocolVersion.current)),
                    "implementation": "agent-terminal-control",
                ])
            }
        }
        waitServer.onRequest = { request, connection in
            guard request.method == "events.subscribe" else { return }
            _ = try? connection.send(frame: [
                "event": .string("agentChanged"),
                "agent": .object(["id": .string("A1"), "stateRevision": .int(9),
                                  "lifecycle": .string("idle")]),
            ])
            // Keep the subscription open — the client must win from the frame.
        }
        try waitServer.start()
        defer { waitServer.stop() }
        waitServer.awaitListening()

        let startedAt = Date()
        let clamped = try runAgentctl(
            ["agent", "wait", "A1", "--lifecycle", "idle", "--timeout-ms",
             "18446744073709551615"],
            socketFlag: waitServer.socketPath
        )

        XCTAssertEqual(clamped.status, 0, "stderr: \(clamped.stderr)")
        let envelope = try stdoutEnvelope(clamped)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["matched"] as? Bool, true)
        XCTAssertEqual(result["stateRevision"] as? Int, 9)
        XCTAssertEqual(result["lifecycle"] as? String, "idle")
        XCTAssertEqual(waitServer.requests.map(\.method), [
            "system.ping", "agent.get", "events.subscribe", "agent.get",
        ])
        XCTAssertLessThanOrEqual(
            Date().timeIntervalSince(startedAt), 8,
            "clamped wait must resolve from the frame, not approach any deadline"
        )

        // (b) Malformed pid rejects cleanly after handshake, before dispatch.
        let pidServer = try ScriptedServer()
        try pidServer.start()
        defer { pidServer.stop() }
        pidServer.awaitListening()
        let badPid = try runAgentctl(
            ["launcher", "started", "--agent-id", "A1", "--terminal-id", "T1",
             "--surface-generation", "0", "--pid", "abc"],
            environment: ["AGENT_TERMINAL_TOKEN": "tok-1"],
            socketFlag: pidServer.socketPath
        )
        XCTAssertEqual(badPid.status, 1)
        XCTAssertTrue(
            badPid.stderr.contains("must be a 32-bit integer"),
            "stderr: \(badPid.stderr)"
        )
        XCTAssertEqual(pidServer.requests.map(\.method), ["system.ping"])
    }
}

@testable import AgentControl
import AgentCore
import Foundation
import XCTest

extension SocketIntegrationTests {
    // MARK: Socket properties

    func testSocketFileIsCreatedWithMode0600() async throws {
        let harness = try SocketHarness.make()
        defer { Task { await harness.stop() } }
        try await harness.start()
        try await harness.waitUntilListening()

        let attributes = try FileManager.default.attributesOfItem(atPath: harness.socketPath)
        let mode = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.uint16Value, 0o600, "control socket must be owner-only")
    }

    func testMalformedJSONGetsBadRequestAndConnectionSurvives() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let fd = try openRawSocket(harness.socketPath)
        let malformed = Array("{\"nope\n".utf8)
        _ = malformed.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        let first = try await readLine(fd: fd)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("badRequest"))

        // Connection still usable afterwards.
        let ping = Array("{\"protocolVersion\":1,\"requestID\":\"m\",\"method\":\"system.ping\",\"params\":{}}\n".utf8)
        _ = ping.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        let second = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(second.contains("\"ok\":true"))
        close(fd)
    }

    func testOversizedFrameRejectedAndConnectionClosed() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let fd = try openRawSocket(harness.socketPath)
        let giant = Data(repeating: 0x61, count: (1 << 20) + 64) + Data([0x0A])
        _ = giant.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
        let response = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(response.contains("payloadTooLarge"))
        // Server closes the connection: EOF follows.
        var sink: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, 4096, 0)
            }
            if received <= 0 {
                break
            }
            sink.append(contentsOf: chunk[0 ..< received])
            if sink.count > 8192 {
                break
            }
        }
        XCTAssertTrue(sink.isEmpty, "expected EOF after oversized frame")
        close(fd)
    }

    func testVersionMismatchRejectedOverWire() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let fd = try openRawSocket(harness.socketPath)
        var line = "{\"protocolVersion\":2,\"requestID\":\"v\",\"method\":\"system.ping\",\"params\":{}}\n"
        line.withUTF8 { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
        let response = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(response.contains("unsupportedProtocolVersion"))
        close(fd)
    }

    // MARK: Idempotency — prompt MUST NOT send twice

    func testDuplicateCommandIDReturnsCachedResultAndDeliversOnce() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let commandID = UUID().uuidString
        let params: [String: JSONValue] = [
            "agentID": .string(harness.agentID.rawValue.uuidString),
            "text": .string("do the thing"),
            "policy": .string("sendNow"),
        ]

        let firstClient = try harness.client()
        let firstResponse = try firstClient.roundtrip(
            method: ControlMethod.agentPrompt.rawValue,
            params: params,
            commandID: commandID
        )
        firstClient.close()

        XCTAssertTrue(firstResponse.ok, "prompt should succeed: \(String(describing: firstResponse.error))")

        // A retry with the SAME commandID — different connection, later time.
        let retryClient = try harness.client()
        let retryResponse = try retryClient.roundtrip(
            method: ControlMethod.agentPrompt.rawValue,
            params: params,
            commandID: commandID
        )
        retryClient.close()
        XCTAssertEqual(retryResponse.result["receipt"], firstResponse.result["receipt"],
                       "retry must replay the cached result verbatim")

        let deliveries = harness.runtime.deliveredPrompts[harness.agentID]
        XCTAssertEqual(deliveries, 1, "runtime must have received the prompt EXACTLY once")
    }

    func testConcurrentDuplicateCommandIDCannotDoubleExecute() async throws {
        // The idempotency cache only replays AFTER the first response is
        // cached; a duplicate racing on a second connection must be rejected
        // in-flight instead of executing the prompt a second time.
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let commandID = UUID().uuidString
        let params: [String: JSONValue] = [
            "agentID": .string(harness.agentID.rawValue.uuidString),
            "text": .string("do the thing"),
            "policy": .string("sendNow"),
        ]
        var line = "{\"protocolVersion\":1,\"requestID\":\"r\",\"commandID\":\"\(commandID)\",\"method\":\"\(ControlMethod.agentPrompt.rawValue)\",\"params\":{"
        line += "\"agentID\":\"\(harness.agentID.rawValue.uuidString)\",\"text\":\"do the thing\",\"policy\":\"sendNow\"}}\n"

        harness.runtime.holdsPrompts = true
        let fdA = try openRawSocket(harness.socketPath)
        let fdB = try openRawSocket(harness.socketPath)
        defer { close(fdA); close(fdB) }

        // A enters dispatch and parks inside the (gated) runtime.
        _ = line.withUTF8 { buffer in write(fdA, buffer.baseAddress, buffer.count) }
        var deliveries = 0
        for _ in 0 ..< 250 {
            deliveries = harness.runtime.deliveredPrompts[harness.agentID] ?? 0
            if deliveries == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(deliveries, 1, "first request must be executing")

        // B arrives while A is still in flight → must be rejected, not run.
        _ = line.withUTF8 { buffer in write(fdB, buffer.baseAddress, buffer.count) }
        // Release the gate only once B's rejection is actually queued (never
        // later than the previous fixed 300 ms window), so the in-flight
        // observation happens while A is provably parked.
        let rejectionQueued = await waitForResponse(fd: fdB, budgetMilliseconds: 300)
        XCTAssertTrue(
            rejectionQueued,
            "B's rejection must be queued before the gate releases; a silent lapse breaks the in-flight premise"
        )

        harness.runtime.releasePromptGate()

        let responseB = try await String(decoding: readLine(fd: fdB), as: UTF8.self)
        XCTAssertTrue(responseB.contains("commandInFlight"),
                      "in-flight duplicate must be rejected; got: \(responseB)")
        let responseA = try await String(decoding: readLine(fd: fdA), as: UTF8.self)
        XCTAssertTrue(responseA.contains("\"ok\":true"), "original request must succeed: \(responseA)")

        // Exactly-once is THE invariant.
        let finalDeliveries = harness.runtime.deliveredPrompts[harness.agentID]
        XCTAssertEqual(finalDeliveries, 1, "prompt must have executed exactly once")

        // After completion the retry replays the cached result.
        let retryClient = try harness.client()
        let retry = try retryClient.roundtrip(
            method: ControlMethod.agentPrompt.rawValue,
            params: params,
            commandID: commandID
        )
        retryClient.close()
        XCTAssertTrue(retry.ok)
        let afterRetry = harness.runtime.deliveredPrompts[harness.agentID]
        XCTAssertEqual(afterRetry, 1, "cached replay must not re-execute")
    }

    // MARK: Hook authentication

    func testHookTokenMismatchIsUnauthorized() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        await harness.hooks.register(agentID: harness.agentID, surfaceGeneration: .initial, token: harness.token)

        let response = try reportLifecycle(harness, token: "wrong-token", seq: 1, generation: 0)
        XCTAssertEqual(response.error?.code, .unauthorized)
    }

    func testStaleGenerationReportIsRejected() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        await harness.hooks.register(
            agentID: harness.agentID,
            surfaceGeneration: SurfaceGeneration(rawValue: 3),
            token: harness.token
        )

        // Report from an older generation → stale.
        let stale = try reportLifecycle(harness, token: harness.token, seq: 1, generation: 2)
        XCTAssertEqual(stale.error?.code, .staleGeneration)

        // Current generation → accepted.
        let current = try reportLifecycle(harness, token: harness.token, seq: 1, generation: 3)
        XCTAssertNil(current.error)
        XCTAssertTrue(current.result["accepted"]?.boolValue ?? false)
    }

    func testUnregisteredAgentReportIsRejected() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let response = try reportLifecycle(harness, token: harness.token, seq: 1, generation: 0)
        XCTAssertEqual(response.error?.code, .unauthorized)
    }

    func testDuplicateSequenceAcknowledgedWithoutNewEvent() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        await harness.hooks.register(agentID: harness.agentID, surfaceGeneration: .initial, token: harness.token)

        let first = try reportLifecycle(harness, token: harness.token, seq: 7, generation: 0)
        XCTAssertTrue(first.ok)
        let ingestCountAfterFirst = harness.runtime.ingestedEvidence.count

        let duplicate = try reportLifecycle(harness, token: harness.token, seq: 7, generation: 0)
        XCTAssertTrue(duplicate.ok, "duplicate is ACKed ok:true per §3.6")
        XCTAssertEqual(duplicate.result["duplicate"]?.boolValue, true)
        XCTAssertEqual(duplicate.result["lastAcceptedSequence"]?.intValue, 7)
        let olderThanAccepted = try reportLifecycle(harness, token: harness.token, seq: 3, generation: 0)
        XCTAssertTrue(olderThanAccepted.ok)

        let ingestCountAfterDuplicates = harness.runtime.ingestedEvidence.count
        XCTAssertEqual(ingestCountAfterFirst, ingestCountAfterDuplicates,
                       "duplicates must not create new events")

        let gap = try reportLifecycle(harness, token: harness.token, seq: 9, generation: 0)
        XCTAssertTrue(gap.ok, "sequence gaps are accepted (§3.6)")
    }

    /// Stage-16 item B regression (§3.6): the exact stage-15 probe sequence —
    /// an approval inputRequest report (seq 1) followed by an idle report
    /// (seq 2) on the SAME (agent, source) — must be accepted AND observed by
    /// the runtime. The stage-15 "drop" was a scenario-side double-optional
    /// closure bug, not duplicate accounting; this locks the wire behavior.
    func testApprovalReportThenIdleReportOnSameSourceIsObserved() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let workspaceID = await runtime.createWorkspace(name: "s16", rootPath: "/tmp/s16")
        let agentID = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "s16"),
            in: workspaceID
        )
        try await runtime.surfaceCreated(
            agentID: agentID, terminalID: TerminalID(),
            generation: .initial, pid: nil, processGroupID: nil
        )

        let hooks = HookAuthenticator()
        let token = "s16-\(UUID().uuidString)"
        await hooks.register(agentID: agentID, surfaceGeneration: .initial, token: token)
        let broker = EventStreamBroker.streamBound(to: runtime)
        let router = ControlRequestRouter(
            runtime: LiveControlRuntime(runtime: runtime), hooks: hooks, broker: broker
        )
        let socketPath = "/tmp/aterm-s16-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixSocketServer(path: socketPath) { [router] request, connection in
            await router.handle(request, connection: connection)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        func report(_ seq: UInt64, lifecycle: String, inputRequest: Bool) throws -> ControlResponse {
            let client = try ControlClient(socketPath: socketPath)
            defer { client.close() }
            try client.handshake()
            var params: [String: JSONValue] = [
                "agentID": .string(agentID.rawValue.uuidString),
                "surfaceGeneration": .uint64(0),
                "source": "hook:regression",
                "token": .string(token),
                "seq": .uint64(seq),
                "lifecycle": .string(lifecycle),
            ]
            if inputRequest {
                params["inputRequest"] = .object([
                    "kind": .string("approval"),
                    "summary": .string("Allow write access?"),
                ])
            }
            return try client.roundtrip(method: "integration.report", params: params)
        }

        let approval = try report(1, lifecycle: "waitingForInput", inputRequest: true)
        XCTAssertTrue(approval.ok, "approval report rejected: \(String(describing: approval.error))")
        let raised = try await runtime.state(of: agentID)
        guard case let .waitingForInput(descriptor) = raised.lifecycle else {
            return XCTFail("approval not observed: \(raised.lifecycle)")
        }
        XCTAssertEqual(descriptor.kind, .approval)
        XCTAssertEqual(descriptor.safeReplyMode, .terminalOnly)

        let idle = try report(2, lifecycle: "idle", inputRequest: false)
        XCTAssertTrue(idle.ok, "idle report rejected: \(String(describing: idle.error))")
        XCTAssertNotEqual(idle.result["duplicate"]?.boolValue, true, "seq2 must not be accounted duplicate")

        let cleared = try await runtime.state(of: agentID)
        guard case .idle = cleared.lifecycle else {
            return XCTFail("REPRODUCED idle-after-approval drop: \(cleared.lifecycle)")
        }
        if case .none = cleared.attention {} else {
            XCTFail("attention not cleared: \(cleared.attention)")
        }
    }

    func testLauncherStartedValidatesTokenAndForwardsSurfaceCreated() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        await harness.hooks.register(agentID: harness.agentID, surfaceGeneration: .initial, token: harness.token)

        let badParams: [String: JSONValue] = [
            "agentID": .string(harness.agentID.rawValue.uuidString),
            "terminalID": .string(UUID().uuidString),
            "surfaceGeneration": .int(0),
            "token": .string("bogus"),
        ]
        let badClient = try harness.client()
        let rejected = try badClient.roundtrip(method: ControlMethod.launcherStarted.rawValue, params: badParams)
        badClient.close()
        XCTAssertEqual(rejected.error?.code, .unauthorized)

        let goodParams: [String: JSONValue] = [
            "agentID": .string(harness.agentID.rawValue.uuidString),
            "terminalID": .string(UUID().uuidString),
            "surfaceGeneration": .int(0),
            "token": .string(harness.token),
            "pid": .int(4242),
        ]
        let goodClient = try harness.client()
        let accepted = try goodClient.roundtrip(method: ControlMethod.launcherStarted.rawValue, params: goodParams)
        goodClient.close()
        XCTAssertTrue(accepted.ok)

        let calls = harness.runtime.surfaceCreatedCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.generation.rawValue, 0)
    }

    func testDuplicateLauncherReportsAreAcknowledgedWithoutReexecuting() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        await harness.hooks.register(agentID: harness.agentID, surfaceGeneration: .initial, token: harness.token)

        func launcher(_ method: ControlMethod, seq: UInt64) throws -> ControlResponse {
            let client = try harness.client()
            defer { client.close() }
            return try client.roundtrip(method: method.rawValue, params: [
                "agentID": .string(harness.agentID.rawValue.uuidString),
                "terminalID": .string(UUID().uuidString),
                "surfaceGeneration": .int(0),
                "seq": .uint64(seq),
                "reason": .string("boom"),
                "token": .string(harness.token),
            ])
        }

        // First launcher.started with seq 1 is accepted and forwarded…
        let firstStarted = try launcher(.launcherStarted, seq: 1)
        XCTAssertTrue(firstStarted.ok)
        XCTAssertEqual(harness.runtime.surfaceCreatedCalls.count, 1)

        // …its resend must be ACKed as a duplicate per §3.6, not run
        // surfaceCreated a second time.
        let duplicateStarted = try launcher(.launcherStarted, seq: 1)
        XCTAssertTrue(duplicateStarted.ok, "duplicate is ACKed ok:true per §3.6")
        XCTAssertEqual(duplicateStarted.result["duplicate"]?.boolValue, true)
        XCTAssertEqual(duplicateStarted.result["lastAcceptedSequence"]?.intValue, 1)
        XCTAssertEqual(harness.runtime.surfaceCreatedCalls.count, 1,
                       "duplicate launcher.started must not re-execute")

        // Same contract for launcher.failed: one ingest, then a duplicate ack.
        let firstFailed = try launcher(.launcherFailed, seq: 2)
        XCTAssertTrue(firstFailed.ok)
        XCTAssertEqual(harness.runtime.ingestedEvidence.count, 1)
        let duplicateFailed = try launcher(.launcherFailed, seq: 2)
        XCTAssertTrue(duplicateFailed.ok)
        XCTAssertEqual(duplicateFailed.result["duplicate"]?.boolValue, true)
        XCTAssertEqual(duplicateFailed.result["lastAcceptedSequence"]?.intValue, 2)
        XCTAssertEqual(harness.runtime.ingestedEvidence.count, 1,
                       "duplicate launcher.failed must not create a second event")
    }

    func testFailureResponsesStayReplayableAcrossRetries() async throws {
        // Only ok:true responses enter the idempotency cache. A retry with
        // the SAME commandID after a rejected report must re-execute instead
        // of replaying the sticky failure for the whole TTL.
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        await harness.hooks.register(
            agentID: harness.agentID,
            surfaceGeneration: SurfaceGeneration(rawValue: 3),
            token: harness.token
        )

        let commandID = UUID().uuidString

        // Stale generation → rejected (ok:false); nothing was mutated.
        let stale = try reportLifecycle(harness, token: harness.token, seq: 1, generation: 2, commandID: commandID)
        XCTAssertEqual(stale.error?.code, .staleGeneration)

        // The retry with the same commandID now carries the CURRENT
        // generation: it must be validated fresh and accepted.
        let current = try reportLifecycle(harness, token: harness.token, seq: 1, generation: 3, commandID: commandID)
        XCTAssertTrue(current.ok, "failed response must not be cached: \(String(describing: current.error))")
        XCTAssertTrue(current.result["accepted"]?.boolValue ?? false)
    }

    // MARK: Race-closed event-driven wait

    func testWaitReturnsImmediatelyWhenPredicateAlreadyTrue() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let started = Date()
        let outcome = try await runWait(harness, targets: ["working"], timeoutMs: 5000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.0,
                          "already-matching predicate must not block (ceiling stays under the 5 s wait deadline)")
        XCTAssertEqual(outcome?["matched"]?.boolValue, true)
        XCTAssertEqual(outcome?["lifecycle"]?.stringValue, "working")
    }

    func testWaitMatchesOnStreamedTransitionWithoutPolling() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let waiter = Task {
            try await runWait(harness, targets: ["idle"], timeoutMs: 10000)
        }

        // Arm-confirmation replaces the old fixed settle sleep: wait until
        // the server actually entered its subscription, then push the
        // transition through the delta stream.
        let subscribersBefore = await harness.broker.liveSubscribers
        await waitUntil(budgetMilliseconds: 2000) { [harness] in
            await harness.broker.liveSubscribers == subscribersBefore + 1
        }
        let idleSummary = FakeControlRuntime.summary(id: harness.agentID, lifecycle: .idle, revision: 6)
        harness.runtime.emit(idleSummary)

        let outcome = try await waiter.value
        XCTAssertEqual(outcome?["matched"]?.boolValue, true)
        XCTAssertEqual(outcome?["lifecycle"]?.stringValue, "idle")
        XCTAssertEqual(outcome?["stateRevision"]?.intValue, 6)
    }

    func testWaitClosesSubscribeRaceWindowDeterministically() async throws {
        // Simulates the transition landing between step 1's read and step 3's
        // subscription: the reader reports working first, then idle on every
        // subsequent read (the post-subscribe re-check sees it). No delta is
        // ever emitted — only step 4 can rescue this wait.
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        harness.runtime.setState(.working, revision: 1)

        let started = Date()
        let reader = { @Sendable () -> LifecycleSnapshot? in
            // First call (step 1): working. Post-subscribe call (step 4)+: idle.
            if Self.readerCalls.add(1) == 1 {
                return LifecycleSnapshot(stateRevision: 1, lifecycle: .working)
            }
            return LifecycleSnapshot(stateRevision: 2, lifecycle: .idle)
        }

        // Direct algorithm-level check of the §3.16 steps 1–6 ordering.
        let outcome = await waitForLifecycle(
            targets: [.idle],
            minStateRevision: nil,
            timeout: .seconds(2),
            reader: reader,
            events: { await harness.broker.subscribe(agentID: nil) }
        )
        guard case let .success(.matched(revision, .idle)) = outcome else {
            return XCTFail("wait must close the subscribe race via post-subscribe re-check, got \(outcome)")
        }
        XCTAssertEqual(revision, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "must not hang until timeout")
    }

    private static let readerCalls = AtomicCounter()

    func testWaitTimesOutWhenPredicateNeverTrue() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let started = Date()
        let outcome = await waitForLifecycle(
            targets: [.stopped],
            minStateRevision: nil,
            timeout: .milliseconds(150),
            reader: { LifecycleSnapshot(stateRevision: 1, lifecycle: .working) },
            events: { AsyncThrowingStream { _ in } } // never yields, never finishes
        )
        guard case let .success(.timedOut(lastKnown)) = outcome else {
            return XCTFail("expected timeout, got \(outcome)")
        }
        XCTAssertEqual(lastKnown, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.12)
    }

    func testDisconnectMidWaitCancelsCleanly() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let subscriberCountBefore = await harness.broker.liveSubscribers

        // Client opens a wait for a lifecycle that will never happen, then
        // slams the connection shut.
        let fd = try openRawSocket(harness.socketPath)
        var line = "{\"protocolVersion\":1,\"requestID\":\"w\",\"method\":\"agent.wait\",\"params\":{"
            + "\"agentID\":\"\(harness.agentID.rawValue.uuidString)\",\"targetLifecycle\":[\"failed\"],\"timeoutMs\":30000}}\n"
        line.withUTF8 { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
        // Arm-confirmation: wait until the wait's subscription is live, then
        // slam the connection shut (replaces a fixed 200 ms settle sleep).
        await waitUntil(budgetMilliseconds: 2000) { [harness] in
            await harness.broker.liveSubscribers == subscriberCountBefore + 1
        }
        close(fd)
        // The server-side operation must unwind promptly instead of hanging
        // for the full 30 s timeout.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let live = await harness.broker.liveSubscribers
            if live == subscriberCountBefore {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let liveAfterClose = await harness.broker.liveSubscribers
        XCTAssertEqual(liveAfterClose, subscriberCountBefore,
                       "disconnect must cancel the wait and detach its subscription")
    }

    /// R11-A: after ≥ 1.6 s of connection silence — strictly more than the
    /// production close-watcher's 1000 ms poll timeout (UnixSocketServer) —
    /// the per-connection watcher must STILL be alive, so a subsequent
    /// abrupt peer EOF unwinds an in-flight long operation promptly.
    /// Pins the watcher-survival law: a timeout must `continue` watching,
    /// never `return` (which silently killed liveness for quiet connections).
    func testCloseWatcherSurvivesIdleWindowLongerThanPollTimeoutAndStillDetectsPeerEOF() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let baseline = await harness.broker.liveSubscribers

        // Client opens a wait with a 30 s horizon, then goes quiet well past
        // one full watcher poll window.
        let fd = try openRawSocket(harness.socketPath)
        var line = "{\"protocolVersion\":1,\"requestID\":\"idle\",\"method\":\"agent.wait\",\"params\":{"
            + "\"agentID\":\"\(harness.agentID.rawValue.uuidString)\",\"targetLifecycle\":[\"failed\"],\"timeoutMs\":30000}}\n"
        line.withUTF8 { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
        // Arm-confirmation: the wait's subscription is live before going quiet.
        await waitUntil(budgetMilliseconds: 2000) { [harness] in
            await harness.broker.liveSubscribers == baseline + 1
        }
        // The single fixed wait IS the exercised production constant: an idle
        // window strictly longer than the watcher poll timeout. Everything
        // after this is event-driven.
        try await Task.sleep(for: .milliseconds(1600))
        close(fd)
        // The server-side operation must still unwind promptly: nobody may
        // have stopped watching during the silence.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let live = await harness.broker.liveSubscribers
            if live == baseline {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let liveAfterClose = await harness.broker.liveSubscribers
        XCTAssertEqual(liveAfterClose, baseline,
                       "disconnect after an idle window must still cancel the wait and detach its subscription")
    }

    // MARK: Subscription streaming

    func testEventsSubscribeStreamsDeltasUntilDisconnect() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let client = try harness.client()
        let subscriptionID = try client.openSubscription(agentID: nil)
        XCTAssertFalse(subscriptionID.isEmpty)

        client.setReceiveTimeout(milliseconds: 2000)
        let summary = FakeControlRuntime.summary(id: harness.agentID, lifecycle: .idle, revision: 42)
        harness.runtime.emit(summary)

        let frame = try client.nextEventFrame()
        XCTAssertEqual(frame?["event"]?.stringValue, "agentChanged")
        let agent = frame?["agent"]?.objectValue
        XCTAssertEqual(agent?["id"]?.stringValue, harness.agentID.rawValue.uuidString)
        XCTAssertEqual(agent?["stateRevision"]?.intValue, 42)
        client.close()
    }

    // MARK: Live end-to-end smoke: agentctl binary vs real AgentRuntime

    func testLiveSmokeAgentctlAgainstRealRuntime() async throws {
        // Real runtime + fake terminal port, wired like stage 8 will do.
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let deliveries = DeliveryCountingTerminalPort()
        await runtime.setTerminalPort(deliveries)

        let workspaceID = await runtime.createWorkspace(name: "smoke", rootPath: "/tmp/smoke")
        let agentID = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "smoke-agent"),
            in: workspaceID
        )
        try await runtime.surfaceCreated(
            agentID: agentID,
            terminalID: TerminalID(),
            generation: .initial,
            pid: nil,
            processGroupID: nil
        )

        let hooks = HookAuthenticator()
        let broker = EventStreamBroker.streamBound(to: runtime)
        let router = ControlRequestRouter(
            runtime: LiveControlRuntime(runtime: runtime),
            hooks: hooks,
            broker: broker
        )
        let socketPath = "/tmp/aterm-smoke-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixSocketServer(path: socketPath) { [router] request, connection in
            await router.handle(request, connection: connection)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let binary = try XCTUnwrap(Self.locateAgentctl())

        // 1. ping
        do {
            let output = try runProcess(binary, ["--socket", socketPath, "ping"])
            XCTAssertTrue(output.stdout.contains("\"ok\":true"), "ping failed: \(output.stderr)")
            XCTAssertTrue(output.stdout.contains("\"protocolVersion\":1"))
        }

        // 2. agent get shows the created agent
        do {
            let output = try runProcess(binary, ["--socket", socketPath, "agent", "get", agentID.rawValue.uuidString])
            XCTAssertTrue(output.stdout.contains(agentID.rawValue.uuidString), "agent.get failed: \(output.stderr)")
        }

        // 3. prompt twice with the same --command-id → delivered exactly once
        let commandID = UUID().uuidString
        let promptArguments = [
            "--socket", socketPath, "agent", "prompt",
            agentID.rawValue.uuidString, "hello smoke",
            "--command-id", commandID,
        ]
        do {
            let first = try runProcess(binary, promptArguments)
            XCTAssertTrue(first.stdout.contains("delivered"), "first prompt failed: \(first.stderr)")

            let retry = try runProcess(binary, promptArguments)
            XCTAssertTrue(retry.stdout.contains("delivered"))
            XCTAssertEqual(
                Self.extractReceiptCommandID(from: first.stdout),
                Self.extractReceiptCommandID(from: retry.stdout),
                "idempotent retry must return the identical receipt"
            )

            let deliveryCount = deliveries.count
            XCTAssertEqual(deliveryCount, 1, "terminal input path must see the text EXACTLY once")
        }
    }
}

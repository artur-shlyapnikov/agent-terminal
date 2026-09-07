@testable import AgentControl
import AgentCore
import Foundation
import XCTest

extension SocketIntegrationTests {
    func testRawLineReaderPreservesCoalescedFrames() async throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(sockets[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let frames = Array("first\nsecond\n".utf8)
        XCTAssertEqual(frames.withUnsafeBytes { write(sockets[0], $0.baseAddress, $0.count) }, frames.count)

        let first = try await readLine(fd: sockets[1], budgetSeconds: 1)
        let second = try await readLine(fd: sockets[1], budgetSeconds: 1)
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "first")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "second")
    }

    /// R12-A: the complementary half of the idle-window law. After ≥ 1.6 s
    /// of silence (> the watcher's 1000 ms poll timeout), inbound DATA on
    /// the watched fd must take the POLLIN branch, be left ENTIRELY for the
    /// serve loop (MSG_PEEK consumes nothing; 20 ms back-off), and NEVER
    /// trigger close() — while the watcher stays alive for a later EOF.
    /// An eager watcher that closes on ANY readability (or spins against
    /// the serve loop's reads) kills healthy-but-chatty connections after
    /// one quiet second — the failure mode this pins shut.
    func testCloseWatcherLeavesInboundDataAloneAfterIdleWindowAndConnectionStaysUsable() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let baseline = await harness.broker.liveSubscribers

        // Same arrange as the idle-window survival test: arm a long wait,
        // confirm the subscription, then go quiet past one poll window.
        let fd = try openRawSocket(harness.socketPath)
        var line = "{\"protocolVersion\":1,\"requestID\":\"idle\",\"method\":\"agent.wait\",\"params\":{"
            + "\"agentID\":\"\(harness.agentID.rawValue.uuidString)\",\"targetLifecycle\":[\"failed\"],\"timeoutMs\":30000}}\n"
        line.withUTF8 { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
        await waitUntil(budgetMilliseconds: 2000) { [harness] in
            await harness.broker.liveSubscribers == baseline + 1
        }

        // The single fixed wait IS the exercised production constant.
        try await Task.sleep(for: .milliseconds(1600))

        // Inbound data after the quiet window lands in the kernel buffer
        // while the serve loop is still inside the serial agent.wait handler
        // (§3.18). The watcher must take its POLLIN branch, MSG_PEEK without
        // consuming, back off, and above all NOT close. Give it ample
        // opportunity to misbehave, then assert the subscription survived.
        let malformed = Array("{\"nope\n".utf8)
        _ = malformed.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        let ping = Array("{\"protocolVersion\":1,\"requestID\":\"m\",\"method\":\"system.ping\",\"params\":{}}\n".utf8)
        _ = ping.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        let observationDeadline = Date().addingTimeInterval(0.4)
        while Date() < observationDeadline {
            let live = await harness.broker.liveSubscribers
            XCTAssertEqual(live, baseline + 1,
                           "inbound data after an idle window must NOT tear down the watched connection")
            try await Task.sleep(for: .milliseconds(50))
        }

        // Resolve the wait so the serial serve loop drains the queued lines.
        // The bytes were left untouched by the watcher, so they now come back
        // IN ORDER: the wait's own success frame first, then badRequest for
        // the malformed line, then system.ping's ok — proof the connection is
        // fully usable and nothing was consumed or lost while blocked.
        harness.runtime.emit(FakeControlRuntime.summary(
            id: harness.agentID, lifecycle: .failed(FailureDescriptor()), revision: 43
        ))
        let waitReply = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(waitReply.contains("\"matched\":true"), waitReply)
        let badRequestReply = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(badRequestReply.contains("badRequest"), badRequestReply)
        let pingReply = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(pingReply.contains("\"ok\":true"), pingReply)

        // The watcher survived the whole exchange and still detects EOF.
        close(fd)
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
                       "disconnect after data-bearing traffic must still be detected promptly")
    }

    /// R13-A3: watcher hygiene under rapid connect/disconnect churn. Rapid
    /// open/close cycles recycle descriptor numbers aggressively; a watcher
    /// that fails to exit when ITS connection dies (broken closed-state
    /// self-exit guards) ends up polling an fd number the kernel has handed
    /// to a NEW connection — where any event (or a misdirected close())
    /// kills the innocent successor. First outcome-level pin of the
    /// documented "its number gets reused by another connection" hazard.
    func testWatcherChurnFromRapidConnectDisconnectCyclesDoesNotKillReusedConnections() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let baseline = await harness.broker.liveSubscribers

        // Churn phase: each cycle forces the server to accept, spawn a
        // watcher, detect EOF, and retire the descriptor number for imminent
        // reuse.
        for _ in 0 ..< 6 {
            let churned = try openRawSocket(harness.socketPath)
            close(churned)
        }

        // Survivor phase: arm a long wait through the churned descriptor pool.
        let fd2 = try openRawSocket(harness.socketPath)
        var line = "{\"protocolVersion\":1,\"requestID\":\"idle\",\"method\":\"agent.wait\",\"params\":{"
            + "\"agentID\":\"\(harness.agentID.rawValue.uuidString)\",\"targetLifecycle\":[\"failed\"],\"timeoutMs\":30000}}\n"
        line.withUTF8 { buffer in
            _ = write(fd2, buffer.baseAddress, buffer.count)
        }
        // Arm-first confirmation: the wait's subscription is live.
        await waitUntil(budgetMilliseconds: 2000) { [harness] in
            await harness.broker.liveSubscribers == baseline + 1
        }
        // The single fixed wait IS the exercised production constant,
        // identical justification to the idle-window tests above.
        try await Task.sleep(for: .milliseconds(1600))

        // Resolve the wait: the survivor worked THROUGH the quiet window
        // despite the churn.
        harness.runtime.emit(FakeControlRuntime.summary(
            id: harness.agentID, lifecycle: .failed(FailureDescriptor()), revision: 43
        ))
        let waitReply = try await String(decoding: readLine(fd: fd2), as: UTF8.self)
        XCTAssertTrue(waitReply.contains("\"matched\":true"), waitReply)

        // Final unwind: prompt subscriber drain-down proves the surviving
        // watcher also exited cleanly rather than leaking into the
        // recycled-number pool.
        close(fd2)
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
                       "post-churn disconnect must still be detected promptly")
    }

    /// Round 14 B3: the disconnect-cancellation path THROWS rather than
    /// returning a `.failure(.cancelled)` response, so the cancellation never
    /// enters the idempotency cache — a retry with the SAME commandID on a
    /// fresh connection must execute a FRESH wait instead of replaying
    /// "cancelled" (ControlRequestRouter).
    func testDisconnectCancelledWaitIsNotCachedAndRetryRewaits() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let baseline = await harness.broker.liveSubscribers

        // First attempt: arm a long wait under commandID "retry-1", then slam
        // the connection shut mid-wait.
        let fd1 = try openRawSocket(harness.socketPath)
        var firstFrame = "{\"protocolVersion\":1,\"requestID\":\"w1\",\"commandID\":\"retry-1\",\"method\":\"agent.wait\",\"params\":{"
        firstFrame += "\"agentID\":\"\(harness.agentID.rawValue.uuidString)\",\"targetLifecycle\":[\"failed\"],\"timeoutMs\":30000}}\n"
        _ = firstFrame.withUTF8 { buffer in write(fd1, buffer.baseAddress, buffer.count) }
        await waitUntil(budgetMilliseconds: 2000) { [harness] in
            await harness.broker.liveSubscribers == baseline + 1
        }
        close(fd1)
        // Drain-down: the disconnect is observed and the wait cancelled.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let live = await harness.broker.liveSubscribers
            if live == baseline {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let afterClose = await harness.broker.liveSubscribers
        XCTAssertEqual(afterClose, baseline, "disconnect must cancel the first wait")

        // Retry: identical frame (same commandID), new connection. The reply
        // must NOT be an instantly replayed cached cancellation — emit the
        // matching failure FIRST and prove the fresh wait actually observes it.
        let fd2 = try openRawSocket(harness.socketPath)
        var retryFrame = "{\"protocolVersion\":1,\"requestID\":\"w2\",\"commandID\":\"retry-1\",\"method\":\"agent.wait\",\"params\":{"
        retryFrame += "\"agentID\":\"\(harness.agentID.rawValue.uuidString)\",\"targetLifecycle\":[\"failed\"],\"timeoutMs\":30000}}\n"
        _ = retryFrame.withUTF8 { buffer in write(fd2, buffer.baseAddress, buffer.count) }
        await waitUntil(budgetMilliseconds: 2000) { [harness] in
            await harness.broker.liveSubscribers == baseline + 1
        }
        harness.runtime.emit(FakeControlRuntime.summary(
            id: harness.agentID, lifecycle: .failed(FailureDescriptor()), revision: 43
        ))
        let reply = try await String(decoding: readLine(fd: fd2), as: UTF8.self)
        XCTAssertTrue(reply.contains("\"matched\":true"),
                      "retry must execute a FRESH wait that observes the failure; got: \(reply)")
        XCTAssertFalse(reply.lowercased().contains("cancel"), reply)

        close(fd2)
        let finalDeadline = Date().addingTimeInterval(5)
        while Date() < finalDeadline {
            let live = await harness.broker.liveSubscribers
            if live == baseline {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let finalLive = await harness.broker.liveSubscribers
        XCTAssertEqual(finalLive, baseline,
                       "post-retry disconnect must still be detected promptly")
    }

    // MARK: R28-S6 — undecodable idempotency entry fails CLOSED

    /// A cache entry that no longer decodes must NOT fall through to
    /// execution: re-running agent.prompt would break exactly-once (§3.16).
    /// The router must fail the request with a sanitized internalError and
    /// leave both the runtime AND the corrupt cache entry untouched.
    func testUndecodableIdempotencyEntryFailsClosedWithoutReexecuting() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let commandID = UUID().uuidString
        // Seed the cache with bytes decodeCached cannot decode.
        await harness.router.idempotency.put(commandID, Data("garbage-bytes".utf8))

        let params: [String: JSONValue] = [
            "agentID": .string(harness.agentID.rawValue.uuidString),
            "text": .string("must never run"),
            "policy": .string("sendNow"),
        ]
        let client = try harness.client()
        let response = try client.roundtrip(
            method: ControlMethod.agentPrompt.rawValue,
            params: params,
            commandID: commandID
        )
        client.close()

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .internalError)
        XCTAssertEqual(response.error?.message, "internal error",
                       "the failure must be sanitized — no internals leaked")

        // Fail-closed: NOT executed.
        XCTAssertEqual(harness.runtime.deliveredPrompts[harness.agentID] ?? 0, 0,
                       "a corrupt cached entry must never re-execute the prompt")

        // The corrupt entry was not overwritten: the retry replays the same
        // sanitized internalError instead of executing.
        let retryClient = try harness.client()
        let retry = try retryClient.roundtrip(
            method: ControlMethod.agentPrompt.rawValue,
            params: params,
            commandID: commandID
        )
        retryClient.close()
        XCTAssertEqual(retry.error?.code, .internalError)
        XCTAssertEqual(harness.runtime.deliveredPrompts[harness.agentID] ?? 0, 0)

        // Positive control: the cache machinery itself is alive — a fresh
        // commandID executes normally and its replay comes from the cache.
        let freshCommandID = UUID().uuidString
        let fresh = try harness.client()
        let firstRun = try fresh.roundtrip(
            method: ControlMethod.agentPrompt.rawValue,
            params: params,
            commandID: freshCommandID
        )
        fresh.close()
        XCTAssertTrue(firstRun.ok, "a well-formed request must work: \(String(describing: firstRun.error))")
        let replayClient = try harness.client()
        let replay = try replayClient.roundtrip(
            method: ControlMethod.agentPrompt.rawValue,
            params: params,
            commandID: freshCommandID
        )
        replayClient.close()
        XCTAssertTrue(replay.ok)
        XCTAssertEqual(harness.runtime.deliveredPrompts[harness.agentID] ?? 0, 1,
                       "exactly one delivery total: the corrupt entry blocked none of the fresh traffic")
    }

    // MARK: R28-S7 — crafted agent.wait timeoutMs above ceiling rejected, server survives

    /// A crafted NDJSON frame must never trap the host: timeoutMs above the
    /// 24 h ceiling is a client error, and the connection stays usable.
    /// Deviation from the sketch's UInt64.max value: wire numbers above
    /// Int64.max decode as doubles and are already rejected by the uint64
    /// param decoder; Int64.max is the largest integer that actually reaches
    /// the ceiling guard. UInt64.max is still sent first as an extra
    /// hostile-input leg — it too must merely yield badRequest.
    func testCraftedWaitTimeoutAboveCeilingIsRejectedAndConnectionSurvives() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let fd = try openRawSocket(harness.socketPath)
        defer { close(fd) }

        func sendWait(timeoutLiteral: String, requestID: String) throws {
            var line = "{\"protocolVersion\":1,\"requestID\":\"\(requestID)\",\"method\":\"agent.wait\",\"params\":{"
            line += "\"agentID\":\"\(harness.agentID.rawValue.uuidString)\",\"targetLifecycle\":[\"failed\"],\"timeoutMs\":\(timeoutLiteral)}}\n"
            _ = line.withUTF8 { buffer in write(fd, buffer.baseAddress, buffer.count) }
        }
        try sendWait(timeoutLiteral: "18446744073709551615", requestID: "u64max")
        let u64Reply = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(u64Reply.contains("badRequest"), u64Reply)

        try sendWait(timeoutLiteral: "9223372036854775807", requestID: "i64max")
        let reply = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(reply.contains("badRequest"), reply)
        XCTAssertTrue(reply.contains("timeoutMs exceeds maximum"),
                      "the rejection must name the ceiling: \(reply)")

        // The connection survived both hostile frames: a normal request on
        // the SAME connection succeeds.
        let ping = Array("{\"protocolVersion\":1,\"requestID\":\"p\",\"method\":\"system.ping\",\"params\":{}}\n".utf8)
        _ = ping.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        let pingReply = try await String(decoding: readLine(fd: fd), as: UTF8.self)
        XCTAssertTrue(pingReply.contains("\"ok\":true"), pingReply)
    }

    // MARK: R29-S1a — first send failure tears the connection down (unit law)

    /// A failed send must tear the connection down AFTER the write lock is
    /// released (`UnixSocketServer.send(raw:)` capture-then-teardown): the
    /// thrown failure is `.cancelled`, the peer received only a torn mid-line
    /// PREFIX of the frame (never a completable NDJSON line), an immediate
    /// retry fails fast with "connection closed" — proving `finish()` ran
    /// post-release and that neither call re-entered `writeLock` — and the
    /// closed state is observable via `awaitClosed()`.
    ///
    /// Hermetic construction: a raw socketpair replaces the accept path, and
    /// the send ceiling is bounded at 200 ms instead of the production
    /// accept-path constant of 10 s — the SAME EAGAIN branch is exercised
    /// (`Darwin.send` → partial prefix → block → SO_SNDTIMEO expiry) at unit
    /// cost. The ~1 MiB payload carries NO interior newline, so any delivered
    /// bytes are provably a torn single frame.
    func testFirstSendFailureThrowsCancelledTearsFrameAndClosesConnection() async throws {
        let (serverFD, peerFD) = try makeSocketpair()
        defer { close(peerFD) } // serverFD is owned (and closed) by the connection

        // The production constant is 10 s (accept path); this law needs the
        // failure, not the wait, so bound the ceiling at 200 ms.
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        XCTAssertEqual(
            setsockopt(
                serverFD, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            ), 0, "SO_SNDTIMEO must apply"
        )
        // Shrink the peer's receive buffer far below the payload: the send
        // drains both kernel buffers, then parks until the timeout expires
        // having written only a prefix.
        var tinyReceiveBuffer: Int32 = 4 * 1024
        _ = setsockopt(
            peerFD, SOL_SOCKET, SO_RCVBUF, &tinyReceiveBuffer,
            socklen_t(MemoryLayout<Int32>.size)
        )

        guard let connection = ControlConnection(fd: serverFD, maxMessageSize: 1 << 20) else {
            return XCTFail("ControlConnection rejected a valid socketpair endpoint")
        }

        let payloadCount = 1 << 20
        let data = Data(repeating: 0x61, count: payloadCount)

        var caught: Error?
        do {
            try connection.send(raw: data)
            XCTFail("send against a full peer buffer must fail")
        } catch {
            caught = error
        }

        // Leg 1: the failure IS ControlFailure.cancelled — typed cast, never
        // string matching.
        let failure = try XCTUnwrap(
            caught as? ControlFailure,
            "expected ControlFailure, got \(String(describing: caught))"
        )
        XCTAssertEqual(failure.code, .cancelled)

        // Leg 2: the peer holds a strict NON-EMPTY prefix whose last byte is
        // not \n — the frame really was torn mid-line. Non-blocking drain.
        var delivered: [UInt8] = []
        let drainDeadline = Date().addingTimeInterval(1)
        while Date() < drainDeadline {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let capacity = chunk.count
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(peerFD, raw.baseAddress, capacity, MSG_DONTWAIT)
            }
            if received > 0 {
                delivered.append(contentsOf: chunk[0 ..< received])
                continue
            }
            if received == 0 {
                break
            }
            let failure = errno
            guard failure == EAGAIN || failure == EWOULDBLOCK else { break }
            usleep(5000)
        }
        XCTAssertFalse(delivered.isEmpty, "at least one buffer's worth must reach the peer")
        XCTAssertLessThan(delivered.count, payloadCount, "the whole 1 MiB cannot fit tiny buffers")
        XCTAssertNotEqual(delivered.last, UInt8(0x0A), "the torn prefix must NOT end a line")

        // Leg 3: an immediate retry fails FAST with "connection closed".
        // Old code left the connection open: the retry would have appended
        // onto the torn frame instead. Both calls returning also proves no
        // re-entrant writeLock deadlock.
        do {
            try connection.send(raw: Data("x\n".utf8))
            XCTFail("retry on a torn-down connection must throw")
        } catch let retry as ControlFailure {
            XCTAssertEqual(retry.code, .cancelled)
            XCTAssertEqual(retry.message, "connection closed")
        }

        // Leg 4: the closed state is observable — bounded race, never a bare
        // await (a regression that never marks closed would hang the suite).
        let closedInTime = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { await connection.awaitClosed(); return true }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(2000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(closedInTime, "awaitClosed() must observe the teardown")
    }

    // MARK: R29-S1b — server survives a wedged peer's send failure (integration law)

    /// The accept path installs SO_SNDTIMEO = 10 s precisely so a peer that
    /// stops reading cannot park the serial serve loop inside `send` holding
    /// `writeLock` forever. Fire ~300 pings WITHOUT reading any response
    /// (responses exceed the kernel buffers), then close the peer: the live
    /// subscriber count must drain back to baseline within a bounded window
    /// (a re-entrant `finish()` deadlock regression never drains), a FRESH
    /// connection must roundtrip `system.ping`, and `stop()` must complete.
    ///
    /// Honesty note: because the trigger ends with the peer gone, EOF
    /// co-cleanup alone could also drain subscribers; the discriminating
    /// assertions are the bounded drain and the fresh-connection liveness.
    func testWedgedPeerSendFailureDrainsSubscriberAndServerStaysAlive() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }
        try await harness.waitUntilListening()

        let baseline = await harness.broker.liveSubscribers

        let fd = try openRawSocket(harness.socketPath)
        // The client writes without ever reading: responses fill our receive
        // buffer, then the serve loop's send parks on OUR full buffer — the
        // exact hazard the 10 s send ceiling exists for.
        var nosigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let pingCount = 300
        var payload = Data()
        payload.reserveCapacity(pingCount * 96)
        for index in 0 ..< pingCount {
            payload.append(contentsOf: Data(
                "{\"protocolVersion\":1,\"requestID\":\"wedge\(index)\",\"method\":\"system.ping\",\"params\":{}}\n"
                    .utf8
            ))
        }

        // Non-blocking fire-and-forget: stop early on EPIPE/ECONNRESET (the
        // server tore us down first — equally valid), never park forever.
        let writeDeadline = Date().addingTimeInterval(5)
        var offset = 0
        while offset < payload.count, Date() < writeDeadline {
            let written = payload.withUnsafeBytes { raw -> Int in
                send(fd, raw.baseAddress! + offset, payload.count - offset, 0)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                break
            }
            let failure = errno
            if failure == EAGAIN || failure == EWOULDBLOCK {
                var pollSet = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pollSet, 1, 50)
                continue
            }
            break // EPIPE / ECONNRESET: the teardown already happened
        }
        close(fd)

        // Leg 1: the subscriber drains back to baseline WITHIN the budget —
        // the ≤10 s ceiling mirrors the exercised production constant; in
        // practice peer close wakes the blocked send in milliseconds.
        await waitUntil(budgetMilliseconds: 10000, intervalMilliseconds: 50) { [harness] in
            await harness.broker.liveSubscribers == baseline
        }
        let drained = await harness.broker.liveSubscribers
        XCTAssertEqual(
            drained, baseline,
            "wedged-peer teardown must release the subscriber; a finish()-under-lock deadlock never drains"
        )

        // Leg 2: the server is alive and unpolluted — a FRESH connection's
        // system.ping roundtrips ok:true.
        let fresh = try openRawSocket(harness.socketPath)
        defer { close(fresh) }
        var probe = "{\"protocolVersion\":1,\"requestID\":\"alive\",\"method\":\"system.ping\",\"params\":{}}\n"
        probe.withUTF8 { buffer in
            _ = write(fresh, buffer.baseAddress, buffer.count)
        }
        let reply = try await String(decoding: readLine(fd: fresh), as: UTF8.self)
        XCTAssertTrue(reply.contains("\"ok\":true"), reply)

        // Leg 3: stop() completes — a poisoned writeLock would hang here.
        await harness.stop()
    }

    // MARK: C2 — stop() deterministically ends the accept loop (stop/restart)

    /// On Darwin, shutdown(2) of a LISTENING socket returns ENOTCONN and
    /// close(2) never wakes a thread parked in accept() — the old blocking
    /// accept loop leaked past stop(), leaving a listener fd alive that
    /// could even steal connections via fd-number reuse. The accept loop
    /// now parks in poll() over {listen fd, wake fd} and stop() writes the
    /// wake byte: the loop must unwind deterministically, the listener must
    /// close exactly once, and the server must restart cleanly on the SAME
    /// path (a lingering or double-closed listener would break this).
    func testStopUnblocksAcceptLoopAndRestartServesOnSamePath() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        try await harness.waitUntilListening()

        // First life: prove the accept path is live before stopping.
        let first = try harness.client()
        try first.handshake()
        first.close()

        // stop() itself must return promptly: a hang here IS the defect
        // (accept parked forever against a closed listener). Race it
        // against a watchdog so the failure is an assertion, not a hang.
        let finishedPromptly = await withTaskGroup(
            of: Bool.self,
            returning: Bool.self
        ) { group -> Bool in
            group.addTask { await harness.stop(); return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first_ = await group.next() ?? false
            group.cancelAll()
            return first_
        }
        XCTAssertTrue(finishedPromptly, "stop() hung: the accept loop was not woken")
        let runningAfterStop = await harness.server.isRunning
        XCTAssertFalse(runningAfterStop)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: harness.socketPath),
            "stop() unlinks the socket file; a leaked predecessor would too, but its absence is part of the contract"
        )

        // Second life on the SAME path: restart must serve again. A stale
        // accept task from the first life would either steal this
        // connection or crash on a reused fd number.
        try await harness.start()
        try await harness.waitUntilListening()
        let second = try harness.client()
        try second.handshake()
        second.close()
        await harness.stop()
    }
}

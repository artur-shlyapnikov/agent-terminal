@testable import AgentControl
import Darwin
import Foundation
import XCTest

// Gap #8 — `ControlClient.readLine` discrimination: EAGAIN/EWOULDBLOCK maps to
// `ControlReadTimeout.timedOut`, a clean peer close (`recv == 0`) maps to
// `.closed` even while SO_RCVTIMEO is armed, and bytes received before a
// mid-line timeout survive in the client buffer and complete the NDJSON frame.
//
// A test-local raw AF_UNIX listener gives exact server-side control over
// send/close timing. Methods stay synchronous `throws` — the blocking recv
// wants the test thread parked. E4 covers the `EINTR` retry branch with a
// self-blocking raiser thread that forces SIGUSR1 delivery onto the parked
// reader (round-5 promotion — see .omp/test-design-5.md).

// MARK: - Test-local raw listener (server side)

private final class RawSocketListener {
    enum ListenerError: Error {
        case posix(String, Int32)
    }

    let path: String
    private var listenFD: Int32 = -1
    private(set) var connectionFD: Int32 = -1

    init() throws {
        path = "/tmp/aterm-cl-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError("socket") }
        listenFD = fd
        unlink(path) // defensive: stale socket at a collided name

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < 104 else {
            throw ListenerError.posix("path too long", 0)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Self.posixError("bind") }
        guard listen(listenFD, 1) == 0 else { throw Self.posixError("listen") }
    }

    deinit {
        closeConnection()
        if listenFD >= 0 {
            Darwin.close(listenFD)
        }
        unlink(path)
    }

    /// Blocking accept(2).
    func acceptConnection() throws {
        guard connectionFD < 0 else { return }
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { throw Self.posixError("accept") }
        connectionFD = fd
    }

    /// write(2) loop on the accepted connection.
    func send(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { return }
                let written = write(connectionFD, base + offset, buffer.count - offset)
                guard written > 0 else { throw Self.posixError("write") }
                offset += written
            }
        }
    }

    /// shutdown + close of the accepted connection (clean EOF for the client).
    func closeConnection() {
        guard connectionFD >= 0 else { return }
        shutdown(connectionFD, Int32(SHUT_RDWR))
        Darwin.close(connectionFD)
        connectionFD = -1
    }

    private static func posixError(_ call: String) -> ListenerError {
        ListenerError.posix(call, errno)
    }
}

// MARK: - E4 signal-injection plumbing

/// Delivery counter incremented from the C signal handler. `sig_atomic_t`
/// is the POSIX-sanctioned signal-handler pattern: a single store needs no
/// lock (which would not be async-signal-safe anyway).
private var eintrSignalCount: sig_atomic_t = 0

/// SIGUSR1 handler as a bare C function pointer — it captures NOTHING
/// (a @convention(c) value cannot), hence the global counter above.
private func noteUSR1(_: Int32) {
    eintrSignalCount += 1
}

/// Done-flag box shared with the raiser thread (threads capture references,
/// never plain variables).
private final class EINTRRaiserState: @unchecked Sendable {
    let lock = NSLock()
    var done = false
}

// MARK: - Tests

final class ControlClientReadLineTests: XCTestCase {
    /// Listener first, then client (connect succeeds via backlog before
    /// accept), then accept when the server side must act.
    private func makeConnectedPair() throws -> (RawSocketListener, ControlClient) {
        let listener = try RawSocketListener()
        let client = try ControlClient(socketPath: listener.path)
        return (listener, client)
    }

    private func assertThrows(
        _ expectation: ControlReadTimeout,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try body()
            XCTFail("expected ControlReadTimeout, got success", file: file, line: line)
        } catch let timeout as ControlReadTimeout {
            switch (timeout, expectation) {
            case (.timedOut, .timedOut), (.closed, .closed):
                break
            default:
                XCTFail("expected \(expectation), got \(timeout)", file: file, line: line)
            }
        } catch {
            XCTFail("expected \(expectation), got \(error)", file: file, line: line)
        }
    }

    // MARK: E1

    func testReceiveDeadlineWithoutDataThrowsTimedOut() throws {
        let (listener, client) = try makeConnectedPair()
        defer { listener.closeConnection() } // keeps the pair alive for the scope
        // accept NOT required: an idle backloged connection delivers EAGAIN.
        client.setReceiveTimeout(milliseconds: 150)

        assertThrows(.timedOut) { _ = try client.readLine() }
    }

    // MARK: E2

    func testCleanPeerCloseYieldsClosedEvenWhileReceiveTimeoutIsArmed() throws {
        let (listener, client) = try makeConnectedPair()
        client.setReceiveTimeout(milliseconds: 60000)
        try listener.acceptConnection()

        listener.closeConnection()

        // The 60 s deadline proves the classification came from EOF, not
        // the clock: recv must return 0 and map to .closed, never .timedOut.
        assertThrows(.closed) { _ = try client.readLine() }
    }

    // MARK: E3

    func testPartialLineSurvivesMidLineTimeoutAndCompletesAfterResume() throws {
        let (listener, client) = try makeConnectedPair()
        client.setReceiveTimeout(milliseconds: 200)
        try listener.acceptConnection()

        try listener.send(Array("{\"event\":\"delta\",\"seq\":1".utf8)) // no newline yet
        assertThrows(.timedOut) { _ = try client.readLine() }

        try listener.send(Array("}\r\n".utf8))
        let line = try client.readLine()
        XCTAssertEqual(String(decoding: line, as: UTF8.self),
                       "{\"event\":\"delta\",\"seq\":1}",
                       "the half-received frame must complete across the timeout boundary")

        // Buffer fully consumed: no duplication, next read hits the deadline.
        assertThrows(.timedOut) { _ = try client.readLine() }
    }

    // MARK: E4 — EINTR retries the blocking recv instead of failing

    func testInterruptedRecvIsRetriedUntilDataArrives() throws {
        let (listener, client) = try makeConnectedPair()
        try listener.acceptConnection() // accept first — data must be withheld
        // The 10 s deadline must NEVER fire: the test's own bounds apply, and
        // progress has to come from the EINTR retry loop, not the timeout.
        client.setReceiveTimeout(milliseconds: 10000)

        eintrSignalCount = 0

        // C function pointers are not Equatable — compare the raw bit pattern
        // against SIG_ERR ((sig_t)-1).
        let previousHandler = signal(SIGUSR1, noteUSR1)
        if unsafeBitCast(previousHandler, to: UInt.self)
            == unsafeBitCast(SIG_ERR, to: UInt.self)
        {
            XCTFail("could not install SIGUSR1 handler")
            return
        }
        defer { signal(SIGUSR1, previousHandler) }

        // Raiser thread: FIRST block SIGUSR1 on itself (forcing kernel
        // delivery onto other threads — i.e. the one parked in recv), then
        // raise every millisecond until the done-flag flips AFTER readLine
        // returned. Coalescing therefore cannot starve the blocked window.
        let state = EINTRRaiserState()
        let finished = DispatchSemaphore(value: 0)
        let raiser = Thread {
            var blockSet = sigset_t()
            sigemptyset(&blockSet)
            sigaddset(&blockSet, SIGUSR1)
            pthread_sigmask(SIG_BLOCK, &blockSet, nil)
            while true {
                state.lock.lock()
                let done = state.done
                state.lock.unlock()
                if done {
                    break
                }
                // Process-directed send: the kernel routes it to SOME thread
                // that does not block SIGUSR1 — i.e. the one parked in recv.
                // (Thread-directed raise() would stay pending on THIS thread,
                // which blocks the signal below.)
                kill(getpid(), SIGUSR1)
                usleep(1000)
            }
            finished.signal()
        }
        raiser.name = "eintr-raiser"
        raiser.start()

        Thread.sleep(forTimeInterval: 0.1) // raises are already flowing
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? listener.send(Array("{\"ok\":true}\r\n".utf8))
        }

        let startedAt = Date()
        let line = try client.readLine() // interrupted repeatedly; must retry
        let elapsed = Date().timeIntervalSince(startedAt)

        // Flip the flag only AFTER readLine returned (flake-floor law).
        state.lock.lock()
        state.done = true
        state.lock.unlock()
        _ = finished.wait(timeout: .now() + 2)

        // CR stripped — the buffer path is unaffected by the retry loop.
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "{\"ok\":true}")
        let delivered = eintrSignalCount
        // Expected ≈ hundreds; the floor sits ~30× below expectation and only
        // tolerates ~97 % coalescing loss — worst case is a false FAIL of THIS
        // assert, never a false PASS of a broken branch.
        XCTAssertGreaterThanOrEqual(delivered, 10, "SIGUSR1 deliveries")
        // Progress came from the retry, not the receive timeout.
        XCTAssertLessThanOrEqual(elapsed, 9.0, "readLine took \(elapsed)s")
    }
}

import AgentCore
import Foundation

// 0600 AF_UNIX NDJSON listener (architecture §3.16, §4.5).
//
// Transport rules:
// - Unix domain socket ONLY; no TCP listener exists anywhere in this module.
// - The socket file is created with mode 0600 (owner read/write) — enforced
//   with chmod after bind, before accept.
// - NDJSON framing: one JSON object per line; CRLF tolerated.
// - Maximum message size 1 MiB. A frame exceeding the limit receives a
//   `payloadTooLarge` error response (requestID "") and the connection is
//   closed — there is no resynchronization inside an oversized frame.
// - Per §3.18 the server processes requests serially per connection: each
//   request runs to completion before the next line on that connection is
//   dispatched (subscriptions are the one long-lived exception; they forward
//   frames from their own task).

public actor UnixSocketServer {
    public let path: String
    public let maxMessageSize: Int
    private let backlog: Int32 = 16

    private let handler: @Sendable (ControlRequest, ControlConnection) async -> Void

    /// Lock-protected listener lifecycle shared between the actor and the
    /// accept task: the listen descriptor plus a self-wake socketpair.
    ///
    /// Why the wake channel: on a LISTENING socket shutdown(2) always fails
    /// (ECONNABORTED-family errno) and close(2)'s wakeup of a thread parked
    /// in accept() is an unguaranteed kernel accident — observed to fire on
    /// some Darwin builds, never promised by any contract, and useless when
    /// the task has not yet reached accept(). stop() instead writes one
    /// byte to wakeWriteFD, which the poll-parked loop treats as shutdown:
    /// deterministic termination independent of errno quirks or scheduling.
    private let listenerState = ListenerState()
    private var acceptTask: Task<Void, Never>?
    private var connections: [String: ControlConnection] = [:]
    public private(set) var isRunning = false

    private final class ListenerState: @unchecked Sendable {
        /// Read end of the wake socketpair; polled alongside the listener.
        let wakeReadFD: Int32
        private let wakeWriteFD: Int32
        private let lock = NSLock()
        private var listenFD: Int32 = -1

        init() {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
                // Without the wake channel stop() could not end the parked
                // accept loop deterministically; there is no sane fallback.
                fatalError("unix socket server: socketpair failed: errno \(errno)")
            }
            // Non-blocking both ends: reads must never wedge on an empty
            // pair while draining, writes must never wedge on a full one.
            for fd in pair {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            }
            wakeReadFD = pair[0]
            wakeWriteFD = pair[1]
        }

        deinit {
            Darwin.close(wakeReadFD)
            Darwin.close(wakeWriteFD)
        }

        func install(_ fd: Int32) {
            lock.withLock { listenFD = fd }
        }

        /// Current listener descriptor, or -1 once stopped.
        func listenDescriptor() -> Int32 {
            lock.withLock { listenFD }
        }

        /// Empties pending wake bytes so a freshly (re)started accept loop
        /// does not mistake a previous stop()'s signal for its own shutdown.
        func drainWake() {
            var sink: [UInt8] = [0, 0, 0, 0]
            while read(wakeReadFD, &sink, sink.count) > 0 {}
        }

        /// Closes the listener exactly once and wakes the parked accept
        /// loop. Idempotent under concurrency: the swap to -1 happens under
        /// the lock, so only the first caller ever closes.
        @discardableResult
        func closeListenerAndWake() -> Bool {
            let doomed: Int32 = lock.withLock {
                let fd = listenFD
                listenFD = -1
                return fd
            }
            guard doomed >= 0 else { return false }
            Darwin.close(doomed)
            // One byte suffices: ANY readability on the wake end means
            // shutdown. The pair is non-blocking, so even a full buffer
            // cannot wedge stop().
            var byte: UInt8 = 1
            _ = write(wakeWriteFD, &byte, 1)
            return true
        }
    }

    public init(
        path: String,
        maxMessageSize: Int = 1 << 20,
        handler: @escaping @Sendable (ControlRequest, ControlConnection) async -> Void
    ) throws {
        precondition(maxMessageSize > 0)
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.utf8.count < 104 else {
            throw ControlFailure(
                code: .internalError,
                message: "socket path exceeds sockaddr_un sun_path limit"
            )
        }
        self.path = expanded
        self.maxMessageSize = maxMessageSize
        self.handler = handler
    }

    /// Default production socket path:
    /// ~/Library/Application Support/AgentTerminal/runtime/control.sock
    public static func defaultPath() -> String {
        // Hermetic override for automation runs (mirrors ATERM_DB_PATH and
        // agentctl's defaultSocketPath()): lets a probe instance run beside
        // a live app without touching the production control plane.
        if let override = ProcessInfo.processInfo.environment["AGENT_TERMINAL_CONTROL_SOCKET"] {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/AgentTerminal/runtime/control.sock"
    }

    // MARK: Lifecycle

    public func start() throws {
        guard !isRunning else { return }

        // Belt-and-braces next to SO_NOSIGPIPE on accepted fds: peers that
        // vanish mid-write (the fire-and-forget launcher closes before
        // reading its ack) must never kill the server process with SIGPIPE.
        // Writes still report EPIPE through the normal error path.
        _ = signal(SIGPIPE, SIG_IGN)

        // Remove a stale socket file left by a crashed predecessor; bind()
        // would fail with EADDRINUSE otherwise. A concurrently-live server on
        // the same path cannot occur in practice: only the composition root
        // creates this server for its runtime directory.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.posix("socket", errno)
        }

        // Non-blocking listener: the accept loop drains pending
        // connections only after poll() reports readability, so a drained
        // accept must return EAGAIN instead of ever blocking (blocking
        // would defeat the wake channel — see ListenerState).
        let fdFlags = fcntl(fd, F_GETFL, 0)
        guard fdFlags >= 0, fcntl(fd, F_SETFL, fdFlags | O_NONBLOCK) == 0 else {
            let failure = errno
            Darwin.close(fd)
            throw SocketError.posix("fcntl(O_NONBLOCK)", failure)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let failure = errno
            Darwin.close(fd)
            throw SocketError.posix("bind", failure)
        }

        // Enforce owner-only access before anyone can connect.
        guard chmod(path, 0o600) == 0 else {
            let failure = errno
            Darwin.close(fd)
            unlink(path)
            throw SocketError.posix("chmod", failure)
        }

        guard listen(fd, backlog) == 0 else {
            let failure = errno
            Darwin.close(fd)
            unlink(path)
            throw SocketError.posix("listen", failure)
        }

        // Clear any wake byte left by a previous stop() so the fresh loop
        // does not mistake a stale signal for its own shutdown.
        listenerState.drainWake()
        listenerState.install(fd)
        isRunning = true

        let listenerState = listenerState
        let maxMessageSize = maxMessageSize
        let handler = handler
        acceptTask = Task { [weak self] in
            loop: while !Task.isCancelled {
                let listenFD = listenerState.listenDescriptor()
                guard listenFD >= 0 else {
                    break // stop() already ran (restart race)
                }

                // Park over BOTH the listener and the wake channel:
                // shutdown(2) always fails on a LISTENING socket and
                // close(2)'s wakeup of a parked accept() is an unguaranteed
                // kernel accident (see ListenerState). stop() signals via
                // the socketpair, so loop termination is deterministic.
                // This replaces the old blocking accept() whose unwind
                // after stop() depended on errno luck.
                var watchers = [
                    pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: listenerState.wakeReadFD, events: Int16(POLLIN), revents: 0),
                ]
                let ready = watchers.withUnsafeMutableBufferPointer { buffer in
                    poll(buffer.baseAddress, nfds_t(buffer.count), -1)
                }
                if ready < 0 {
                    if errno == EINTR {
                        continue
                    }
                    break // poll permanently broken
                }
                // A descriptor closed underneath us (stop() raced this
                // iteration → POLLNVAL) or any wake-channel event means
                // shutdown; neither case may touch a client fd again.
                if watchers[0].revents & Int16(POLLNVAL) != 0 ||
                    watchers[1].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0
                {
                    break
                }
                guard watchers[0].revents & Int16(POLLIN) != 0 else {
                    continue // spurious wakeup — re-park
                }

                // Listener readable: drain every pending connection. The
                // listen fd is non-blocking, so the drain always ends.
                draining: while true {
                    let clientFD = accept(listenFD, nil, nil)
                    guard clientFD >= 0 else {
                        switch errno {
                        case EINTR, ECONNABORTED, EPROTO:
                            continue // transient — keep draining
                        case EAGAIN:
                            break draining // fully drained
                        case EMFILE, ENFILE:
                            FileHandle.standardError.write(Data(
                                "unix socket server: accept failed: errno \(errno); backing off 50ms\n".utf8
                            ))
                            usleep(50000)
                            continue
                        default:
                            break loop // fatal error
                        }
                    }
                    // Unlike Linux, Darwin propagates the listener's
                    // O_NONBLOCK into accepted sockets; ControlConnection
                    // depends on blocking recv/send semantics, so strip it.
                    let clientFlags = fcntl(clientFD, F_GETFL, 0)
                    if clientFlags >= 0 {
                        _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)
                    }
                    // Fire-and-forget clients (the launcher) close immediately
                    // after writing and never read the ack; without SO_NOSIGPIPE
                    // our response write would raise SIGPIPE and kill the whole
                    // server process.
                    var nosigpipe: Int32 = 1
                    _ = setsockopt(
                        clientFD, SOL_SOCKET, SO_NOSIGPIPE,
                        &nosigpipe, socklen_t(MemoryLayout<Int32>.size)
                    )
                    // A client that stops reading fills the socket buffer; the
                    // blocking send() would then hold writeLock forever and
                    // stall stop()/cancellation. A 10 s send ceiling is far
                    // above any legitimate client's drain time and turns a
                    // wedged peer into an ordinary send failure (EAGAIN).
                    var sendTimeout = timeval(tv_sec: 10, tv_usec: 0)
                    _ = setsockopt(
                        clientFD, SOL_SOCKET, SO_SNDTIMEO,
                        &sendTimeout, socklen_t(MemoryLayout<timeval>.size)
                    )
                    guard let connection = ControlConnection(fd: clientFD, maxMessageSize: maxMessageSize) else {
                        Darwin.close(clientFD)
                        continue
                    }
                    await self?.track(connection: connection)
                    Task {
                        await connection.serve(handler: handler)
                    }
                }
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        // Closes the listener exactly once AND writes the wake byte: on
        // Darwin closing a listening socket never wakes poll()/accept(),
        // so without that byte the accept task would leak past stop().
        listenerState.closeListenerAndWake()
        acceptTask?.cancel()
        acceptTask = nil
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        unlink(path)
    }

    /// Test/diagnostics hook: live connections by id.
    public var activeConnections: [String: ControlConnection] {
        connections
    }

    // MARK: Connection registry

    private func track(connection: ControlConnection) {
        // A connection accepted just before stop() can land here after the
        // registry was already drained: reject-and-close it instead of
        // registering into a stopped server, where nothing would ever reap
        // its open descriptor. (Actor isolation serializes this against
        // stop(), so `isRunning` is a stable verdict here.)
        guard isRunning else {
            connection.close()
            return
        }
        connections[connection.id] = connection
        connection.onClose = { [weak self] connectionID in
            Task { await self?.forget(connectionID: connectionID) }
        }
    }

    private func forget(connectionID: String) {
        connections.removeValue(forKey: connectionID)
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case posix(String, Int32)

    public var description: String {
        switch self {
        case let .posix(call, errnoValue):
            "unix socket \(call) failed: errno \(errnoValue)"
        }
    }
}

// MARK: - Connection

/// One accepted client. Writes are serialized by a lock because responses,
/// cached replays, and subscription frames may originate from different tasks;
/// reads run in the connection's own serve task.
public final class ControlConnection: @unchecked Sendable {
    public let id: String
    public private(set) var fd: Int32
    private let maxMessageSize: Int
    private let writeLock = NSLock()
    private var closeWatcherStarted = false
    // Guarded by writeLock. fd teardown is split in two: shutdown(2) — safe
    // to run while a reader/writer is parked on fd, and what wakes it — and
    // the final Darwin.close(2), deferred until no thread can still be
    // inside send()/recv(): owned by the serve loop's exit, or performed by
    // finish() directly when no serve loop is running.
    private var serveLoopRunning = false
    private var fdIsShutdown = false
    private var finishStarted = false
    private let closedState = ClosedState()

    var onClose: (@Sendable (String) -> Void)?

    private final class ClosedState: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var continuations: [AsyncStream<Void>.Continuation] = []

        var isClosed: Bool {
            lock.withLock { closed }
        }

        /// Registers a closed-awaiter BEFORE checking the flag to avoid the
        /// lost-signal race.
        func awaitClosureStream() -> AsyncStream<Void> {
            lock.lock()
            if closed {
                lock.unlock()
                return AsyncStream { $0.finish() }
            }
            return AsyncStream { continuation in
                continuations.append(continuation)
                lock.unlock()
            }
        }

        func markClosed() {
            let drained: [AsyncStream<Void>.Continuation] = lock.withLock {
                let wasClosed = closed
                closed = true
                let drained = continuations
                continuations = []
                return wasClosed ? [] : drained
            }
            for continuation in drained {
                continuation.finish()
            }
        }
    }

    init?(fd: Int32, maxMessageSize: Int) {
        guard fd >= 0 else { return nil }
        id = UUID().uuidString
        self.fd = fd
        self.maxMessageSize = maxMessageSize
    }

    deinit {
        closeFD()
    }

    // MARK: Writing

    /// Sends one encoded response envelope as an NDJSON line.
    public func send(_ response: ControlResponse) throws {
        try send(raw: ControlWire.encode(response))
    }

    /// Sends one event notification frame as an NDJSON line.
    public func send(frame: [String: JSONValue]) throws {
        try send(raw: ControlWire.encode(eventFrame: frame))
    }

    /// Sends pre-encoded wire data (used for cached idempotent replays).
    public func send(raw data: Data) throws {
        // Attempt the whole write under the lock, capturing any failure;
        // teardown happens AFTER the lock is released because finish() takes
        // writeLock itself (closeFD) — calling it re-entrantly would deadlock.
        let failure: ControlFailure? = writeLock.withLock {
            do {
                guard !closedState.isClosed else {
                    throw ControlFailure(code: .cancelled, message: "connection closed")
                }
                try data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.send(fd, base + offset, raw.count - offset, 0)
                        if written < 0 {
                            guard errno == EINTR else {
                                throw ControlFailure(code: .cancelled, message: "send failed")
                            }
                            continue
                        }
                        if written == 0 {
                            throw ControlFailure(code: .cancelled, message: "send failed")
                        }
                        offset += written
                    }
                }
                return nil
            } catch {
                return error as? ControlFailure
                    ?? ControlFailure(code: .cancelled, message: "send failed")
            }
        }
        guard let failure else { return }
        // A failed/short send may have written PARTIAL bytes of this NDJSON
        // line (e.g. SO_SNDTIMEO timeout). The frame is torn: no further
        // responses may append mid-line, so finish() tears down the
        // connection (idempotent via closedState.markClosed) before throwing.
        finish()
        throw failure
    }

    // MARK: Reading / dispatch loop

    /// First index of `\n` inside `chunk[range]` via libc `memchr`: a plain
    /// pointer-based scan that stays fast even in unoptimized builds, where
    /// generic `firstIndex(of:)` is not specialized. Scanning only fresh
    private func firstNewline(in chunk: [UInt8], range: Range<Int>) -> Int? {
        chunk.withUnsafeBufferPointer { buffer -> Int? in
            guard let base = buffer.baseAddress else { return nil }
            let start = base + range.lowerBound
            guard let hit = memchr(start, 0x0A, range.count) else { return nil }
            return UnsafeRawPointer(start).distance(to: UnsafeRawPointer(hit)) + range.lowerBound
        }
    }

    /// Serial request loop per §3.18: parse → handle → next line. Returns
    /// when the peer disconnects, sends EOF, or a fatal framing error occurs.
    func serve(handler: @Sendable (ControlRequest, ControlConnection) async -> Void) async {
        writeLock.withLock { serveLoopRunning = true }
        // The serve loop owns the final close: it runs only after this task
        // has drained, so no recv/send can still be in flight against fd.
        defer {
            writeLock.withLock { serveLoopRunning = false }
            closeFD()
        }
        var pending: [UInt8] = []
        pending.reserveCapacity(65536)
        let chunkSize = 65536
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            // Snapshot under writeLock; the blocking recv itself runs
            // outside the lock because concurrent teardown only shuts down.
            let readFD = writeLock.withLock { fd }
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(readFD, raw.baseAddress, chunkSize, 0)
            }
            // Snapshot errno IMMEDIATELY: it must be read before any
            // intervening operation (the lock ops below) can clobber it.
            let recvErrno = received < 0 ? errno : 0
            // Revalidate the snapshot under the lock: a concurrent shutdown
            // must turn whatever this recv returned into EOF — bytes read
            // from a shut-down descriptor are never dispatched.
            let invalidated = writeLock.withLock { fdIsShutdown || fd != readFD }
            if received < 0 {
                if recvErrno == EINTR, !invalidated {
                    continue // interrupted by a signal — the peer is still there
                }
            }
            if received <= 0 || invalidated {
                break // peer closed, error, or concurrent teardown
            }

            // Dispatch every complete line whose terminator landed in this
            // chunk; only fresh bytes are scanned for newlines.
            var cursor = 0
            while cursor < received, let newlineIndex = firstNewline(in: chunk, range: cursor ..< received) {
                pending.append(contentsOf: chunk[cursor ..< newlineIndex])
                cursor = newlineIndex + 1
                if pending.last == 0x0D {
                    pending.removeLast()
                } // tolerate CRLF

                let text = String(decoding: pending, as: UTF8.self)
                pending.removeAll(keepingCapacity: true)
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    continue
                }

                guard trimmed.utf8.count <= maxMessageSize else {
                    // Oversized frame: structured rejection, then close — no
                    // resynchronization inside an oversized frame.
                    try? send(.failure(
                        ControlFailure(
                            code: .payloadTooLarge,
                            message: "frame exceeds \(maxMessageSize) byte limit"
                        ),
                        requestID: ""
                    ))
                    finish()
                    return
                }

                switch try? ControlWire.parse(line: Substring(trimmed)) {
                case let .request(request):
                    await handler(request, self)
                case .response:
                    // A client never speaks response frames; ignore politely.
                    continue
                case nil:
                    try? send(.failure(
                        ControlFailure(code: .badRequest, message: "malformed JSON frame"),
                        requestID: ""
                    ))
                }
            }
            pending.append(contentsOf: chunk[cursor ..< received])

            // Guard against unbounded buffering between newlines.
            if pending.count > maxMessageSize {
                try? send(.failure(
                    ControlFailure(
                        code: .payloadTooLarge,
                        message: "frame exceeds \(maxMessageSize) byte limit"
                    ),
                    requestID: ""
                ))
                finish()
                return
            }
        }
        finish()
    }

    /// Awaits connection closure (for racing long-running operations such as
    /// agent.wait cancellation on disconnect).
    ///
    /// The serve loop cannot notice a dead peer while it is blocked inside a
    /// long-running handler, so closure detection uses a dedicated watcher on
    /// the socket itself: `poll()` blocks until readability/hangup, then a
    /// MSG_PEEK probe distinguishes "data for the serve loop" from EOF.
    /// This is socket-liveness watching, not request polling.
    public func awaitClosed() async {
        startCloseWatcherIfNeeded()
        let stream = closedState.awaitClosureStream()
        for await _ in stream {}
    }

    private func startCloseWatcherIfNeeded() {
        writeLock.lock()
        let alreadyStarted = closeWatcherStarted
        closeWatcherStarted = true
        let watchFD = fd
        writeLock.unlock()
        guard !alreadyStarted, watchFD >= 0 else { return }

        Thread.detachNewThread { [weak self] in
            var fds = pollfd(fd: watchFD, events: Int16(POLLIN), revents: 0)
            while true {
                // Finite timeout: if the watched fd is closed elsewhere and
                // its number gets reused by another connection, poll would
                // otherwise report foreign events forever. Bound each wait
                // and re-check this connection's own closed state.
                let result = poll(&fds, 1, 1000)
                if result < 0, errno == EINTR {
                    continue
                }
                if result == 0 {
                    // Quiet-but-alive timeout: keep watching unless this
                    // connection's own lifecycle already ended.
                    guard let self, !self.closedState.isClosed else { return }
                    continue
                }
                if result < 0 {
                    // Poll is permanently broken for this fd: bail out,
                    // closing conservatively unless closure already happened.
                    if let self {
                        if !closedState.isClosed {
                            close()
                        }
                        return
                    }
                    return
                }
                if fds.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    self?.close()
                    return
                }
                if fds.revents & Int16(POLLIN) != 0 {
                    var probe: UInt8 = 0
                    let peeked = recv(watchFD, &probe, 1, MSG_PEEK | MSG_DONTWAIT)
                    if peeked == 0 {
                        // Orderly EOF: the peer is gone.
                        self?.close()
                        return
                    }
                    // Inbound data belongs to the serve loop; back off so
                    // this watcher never spins against it.
                    usleep(20000)
                }
                // Exit when this connection's own lifecycle ended, even if
                // poll keeps reporting events from a reused fd number.
                guard let self, !self.closedState.isClosed else { return }
            }
        }
    }

    public func close() {
        finish()
    }

    private func finish() {
        // shutdown(2) under writeLock wakes any blocking recv/send so the
        // serve loop drains and performs the final close exactly once. With
        // no serve loop running (idle-connection close) nothing would ever
        // drain, so finish closes directly here instead of leaking the fd.
        let closeNow: Bool = writeLock.withLock {
            if finishStarted {
                return false
            }
            finishStarted = true
            fdIsShutdown = true
            if fd >= 0 {
                shutdown(fd, Int32(SHUT_RDWR))
            }
            return !serveLoopRunning
        }
        closedState.markClosed()
        if closeNow {
            closeFD()
        }
        onClose?(id)
    }

    /// Final reclamation of the descriptor: idempotent, runs only once the
    /// fd can no longer be observed by send()/recv() (serve-loop exit or
    /// the direct finish path).
    private func closeFD() {
        writeLock.withLock {
            guard fd >= 0 else { return }
            let doomed = fd
            fd = -1
            Darwin.close(doomed)
        }
    }
}

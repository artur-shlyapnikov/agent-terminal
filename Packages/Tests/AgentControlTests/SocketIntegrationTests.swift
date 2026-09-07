@testable import AgentControl
import AgentCore
import Foundation
import XCTest

// §4.8 SocketIntegrationTests — real-socket integration: 0600 enforcement,
// framing limits, auth/generation/seq handling, idempotent prompt delivery
// (exactly-once), race-closed wait, disconnect cancellation.

// MARK: - Test double runtime

/// Controllable `ControlRuntime` double with delivery counting so the
/// exactly-once prompt guarantee is observable.
final class FakeControlRuntime: ControlRuntime, @unchecked Sendable {
    private let lock = NSLock()

    var workspaces: [Workspace] = []
    var summariesByID: [AgentID: AgentSummary] = [:]

    /// Number of times a prompt was actually handed to the (fake) terminal.
    private(set) var deliveredPrompts: [AgentID: Int] = [:]
    private(set) var ingestedEvidence: [Evidence] = []
    private(set) var surfaceCreatedCalls: [(agentID: AgentID, terminalID: TerminalID, generation: SurfaceGeneration)] =
        []

    var nextPromptOutcome: PromptOutcome = .delivered
    /// When set, `prompt()` suspends every caller until `releasePromptGate()`
    /// — drives deterministic in-flight races across connections.
    var holdsPrompts = false
    /// When set, `state(of:)` returns these values in order before falling
    /// back to the summary state; used to simulate transitions inside the
    /// wait-race window deterministically.
    var scriptedStates: [AgentState] = []
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []

    func releasePromptGate() {
        lock.lock()
        holdsPrompts = false
        let waiters = promptWaiters
        promptWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private var stream: AsyncStream<RuntimeDelta>?
    private var continuation: AsyncStream<RuntimeDelta>.Continuation?

    func deltaStream() -> AsyncStream<RuntimeDelta> {
        // NB: never hold `lock` while constructing the stream — the builder
        // closure runs synchronously and would self-deadlock.
        lock.lock()
        let existing = stream
        lock.unlock()
        if let existing {
            return existing
        }

        var stored: AsyncStream<RuntimeDelta>.Continuation?
        let fresh = AsyncStream<RuntimeDelta> { continuation in
            stored = continuation
        }
        lock.lock()
        if let existing = stream {
            lock.unlock()
            stored?.finish()
            return existing
        }
        continuation = stored
        stream = fresh
        lock.unlock()
        return fresh
    }

    func emit(_ summary: AgentSummary) {
        lock.lock()
        summariesByID[summary.id] = summary
        let continuation = continuation
        lock.unlock()
        continuation?.yield(.agentChanged(summary))
    }

    // MARK: ControlRuntime

    func listWorkspaces() async -> [Workspace] {
        lock.withLock { workspaces }
    }

    func createAgent(_: AgentLaunchRequest, in workspaceID: WorkspaceID) async throws -> AgentID {
        let agentID = AgentID()
        lock.withLock {
            summariesByID[agentID] = Self.summary(
                id: agentID,
                workspaceID: workspaceID,
                lifecycle: .starting,
                revision: 1
            )
        }
        return agentID
    }

    func summaries() async -> [AgentSummary] {
        lock.withLock { Array(summariesByID.values) }
    }

    func summary(of agentID: AgentID) async -> AgentSummary? {
        lock.withLock { summariesByID[agentID] }
    }

    func prompt(_ agentID: AgentID, _: String, _: PromptPolicy) async throws -> PromptReceipt {
        let holds = lock.withLock {
            deliveredPrompts[agentID, default: 0] += 1
            return holdsPrompts
        }
        // Park AFTER counting so tests can observe "dispatch in progress".
        if holds {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                promptWaiters.append(cont)
                lock.unlock()
            }
        }
        return PromptReceipt(commandID: CommandID(), agentID: agentID, outcome: nextPromptOutcome)
    }

    func cancelQueuedPrompt(_: AgentID) async throws {}

    func focus(_: AgentID) async throws {}

    func interrupt(_: AgentID) async throws {}

    func stop(_: AgentID, mode _: StopMode) async throws {}

    func resume(_: AgentID) async throws {}

    func read(_: AgentID, source _: TerminalReadSource) async throws -> TerminalSnapshot {
        TerminalSnapshot(text: "fake screen", outputRevision: 1, generation: .initial)
    }

    func state(of agentID: AgentID) async throws -> AgentState {
        try lock.withLock { () -> AgentState in
            if !scriptedStates.isEmpty {
                return scriptedStates.removeFirst()
            }
            guard let summary = summariesByID[agentID] else {
                throw RuntimeErrors.agentNotFound
            }
            return summary.state
        }
    }

    func surfaceCreated(
        agentID: AgentID,
        terminalID: TerminalID,
        generation: SurfaceGeneration,
        pid _: Int32?,
        processGroupID _: Int32?
    ) async throws {
        lock.withLock {
            surfaceCreatedCalls.append((agentID, terminalID, generation))
        }
    }

    func ingest(_ evidence: Evidence) async {
        lock.withLock {
            ingestedEvidence.append(evidence)
        }
    }

    func integrationExpired(sourceID _: String, agentID _: AgentID) async {}

    // Helpers

    static func summary(
        id: AgentID = AgentID(),
        workspaceID: WorkspaceID = WorkspaceID(),
        lifecycle: LifecyclePhase,
        revision: UInt64
    ) -> AgentSummary {
        let session = AgentSession(
            id: id,
            workspaceID: workspaceID,
            kind: .genericShell,
            displayName: "test",
            taskSummary: nil,
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: .genericShell,
                program: "sh",
                arguments: [],
                workingDirectory: "/tmp"
            ),
            resumePolicy: .none,
            state: AgentState(lifecycle: lifecycle, revision: revision, observedAt: MonotonicInstant.zero),
            createdAt: MonotonicInstant.zero,
            lastActivityAt: MonotonicInstant.zero
        )
        return AgentSummary(session: session)
    }
}

// MARK: - Harness

final class SocketHarness {
    let runtime: FakeControlRuntime
    let hooks: HookAuthenticator
    let broker: EventStreamBroker
    let router: ControlRequestRouter
    let server: UnixSocketServer
    let socketPath: String
    let token = "hook-token-\(UUID().uuidString)"
    let agentID = AgentID()

    init() throws {
        runtime = FakeControlRuntime()
        hooks = HookAuthenticator()
        broker = EventStreamBroker(streamProvider: { [runtime] in runtime.deltaStream() })
        router = ControlRequestRouter(runtime: runtime, hooks: hooks, broker: broker)
        socketPath = "/tmp/aterm-ctl-\(UUID().uuidString.prefix(8)).sock"
        server = try UnixSocketServer(path: socketPath) { [router] request, connection in
            await router.handle(request, connection: connection)
        }
        runtime.summariesByID[agentID] = FakeControlRuntime.summary(
            id: agentID,
            lifecycle: .working,
            revision: 5
        )
    }

    func start() async throws {
        try await server.start()
    }

    func stop() async {
        await server.stop()
    }

    func client() throws -> ControlClient {
        try ControlClient(socketPath: socketPath)
    }
}

// MARK: - Tests

final class SocketIntegrationTests: XCTestCase {
    static func extractReceiptCommandID(from stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let receipt = object["result"] as? [String: Any],
              let inner = receipt["receipt"] as? [String: Any] else { return nil }
        return inner["commandID"] as? String
    }

    static func locateAgentctl() throws -> URL {
        // SwiftPM places executables next to the test runner's build dir.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AgentControlTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Packages
        let candidates = [
            packageRoot.appendingPathComponent(".build-control/debug/agentctl"),
            packageRoot.appendingPathComponent(".build/debug/agentctl"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw XCTSkip("agentctl binary not built yet at \(candidates.map(\.path))")
    }

    func runProcess(_ executable: URL, _ arguments: [String]) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Bounded exit wait (mirrors runAgentctl in AgentctlCliTests): a
        // wedged child is terminated instead of hanging the runner in an
        // unbounded readDataToEndOfFile. Reading only AFTER the exit wait
        // also cannot deadlock on a full 64 KB pipe buffer — termination
        // unblocks a write-blocked child.
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       "\(executable.lastPathComponent) \(arguments.dropFirst().dropFirst()) exited \(process.terminationStatus)")
        return (String(decoding: data, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    // MARK: Shared helpers

    func reportLifecycle(
        _ harness: SocketHarness,
        token: String,
        seq: UInt64,
        generation: UInt64,
        commandID: String? = nil
    ) throws -> ControlResponse {
        let client = try harness.client()
        defer { client.close() }
        return try client.roundtrip(method: ControlMethod.integrationReport.rawValue, params: [
            "agentID": .string(harness.agentID.rawValue.uuidString),
            "surfaceGeneration": .uint64(generation),
            "source": "hook:test",
            "seq": .uint64(seq),
            "lifecycle": .string("working"),
            "token": .string(token),
        ], commandID: commandID)
    }

    /// Runs `agentctl agent wait` on a background thread and returns the
    /// parsed result object from stdout (nil when the CLI failed).
    func runWait(
        _ harness: SocketHarness,
        targets: Set<String>,
        timeoutMs: UInt64
    ) async throws -> [String: JSONValue]? {
        let arguments = [
            "--socket", harness.socketPath,
            "agent", "wait", harness.agentID.rawValue.uuidString,
            "--lifecycle", targets.joined(separator: ","),
            "--timeout-ms", String(timeoutMs),
        ]
        guard let binary = try? Self.locateAgentctl() else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let process = Process()
                    process.executableURL = binary
                    process.arguments = arguments
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = Pipe()
                    try process.run()
                    // Bounded exit wait (mirrors runAgentctl): a wedged
                    // agentctl must not hang this detached thread in an
                    // unbounded pipe read forever.
                    let deadline = Date().addingTimeInterval(15)
                    while process.isRunning, Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    if process.isRunning {
                        process.terminate()
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let result = object?["result"].map(Self.foundationToJSONValues)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func foundationToJSONValues(_ any: Any) -> [String: JSONValue] {
        guard let dictionary = any as? [String: Any] else { return [:] }
        var result: [String: JSONValue] = [:]
        for (key, value) in dictionary {
            switch value {
            case is NSNull: result[key] = .null
            case let bool as Bool: result[key] = .bool(bool)
            case let number as NSNumber: result[key] = .int(number.int64Value)
            case let string as String: result[key] = .string(string)
            default: break
            }
        }
        return result
    }

    // Raw POSIX helpers for framing-level tests.

    func openRawSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.posix("socket", errno) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let failure = errno
            close(fd)
            throw SocketError.posix("connect", failure)
        }
        return fd
    }

    /// Reads bytes from `fd` up to the first newline (excluded). Tolerates
    /// SO_RCVTIMEO expiry (EAGAIN/EWOULDBLOCK) for up to `budgetSeconds`,
    /// so a legitimately slow reply (a ~30s `agent.wait` timeout) is still
    /// observed. Fails fast on peer EOF and any other hard error.
    func readLine(fd: Int32, budgetSeconds: Int = 35) async throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(Double(budgetSeconds))
        var buffer: [UInt8] = []
        // This helper owns no persistent receive buffer. Read exactly one
        // byte so coalesced replies remain available to the next call.
        var chunk = [UInt8](repeating: 0, count: 1)
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                return Array(buffer[0 ..< index])
            }
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, 1, 0)
            }
            if received > 0 {
                buffer.append(contentsOf: chunk[0 ..< received])
                continue
            }
            if received == 0 {
                throw SocketError.posix("recv", ECONNRESET)
            }
            let failure = errno
            guard failure == EAGAIN || failure == EWOULDBLOCK else {
                throw SocketError.posix("recv", failure)
            }
            guard Date() < deadline else {
                throw SocketError.posix("recv", EAGAIN)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Polls until `condition` holds or the budget lapses. Shrinks
    /// "processed while X still holds" windows to the minimum that keeps
    /// assertion strength; the caller asserts afterwards either way.
    func waitUntil(
        budgetMilliseconds: Int,
        intervalMilliseconds: Int = 2,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(Double(budgetMilliseconds) / 1000)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
        }
    }

    /// Returns once `fd` has readable bytes queued (or hit EOF/error) —
    /// i.e. as soon as the server has produced a response frame. Returns
    /// false when the budget lapsed with nothing queued: callers must treat
    /// a lapse as a failed premise, never release a gate on it silently.
    func waitForResponse(fd: Int32, budgetMilliseconds: Int) async -> Bool {
        var responded = false
        await waitUntil(budgetMilliseconds: budgetMilliseconds) {
            var probe = [UInt8](repeating: 0, count: 1)
            let peeked = probe.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, 1, MSG_PEEK | MSG_DONTWAIT)
            }
            if peeked >= 0 {
                responded = true
                return true
            }
            return errno != EAGAIN
        }
        return responded
    }
}

extension SocketHarness {
    static func make() throws -> SocketHarness {
        try SocketHarness()
    }

    func waitUntilListening() async throws {
        // The listen socket exists synchronously after start(); poll briefly
        // for connectability to avoid flakes.
        for _ in 0 ..< 100 {
            if let client = try? ControlClient(socketPath: socketPath) {
                client.close()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTFailure("socket never became connectable")
    }

    struct XCTFailure: LocalizedError {
        let message: String
        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }
}

extension FakeControlRuntime {
    func setState(_ phase: LifecyclePhase, revision: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        for (id, existing) in summariesByID {
            summariesByID[id] = Self.summary(
                id: id,
                workspaceID: existing.workspaceID,
                lifecycle: phase,
                revision: revision
            )
        }
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ delta: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += delta
        return value
    }
}

/// Terminal port double counting actual input deliveries for the live smoke.
final class DeliveryCountingTerminalPort: TerminalControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func deliverInput(_: TerminalID, text _: String, submit _: Bool) async throws {
        lock.withLock { count += 1 }
    }

    func sendKeys(_: TerminalID, keys _: [String]) async throws {}

    func sendSignal(_: SignalIntent, to _: TerminalID) async throws {}

    func read(_: TerminalID, source _: TerminalReadSource) async throws -> TerminalSnapshot? {
        TerminalSnapshot(text: "", outputRevision: 0, generation: .initial)
    }
}

extension EventStreamBroker {
    /// Broker bound to a live AgentRuntime's delta stream.
    static func streamBound(to runtime: AgentRuntime) -> EventStreamBroker {
        EventStreamBroker(streamProvider: EventStreamBroker.provider(for: runtime))
    }
}

/// File-local raw-fd fixture for framing-level unit laws: an AF_UNIX
/// SOCK_STREAM socketpair, the hermetic stand-in for a live accept path.
func makeSocketpair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw SocketError.posix("socketpair", errno)
    }
    return (fds[0], fds[1])
}

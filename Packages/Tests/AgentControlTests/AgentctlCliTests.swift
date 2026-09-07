import AgentControl
import AgentCore
import Foundation
import XCTest

// Round 4 black-box coverage of the `agentctl` executable (architecture §3.16):
// the spawned REAL binary is driven against a scripted control-plane double, so
// argv→wire plumbing, exit codes (0 ok / 1 failure / 2 wait timeout), the
// once-per-invocation version handshake, usage-error ordering, and the
// event-driven `agent wait` algorithm are pinned end-to-end over a live
// AF_UNIX socket. No production seams — the socket path is injected through
// the public `--socket` flag or `AGENT_TERMINAL_CONTROL_SOCKET`.
//
// Binary lookup mirrors AgentLauncherSmokeTests: the product built by
// `swift build --product agentctl` into `<pkg>/.build/debug/agentctl` is
// located, never rebuilt here.

// MARK: - Scripted server

final class ScriptedServer: @unchecked Sendable {
    let socketPath = "/tmp/aterm-clictl-\(UUID().uuidString.prefix(8)).sock"
    private let server: UnixSocketServer
    private let log: RequestLog
    private let responderBox: ResponderBox
    private let hookBox: HookBox

    init() throws {
        responderBox = ResponderBox { _, _, requestID in
            .okEcho(requestID, result: [
                "protocolVersion": .int(Int64(ProtocolVersion.current)),
                "implementation": "agent-terminal-control",
            ])
        }
        // The handler captures the fully-initialized boxes as LOCAL constants
        // — capturing self mid-initialization is forbidden by two-phase init.
        let requestLog = RequestLog()
        let scripted = responderBox
        let hookBox = HookBox()
        server = try UnixSocketServer(path: socketPath) { request, connection in
            requestLog.append(request)
            let response = scripted.body(request.method, request.params, request.requestID)
            _ = try? connection.send(response)
            // Invoked after the standard log+reply, with the LIVE connection —
            // lets a test push event frames or close mid-stream (public API:
            // connection.send(frame:) / connection.close()).
            if let hook = hookBox.body {
                hook(request, connection)
            }
        }
        log = requestLog
        self.hookBox = hookBox
    }

    /// Optional post-reply hook (see handler above); nil by default, so the
    /// nine pre-existing scripted tests are untouched.
    var onRequest: (@Sendable (ControlRequest, ControlConnection) -> Void)? {
        get { hookBox.body }
        set { hookBox.body = newValue }
    }

    var responder: @Sendable (String, [String: JSONValue], String) -> ControlResponse {
        get { responderBox.body }
        set { responderBox.body = newValue }
    }

    var requests: [(method: String, params: [String: JSONValue], commandID: String?, requestID: String)] {
        log.requests
    }

    /// The server actor's async lifecycle bridged for synchronous tests.
    /// The outcome is written before the semaphore signal and read after the
    /// wait — the semaphore provides the memory ordering, so no lock is
    /// touched inside the async context.
    func start() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var startError: (any Error)?
        Task {
            do {
                try await self.server.start()
            } catch {
                startError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let startError {
            throw startError
        }
    }

    func stop() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await self.server.stop()
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Bounded poll for the bound socket FILE — bind is not instantaneous,
    /// and agentctl must never spawn before the endpoint exists.
    func awaitListening(timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("scripted server never bound \(socketPath) within \(timeout)s")
    }
}

/// NSLock-guarded request recorder; the handler closure hops executors.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: [String: JSONValue], commandID: String?, requestID: String)] = []

    func append(_ request: ControlRequest) {
        lock.lock()
        recorded.append((request.method, request.params, request.commandID, request.requestID))
        lock.unlock()
    }

    var requests: [(method: String, params: [String: JSONValue], commandID: String?, requestID: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// Indirection that lets tests swap the scripted answer after the server exists.
final class ResponderBox: @unchecked Sendable {
    var body: @Sendable (String, [String: JSONValue], String) -> ControlResponse

    init(_ initial: @escaping @Sendable (String, [String: JSONValue], String) -> ControlResponse) {
        body = initial
    }
}

/// Indirection holding the optional live-connection hook — same two-phase-init
/// pattern as ResponderBox: the server handler captures the LOCAL box constant,
/// tests swap the hook through the `onRequest` accessor afterwards.
final class HookBox: @unchecked Sendable {
    var body: (@Sendable (ControlRequest, ControlConnection) -> Void)?
}

extension ControlResponse {
    static func okEcho(_ requestID: String, result: [String: JSONValue] = [:]) -> ControlResponse {
        .success(requestID, result)
    }
}

// MARK: - Process runner

/// Spawn result triple (mirror of AgentLauncherSmokeTests.RunResult).
struct CliRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs the REAL agentctl binary; mirrors AgentLauncherSmokeTests.runLauncher:
/// bounded poll loop at 10 ms, terminate()+XCTFail on overrun.
///
/// Default capture is pipes. `events subscribe` calls
/// FileHandle.synchronizeFile() after every frame, which RAISES on a
/// non-seekable pipe — pass `captureThroughFiles: true` to capture through
/// regular files (the production stdout shape) instead.
@discardableResult
func runAgentctl(
    _ arguments: [String],
    environment: [String: String] = [:],
    socketFlag: String? = nil,
    timeout: TimeInterval = 10,
    captureThroughFiles: Bool = false
) throws -> CliRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: AgentctlCliTests.agentctlBinary)
    var argv = arguments
    if let socketFlag {
        argv += ["--socket", socketFlag]
    }
    process.arguments = argv

    var merged = ProcessInfo.processInfo.environment
    for (key, value) in environment {
        merged[key] = value
    }
    process.environment = merged

    let stdoutPipe = Pipe(), stderrPipe = Pipe()
    // NOTE: the capture directory is removed after the reads below — a
    // `defer` inside this if-block would fire at BLOCK exit, i.e. BEFORE the
    // child even launched, leaving its fds pointing at unlinked inodes.
    var captureDir: URL?
    if captureThroughFiles {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-cli-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let stdoutFileURL = directory.appendingPathComponent("stdout")
        let stderrFileURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutFileURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrFileURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: stdoutFileURL)
        process.standardError = try FileHandle(forWritingTo: stderrFileURL)
        captureDir = directory
    } else {
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        process.terminate()
        XCTFail("agentctl timed out after \(timeout)s: \(arguments)")
    }

    func readCaptured(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    let stdoutText: String
    let stderrText: String
    if let captureDir {
        stdoutText = readCaptured(captureDir.appendingPathComponent("stdout"))
        stderrText = readCaptured(captureDir.appendingPathComponent("stderr"))
        try? FileManager.default.removeItem(at: captureDir)
    } else {
        stdoutText = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        stderrText = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
    return CliRun(
        status: process.terminationStatus,
        stdout: stdoutText,
        stderr: stderrText
    )
}

/// Parses the CLI's stdout JSON envelope (never force-cast).
func stdoutEnvelope(_ run: CliRun) throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any],
        "stdout was not a JSON object: '\(run.stdout)'"
    )
}

// MARK: - Tests

final class AgentctlCliTests: XCTestCase {
    static let packageRoot: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/AgentControlTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Packages
        .path

    /// Locates the agentctl executable produced by `swift build --product
    /// agentctl` — next to the xctest bundle first, then the canonical build
    /// directory. Never rebuilt here.
    fileprivate static let agentctlBinary: String = {
        var candidates: [String] = []
        let bundleParent = URL(fileURLWithPath: Bundle(for: AgentctlCliTests.self).bundlePath)
            .deletingLastPathComponent()
        candidates.append(bundleParent.appendingPathComponent("agentctl").path)
        candidates.append(packageRoot + "/.build/debug/agentctl")
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        XCTFail(
            "agentctl binary not found; run `swift build --product agentctl` first. Looked in:\n\(candidates.joined(separator: "\n"))"
        )
        return ""
    }()

    override class func setUp() {
        super.setUp()
        _ = agentctlBinary
    }
}

// MARK: - Detached runner (M19)

/// Box holding the live control connection captured by an `onRequest` hook
/// so a test can close it later from outside the handler.
final class LiveConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ControlConnection?

    func store(_ connection: ControlConnection) {
        lock.withLock { stored = connection }
    }

    var connection: ControlConnection? {
        lock.withLock { stored }
    }
}

/// Spawn result of `runAgentctlDetached`: the process is left RUNNING with
/// stdout/stderr captured through regular files. File-backed capture ONLY —
/// the flush discrimination relies on the child's FILE\* buffering; pipes
/// would change the buffering mode under test.
struct DetachedCliRun {
    let process: Process
    let stdoutURL: URL
    let stderrURL: URL
    let captureDir: URL
}

/// Mirrors `runAgentctl(captureThroughFiles: true)` setup verbatim but returns
/// WITHOUT waiting for exit, so a test can observe incremental stdout while
/// the child is still connected (M19). The caller owns cleanup.
func runAgentctlDetached(
    _ arguments: [String],
    environment: [String: String] = [:],
    socketFlag: String? = nil
) throws -> DetachedCliRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: AgentctlCliTests.agentctlBinary)
    var argv = arguments
    if let socketFlag {
        argv += ["--socket", socketFlag]
    }
    process.arguments = argv

    var merged = ProcessInfo.processInfo.environment
    for (key, value) in environment {
        merged[key] = value
    }
    process.environment = merged

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aterm-cli-capture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stdoutFileURL = directory.appendingPathComponent("stdout")
    let stderrFileURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutFileURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrFileURL.path, contents: nil)
    process.standardOutput = try FileHandle(forWritingTo: stdoutFileURL)
    process.standardError = try FileHandle(forWritingTo: stderrFileURL)

    try process.run()
    return DetachedCliRun(
        process: process,
        stdoutURL: stdoutFileURL,
        stderrURL: stderrFileURL,
        captureDir: directory
    )
}

func readCapturedFile(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

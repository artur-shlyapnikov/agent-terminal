import AgentControl
import AgentCore
@testable import AgentLauncher
import Foundation
import XCTest

/// Stage 4a integration tests: run the REAL AgentLauncher binary against
/// hand-written ticket JSON (the wire contract itself, not Swift structs),
/// covering every §3.9 launch-ticket rule that is observable from outside
/// the helper process.
///
/// The binary is the one `swift test` already links into the package build
/// directory (the test target depends on the AgentLauncher target) — it is
/// located, never rebuilt here, so no isolated scratch root is created.
///
/// Untestable-from-outside rules and their coverage story:
/// * "environment не записывается в SQLite" and "prompt не включается в
///   ticket" — producer-side guarantees (TerminalKit writer, stage 8); the
///   consumer cannot observe persistence or absence.
/// * O_NOFOLLOW symlink rejection is exercised via the symlink test (ELOOP).
/// * setpgid(0,0) is asserted indirectly: reported pgid == reported pid.
final class AgentLauncherSmokeTests: XCTestCase {
    private static let packageRoot: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/AgentLauncherTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Packages
        .path

    /// Locates the AgentLauncher executable produced by `swift test` itself.
    /// A separate `swift build --scratch-path .build-launcher-test` here used
    /// to recompile the whole dependency chain per suite run (~5 s and a
    /// second 0.5–1 GB scratch root); reading the existing binary is free.
    private static let launcherBinary: String = {
        // Primary: next to the xctest bundle that hosts this suite
        // (<build-dir>/AgentTerminalPackageTests.xctest/../AgentLauncher).
        var candidates: [String] = []
        let bundleParent = URL(fileURLWithPath: Bundle(for: AgentLauncherSmokeTests.self).bundlePath)
            .deletingLastPathComponent()
        candidates.append(bundleParent.appendingPathComponent("AgentLauncher").path)
        // Fallback: canonical package build dir via the source-tree path.
        candidates.append(packageRoot + "/.build/debug/AgentLauncher")
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        XCTFail(
            "AgentLauncher binary not found; run `swift build --build-tests` first. Looked in:\n\(candidates.joined(separator: "\n"))"
        )
        return ""
    }()

    /// Tiny C probe exec'd AS the agent: prints "0" when the inherited
    /// SIGPIPE disposition is SIG_DFL, "1" when it is SIG_IGN (which would
    /// prove the helper leaked its ignore across execve). Compiled once per
    /// suite run alongside the launcher binary.
    private static let signalProbeBinary: String = {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sigpipe-probe-\(UUID().uuidString).c")
        let binaryPath = sourceURL.deletingPathExtension().path
        let cSource = """
        #include <signal.h>
        #include <stdio.h>
        int main(void) {
            sig_t prev = signal(SIGPIPE, SIG_DFL);
            if (prev == SIG_ERR) return 3;
            printf("%d\\n", prev == SIG_DFL ? 0 : 1);
            return 0;
        }
        """
        try? Data(cSource.utf8).write(to: sourceURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        process.arguments = ["-o", binaryPath, sourceURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            XCTFail("failed to spawn cc: \(error)")
            return ""
        }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: binaryPath) else {
            XCTFail("SIGPIPE probe compile failed:\n\(output)")
            return ""
        }
        return binaryPath
    }()

    /// Tiny C probe exec'd AS the agent: exits 0 printing "clean" when the
    /// inherited signal mask is EMPTY and every conventional job-control
    /// signal is at SIG_DFL; otherwise prints what leaked. Pins the
    /// pre-execve signal normalization (blocked masks and SIG_IGN
    /// dispositions survive execve — without the fix they leak into shells).
    private static let signalHygieneProbeBinary: String = {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sighygiene-probe-\(UUID().uuidString).c")
        let binaryPath = sourceURL.deletingPathExtension().path
        let cSource = """
        #include <signal.h>
        #include <stdio.h>
        int main(void) {
            sigset_t mask;
            if (sigprocmask(SIG_SETMASK, NULL, &mask) != 0) return 3;
            // No sigisemptyset on Darwin headers: scan the mask directly.
            for (int s = 1; s < NSIG; s++) {
                if (sigismember(&mask, s) == 1) { printf("masked\\n"); return 1; }
            }
            const int sigs[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE,
                                SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD};
            for (unsigned long i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
                sig_t prev = signal(sigs[i], SIG_DFL);
                if (prev == SIG_ERR) return 3;
                if (prev != SIG_DFL) { printf("sig-%d\\n", sigs[i]); return 2; }
            }
            printf("clean\\n");
            return 0;
        }
        """
        try? Data(cSource.utf8).write(to: sourceURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        process.arguments = ["-o", binaryPath, sourceURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            XCTFail("failed to spawn cc: \(error)")
            return ""
        }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: binaryPath) else {
            XCTFail("signal-hygiene probe compile failed:\n\(output)")
            return ""
        }
        return binaryPath
    }()

    override class func setUp() {
        super.setUp()
        _ = launcherBinary
        _ = signalProbeBinary
        _ = signalHygieneProbeBinary
    }

    // MARK: - Fixtures

    /// TTL constant duplicated here so an accidental producer/consumer drift
    /// away from 60 s fails loudly rather than silently.
    private let launchTicketTTL: Double = 60

    /// Raw wire-format ticket dictionary; mirrors AgentCore.LaunchTicket JSON.
    private func baseTicket(
        cwd: String,
        argv: [String],
        environment: [String: String] = [:],
        expiresAt: Double? = nil,
        protocolVersion: Int = 1,
        expectedUID: UInt32 = UInt32(getuid()),
        surfaceGeneration: UInt64 = 7,
        controlSocketPath: String = "",
        agentID: UUID = UUID(),
        terminalID: UUID = UUID()
    ) -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "ticketID": UUID().uuidString,
            "agentID": agentID.uuidString,
            "terminalID": terminalID.uuidString,
            "surfaceGeneration": surfaceGeneration,
            "expectedUID": expectedUID,
            "createdAt": Date().timeIntervalSince1970 - 1,
            "expiresAt": expiresAt ?? Date().timeIntervalSince1970 + launchTicketTTL - 5,
            "cwd": cwd,
            "argv": argv,
            "environment": environment,
            "integrationToken": "test-token",
            "controlSocketPath": controlSocketPath,
        ]
    }

    @discardableResult
    private func writeTicket(
        _ ticket: [String: Any],
        name: String = "ticket.json",
        permissions: Int = 0o600
    ) throws -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlauncher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ticket)
        let fileURL = dir.appendingPathComponent(name)
        // posixPermissions attribute is applied explicitly, bypassing umask,
        // so the exact requested mode lands on disk.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fileURL.path, contents: data,
            attributes: [.posixPermissions: permissions]
        ))
        return (dir, fileURL.path)
    }

    private func consumingPath(for ticketPath: String) -> String {
        ticketPath + ".consuming"
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    private func runLauncher(ticketPath: String, timeout: TimeInterval = 15) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.launcherBinary)
        process.arguments = [ticketPath]

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate(); XCTFail("launcher timed out")
        }
        return RunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Happy path & exec semantics

    func testHappyPathExecsWithTicketEnvironmentAndConsumesTicket() throws {
        let agentRef = UUID().uuidString
        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/usr/bin/env"],
            environment: ["AGENT_TERMINAL_AGENT_ID": agentRef]
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains(agentRef), "child env missing injected value; got: \(result.stdout)")

        // §3.9 "ticket одноразовый" + "после чтения удаляется": neither the
        // original nor the .consuming copy survives a successful exec.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumingPath(for: fixture.path)))
    }

    func testChildExitCodePropagates() throws {
        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/bin/sh", "-c", "exit 7"]
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertEqual(result.status, 7)
    }

    // MARK: §3.9 rule rejections (exit 126, no exec)

    func testExpiredTicketIsRejectedWithoutExec() throws {
        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/usr/bin/env"],
            expiresAt: Date().timeIntervalSince1970 - 1
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        XCTAssertTrue(result.stderr.contains("expired"), "stderr: \(result.stderr)")
        // Rejected before any chdir/exec: nothing ran.
        XCTAssertTrue(result.stdout.isEmpty)
        // Single-use holds even for rejected tickets: consumed and deleted.
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumingPath(for: fixture.path)))
    }

    func testSymlinkedTicketIsRejected() throws {
        // Valid 0600 ticket plus a symlink pointing at it; handing the
        // launcher the symlink path must hit O_NOFOLLOW → ELOOP.
        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/usr/bin/env"]
        ))
        defer { cleanup(fixture.dir) }
        let linkPath = fixture.dir.appendingPathComponent("ticket-link.json").path
        try FileManager.default.createSymbolicLink(
            atPath: linkPath, withDestinationPath: fixture.path
        )

        let result = try runLauncher(ticketPath: linkPath)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status): \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("symlink"), "stderr: \(result.stderr)")
        // No consumption through the link: original untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

    func testLooseMode0644TicketIsRejected() throws {
        let fixture = try writeTicket(
            baseTicket(cwd: NSTemporaryDirectory(), argv: ["/usr/bin/env"]),
            permissions: 0o644
        )
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        XCTAssertTrue(result.stderr.contains("0600"), "stderr: \(result.stderr)")
    }

    func testGroupWritableMode0660TicketIsRejected() throws {
        let fixture = try writeTicket(
            baseTicket(cwd: NSTemporaryDirectory(), argv: ["/usr/bin/env"]),
            permissions: 0o660
        )
        defer { cleanup(fixture.dir) }
        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
    }

    func testUnsupportedProtocolVersionIsRejected() throws {
        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/usr/bin/env"],
            protocolVersion: 99
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        XCTAssertTrue(result.stderr.contains("protocolVersion"), "stderr: \(result.stderr)")
    }

    func testOwnerMismatchExpectedUIDIsRejected() throws {
        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/usr/bin/env"],
            expectedUID: UInt32(getuid()) &+ 1
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        XCTAssertTrue(result.stderr.contains("uid"), "stderr: \(result.stderr)")
    }

    func testEmptyArgvIsRejected() throws {
        let fixture = try writeTicket(baseTicket(cwd: NSTemporaryDirectory(), argv: []))
        defer { cleanup(fixture.dir) }
        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        XCTAssertTrue(result.stderr.contains("argv"))
    }

    func testRelativeCwdIsRejected() throws {
        let fixture = try writeTicket(baseTicket(cwd: "relative/path", argv: ["/usr/bin/env"]))
        defer { cleanup(fixture.dir) }
        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        XCTAssertTrue(result.stderr.contains("cwd"))
    }

    func testRelativeArgv0IsRejected() throws {
        let fixture = try writeTicket(baseTicket(cwd: NSTemporaryDirectory(), argv: ["env"]))
        defer { cleanup(fixture.dir) }
        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        XCTAssertTrue(result.stderr.contains("absolute"))
    }

    func testMalformedJSONIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlauncher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }
        let path = dir.appendingPathComponent("ticket.json").path
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path, contents: Data("{not json".utf8),
            attributes: [.posixPermissions: 0o600]
        ))

        let result = try runLauncher(ticketPath: path)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        XCTAssertTrue(result.stderr.contains("JSON"), "stderr: \(result.stderr)")
    }

    // MARK: - Single-use race semantics

    func testPreExistingConsumingFileMeansLostRaceAndNothingIsConsumed() throws {
        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/usr/bin/env"]
        ))
        defer { cleanup(fixture.dir) }
        // Another consumer already claimed the slot.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: consumingPath(for: fixture.path), contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ))

        let result = try runLauncher(ticketPath: fixture.path)

        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
        // Loser must NOT have touched either file (no diagnostics leak, no
        // deletion of the winner's claim).
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: consumingPath(for: fixture.path)))
    }

    func testMissingTicketFileIsRejected() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-\(UUID().uuidString).json").path
        let result = try runLauncher(ticketPath: missing)
        XCTAssertTrue(result.status == 126 || result.status == 127, "got \(result.status)")
    }

    func testMissingArgumentExits126() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.launcherBinary)
        process.arguments = []
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 126)
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("usage"))
    }

    // MARK: - Control-plane reporting

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    /// Minimal AF_UNIX listener capturing exactly one NDJSON report line.
    private final class ReportListener {
        let path: String
        private var listenFD: Int32 = -1

        init(path: String) {
            self.path = path
        }

        func bindAndListen() throws {
            unlink(path)
            listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenFD >= 0 else { throw posixError(errno) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            try withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                guard bytes.count < dest.count else { throw posixError(EINVAL) }
                memcpy(dest.baseAddress!, bytes, bytes.count)
            }
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.bind(listenFD, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw posixError(errno) }
            guard Darwin.listen(listenFD, 4) == 0 else { throw posixError(errno) }
        }

        /// Accepts connections for up to `timeout` seconds total, draining
        /// every NDJSON line from each. Each report is its own connection;
        /// keeps accepting until `stopAt` appears in a line (or time runs out).
        func readLines(timeout: TimeInterval, stopAt: String? = nil) -> [String] {
            var all: [String] = []
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
                guard remaining > 0 else { break }
                var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, remaining) > 0 else { break }
                let connFD = Darwin.accept(listenFD, nil, nil)
                guard connFD >= 0 else { break }
                defer { close(connFD) }

                // Bound each recv so a peer that never closes can't hang us.
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                _ = setsockopt(connFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let n = recv(connFD, &buffer, buffer.count, 0)
                    guard n > 0 else { break }
                    data.append(contentsOf: buffer[0 ..< n])
                    if data.count > 4096 {
                        break
                    }
                }
                let lines = (String(data: data, encoding: .utf8) ?? "")
                    .split(separator: "\n").map(String.init)
                all.append(contentsOf: lines)
                if let stopAt, lines.contains(where: { $0.contains(stopAt) }) {
                    break
                }
            }
            return all
        }

        func closeListener() {
            if listenFD >= 0 {
                close(listenFD); listenFD = -1
            }
            unlink(path)
        }
    }

    func testLauncherStartedReportIsAcceptedByRealV1Server() async throws {
        // The report must be a COMPLIANT control-v1 envelope carrying the
        // ticket's hook token: a REAL AgentControl server (UnixSocketServer +
        // router with the generation registered in HookAuthenticator) has to
        // accept it and forward surfaceCreated into the runtime.
        let agentID = UUID()
        let terminalID = UUID()
        let runtime = RecordingControlRuntime()
        let hooks = HookAuthenticator()
        let broker = EventStreamBroker(streamProvider: { AsyncStream { _ in } })
        let router = ControlRequestRouter(runtime: runtime, hooks: hooks, broker: broker)

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-\(UUID().uuidString).sock").path
        let server = try UnixSocketServer(path: socketPath) { request, connection in
            await router.handle(request, connection: connection)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        await hooks.register(
            agentID: AgentID(rawValue: agentID),
            surfaceGeneration: SurfaceGeneration(rawValue: 42),
            token: "test-token"
        )

        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/usr/bin/true"],
            surfaceGeneration: 42,
            controlSocketPath: socketPath,
            agentID: agentID,
            terminalID: terminalID
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")

        // Acceptance IS the assertion: only a token-valid, protocol-compliant
        // launcher.started reaches the runtime as surfaceCreated.
        var call: (
            agentID: AgentID,
            terminalID: TerminalID,
            generation: SurfaceGeneration,
            pid: Int32?,
            processGroupID: Int32?
        )?
        for _ in 0 ..< 500 {
            call = runtime.lastSurfaceCreated
            if call != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let accepted = try XCTUnwrap(call, "real v1 server never accepted launcher.started")
        XCTAssertEqual(accepted.agentID, AgentID(rawValue: agentID))
        XCTAssertEqual(accepted.terminalID, TerminalID(rawValue: terminalID))
        XCTAssertEqual(accepted.generation, SurfaceGeneration(rawValue: 42))
        XCTAssertNotNil(accepted.pid)
        XCTAssertEqual(accepted.processGroupID, accepted.pid,
                       "setpgid(0,0): the child leads its own process group")
        XCTAssertNotEqual(accepted.pid, Int32(ProcessInfo.processInfo.processIdentifier))
    }

    func testFailedReportArrivesOnExecveFailure() async throws {
        // launcher.failed must likewise be accepted by a REAL v1 server and
        // land as a failed process-lifecycle observation from the `launcher`
        // source.
        let agentID = UUID()
        let runtime = RecordingControlRuntime()
        let hooks = HookAuthenticator()
        let broker = EventStreamBroker(streamProvider: { AsyncStream { _ in } })
        let router = ControlRequestRouter(runtime: runtime, hooks: hooks, broker: broker)

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-\(UUID().uuidString).sock").path
        let server = try UnixSocketServer(path: socketPath) { request, connection in
            await router.handle(request, connection: connection)
        }
        try await server.start()
        defer { Task { await server.stop() } }
        await hooks.register(
            agentID: AgentID(rawValue: agentID),
            surfaceGeneration: SurfaceGeneration(rawValue: 7),
            token: "test-token"
        )

        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/nonexistent/binary-\(UUID().uuidString)"],
            controlSocketPath: socketPath,
            agentID: agentID
        ))
        defer { cleanup(fixture.dir) }
        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertEqual(result.status, 127, "ENOENT maps to 127 (not found); stderr: \(result.stderr)")

        var failureReason: String?
        for _ in 0 ..< 500 {
            failureReason = runtime.failedObservationReason
            if failureReason != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let reason = try XCTUnwrap(failureReason, "real v1 server never accepted launcher.failed")
        XCTAssertTrue(reason.lowercased().contains("execve"), reason)
        // Diagnostics go to the PTY (stderr here) but stay terse and leak
        // nothing beyond the failed path shape.
        XCTAssertTrue(result.stderr.hasPrefix("agentlauncher:"))
    }

    func testNonExecutableArgv0MapsTo126() throws {
        // Existing regular file without the +x bit: execve fails with EACCES
        // → POSIX "found but not executable" = 126 (vs 127 for ENOENT).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlauncher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }
        let notExecutable = dir.appendingPathComponent("not-executable").path
        XCTAssertTrue(FileManager.default.createFile(
            atPath: notExecutable, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o644]
        ))

        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: [notExecutable]
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertEqual(result.status, 126, "EACCES maps to 126; stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("errno 13"), "stderr: \(result.stderr)")
    }

    func testExecedChildObservesDefaultSIGPIPEDispositionDespiteLiveControlSocket() throws {
        // Full launcher flow with a live control socket: the helper ignores
        // SIGPIPE only for its own NDJSON write and must restore SIG_DFL
        // BEFORE execve — SIG_IGN survives execve and would break pipelines
        // inside the launched agent.
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-\(UUID().uuidString).sock").path
        let listener = ReportListener(path: socketPath)
        try listener.bindAndListen()
        defer { listener.closeListener() }

        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: [Self.signalProbeBinary],
            controlSocketPath: socketPath
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")

        let lines = listener.readLines(timeout: 10, stopAt: "launcher.started")
        XCTAssertTrue(lines.contains { $0.contains("launcher.started") },
                      "control report must actually flow through the live socket; got: \(lines)")
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "0",
            "exec'd child must observe SIGPIPE at SIG_DFL (probe prints 1 when inherited SIG_IGN)"
        )
    }

    func testAbsentControlSocketDoesNotBlockOrAbortExec() throws {
        let absentSocket = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).sock").path

        let started = Date()
        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: ["/usr/bin/true"],
            controlSocketPath: absentSocket
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        // Connect budget is ≤250 ms even though nothing listens there.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testExecedChildStartsWithEmptySignalMaskAndDefaultJobControlDispositions() throws {
        // Regression for the inherited-signal-state defect: POSIX carries
        // the blocked-signal mask and SIG_IGN dispositions across execve, so
        // a spawner that blocked SIGTERM or ignored SIGHUP would silently
        // poison every launched agent (a blocked SIGTERM defeats teardown;
        // an ignored SIGHUP breaks job control). Pollute THIS process the
        // way such a spawner would, then require the helper to hand the
        // exec'd child a clean slate.
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, &blocked, nil), 0)
        let previousSighupDisposition = signal(SIGHUP, SIG_IGN)
        defer {
            _ = pthread_sigmask(SIG_UNBLOCK, &blocked, nil)
            _ = signal(SIGHUP, previousSighupDisposition)
        }

        let fixture = try writeTicket(baseTicket(
            cwd: NSTemporaryDirectory(),
            argv: [Self.signalHygieneProbeBinary]
        ))
        defer { cleanup(fixture.dir) }

        let result = try runLauncher(ticketPath: fixture.path)
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "clean",
            "exec'd child must start with an empty signal mask and SIG_DFL for all job-control signals"
        )
    }

    // MARK: - R31-S1 — hostile-input frame compliance

    func testHostileTokenStillYieldsOneCompliantStartedFrame() throws {
        // escape() must survive a token carrying raw quotes, backslashes and
        // newlines: the wire law is EXACTLY one '\n' and it is the LAST byte
        // (a stray newline splits the NDJSON stream and silently loses every
        // subsequent report on a v1 server). Observed RAW — the v1 router
        // drops malformed frames by design, which would mask the leak.
        let agentID = UUID()
        let terminalID = UUID()
        let listener = RawReportListener(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("aterm-r31-\(UUID().uuidString.prefix(8)).sock").path
        )
        defer { listener.cleanup() }

        ControlReporter.started(
            agentID: agentID,
            terminalID: terminalID,
            surfaceGeneration: 42,
            token: #"to"ken\evil"# + "\nsecond-line",
            socketPath: listener.path
        )

        let bytes = listener.acceptAndDrain(deadlineMs: 2000)
        XCTAssertFalse(
            bytes.isEmpty,
            "no report reached the raw listener within the accept deadline"
        )

        // One-'\n'-and-it-is-last law, asserted on the WIRE bytes.
        XCTAssertEqual(
            bytes.filter { $0 == UInt8(ascii: "\n") }.count, 1,
            "hostile token must not split the NDJSON stream; got: \(String(decoding: bytes, as: UTF8.self))"
        )
        XCTAssertEqual(bytes.last, UInt8(ascii: "\n"))

        // Envelope laws, asserted on PARSED values (escaping-representation-
        // independent while still failing if any fragment leaks unescaped).
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            "frame is not valid JSON"
        )
        XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
        XCTAssertEqual(envelope["method"] as? String, "launcher.started")
        XCTAssertNotNil(try UUID(uuidString: XCTUnwrap(envelope["requestID"] as? String)))

        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        // quote → \", backslash → \\, newline dropped.
        XCTAssertEqual(params["token"] as? String, "to\"ken\\evilsecond-line")
        XCTAssertEqual(params["agentID"] as? String, agentID.uuidString)
        XCTAssertEqual(params["terminalID"] as? String, terminalID.uuidString)
        XCTAssertEqual(params["surfaceGeneration"] as? Int, 42)
        XCTAssertEqual(params["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(params["processGroupID"] as? Int, Int(getpgrp()))
    }

    func testHostileReasonYieldsOneCompliantFailedFrame() throws {
        // failed() assembles its params independently of started(); its
        // reason string gets the same hostile-input treatment.
        let agentID = UUID()
        let listener = RawReportListener(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("aterm-r31-\(UUID().uuidString.prefix(8)).sock").path
        )
        defer { listener.cleanup() }

        ControlReporter.failed(
            reason: #"exec "missing""# + "\n" + "exttra",
            agentID: agentID,
            surfaceGeneration: 7,
            token: #"tok"en"#,
            socketPath: listener.path
        )

        let bytes = listener.acceptAndDrain(deadlineMs: 2000)
        XCTAssertFalse(
            bytes.isEmpty,
            "no report reached the raw listener within the accept deadline"
        )
        XCTAssertEqual(
            bytes.filter { $0 == UInt8(ascii: "\n") }.count, 1,
            "hostile reason must not split the NDJSON stream; got: \(String(decoding: bytes, as: UTF8.self))"
        )
        XCTAssertEqual(bytes.last, UInt8(ascii: "\n"))

        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            "frame is not valid JSON"
        )
        XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
        XCTAssertEqual(envelope["method"] as? String, "launcher.failed")

        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        XCTAssertEqual(params["reason"] as? String, #"exec "missing"exttra"#)
        XCTAssertEqual(params["token"] as? String, #"tok"en"#)
        XCTAssertEqual(params["agentID"] as? String, agentID.uuidString)
        XCTAssertEqual(params["surfaceGeneration"] as? Int, 7)
    }

    func testDegenerateSocketPathsAreSilentNoOps() {
        // The guard chain (non-empty + absolute + fits sun_path) must swallow
        // degenerate paths BEFORE bind: no crash, no artifact — the exec path
        // is never blocked or aborted.
        let agentID = UUID()

        // Empty path.
        ControlReporter.started(
            agentID: agentID, terminalID: UUID(), surfaceGeneration: 0,
            token: "t", socketPath: ""
        )

        // Relative path: guard fires BEFORE bind, so nothing may appear in cwd.
        let relative = "aterm-r31-relative.sock"
        ControlReporter.started(
            agentID: agentID, terminalID: UUID(), surfaceGeneration: 0,
            token: "t", socketPath: relative
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: FileManager.default.currentDirectoryPath + "/" + relative
            ),
            "relative socketPath must be rejected before bind"
        )

        // Oversize absolute path (> sun_path capacity, 104 on macOS): without
        // the length guard send() would memcpy-truncate and bind a WRONG socket.
        let oversize = NSTemporaryDirectory()
            + "aterm-r31-oversize-" + String(repeating: "d", count: 160) + ".sock"
        ControlReporter.started(
            agentID: agentID, terminalID: UUID(), surfaceGeneration: 0,
            token: "t", socketPath: oversize
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oversize),
            "oversize socketPath must be rejected before bind"
        )
    }
}

// MARK: - Real-server test double

/// Minimal `ControlRuntime` recording exactly what a compliant launcher
/// report must produce on the far side of the v1 router.
private final class RecordingControlRuntime: ControlRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lastSurfaceCreated: (
        agentID: AgentID,
        terminalID: TerminalID,
        generation: SurfaceGeneration,
        pid: Int32?,
        processGroupID: Int32?
    )?
    private(set) var failedObservationReason: String?

    func surfaceCreated(
        agentID: AgentID,
        terminalID: TerminalID,
        generation: SurfaceGeneration,
        pid: Int32?,
        processGroupID: Int32?
    ) async throws {
        lock.withLock {
            lastSurfaceCreated = (agentID, terminalID, generation, pid, processGroupID)
        }
    }

    func ingest(_ evidence: Evidence) async {
        if case let .integrationLifecycle(.failed(descriptor)) = evidence.payload {
            lock.withLock {
                failedObservationReason = descriptor.reason
            }
        }
    }

    /// Unused by the launcher report paths.
    func listWorkspaces() async -> [Workspace] {
        []
    }

    func createAgent(_: AgentLaunchRequest, in _: WorkspaceID) async throws -> AgentID {
        AgentID()
    }

    func summaries() async -> [AgentSummary] {
        []
    }

    func summary(of _: AgentID) async -> AgentSummary? {
        nil
    }

    func prompt(_ agentID: AgentID, _: String, _: PromptPolicy) async throws -> PromptReceipt {
        PromptReceipt(commandID: CommandID(), agentID: agentID, outcome: .delivered)
    }

    func cancelQueuedPrompt(_: AgentID) async throws {}
    func focus(_: AgentID) async throws {}
    func interrupt(_: AgentID) async throws {}
    func stop(_: AgentID, mode _: StopMode) async throws {}
    func resume(_: AgentID) async throws {}
    func read(_: AgentID, source _: TerminalReadSource) async throws -> TerminalSnapshot {
        TerminalSnapshot(text: "", outputRevision: 0, generation: .initial)
    }

    func state(of _: AgentID) async throws -> AgentState {
        AgentState(lifecycle: .unknown, revision: 0, observedAt: MonotonicInstant.zero)
    }

    func integrationExpired(sourceID _: String, agentID _: AgentID) async {}
}

// MARK: - R31-S1 raw-byte observation double

/// File-local raw unix-socket observer for ControlReporter's frames: binds and
/// listens with NO router in between so hostile frames can be inspected
/// byte-for-byte (the v1 router drops anything that fails validation by
/// design, which would mask exactly the leak these tests defend against).
/// Duplicates the real-server plumbing above ON PURPOSE — deliberately not
/// shared with it.
private final class RawReportListener {
    let path: String
    private let fd: Int32

    init(path: String) {
        self.path = path
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket(AF_UNIX): errno \(errno)")

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        precondition(
            pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path),
            "listener path exceeds sun_path capacity"
        )
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            _ = memcpy(dest.baseAddress!, pathBytes, pathBytes.count)
        }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0, "bind(\(path)): errno \(errno)")
        precondition(listen(fd, 1) == 0, "listen: errno \(errno)")

        // NONBLOCK so acceptAndDrain can bound its wait with poll().
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Polls accept() up to `deadlineMs`, then blocks in recv until the peer
    /// closes. EOF is deterministic: ControlReporter.send always closes its
    /// fd via `defer` right after the single write.
    func acceptAndDrain(deadlineMs: Int32) -> Data {
        var data = Data()
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, deadlineMs) > 0 else { return data }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return data }
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 {
                break
            }
            data.append(contentsOf: buffer[0 ..< n])
        }
        return data
    }

    func cleanup() {
        close(fd)
        unlink(path)
    }

    deinit { cleanup() }
}

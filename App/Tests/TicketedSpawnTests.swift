import AgentControl
import AgentCore
import AgentStore
@testable import AgentTerminal
import AppKit
import GRDB
@testable import TerminalKit
import XCTest

// Round-5 Suite P (R5-1 … R5-5): AgentExecutionCoordinator ticketed spawn tails, driven
// through the REAL AgentExecutionCoordinator → ticket → (P2) REAL AgentLauncher-binary
// path. The test itself plays the surface-bootstrap role: a fake engine
// records each created surface's TerminalLaunchSpec verbatim, so the ticketed
// command string and the on-disk ticket bytes are both observable while every
// §3.9/§3.16 law under test stays in production code.
//
// Fixtures are deliberate file-private copies of the preflight suite's
// Harness* shapes and the R4 TicketedScriptedServer (SharedFakes.swift is internal to
// the SwiftPM test target; the original TicketedScriptedServer is invisible outside
// AgentControlTests). Binary lookup mirrors AgentLauncherSmokeTests — located,
// never rebuilt. All sockets live at /tmp/aterm-launch-<uuid8>.sock;
// UnixSocketServer.defaultPath() is never touched.

// MARK: - Fakes (surface bootstrap role)

@MainActor
final class TicketedHarnessSurface: NativeTerminalSurface {
    var screenText: String?
    var viewportText: String?
    var processExitedFlag = false
    var foregroundPIDValue: UInt64 = 0

    func setFocus(_: Bool) {}
    func setOccluded(_: Bool) {}
    func resize(widthPixels _: UInt32, heightPixels _: UInt32, scaleFactor _: Double) {}
    func sendText(_: String) {}
    func sendKey(_: GhosttyKeyEvent) -> Bool {
        true
    }

    func sendPreedit(_: String?) {}
    func mouseButton(state _: MouseButtonState, button _: MouseButton, modifiers _: KeyModifiers) -> Bool {
        true
    }

    func mousePosition(x _: Double, y _: Double, modifiers _: KeyModifiers) {}
    func mouseScroll(dx _: Double, dy _: Double, packedModifiers _: Int32) {}
    func isProcessExited() -> Bool {
        processExitedFlag
    }

    func foregroundPID() -> UInt64 {
        foregroundPIDValue
    }

    func gridSize() -> (columns: UInt32, rows: UInt32)? {
        nil
    }

    func readScreen() -> String? {
        screenText
    }

    func readViewport() -> String? {
        viewportText
    }

    func performFree() {}
}

@MainActor
final class TicketedHarnessEngine: TerminalEngine {
    var eventSink: (@MainActor (GhosttyEvent) -> Void)?
    private(set) var specs: [TerminalLaunchSpec] = []
    private(set) var surfaces: [TicketedHarnessSurface] = []

    func createSurface(
        view _: NSView,
        spec: TerminalLaunchSpec,
        box _: SurfaceCallbackBox
    ) throws -> any NativeTerminalSurface {
        specs.append(spec)
        let surface = TicketedHarnessSurface()
        surfaces.append(surface)
        return surface
    }

    func tick() {}
    func shutdown() {}
}

@MainActor
final class TicketedHarnessParkingHost: TerminalParkingHosting {
    let parkingContentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

    func park(_ view: NSView) {
        view.removeFromSuperview()
        parkingContentView.addSubview(view)
    }
}

// MARK: - Scripted control-plane double (R4 shape)

/// NSLock-guarded request recorder.
final class TicketedRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: [String: JSONValue], requestID: String)] = []

    func append(_ request: ControlRequest) {
        lock.lock()
        recorded.append((request.method, request.params, request.requestID))
        lock.unlock()
    }

    var requests: [(method: String, params: [String: JSONValue], requestID: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

final class TicketedScriptedServer: @unchecked Sendable {
    let socketPath: String
    private let server: UnixSocketServer
    private let log: TicketedRequestLog

    init(path: String) throws {
        socketPath = path
        let responderBox = TicketedResponderBox { _, _, requestID in
            .success(requestID, [
                "protocolVersion": .int(Int64(ProtocolVersion.current)),
                "implementation": "agent-terminal-control",
            ])
        }
        let requestLog = TicketedRequestLog()
        server = try UnixSocketServer(path: socketPath) { request, connection in
            requestLog.append(request)
            let response = responderBox.body(request.method, request.params, request.requestID)
            _ = try? connection.send(response)
        }
        log = requestLog
    }

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

    var requests: [(method: String, params: [String: JSONValue], requestID: String)] {
        log.requests
    }

    func stop() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await self.server.stop()
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Bounded poll for the bound socket FILE.
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

/// Indirection that lets tests swap the scripted answer after server creation.
final class TicketedResponderBox: @unchecked Sendable {
    var body: @Sendable (String, [String: JSONValue], String) -> ControlResponse

    init(_ initial: @escaping @Sendable (String, [String: JSONValue], String) -> ControlResponse) {
        body = initial
    }
}

// MARK: - Helpers

/// Bounded poll, no settles (ticketedWaitUntil law). Callers that need main-queue
/// teardown hops drained invoke drainForTesting() inside the condition.
func ticketedWaitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Stub factory (NewAgentScenario pattern): writes "#!/bin/sh\nexit 0\n" at
/// <dir>/<name>, chmod 0755. Returns the DIRECTORY path for PATH prepending.
func makeTicketedStubDir(name: String = "opencode") throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aterm-stub-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let payload = dir.appendingPathComponent(name)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: payload)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: payload.path
    )
    return dir.path
}

/// PATH swap with guaranteed (idempotent) restore.
func withTicketedStubbedPATH(
    _ stubDir: String, _ body: () async throws -> Void
) async throws {
    let saved = getenv("PATH").map { String(cString: $0) }
    let current = saved ?? "/usr/local/bin:/usr/bin:/bin"
    setenv("PATH", "\(stubDir):\(current)", 1)
    defer {
        if let saved {
            setenv("PATH", saved, 1)
        } else {
            unsetenv("PATH")
        }
    }
    try await body()
}

// MARK: - Wired fixture

@MainActor
final class TicketedSpawnTests: XCTestCase {
    struct Wired {
        let pipeline: AgentExecutionCoordinator
        let runtime: AgentRuntime
        let clock: FakeClock
        let hooks: HookAuthenticator
        let manager: TerminalSessionManager
        let engine: TicketedHarnessEngine
        let registry: AgentTerminalRegistry
        let ticketsDir: URL
        let socketPath: String
    }

    static let packageRoot: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // App
        .path

    /// Locates the AgentLauncher executable — NEVER rebuilds it. Primary: the
    /// app bundle's Helpers copy (project.yml copies it into
    /// Contents/Helpers); fallback: repo-root SwiftPM product.
    static let launcherBinary: String = {
        var candidates: [String] = []
        var appBundleURL = URL(fileURLWithPath: Bundle(for: TicketedSpawnTests.self).bundlePath)
        while appBundleURL.pathExtension != "app", appBundleURL.path.count > 1 {
            appBundleURL.deleteLastPathComponent()
        }
        candidates.append(appBundleURL.appendingPathComponent("Contents/Helpers/AgentLauncher").path)
        candidates.append(packageRoot + "/../Packages/.build/debug/AgentLauncher")
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        XCTFail(
            "AgentLauncher binary not found. Looked in:\n\(candidates.joined(separator: "\n"))"
        )
        return ""
    }()

    override class func setUp() {
        super.setUp()
        _ = launcherBinary
    }

    func makeWired(
        launcherExecutable: URL?,
        withTickets: Bool,
        repository repositoryOut: inout AgentRepository?,
        database databaseOut: inout AgentDatabase?
    ) async throws -> Wired {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let engine = TicketedHarnessEngine()
        let ticketsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-launch-tickets-\(UUID().uuidString)", isDirectory: true)
        let manager = TerminalSessionManager(
            engine: engine,
            parkingHost: TicketedHarnessParkingHost(),
            ticketWriter: withTickets ? LaunchTicketWriter(directory: ticketsDir) : nil,
            inputBracketedPaste: false
        )
        let hooks = HookAuthenticator()
        let registry = AgentTerminalRegistry()
        // Test-local AF_UNIX path — NEVER UnixSocketServer.defaultPath().
        let socketPath = "/tmp/aterm-launch-\(UUID().uuidString.prefix(8)).sock"
        if withTickets, databaseOut != nil {
            repositoryOut = AgentRepository(database: databaseOut!)
        }
        let pipeline = AgentExecutionCoordinator(
            runtime: runtime,
            clock: clock,
            sessionManager: manager,
            registry: registry,
            model: AppModel(),
            hooks: hooks,
            agentRepository: repositoryOut,
            launcherExecutable: launcherExecutable,
            controlSocketPath: socketPath
        )
        return Wired(
            pipeline: pipeline, runtime: runtime, clock: clock,
            hooks: hooks, manager: manager, engine: engine,
            registry: registry, ticketsDir: ticketsDir, socketPath: socketPath
        )
    }

    /// Simple variant (no persistence).
    func makeWired(launcherExecutable: URL?, withTickets: Bool) async throws -> Wired {
        var repository: AgentRepository?
        var database: AgentDatabase?
        return try await makeWired(
            launcherExecutable: launcherExecutable,
            withTickets: withTickets,
            repository: &repository,
            database: &database
        )
    }

    /// Integration-authority observation (preflight-suite lifecycleEvidence).
    func lifecycleEvidence(
        agent: AgentID,
        terminal: TerminalID?,
        generation: SurfaceGeneration,
        outputRevision: UInt64,
        lifecycle: LifecyclePhase,
        at instant: MonotonicInstant
    ) -> Evidence {
        Evidence(
            envelope: ObservationEnvelope(
                agentID: agent,
                terminalID: terminal,
                surfaceGeneration: generation,
                sourceID: "hook:test",
                sourceKind: .integration,
                sequence: nil,
                outputRevision: outputRevision,
                observedAt: instant,
                receivedAt: instant
            ),
            payload: .integrationLifecycle(lifecycle)
        )
    }

    /// The single *.json ticket in the writer directory.
    func soleTicket(in dir: URL) throws -> LaunchTicket {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1, "expected exactly one launch ticket in \(dir.path)")
        return try JSONDecoder().decode(LaunchTicket.self, from: Data(contentsOf: files[0]))
    }

    // MARK: P1 — happy-path tail: exact ticket + full registration

    func testCreateAgentHappyPathWritesExactTicketAndRegistersEverything() async throws {
        let wired = try await makeWired(
            launcherExecutable: URL(fileURLWithPath: "/bin/true"), withTickets: true
        )
        defer {
            wired.engine.shutdown()
            try? FileManager.default.removeItem(at: wired.ticketsDir)
        }
        let stubDir = try makeTicketedStubDir()
        defer { try? FileManager.default.removeItem(atPath: stubDir) }

        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        var agent: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            agent = try await wired.pipeline.createAgent(
                AgentLaunchRequest(
                    agentKind: .openCode,
                    workingDirectory: "/tmp/proj",
                    displayName: "Builder"
                ),
                in: workspace
            )
        }
        let agentID = try XCTUnwrap(agent)

        // Ticket contents mirror the minted material exactly (§3.9).
        let ticket = try soleTicket(in: wired.ticketsDir)
        XCTAssertEqual(ticket.agentID, agentID.rawValue)
        let terminalID = try XCTUnwrap(wired.manager.allSessions.first).id
        XCTAssertEqual(ticket.terminalID, terminalID.rawValue)
        XCTAssertEqual(ticket.surfaceGeneration, SurfaceGeneration.initial.rawValue)
        let mintedToken = try XCTUnwrap(wired.pipeline.activeTokens[agentID])
        XCTAssertEqual(ticket.integrationToken, mintedToken)
        XCTAssertEqual(ticket.controlSocketPath, wired.socketPath)
        // Absolute argv[0]: §3.9 resolution happened BEFORE the ticket write.
        XCTAssertEqual(ticket.argv, ["\(stubDir)/opencode"])
        XCTAssertEqual(ticket.cwd, "/tmp/proj")
        // genericShell-only decoration must not leak into adapter agents.
        XCTAssertFalse(ticket.environment.keys.contains("PS1"))
        XCTAssertFalse(ticket.environment.keys.contains("PROMPT"))

        // Quoting law: libghostty word-splits `command` without shell
        // interpolation, so BOTH interpolated paths carry their own quotes.
        let spec = try XCTUnwrap(wired.engine.specs.first)
        XCTAssertEqual(spec.command, "\"/bin/true\" \"\(wired.ticketsDir.path)/\(ticket.ticketID.uuidString).json\"")

        // Registry bind + model association.
        let binding = try XCTUnwrap(wired.registry.binding(for: agentID))
        XCTAssertEqual(binding.kind, .openCode)
        XCTAssertEqual(binding.displayName, "Builder")
        XCTAssertEqual(binding.cwd, "/tmp/proj")
        XCTAssertEqual(binding.terminalID, terminalID)
        XCTAssertEqual(wired.registry.agentID(for: terminalID), agentID)

        // The minted token really authenticates in the PRODUCTION authenticator.
        let verdict = await wired.hooks.validateReport(
            agentID: agentID,
            surfaceGeneration: .initial,
            sourceID: "launcher",
            sequence: nil,
            token: mintedToken
        )
        XCTAssertEqual(verdict, .accept(sequence: nil))
    }

    // MARK: P2 — REAL binary consumes an APP-written ticket end-to-end

    func testRealAgentLauncherConsumesPipelineTicketAndReportsStartedOverTestSocket() async throws {
        let launcherPath = Self.launcherBinary
        let wired = try await makeWired(
            launcherExecutable: URL(fileURLWithPath: launcherPath), withTickets: true
        )
        defer {
            wired.engine.shutdown()
            try? FileManager.default.removeItem(at: wired.ticketsDir)
        }
        let stubDir = try makeTicketedStubDir()
        defer { try? FileManager.default.removeItem(atPath: stubDir) }

        // The helper chdirs into ticket.cwd before execve — it must EXIST.
        let cwdDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-launch-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwdDir) }

        let server = try TicketedScriptedServer(path: wired.socketPath)
        try server.start()
        defer { server.stop() }
        server.awaitListening()

        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        var agent: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            agent = try await wired.pipeline.createAgent(
                AgentLaunchRequest(
                    agentKind: .openCode,
                    workingDirectory: cwdDir.path,
                    displayName: "Real"
                ),
                in: workspace
            )
        }
        let agentID = try XCTUnwrap(agent)
        let mintedToken = try XCTUnwrap(wired.pipeline.activeTokens[agentID])
        let ticket = try soleTicket(in: wired.ticketsDir)

        // Parse the ticket path out of the captured command string:
        // "\"<launcher>\" \"<ticket>\"" → quoted segment #3.
        let command = try XCTUnwrap(wired.engine.specs.first?.command)
        let segments = command.components(separatedBy: "\"")
        XCTAssertGreaterThanOrEqual(segments.count, 4)
        let ticketPath = segments[3]

        // Run the REAL binary with that path as argv[1] — smoke-suite runner
        // law: bounded 10 s poll at 10 ms, terminate()+fail on overrun.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcherPath)
        process.arguments = [ticketPath]
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("AgentLauncher timed out consuming \(ticketPath)")
        }
        XCTAssertEqual(process.terminationStatus, 0,
                       "stub must terminate promptly via chdir+execve; stderr: "
                           + (String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""))

        // The report landed on the test-owned socket.
        await ticketedWaitUntil(timeout: 5) { server.requests.count >= 1 }
        let requests = server.requests
        XCTAssertEqual(requests.map(\.method), ["launcher.started"],
                       "the fire-and-forget reporter performs NO version handshake")
        let params = try XCTUnwrap(requests.first).params
        guard case let .int(pid)? = params["pid"],
              case let .int(pgid)? = params["processGroupID"]
        else {
            XCTFail("params missing numeric pid/processGroupID: \(params)")
            return
        }
        XCTAssertEqual(pid, pgid, "setpgid(0,0): reported PGID equals reported PID")
        XCTAssertGreaterThan(pid, 1)
        XCTAssertEqual(params["agentID"], .string(agentID.rawValue.uuidString))
        XCTAssertEqual(params["terminalID"], .string(ticket.terminalID.uuidString))
        XCTAssertEqual(params["surfaceGeneration"], .int(0))
        XCTAssertEqual(params["token"], .string(mintedToken))

        // Single-use consumption across the real link/rename/unlink path.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: wired.ticketsDir, includingPropertiesForKeys: nil
        )
        XCTAssertTrue(leftovers.isEmpty, "ticket file must be gone: \(leftovers.map(\.path))")

        // The binary presented credentials the PRODUCTION validation accepts.
        let verdict = await wired.hooks.validateReport(
            agentID: agentID,
            surfaceGeneration: .initial,
            sourceID: "launcher",
            sequence: nil,
            token: mintedToken
        )
        XCTAssertEqual(verdict, .accept(sequence: nil))
    }

    // MARK: P3 — residual-failure compensation

    func testSpawnTailFailureAfterTokenRegistrationInvalidatesTokenAndLeaksNoTicket() async throws {
        let wired = try await makeWired(
            launcherExecutable: URL(fileURLWithPath: "/bin/true"), withTickets: false
        )
        defer { wired.engine.shutdown() }
        let stubDir = try makeTicketedStubDir()
        defer { try? FileManager.default.removeItem(atPath: stubDir) }

        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        var caught: Error?
        try await withTicketedStubbedPATH(stubDir) {
            do {
                _ = try await wired.pipeline.createAgent(
                    AgentLaunchRequest(
                        agentKind: .openCode,
                        workingDirectory: "/tmp/proj",
                        displayName: "Doomed"
                    ),
                    in: workspace
                )
            } catch {
                caught = error
            }
        }
        let stranded = await wired.runtime.projection().agents.first?.id
        let thrownError = try XCTUnwrap(caught)
        // manager.launch threw AFTER runtime/persistence/token mutations…
        XCTAssertEqual(thrownError as? TerminalKitError, .launchTicketWriterUnavailable)
        let agentID = try XCTUnwrap(stranded, "stranded starting session must identify the agent")
        XCTAssertTrue(wired.pipeline.activeTokens.isEmpty)
        let registered = await wired.hooks.isRegistered(agentID: agentID)
        XCTAssertFalse(registered, "half-registered token would authenticate stray reports")
        // The writer never ran — no ticket leaked.
        XCTAssertFalse(FileManager.default.fileExists(atPath: wired.ticketsDir.path))
        // Documented residual: AgentCore exposes no public launchFailed
        // transition, so the stranded `.starting` session remains — pinned as
        // documentation so a future fix updates this test knowingly.
        let projection = await wired.runtime.projection()
        XCTAssertEqual(projection.agents.count, 1)
    }

    // MARK: P4 — executeResume: resolved argv, cwd override, epilogue ordering

    func testExecuteResumeResolvesAdapterArgvAndArchivesOnlyAfterConfirmedLaunch() async throws {
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-launch-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let database = try AgentDatabase(
            databaseURL: dbDir.appendingPathComponent("test.sqlite"),
            backupDirectoryURL: dbDir.appendingPathComponent("backups")
        )
        try database.migrate()
        let repository = AgentRepository(database: database)

        var repositoryArg: AgentRepository? = repository
        var databaseArg: AgentDatabase? = database
        let wired = try await makeWired(
            launcherExecutable: URL(fileURLWithPath: "/bin/true"),
            withTickets: true,
            repository: &repositoryArg,
            database: &databaseArg
        )
        defer {
            wired.engine.shutdown()
            try? FileManager.default.removeItem(at: wired.ticketsDir)
        }
        let stubDir = try makeTicketedStubDir()
        defer { try? FileManager.default.removeItem(atPath: stubDir) }

        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        // agents.workspace_id is a real FK (foreignKeysEnabled): the runtime's
        // createWorkspace is in-memory only, so the row must be persisted here
        // before any agents row references it. Public repository API only.
        try await WorkspaceRepository(
            transactor: PoolTransactor(pool: database.pool)
        )
        .save(
            Workspace(
                id: workspace,
                name: "Default",
                rootPath: "/tmp",
                createdAt: wired.clock.now,
                updatedAt: wired.clock.now
            ),
            sortIndex: 0
        )
        // Seed a superseded row carrying resume intent + an open session ref.
        let doomed = AgentID()
        try await repository.register(AgentSession(
            id: doomed,
            workspaceID: workspace,
            kind: .openCode,
            displayName: "Doomed",
            cwd: "/tmp/doomed",
            launchDescriptor: LaunchDescriptor(
                agentKind: .openCode, program: "opencode",
                arguments: [], workingDirectory: "/tmp/doomed"
            ),
            resumePolicy: .manual,
            sessionReference: SessionReference(
                agentKind: .openCode, opaquePayload: "sess-42"
            ),
            state: .fresh(at: wired.clock.now),
            createdAt: wired.clock.now,
            lastActivityAt: wired.clock.now
        ))
        try await repository.setResumeRequested(true, agentID: doomed)

        let action = RestoreResumeAction(
            persistedAgentID: doomed,
            workspaceID: workspace,
            kind: .openCode,
            displayName: "Resumed",
            cwd: "/tmp/resume",
            sessionReference: SessionReference(
                agentKind: .openCode, opaquePayload: "sess-42"
            ),
            resumeSpec: ResumeSpec(argv: [], workingDirectory: "")
        )

        // Resolved 2026-08-24: the escaping ENOENT throw was the tree-red
        // era binary (workspace row never persisted before agent insert);
        // persisting the workspace row in makeWired fixed it. Assertions
        // below were never weakened.
        // Production parity: the runtime owns persistence through its port;
        // the FIRST post-create commit fabricates the agent row itself.
        let writer = AgentStore.DatabaseWriter(transactor: PoolTransactor(pool: database.pool))
        await wired.runtime.setPersistence(writer)
        var agent: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            agent = try await wired.pipeline.executeResume(action, in: workspace)
        }
        let agentID = try XCTUnwrap(agent)

        // Adapter resume spec became the ticketed argv with absolute argv[0];
        // the opaque payload threaded verbatim; cwd override applied.
        let ticket = try soleTicket(in: wired.ticketsDir)
        XCTAssertEqual(ticket.argv, ["\(stubDir)/opencode", "--session", "sess-42"])
        XCTAssertEqual(ticket.cwd, "/tmp/resume")

        // The NEW agent's persisted row carries the transport descriptor and
        // the fixed task summary. The row is fabricated by the runtime's
        // ASYNC persistence commit now (§3.14: never blocking lifecycle on
        // disk I/O), so poll briefly instead of assuming synchronous order.
        var newSession: AgentSession?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            newSession = try await repository.find(agentID)
            if newSession != nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        _ = writer // port stays alive for the runtime's async commits
        XCTAssertNotNil(newSession?.launchDescriptor)
        XCTAssertEqual(newSession?.taskSummary, "resumed session")

        // §3.15 step 9 ran strictly AFTER the confirmed launch: the doomed
        // row's resume intent is consumed and the row archived (dead terminal
        // detached), so it can never resurface as a recovery candidate.
        let resumedRow = try await repository.find(doomed)
        XCTAssertNil(resumedRow?.terminalID, "archived row must detach its terminal")
        let liveRows = try await repository.list(workspaceID: workspace, includeArchived: false)
        XCTAssertFalse(liveRows.contains { $0.id == doomed }, "archived row excluded from live list")

        // Raw flag check (public pool access; no internal symbols).
        let flags = try await database.pool.read { db -> (Int, Int) in
            let flagged = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agents WHERE id = ? AND resume_requested = 1",
                arguments: [doomed.rawValue.uuidString]
            ) ?? -1
            let archived = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agents WHERE id = ? AND archived_at IS NOT NULL",
                arguments: [doomed.rawValue.uuidString]
            ) ?? -1
            return (flagged, archived)
        }
        XCTAssertEqual(flags.0, 0, "resumeRequested must be cleared")
        XCTAssertEqual(flags.1, 1, "row must be archived")
    }
}

import AgentControl
import AgentCore
import AgentStore
@testable import AgentTerminal
import AppKit
import GRDB
@testable import TerminalKit
import XCTest

@MainActor
extension TicketedSpawnTests {
    // MARK: R1 — interactive resume relaunches through executeResume

    /// Session-identity observation for the ledger. Ingesting an
    /// integration LIFECYCLE afterwards publishes/syncs the reference onto
    /// the session so `runtime.resume`'s validation passes.
    private func identityEvidence(
        agent: AgentID,
        payload: String,
        at instant: MonotonicInstant
    ) -> Evidence {
        Evidence(
            envelope: ObservationEnvelope(
                agentID: agent,
                terminalID: nil,
                surfaceGeneration: .initial,
                sourceID: "hook:test",
                sourceKind: .integration,
                observedAt: instant,
                receivedAt: instant
            ),
            payload: .sessionIdentity(SessionReference(agentKind: .openCode, opaquePayload: payload))
        )
    }

    /// The full interactive-resume path: seam.resume validates through
    /// runtime.resume (.resumeAttempted kept) AND actually relaunches a
    /// fresh ticketed surface via executeResume — previously the bare
    /// runtime transition made interactive resume a silent no-op.
    func testSeamResumeRelaunchesExitedAgentThroughExecuteResume() async throws {
        let stubDir = try makeTicketedStubDir()
        defer { try? FileManager.default.removeItem(atPath: stubDir) }
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
        defer { wired.engine.shutdown() }
        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        await wired.runtime.setTerminalPort(wired.manager)

        // Mirror the production wiring: runtime commits own the persisted
        // agent row, while the repository performs the resume epilogue.
        let writer = AgentStore.DatabaseWriter(transactor: PoolTransactor(pool: database.pool))
        await wired.runtime.setPersistence(writer)
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

        var exitedID: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            exitedID = try await wired.pipeline.createAgent(
                AgentLaunchRequest(
                    agentKind: .openCode,
                    workingDirectory: "/tmp/orig",
                    displayName: "interactive-resume"
                ),
                in: workspace
            )
        }
        let exited = try XCTUnwrap(exitedID)

        // Runtime persistence is intentionally asynchronous; wait until the
        // original row exists before executeInteractiveResume can archive it.
        var persistedOriginal: AgentSession?
        let persistenceDeadline = Date().addingTimeInterval(3)
        while Date() < persistenceDeadline {
            persistedOriginal = try await repository.find(exited)
            if persistedOriginal != nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try XCTUnwrap(persistedOriginal, "runtime did not persist the original agent row")

        // Capture a session reference, publish it onto the session, then
        // exit the process: the resumable-exited shape the inspector sees.
        await wired.runtime.ingest(identityEvidence(agent: exited, payload: "sess-live", at: wired.clock.now))
        await wired.runtime.ingest(lifecycleEvidence(
            agent: exited, terminal: nil, generation: .initial,
            outputRevision: 0, lifecycle: .idle, at: wired.clock.now
        ))
        try await wired.runtime.processExited(
            agentID: exited, exitCode: 0, signal: nil, userInitiated: false
        )

        let seam = RuntimeSeam(runtime: wired.runtime, sessionManager: wired.manager, model: AppModel())
        seam.coordinator = wired.pipeline
        try await withTicketedStubbedPATH(stubDir) {
            await seam.resume(.agent(exited))
        }

        // Kept runtime semantics: the validation leg still appended the
        // `.resumeAttempted` transition on the ORIGINAL agent.
        let timeline = await wired.runtime.timeline(of: exited)
        XCTAssertTrue(
            timeline.contains {
                if case .resumeAttempted = $0.event {
                    true
                } else {
                    false
                }
            },
            "runtime.resume validation semantics must be preserved"
        )

        // §3.15 step-9 epilogue ran against the agent's OWN row: intent
        // consumed, row archived — the consumed reference can never
        // resurface as a recovery candidate.
        let liveRows = try await repository.list(workspaceID: workspace, includeArchived: false)
        XCTAssertEqual(liveRows.count, 1, "the exited row is archived; exactly the successor remains live")
        XCTAssertNotEqual(liveRows.first?.id, exited)
        XCTAssertEqual(liveRows.first?.taskSummary, "resumed session")
        XCTAssertEqual(liveRows.first?.cwd, "/tmp/orig", "creation-time cwd is the resume working directory")
        try await database.pool.read { db in
            let archivedCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agents WHERE id = ? AND archived_at IS NOT NULL",
                arguments: [exited.rawValue.uuidString]
            ) ?? -1
            XCTAssertEqual(archivedCount, 1, "old row must be archived after the confirmed relaunch")
            let flagged = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agents WHERE resume_requested = 1") ?? -1
            XCTAssertEqual(flagged, 0, "resume intent must be consumed")
        }

        // The relaunch went through the TICKETED pipeline with the
        // adapter-generated resume command and absolute argv[0].
        let tickets = try FileManager.default.contentsOfDirectory(at: wired.ticketsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(LaunchTicket.self, from: Data(contentsOf: $0)) }
        let resumeTickets = tickets.filter { $0.argv.contains("--session") }
        XCTAssertEqual(resumeTickets.count, 1, "exactly one resume ticket, got \(tickets.map(\.argv))")
        XCTAssertEqual(resumeTickets.first?.argv, ["\(stubDir)/opencode", "--session", "sess-live"])
        XCTAssertEqual(resumeTickets.first?.cwd, "/tmp/orig")
    }

    /// Unsupported kinds surface a CLEAN failure (diagnostics ring record,
    /// no .resumeAttempted event, no successor) instead of silently no-oping.
    func testSeamResumeOfGenericShellSurfacesFailureWithoutRelaunch() async throws {
        let wired = try await makeWired(
            launcherExecutable: URL(fileURLWithPath: "/bin/true"), withTickets: true
        )
        defer { wired.engine.shutdown() }
        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        await wired.runtime.setTerminalPort(wired.manager)
        let shell = try await wired.pipeline.createAgent(
            AgentLaunchRequest(
                agentKind: .genericShell,
                workingDirectory: "/tmp",
                displayName: "shell-no-resume"
            ),
            in: workspace
        )

        let seam = RuntimeSeam(runtime: wired.runtime, sessionManager: wired.manager, model: AppModel())
        seam.coordinator = wired.pipeline
        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        await seam.resume(.agent(shell))

        let added = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertEqual(added.count, 1, "expected exactly the resume-failure record, got \(added)")
        XCTAssertTrue(added[0].contains("resume failed"), "got: \(added[0])")
        let timeline = await wired.runtime.timeline(of: shell)
        XCTAssertFalse(
            timeline.contains {
                if case .resumeAttempted = $0.event {
                    true
                } else {
                    false
                }
            },
            "unsupported kinds must fail BEFORE the runtime transition"
        )
        XCTAssertEqual(wired.registry.bindings.count, 1, "no successor surface may be spawned")
    }

    // MARK: R27-LP1/LP2 — resume epilogue survives persistence failures (records, never throws)

    /// Column-scoped ABORT trigger: ONLY the epilogue statement touching
    /// `column` fails. Hermetic by construction — the consume UPDATE writes
    /// resume_requested only, the archive UPDATE archived_at only, and no
    /// other statement in the executeResume flow writes either column (the
    /// successor's save takes the upsert INSERT arm via a fresh UUID).
    /// Swift-side string building: GRDB would turn sql-interpolation into
    /// bind parameters, which DDL forbids.
    private func installR27EpilogueTrigger(column: String, reason: String, database: AgentDatabase) async throws {
        let ddl = """
        CREATE TRIGGER r27_block_\(column) BEFORE UPDATE OF \(column) ON agents \
        BEGIN SELECT RAISE(ABORT, '\(reason)'); END;
        """
        try await database.pool.write { db in
            try db.execute(sql: ddl)
        }
    }

    /// R27-LP1: a failed resume_requested consume must not fail a CONFIRMED
    /// launch — the epilogue records the failure in the diagnostics ring and
    /// the archive leg still runs (ordering preserved). Reverting to the bare
    /// try? predecessor's throwing shape rethrows after the launch, which
    /// both assertions below catch.
    func testExecuteResumeRecordsAndSurvivesFailedResumeRequestedConsume() async throws {
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
        // agents.workspace_id is a real FK: persist the workspace row first.
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
        let doomed = AgentID()
        try await repository.register(AgentSession(
            id: doomed,
            workspaceID: workspace,
            kind: .openCode,
            displayName: "Doomed",
            cwd: "/tmp/doomed",
            launchDescriptor: LaunchDescriptor(
                agentKind: .openCode, program: "opencode", arguments: [], workingDirectory: "/tmp/doomed"
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

        // From here on, ONLY the consume statement may touch resume_requested.
        try await installR27EpilogueTrigger(
            column: "resume_requested", reason: "forced resume-consume failure", database: database
        )

        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        var agent: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            agent = try await wired.pipeline.executeResume(action, in: workspace)
        }
        let successor = try XCTUnwrap(agent, "epilogue persistence failure must not fail a confirmed launch")
        XCTAssertNotEqual(successor, doomed)

        // The failure is recorded, never thrown.
        let gained = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertTrue(
            gained.contains(where: {
                $0.contains("resume epilogue: consume resume_requested failed for \(doomed.rawValue.uuidString)")
            }),
            "consume failure never landed in the ring: \(gained)"
        )

        // Raw row state: the trigger genuinely aborted the consume (flag
        // still set — guards a vacuous pass) AND the archive leg still ran.
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
        XCTAssertEqual(flags.0, 1, "trigger must have aborted the consume: resume_requested still set")
        XCTAssertEqual(flags.1, 1, "the archive leg must run after the failed consume")
    }

    /// R27-LP2: a failed archive must not fail the resume either — the
    /// consume leg ran FIRST (intent cleared), the failure is recorded, and
    /// the un-archived row stays a live recovery candidate.
    func testExecuteResumeRecordsAndSurvivesFailedArchive() async throws {
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
        let doomed = AgentID()
        try await repository.register(AgentSession(
            id: doomed,
            workspaceID: workspace,
            kind: .openCode,
            displayName: "Doomed",
            cwd: "/tmp/doomed",
            launchDescriptor: LaunchDescriptor(
                agentKind: .openCode, program: "opencode", arguments: [], workingDirectory: "/tmp/doomed"
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

        // From here on, ONLY the archive statement may touch archived_at.
        try await installR27EpilogueTrigger(
            column: "archived_at", reason: "forced archive failure", database: database
        )

        let beforeLines = Set(DiagnosticsLogRing.shared.lines)

        var agent: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            agent = try await wired.pipeline.executeResume(action, in: workspace)
        }
        let successor = try XCTUnwrap(agent, "epilogue persistence failure must not fail a confirmed launch")
        XCTAssertNotEqual(successor, doomed)

        let gained = DiagnosticsLogRing.shared.lines.filter { !beforeLines.contains($0) }
        XCTAssertTrue(
            gained.contains(where: {
                $0.contains("resume epilogue: archive failed for \(doomed.rawValue.uuidString)")
            }),
            "archive failure never landed in the ring: \(gained)"
        )

        // Consume leg ran FIRST and succeeded; archive genuinely aborted.
        let flags = try await database.pool.read { db -> (Int, Int) in
            let cleared = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agents WHERE id = ? AND resume_requested = 0",
                arguments: [doomed.rawValue.uuidString]
            ) ?? -1
            let archived = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agents WHERE id = ? AND archived_at IS NOT NULL",
                arguments: [doomed.rawValue.uuidString]
            ) ?? -1
            return (cleared, archived)
        }
        XCTAssertEqual(flags.0, 1, "the consume leg must run first and succeed")
        XCTAssertEqual(flags.1, 0, "trigger must have aborted the archive: row not archived")

        let liveRows = try await repository.list(workspaceID: workspace, includeArchived: false)
        XCTAssertTrue(
            liveRows.contains { $0.id == doomed },
            "an un-archived row stays a live recovery candidate"
        )
    }

    // MARK: P5 — restart preflight failure aborts BEFORE the irreversible ladder

    func testRestartPreflightFailureAbortsBeforeIrreversibleLadder() async throws {
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
                    displayName: "Stable"
                ),
                in: workspace
            )
        }
        let agentID = try XCTUnwrap(agent)
        let originalBinding = try XCTUnwrap(wired.registry.binding(for: agentID))
        let oldTerminalID = originalBinding.terminalID
        let oldToken = try XCTUnwrap(wired.pipeline.activeTokens[agentID])

        // Drive to .idle with one integration-lifecycle ingest.
        await wired.runtime.ingest(lifecycleEvidence(
            agent: agentID, terminal: oldTerminalID, generation: .initial,
            outputRevision: 0, lifecycle: .idle, at: wired.clock.now
        ))
        await ticketedWaitUntil {
            guard let state = try? await wired.runtime.state(of: agentID) else { return false }
            return state.lifecycle == .idle
        }
        let revisionBefore = try await wired.runtime.state(of: agentID).revision

        // Act OUTSIDE the stub scope: argv[0] no longer resolves → the §6.6
        // preflight must abort before runtime.restart / hooks.invalidate /
        // retire touch anything.
        var caught: Error?
        do {
            try await wired.pipeline.restartAgent(agentID)
        } catch {
            caught = error
        }
        let thrownError = try XCTUnwrap(caught, "restart without a resolvable CLI must throw")
        let failure = try XCTUnwrap(thrownError as? ControlFailure)
        XCTAssertEqual(failure.code, .launchFailed)
        XCTAssertTrue(failure.message.contains("OpenCode CLI not found"),
                      "unexpected message: \(failure.message)")

        // The OLD world is completely intact.
        let revisionAfter = try await wired.runtime.state(of: agentID).revision
        XCTAssertEqual(revisionAfter, revisionBefore, "runtime.restart never ran")
        XCTAssertEqual(wired.manager.allSessions.count, 1)
        XCTAssertEqual(wired.manager.allSessions.first?.id, oldTerminalID,
                       "retire never ran — nothing was closed")
        let binding = try XCTUnwrap(wired.registry.binding(for: agentID))
        XCTAssertEqual(binding.surfaceGeneration, .initial)
        XCTAssertEqual(wired.registry.agentID(for: oldTerminalID), agentID)
        let verdict = await wired.hooks.validateReport(
            agentID: agentID,
            surfaceGeneration: .initial,
            sourceID: "launcher",
            sequence: nil,
            token: oldToken
        )
        XCTAssertEqual(verdict, .accept(sequence: nil),
                       "the ladder never began — token NOT invalidated")
        let ticketsLeft = try FileManager.default.contentsOfDirectory(
            at: wired.ticketsDir, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        XCTAssertEqual(ticketsLeft.count, 1, "no successor ticket written")
    }

    // MARK: P6 — restart relaunch rotates token generations, rebinds, retires

    func testRestartRelaunchRotatesTokenGenerationsRebindsRegistryAndRetiresOldTerminal() async throws {
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
                    displayName: "Rotating"
                ),
                in: workspace
            )
        }
        let agentID = try XCTUnwrap(agent)
        let originalBinding = try XCTUnwrap(wired.registry.binding(for: agentID))
        let oldTerminalID = originalBinding.terminalID
        let oldToken = try XCTUnwrap(wired.pipeline.activeTokens[agentID])

        await wired.runtime.ingest(lifecycleEvidence(
            agent: agentID, terminal: oldTerminalID, generation: .initial,
            outputRevision: 0, lifecycle: .idle, at: wired.clock.now
        ))
        await ticketedWaitUntil {
            guard let state = try? await wired.runtime.state(of: agentID) else { return false }
            return state.lifecycle == .idle
        }
        let idleRevision = try await wired.runtime.state(of: agentID).revision
        // Act with the stub PATH STILL ACTIVE — the restart must succeed.
        try await withTicketedStubbedPATH(stubDir) {
            try await wired.pipeline.restartAgent(agentID)
        }

        // Registry cutover: successor generation, both maps flipped.
        let newBinding = try XCTUnwrap(wired.registry.binding(for: agentID))
        XCTAssertEqual(newBinding.surfaceGeneration.rawValue, 1)
        let newTerminalID = newBinding.terminalID
        XCTAssertNotEqual(newTerminalID, oldTerminalID)
        // Fixed 2026-08-24: rebind now clears the reverse-map entry for the
        // old terminal (rebind runs after bind-and-spawn). Assertion below
        // pins the design §P6 contract; was kept-red while the bug lived.
        XCTAssertNil(wired.registry.agentID(for: oldTerminalID))
        XCTAssertEqual(wired.registry.agentID(for: newTerminalID), agentID)

        // Successor ticket: generation 1, different terminal, NEW token.
        let ticketFiles = try FileManager.default.contentsOfDirectory(
            at: wired.ticketsDir, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        XCTAssertEqual(ticketFiles.count, 2)
        var successorTicket: LaunchTicket?
        for file in ticketFiles {
            let ticket = try JSONDecoder().decode(LaunchTicket.self, from: Data(contentsOf: file))
            if ticket.surfaceGeneration == 1 {
                successorTicket = ticket
            }
        }
        let successor = try XCTUnwrap(successorTicket)
        XCTAssertEqual(successor.terminalID, newTerminalID.rawValue)
        let newToken = try XCTUnwrap(wired.pipeline.activeTokens[agentID])
        XCTAssertEqual(successor.integrationToken, newToken)
        XCTAssertNotEqual(successor.integrationToken, oldToken)

        // Generation rotation enforced by the production authenticator.
        let staleVerdict = await wired.hooks.validateReport(
            agentID: agentID,
            surfaceGeneration: .initial,
            sourceID: "launcher",
            sequence: nil,
            token: oldToken
        )
        guard case let .reject(staleFailure) = staleVerdict else {
            XCTFail("old-generation token must be rejected, got \(staleVerdict)")
            return
        }
        XCTAssertEqual(staleFailure.code, .unauthorized)
        let freshVerdict = await wired.hooks.validateReport(
            agentID: agentID,
            surfaceGeneration: SurfaceGeneration(rawValue: 1),
            sourceID: "launcher",
            sequence: nil,
            token: newToken
        )
        XCTAssertEqual(freshVerdict, .accept(sequence: nil))

        // Retire ladder end-state: the old session eventually disappears
        // (fixed 2 s grace dominates — event-driven bounded wait, no settles;
        // each poll drains the teardown queue deterministically).
        await ticketedWaitUntil(timeout: 6) {
            wired.manager.teardownQueueForTesting().drainForTesting()
            return wired.manager.session(for: oldTerminalID) == nil
        }
        let stateAfter = try await wired.runtime.state(of: agentID)
        XCTAssertEqual(stateAfter.lifecycle, .starting)
        XCTAssertGreaterThan(stateAfter.revision, idleRevision)
        XCTAssertNil(wired.manager.session(for: oldTerminalID))
    }

    // MARK: R9-D1 — reattach-failure compensation (PRODUCTION-SEAM)

    /// When reattach throws AFTER the successor spawned, the compensation
    /// retires the successor, drops its active token, rethrows verbatim, and
    /// leaves the agent UNBOUND: no registry binding may reference a retired
    /// terminal.
    func testInjectedReattachFailureRetiresSuccessorDropsTokenAndRethrows() async throws {
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
                    displayName: "Seamed"
                ),
                in: workspace
            )
        }
        let agentID = try XCTUnwrap(agent)
        let originalBinding = try XCTUnwrap(wired.registry.binding(for: agentID))
        let oldTerminalID = originalBinding.terminalID
        let oldToken = try XCTUnwrap(wired.pipeline.activeTokens[agentID])

        await wired.runtime.ingest(lifecycleEvidence(
            agent: agentID, terminal: oldTerminalID, generation: .initial,
            outputRevision: 0, lifecycle: .idle, at: wired.clock.now
        ))
        await ticketedWaitUntil {
            guard let state = try? await wired.runtime.state(of: agentID) else { return false }
            return state.lifecycle == .idle
        }

        // Arm the one-shot seam: the NEXT reattach throws this error.
        let seamError = ControlFailure(code: .internalError, message: "seam: reattach desync")
        await wired.runtime._testFailNextReattach(seamError)

        var caught: Error?
        do {
            try await withTicketedStubbedPATH(stubDir) {
                try await wired.pipeline.restartAgent(agentID)
            }
            XCTFail("restartAgent must throw when reattach fails")
        } catch {
            caught = error
        }

        // 1. Verbatim rethrow — NOT a launchFailed wrapper.
        let thrown = try XCTUnwrap(caught)
        XCTAssertEqual(thrown as? ControlFailure, seamError)

        // 2. Fresh successor token dropped (:224).
        XCTAssertNil(wired.pipeline.activeTokens[agentID])

        // 3. Hook registration invalidated (:223) — old AND fresh tokens dead.
        let oldVerdict = await wired.hooks.isRegistered(agentID: agentID)
        XCTAssertFalse(oldVerdict)
        let staleVerdict = await wired.hooks.validateReport(
            agentID: agentID, surfaceGeneration: .initial,
            sourceID: "launcher", sequence: nil, token: oldToken
        )
        guard case .reject = staleVerdict else {
            return XCTFail("invalidated hook must reject, got \(staleVerdict)")
        }

        // 4. Registry UNBOUND (:239-249). Spawn-time bindAndSpawn had
        //    installed the successor binding, but the reattach-failure path
        //    removes it: both the old and the successor surface are retired,
        //    so prompt/stop traffic must not route into a dead surface.
        XCTAssertNil(wired.registry.binding(for: agentID))
        XCTAssertNil(wired.registry.agentID(for: oldTerminalID),
                     "the retired terminal's reverse mapping must be swept too")

        // 5. Two tickets; the generation-1 ticket names the successor terminal.
        let ticketFiles = try FileManager.default.contentsOfDirectory(
            at: wired.ticketsDir, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        XCTAssertEqual(ticketFiles.count, 2)
        var successorTerminal: TerminalID?
        for file in ticketFiles {
            let ticket = try JSONDecoder().decode(LaunchTicket.self, from: Data(contentsOf: file))
            if ticket.surfaceGeneration == 1 {
                successorTerminal = TerminalID(rawValue: ticket.terminalID)
            }
        }
        let successorTerminalID = try XCTUnwrap(successorTerminal, "generation-1 ticket must exist")

        // 6. Successor retired through the §3.11 ladder.
        await ticketedWaitUntil(timeout: 6) {
            wired.manager.teardownQueueForTesting().drainForTesting()
            return wired.manager.session(for: successorTerminalID) == nil
        }

        // 7. The runtime kept its post-restart view — the exact desync the
        //    compensation comment describes.
        _ = try await wired.runtime.state(of: agentID)
    }

    // MARK: Round 15 B1 — awaitPendingRetires drains every superseded ladder

    func testAwaitPendingRetiresDrainsEveryInFlightSupersededSurfaceLadder() async throws {
        let wired = try await makeWired(
            launcherExecutable: URL(fileURLWithPath: "/bin/true"), withTickets: true
        )
        defer {
            wired.engine.shutdown()
            try? FileManager.default.removeItem(at: wired.ticketsDir)
        }
        let stubDir = try makeTicketedStubDir()
        defer { try? FileManager.default.removeItem(atPath: stubDir) }

        // Arrange: the full P6 flow up to an idle agent.
        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        var agent: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            agent = try await wired.pipeline.createAgent(
                AgentLaunchRequest(
                    agentKind: .openCode,
                    workingDirectory: "/tmp/proj",
                    displayName: "Draining"
                ),
                in: workspace
            )
        }
        let agentID = try XCTUnwrap(agent)
        let oldTerminalID = try XCTUnwrap(wired.registry.binding(for: agentID)).terminalID

        await wired.runtime.ingest(lifecycleEvidence(
            agent: agentID, terminal: oldTerminalID, generation: .initial,
            outputRevision: 0, lifecycle: .idle, at: wired.clock.now
        ))
        await ticketedWaitUntil {
            guard let state = try? await wired.runtime.state(of: agentID) else { return false }
            return state.lifecycle == .idle
        }

        // Act: restartAgent RETURNS while the old terminal's retire ladder
        // (SIGTERM → real 2 s grace → SIGKILL → close) is still in flight —
        // the ladder cannot have finished within the call.
        try await withTicketedStubbedPATH(stubDir) {
            try await wired.pipeline.restartAgent(agentID)
        }
        XCTAssertNotNil(
            wired.manager.session(for: oldTerminalID),
            "precondition: the superseded surface must still be alive when restartAgent returns"
        )

        // The production drain IS the only wait: it absorbs the ladder's own
        // grace period. NO polling afterwards — immediacy is the law.
        await wired.pipeline.awaitPendingRetires()

        // 1. The close leg completed synchronously with the drain: no
        // superseded process outlives it.
        XCTAssertNil(wired.manager.session(for: oldTerminalID))
        // 2. Draining did not resurrect anything in the reverse map.
        XCTAssertNil(wired.registry.agentID(for: oldTerminalID))

        // 3. Idempotence: tasks self-remove from pendingRetires, so a second
        // drain walks an EMPTY dict and changes nothing.
        await wired.pipeline.awaitPendingRetires()
        XCTAssertNil(wired.manager.session(for: oldTerminalID))
    }

    // MARK: R28-S1 — overlapping restarts coalesce onto ONE successor

    func testOverlappingRestartsCoalesceOntoOneSuccessor() async throws {
        let stubDir = try makeTicketedStubDir()
        defer { try? FileManager.default.removeItem(atPath: stubDir) }
        let wired = try await makeWired(
            launcherExecutable: URL(fileURLWithPath: "/bin/true"), withTickets: true
        )
        defer {
            wired.engine.shutdown()
            try? FileManager.default.removeItem(at: wired.ticketsDir)
        }
        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        var agent: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            agent = try await wired.pipeline.createAgent(
                AgentLaunchRequest(
                    agentKind: .openCode,
                    workingDirectory: "/tmp/proj",
                    displayName: "Coalescing"
                ),
                in: workspace
            )
        }
        let agentID = try XCTUnwrap(agent)
        let oldTerminalID = try XCTUnwrap(wired.registry.binding(for: agentID)).terminalID
        await wired.runtime.ingest(lifecycleEvidence(
            agent: agentID, terminal: oldTerminalID, generation: .initial,
            outputRevision: 0, lifecycle: .idle, at: wired.clock.now
        ))
        await ticketedWaitUntil {
            guard let state = try? await wired.runtime.state(of: agentID) else { return false }
            return state.lifecycle == .idle
        }
        let initialSpecCount = wired.engine.specs.count

        // Act: two concurrent callers. Whichever enters `restartAgent` first
        // stores the in-flight task entry BEFORE its first suspension, so the
        // other caller necessarily observes the entry and coalesces — the
        // overlap needs no timing luck.
        let first = Task { [pipeline = wired.pipeline] in
            try await withTicketedStubbedPATH(stubDir) {
                try await pipeline.restartAgent(agentID)
            }
        }
        let second = Task { [pipeline = wired.pipeline] in
            try await withTicketedStubbedPATH(stubDir) {
                try await pipeline.restartAgent(agentID)
            }
        }
        try await first.value
        try await second.value

        // Assert: exactly ONE successor spawn observable.
        XCTAssertEqual(wired.engine.specs.count, initialSpecCount + 1,
                       "both callers must share ONE restart — a second spawn orphans the first")
        let ticketFiles = try FileManager.default.contentsOfDirectory(
            at: wired.ticketsDir, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        XCTAssertEqual(ticketFiles.count, 2, "initial + exactly one successor ticket")
        let genOneTickets = ticketFiles.filter { file -> Bool in
            guard let ticket = try? JSONDecoder().decode(LaunchTicket.self, from: Data(contentsOf: file)) else {
                return false
            }
            return ticket.surfaceGeneration == 1
        }
        XCTAssertEqual(genOneTickets.count, 1)

        // The registry references the ONE new terminal; the old terminal is
        // fully unmapped.
        let binding = try XCTUnwrap(wired.registry.binding(for: agentID))
        XCTAssertEqual(binding.surfaceGeneration.rawValue, 1)
        XCTAssertNotEqual(binding.terminalID, oldTerminalID)
        XCTAssertEqual(wired.registry.agentID(for: binding.terminalID), agentID)
        XCTAssertNil(wired.registry.agentID(for: oldTerminalID))
    }

    // MARK: R28-S2 — restart after completion restarts AGAIN (replay window)

    /// Regression: if `inFlightRestarts` were cleared by the first AWAITER
    /// instead of the task body's defer, a caller arriving after completion
    /// would coalesce onto the COMPLETED task and replay its success instead
    /// of starting a fresh restart — the agent stays on the retired surface.
    func testSecondRestartAfterCompletionPerformsARealRestart() async throws {
        let stubDir = try makeTicketedStubDir()
        defer { try? FileManager.default.removeItem(atPath: stubDir) }
        let wired = try await makeWired(
            launcherExecutable: URL(fileURLWithPath: "/bin/true"), withTickets: true
        )
        defer {
            wired.engine.shutdown()
            try? FileManager.default.removeItem(at: wired.ticketsDir)
        }
        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        var agent: AgentID?
        try await withTicketedStubbedPATH(stubDir) {
            agent = try await wired.pipeline.createAgent(
                AgentLaunchRequest(
                    agentKind: .openCode,
                    workingDirectory: "/tmp/proj",
                    displayName: "Replaying"
                ),
                in: workspace
            )
        }
        let agentID = try XCTUnwrap(agent)
        let oldTerminalID = try XCTUnwrap(wired.registry.binding(for: agentID)).terminalID
        await wired.runtime.ingest(lifecycleEvidence(
            agent: agentID, terminal: oldTerminalID, generation: .initial,
            outputRevision: 0, lifecycle: .idle, at: wired.clock.now
        ))
        await ticketedWaitUntil {
            guard let state = try? await wired.runtime.state(of: agentID) else { return false }
            return state.lifecycle == .idle
        }
        let initialSpecCount = wired.engine.specs.count

        // Act: two SEQUENTIAL restarts — the second begins only after the
        // first fully completed.
        try await withTicketedStubbedPATH(stubDir) {
            try await wired.pipeline.restartAgent(agentID)
        }
        let firstBinding = try XCTUnwrap(wired.registry.binding(for: agentID))
        XCTAssertEqual(firstBinding.surfaceGeneration.rawValue, 1, "G1 from the first restart")
        let firstSuccessorTerminal = firstBinding.terminalID

        try await withTicketedStubbedPATH(stubDir) {
            try await wired.pipeline.restartAgent(agentID)
        }

        // Assert: generation advanced AGAIN (G2 > G1) with one more real
        // spawn. A stale-success replay would leave generation 1.
        let secondBinding = try XCTUnwrap(wired.registry.binding(for: agentID))
        XCTAssertEqual(secondBinding.surfaceGeneration.rawValue, 2)
        XCTAssertNotEqual(secondBinding.terminalID, firstSuccessorTerminal)
        XCTAssertEqual(wired.registry.agentID(for: secondBinding.terminalID), agentID)
        XCTAssertNil(wired.registry.agentID(for: firstSuccessorTerminal))
        XCTAssertEqual(wired.engine.specs.count, initialSpecCount + 2,
                       "each completed restart must spawn its own successor surface")
        let ticketFiles = try FileManager.default.contentsOfDirectory(
            at: wired.ticketsDir, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        XCTAssertEqual(ticketFiles.count, 3, "initial + G1 + G2 tickets")
    }
}

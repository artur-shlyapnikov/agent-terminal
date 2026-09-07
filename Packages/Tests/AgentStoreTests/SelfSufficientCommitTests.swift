import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Self-sufficient persistence contract (§3.14): a runtime commit carrying
// session identity is enough to produce a full durable agent row — callers
// never pre-register a DB identity row, and operator/store-owned columns
// survive every later snapshot upsert.

final class SelfSufficientCommitTests: XCTestCase {
    private func makeWriter(_ db: AgentDatabase) -> AgentStore.DatabaseWriter {
        AgentStore.DatabaseWriter(transactor: PoolTransactor(pool: db.pool))
    }

    private func makeSession(id: AgentID, workspace: WorkspaceID) -> AgentSession {
        AgentSession(
            id: id,
            workspaceID: workspace,
            kind: .claudeCode,
            displayName: "self-sufficient",
            taskSummary: "contract",
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: .claudeCode, program: "claude",
                workingDirectory: "/tmp"
            ),
            resumePolicy: .manual,
            state: AgentState(lifecycle: .starting, authority: .unknown,
                              revision: 1, observedAt: .zero),
            createdAt: .zero,
            lastActivityAt: .zero
        )
    }

    /// The key contract: create + ONE commit ⇒ full durable agent row.
    func testFirstCommitFabricatesTheIdentityRowWithoutRegistration() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspaces = WorkspaceRepository(database: db)
        let workspace = Workspace(name: "W", rootPath: "/tmp", createdAt: .zero, updatedAt: .zero)
        try await workspaces.save(workspace, sortIndex: 0)

        let writer = makeWriter(db)
        let agent = AgentID()
        let session = makeSession(id: agent, workspace: workspace.id)
        let state = session.state
        await writer.commit(StateCommit(
            agentID: agent,
            state: state,
            events: [],
            sessionReference: nil,
            session: session
        ))

        let repository = AgentRepository(database: db)
        let restored = try await repository.find(agent)
        XCTAssertNotNil(restored, "the writer must fabricate the row from the commit's session")
        XCTAssertEqual(restored?.workspaceID, workspace.id)
        XCTAssertEqual(restored?.kind, .claudeCode)
        XCTAssertEqual(restored?.displayName, "self-sufficient")
    }

    /// Operator-owned columns (resume_requested / archived_at) are written
    /// only by their repository APIs and must survive snapshot updates.
    func testSnapshotUpdatePreservesOperatorOwnedColumns() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspaces = WorkspaceRepository(database: db)
        let workspace = Workspace(name: "W", rootPath: "/tmp", createdAt: .zero, updatedAt: .zero)
        try await workspaces.save(workspace, sortIndex: 0)

        let writer = makeWriter(db)
        let agent = AgentID()
        var session = makeSession(id: agent, workspace: workspace.id)
        await writer.commit(StateCommit(
            agentID: agent, state: session.state, events: [],
            sessionReference: nil, session: session
        ))

        let repository = AgentRepository(database: db)
        try await repository.setResumeRequested(true, agentID: agent)
        try await repository.archive(agent)

        // A NEWER-revision runtime commit must not clobber the flags.
        session.state.revision += 1
        await writer.commit(StateCommit(
            agentID: agent, state: session.state, events: [],
            sessionReference: nil, session: session
        ))

        let flags = try await db.pool.read { db -> (Int, Double?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT resume_requested, archived_at FROM agents WHERE id = ?",
                arguments: [agent.rawValue.uuidString]
            )
            return (Int((row?["resume_requested"] as Int64?) ?? -1),
                    row?["archived_at"] as Double?)
        }
        XCTAssertEqual(flags.0, 1, "resume_requested must survive the snapshot update")
        XCTAssertNotNil(flags.1, "archived_at must survive the snapshot update")
    }

    /// A commit WITHOUT session identity for an unknown agent still records
    /// its events but cannot fabricate an identity row (legacy contract).
    func testLegacyCommitWithoutSessionStillRecordsEventsOnly() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let writer = makeWriter(db)
        let agent = AgentID()
        await writer.commit(StateCommit(
            agentID: agent,
            state: AgentState(lifecycle: .idle, authority: .unknown,
                              revision: 3, observedAt: .zero),
            events: [],
            sessionReference: nil,
            session: nil
        ))
        let rows = try await TestEnv.rowCount(db, "agents")
        XCTAssertEqual(rows, 0)
    }
}

import AgentCore
import Foundation
import GRDB

// Terminal runtime metadata persistence (architecture §4.4). Surface
// generation, presentation and output revision are ephemeral (§3.3) and are
// deliberately not stored.

public final class TerminalRepository: Sendable {
    private let transactor: any StoreTransacting

    public init(transactor: any StoreTransacting) {
        self.transactor = transactor
    }

    public convenience init(database: AgentDatabase) {
        self.init(transactor: PoolTransactor(pool: database.pool))
    }

    public func save(_ terminal: TerminalSession, now: Date = Date()) async throws {
        let row = terminal.row(now: now.timeIntervalSince1970, exitAt: terminal.exitAt)
        try await transactor.write { db in
            try db.execute(
                sql: """
                INSERT INTO terminals
                    (id, workspace_id, agent_id, cwd, last_runtime_status, last_exit_code, last_exit_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    workspace_id = excluded.workspace_id,
                    agent_id = excluded.agent_id,
                    cwd = excluded.cwd,
                    last_runtime_status = excluded.last_runtime_status,
                    last_exit_code = excluded.last_exit_code,
                    last_exit_at = excluded.last_exit_at,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    row.id,
                    row.workspaceID,
                    row.agentID,
                    row.cwd,
                    row.lastRuntimeStatus,
                    row.lastExitCode,
                    row.lastExitAt,
                    row.createdAt,
                    row.updatedAt,
                ]
            )
        }
    }

    public func find(_ id: TerminalID) async throws -> TerminalSession? {
        let idString = id.rawValue.uuidString
        return try await transactor.write { db in
            try TerminalRow
                .filter(Column("id") == idString)
                .fetchOne(db)
                .flatMap(TerminalSession.restoring)
        }
    }

    public func list(workspaceID: WorkspaceID) async throws -> [TerminalSession] {
        let wsString = workspaceID.rawValue.uuidString
        return try await transactor.write { db in
            try TerminalRow
                .filter(Column("workspace_id") == wsString)
                .order(Column("created_at").asc)
                .fetchAll(db)
                .compactMap(TerminalSession.restoring)
        }
    }

    public func delete(_ id: TerminalID) async throws {
        let idString = id.rawValue.uuidString
        try await transactor.write { db in
            _ = try TerminalRow.deleteOne(db, key: idString)
        }
    }
}

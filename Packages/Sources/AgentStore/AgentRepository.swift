import AgentCore
import Foundation
import GRDB

// Agent snapshot / session-reference persistence (architecture §4.4).
// Only adapter-owned non-secret data reaches launch_descriptor_json and
// session_ref_json; queued prompts and turns are never written (§3.11).

public final class AgentRepository: Sendable {
    private let transactor: any StoreTransacting

    public init(transactor: any StoreTransacting) {
        self.transactor = transactor
    }

    public convenience init(database: AgentDatabase) {
        self.init(transactor: PoolTransactor(pool: database.pool))
    }

    /// Full upsert of the persisted projection of an agent session.
    public func save(_ session: AgentSession, now: Date = Date()) async throws {
        let row = try session.row(now: now.timeIntervalSince1970)
        try await transactor.write { db in
            // Shadow copy: GRDB's upsert mutates persistence bookkeeping on
            // the record; mutating a captured var across the @Sendable write
            // closure is a Swift 6 error. The mutation stays closure-local.
            var row = row
            if let existing = try AgentRow.filter(Column("id") == row.id).fetchOne(db) {
                // §3.14 revision law: never let a stale app-side session
                // regress last_state_revision below what DatabaseWriter
                // already persisted; skip the upsert entirely in that case.
                guard existing.lastStateRevision <= row.lastStateRevision else { return }
                // Columns the domain model does not own — resume_requested
                // and archived_at are written only by setResumeRequested/
                // archive — must survive a full-column upsert. Re-apply the
                // stored values before the write.
                row.resumeRequested = existing.resumeRequested
                row.archivedAt = existing.archivedAt
            }
            try row.upsert(db)
        }
    }

    public func find(_ id: AgentID) async throws -> AgentSession? {
        let idString = id.rawValue.uuidString
        return try await transactor.write { db in
            try AgentRow
                .filter(Column("id") == idString)
                .fetchOne(db)
                .flatMap(AgentSession.restoring)
        }
    }

    /// Live (non-archived) agents of a workspace in creation order.
    public func list(workspaceID: WorkspaceID, includeArchived: Bool = false) async throws -> [AgentSession] {
        let wsString = workspaceID.rawValue.uuidString
        return try await transactor.write { db in
            var request = AgentRow.filter(Column("workspace_id") == wsString)
            if !includeArchived {
                request = request.filter(Column("archived_at") == nil)
            }
            return try request
                .order(Column("created_at").asc)
                .fetchAll(db)
                .compactMap(AgentSession.restoring)
        }
    }

    /// Marks resume intent for the quit-and-resume-later flow (§3.15).
    public func setResumeRequested(_ requested: Bool, agentID: AgentID) async throws {
        let idString = agentID.rawValue.uuidString
        try await transactor.write { db in
            try db.execute(
                sql: "UPDATE agents SET resume_requested = ?, updated_at = ? WHERE id = ?",
                arguments: [requested, Date().timeIntervalSince1970, idString]
            )
        }
    }

    /// Clears the resume intent flag on EVERY row in one statement. Used by
    /// the 'Quit and Stop Agents' teardown path: the operator's latest
    /// explicit choice supersedes any earlier-armed resume request (§3.15).
    public func clearResumeRequested() async throws {
        try await transactor.write { db in
            try db.execute(
                sql: "UPDATE agents SET resume_requested = 0, updated_at = ? WHERE resume_requested = 1",
                arguments: [Date().timeIntervalSince1970]
            )
        }
    }

    public func archive(_ id: AgentID, at date: Date = Date()) async throws {
        let idString = id.rawValue.uuidString
        try await transactor.write { db in
            try db.execute(
                sql: "UPDATE agents SET archived_at = ?, terminal_id = NULL, updated_at = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, date.timeIntervalSince1970, idString]
            )
        }
    }

    public func delete(_ id: AgentID) async throws {
        let idString = id.rawValue.uuidString
        try await transactor.write { db in
            _ = try AgentRow.deleteOne(db, key: idString)
        }
    }

    // MARK: - Writer support

    /// Registers an agent so DatabaseWriter commits have a snapshot row to
    /// update. Called when the runtime creates the session.
    public func register(_ session: AgentSession, now: Date = Date()) async throws {
        try await save(session, now: now)
    }
}

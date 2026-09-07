import AgentCore
@testable import AgentStore
import Foundation
import XCTest

// Round 4 residue: `SchemaMigrator.migrate()` idempotence (architecture §5.2).
// MigrationTests pins fresh installs, backup-before-upgrade, newer-schema
// refusal, and constraints — nobody re-runs migrate() on an already-current,
// POPULATED database. The §5.2 "already-current ⇒ no backup" branch
// (Migrations.swift:57-64) must stay a no-op: an "ensure migrated" wrapper
// that always re-backs-up floods the user's backups/ directory on every app
// start.

final class MigrationIdempotencyTests: XCTestCase {
    func testSecondMigrateOnPopulatedCurrentDatabaseIsANoOpWithoutBackup() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)

        // Fresh install: migrates without backup (the OTHER sanctioned
        // exception — no prior schema to preserve).
        try db.migrate()
        XCTAssertEqual(try TestEnv.backupFiles(in: dir), [])

        // Populate: one workspace + one agent row (FK order honored).
        let workspace = makeWorkspace(name: "Idempotency")
        try await installWorkspace(db, workspace)
        try await AgentRepository(database: db).save(makeSession(workspace: workspace))

        let workspacesBefore = try await TestEnv.rowCount(db, "workspaces")
        let agentsBefore = try await TestEnv.rowCount(db, "agents")
        let migrationsBefore = try await TestEnv.rowCount(db, "grdb_migrations")
        XCTAssertEqual(workspacesBefore, 1)
        XCTAssertEqual(agentsBefore, 1)

        // Act: second migrate() on an already-current database.
        try db.migrate()

        // Assert: no throw; still no backup; nothing mutated.
        XCTAssertEqual(
            try TestEnv.backupFiles(in: dir),
            [],
            "already-current database must not be backed up on re-migration"
        )
        let workspacesAfter = try await TestEnv.rowCount(db, "workspaces")
        XCTAssertEqual(workspacesAfter, workspacesBefore)
        let agentsAfter = try await TestEnv.rowCount(db, "agents")
        XCTAssertEqual(agentsAfter, agentsBefore)
        let migrationsAfter = try await TestEnv.rowCount(db, "grdb_migrations")
        XCTAssertEqual(
            migrationsAfter,
            migrationsBefore,
            "re-running migrate() must not duplicate migration identifiers"
        )

        // Seeded data stays readable through the repository layer.
        let restored = try await WorkspaceRepository(database: db).find(workspace.id)
        XCTAssertEqual(restored?.workspace.id, workspace.id)
        XCTAssertEqual(restored?.workspace.name, workspace.name)
    }
}

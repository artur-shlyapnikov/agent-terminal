import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Migration behavior (architecture §3.14 schema, §5.2 rules).

final class MigrationTests: XCTestCase {
    func testFreshInstallCreatesExactSchemaWithoutBackup() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let expectedColumns: [String: [String]] = [
            "workspaces": ["id", "name", "root_path", "sort_index", "created_at", "updated_at", "archived_at"],
            "agents": [
                "id", "workspace_id", "terminal_id", "kind", "display_name", "task_summary",
                "cwd", "launch_descriptor_json", "resume_policy", "session_ref_json",
                "last_lifecycle", "last_attention", "last_state_revision", "last_activity_at",
                "resume_requested", "created_at", "updated_at", "archived_at",
            ],
            "terminals": [
                "id", "workspace_id", "agent_id", "cwd", "last_runtime_status",
                "last_exit_code", "last_exit_at", "created_at", "updated_at",
            ],
            "layouts": ["workspace_id", "schema_version", "tree_json", "selected_agent_id", "updated_at"],
            "agent_events": ["id", "agent_id", "revision", "kind", "source", "payload_json", "created_at", "seen_at"],
            "integration_installs": [
                "agent_kind", "integration_version", "status",
                "managed_files_json", "managed_fingerprint", "installed_at",
            ],
            "app_runs": ["id", "started_at", "ended_at", "termination_kind"],
            "settings": ["key", "value_json", "updated_at"],
        ]

        let transactor = PoolTransactor(pool: db.pool)
        for (table, expected) in expectedColumns {
            let names: [String] = try await transactor.write { database in
                try String.fetchAll(database, sql: "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid")
            }
            XCTAssertEqual(names, expected, "column mismatch on \(table)")
        }

        // Spot-check §3.14 defaults.
        let defaults: [(String, String, String)] = [
            ("workspaces", "sort_index", "0"),
            ("agents", "resume_policy", "'manual'"),
            ("agents", "last_lifecycle", "'unknown'"),
            ("agents", "last_attention", "'none'"),
            ("agents", "last_state_revision", "0"),
            ("agents", "resume_requested", "0"),
        ]
        for (table, column, expectedDefault) in defaults {
            let dflt: String? = try await transactor.write { database in
                try String.fetchOne(
                    database,
                    sql: "SELECT dflt_value FROM pragma_table_info('\(table)') WHERE name = '\(column)'"
                )
            }
            XCTAssertEqual(
                dflt?.replacingOccurrences(of: "'", with: ""),
                expectedDefault.replacingOccurrences(of: "'", with: ""),
                "\(table).\(column) default"
            )
        }

        // Fresh install: no backup noise (§5.2 backs up only real upgrades).
        XCTAssertEqual(try TestEnv.backupFiles(in: dir), [])
    }

    func testBackupCreatedBeforeUpgradeMigration() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let url = dir.appendingPathComponent("upgrade.sqlite")

        // Simulate a previous-generation database (applied version 0).
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        var legacy = DatabaseMigrator()
        legacy.registerMigration("agentstore-v0") { database in
            try database.execute(sql: "CREATE TABLE legacy_marker (note TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO legacy_marker (note) VALUES ('precious data')")
        }
        try legacy.migrate(pool)

        // Now open through AgentStore and migrate to the current schema.
        let db = try AgentDatabase(
            databaseURL: url,
            backupDirectoryURL: dir.appendingPathComponent("backups")
        )
        try db.migrate()

        // Backup exists and contains the pre-migration data (§5.2).
        let backups = try TestEnv.backupFiles(in: dir)
        guard let backupURL = backups.first else {
            let listed = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return XCTFail("no backup file; dir contains \(listed.map(\.lastPathComponent))")
        }
        let backupPool = try DatabasePool(path: backupURL.path, configuration: Configuration())
        let note = try await backupPool.read { database in
            try String.fetchOne(database, sql: "SELECT note FROM legacy_marker")
        }
        XCTAssertEqual(note, "precious data")

        // And current schema is live afterwards.
        try await PoolTransactor(pool: db.pool).write { database in
            try database.execute(
                sql: "INSERT INTO settings (key, value_json, updated_at) VALUES ('k', ?, 1)",
                arguments: [Data("{}".utf8)]
            )
        }
    }

    func testRefusesToWriteNewerSchema() throws {
        let dir = try TestEnv.makeTempDirectory()
        let url = dir.appendingPathComponent("future.sqlite")

        // A database written by a NEWER build.
        let config = Configuration()
        let pool = try DatabasePool(path: url.path, configuration: config)
        var future = DatabaseMigrator()
        future.registerMigration("agentstore-v99") { _ in }
        try future.migrate(pool)

        let db = try TestEnv.makeDatabase(in: dir, name: "future.sqlite")
        XCTAssertThrowsError(try db.migrate()) { error in
            guard case let MigrationError.databaseFromNewerSchema(applied, known) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(applied, 99)
            XCTAssertEqual(known, UInt64(Schema.currentVersion))
        }
    }

    func testUniqueAndForeignKeyConstraintsEnforced() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let wsID = UUID().uuidString
        let agentA = UUID().uuidString
        let terminalX = UUID().uuidString
        try await PoolTransactor(pool: db.pool).write { database in
            try database.execute(
                sql: "INSERT INTO workspaces (id, name, root_path, sort_index, created_at, updated_at) VALUES (?, 'w', '/p', 0, 1, 1)",
                arguments: [wsID]
            )
            try database.execute(
                sql: """
                INSERT INTO agents (id, workspace_id, terminal_id, kind, display_name, cwd, launch_descriptor_json, created_at, updated_at)
                VALUES (?, ?, ?, 'claude-code', 'a', '/p', ?, 1, 1)
                """,
                arguments: [agentA, wsID, terminalX, Data("{}".utf8)]
            )
            try database.execute(
                sql: """
                INSERT INTO terminals (id, workspace_id, agent_id, cwd, last_runtime_status, created_at, updated_at)
                VALUES (?, ?, ?, '/p', 'running', 1, 1)
                """,
                arguments: [UUID().uuidString, wsID, agentA]
            )
        }

        let pool = db.pool

        // agents.terminal_id is UNIQUE (§3.14).
        do {
            try await pool.write { database in
                try database.execute(
                    sql: """
                    INSERT INTO agents (id, workspace_id, terminal_id, kind, display_name, cwd, launch_descriptor_json, created_at, updated_at)
                    VALUES (?, ?, ?, 'codex', 'b', '/p', ?, 2, 2)
                    """,
                    arguments: [UUID().uuidString, wsID, terminalX, Data("{}".utf8)]
                )
            }
            XCTFail("duplicate agents.terminal_id must be rejected")
        } catch {
            assertConstraintError(error, naming: "UNIQUE", context: "agents.terminal_id")
        }

        // terminals.agent_id is UNIQUE (§3.14).
        do {
            try await pool.write { database in
                try database.execute(
                    sql: """
                    INSERT INTO terminals (id, workspace_id, agent_id, cwd, last_runtime_status, created_at, updated_at)
                    VALUES (?, ?, ?, '/p', 'running', 2, 2)
                    """,
                    arguments: [UUID().uuidString, wsID, agentA]
                )
            }
            XCTFail("duplicate terminals.agent_id must be rejected")
        } catch {
            assertConstraintError(error, naming: "UNIQUE", context: "terminals.agent_id")
        }

        // FK enforcement: agent row must reference an existing workspace.
        do {
            try await pool.write { database in
                try database.execute(
                    sql: """
                    INSERT INTO agents (id, workspace_id, kind, display_name, cwd, launch_descriptor_json, created_at, updated_at)
                    VALUES (?, ?, 'claude-code', 'c', '/p', ?, 3, 3)
                    """,
                    arguments: [UUID().uuidString, UUID().uuidString, Data("{}".utf8)]
                )
            }
            XCTFail("FK violation must be rejected")
        } catch {
            assertConstraintError(error, naming: "FOREIGN KEY", context: "agents.workspace_id")
        }
    }

    /// A bare catch proves only "something threw": a typo'd column or a
    /// misconfigured pool satisfies it. Each negative case must pin the
    /// constraint it exercises (§3.14).
    private func assertConstraintError(
        _ error: any Error, naming fragment: String, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let dbError = error as? DatabaseError else {
            XCTFail("\(context): expected DatabaseError, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            dbError.message?.uppercased().contains(fragment) == true,
            "\(context): expected \(fragment) constraint error, got \(dbError.message ?? "nil")",
            file: file, line: line
        )
    }
}

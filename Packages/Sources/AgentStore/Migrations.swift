import Foundation
import GRDB

// Versioned schema migrations (architecture §3.14 tables, §5.2 rules):
// - a file-level backup is taken before ANY migration is applied;
// - a database written by a NEWER AgentStore refuses to be written;
// - downgrades never happen automatically.

enum MigrationError: Error, Equatable {
    /// The on-disk schema is newer than this build knows (§5.2: refuse to write).
    case databaseFromNewerSchema(appliedVersion: UInt64, knownVersion: UInt64)
    /// Version bookkeeping is empty yet the schema's tables exist — a wiped
    /// or partially restored database. Refused so V1 CREATE TABLEs never
    /// run against existing tables (§5.2: never write blind).
    case schemaWithoutVersionBookkeeping
}

enum Schema {
    /// Highest migration version defined by this build.
    static let currentVersion: UInt64 = 1
    static let identifierPrefix = "agentstore-v"

    static func identifier(for version: UInt64) -> String {
        "\(identifierPrefix)\(version)"
    }

    /// Extracts the numeric version from a migration identifier minted here.
    static func version(ofIdentifier identifier: String) -> UInt64? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UInt64(identifier.dropFirst(identifierPrefix.count))
    }
}

struct SchemaMigrator {
    private let database: AgentDatabase

    init(database: AgentDatabase) {
        self.database = database
    }

    /// Versions already applied to the on-disk database (empty for fresh installs).
    func appliedVersions() throws -> [UInt64] {
        try database.pool.read { db in
            let migrator = DatabaseMigrator()
            let identifiers = try migrator.appliedIdentifiers(db)
            return identifiers.compactMap(Schema.version(ofIdentifier:)).sorted()
        }
    }

    func migrate() throws {
        let applied = try appliedVersions()

        // §5.2: refuse to write when the schema is newer than we support.
        if let newest = applied.max(), newest > Schema.currentVersion {
            throw MigrationError.databaseFromNewerSchema(
                appliedVersion: newest,
                knownVersion: Schema.currentVersion
            )
        }

        // Empty bookkeeping does NOT imply a fresh install: a partially
        // restored file or wiped grdb_migrations can still carry V1 tables.
        // Probe the schema first — if anything exists, secure a backup and
        // refuse, instead of failing 'table already exists' on every launch.
        if applied.isEmpty {
            let hasSchema = try database.pool.read { db in
                // Any V1 table counts: a partial restore can carry some
                // tables without others, and every one of them makes the
                // later CREATE TABLE fail without a §5.2 backup.
                try ["workspaces", "agents", "terminals", "app_runs"]
                    .contains { try db.tableExists($0) }
            }
            if hasSchema {
                try backupDatabaseFiles(newestAppliedVersion: 0)
                throw MigrationError.schemaWithoutVersionBookkeeping
            }
        }

        // §5.2 sanctioned exception: a FRESH install has no prior schema to
        // preserve, so no backup is taken. Already-current databases run no
        // migration, so no backup is needed either.
        if let newest = applied.max(), newest < Schema.currentVersion {
            try backupDatabaseFiles(newestAppliedVersion: newest)
        }

        try migrator.migrate(database.pool)
    }

    // MARK: - Backup (§5.2)

    private func backupDatabaseFiles(newestAppliedVersion: UInt64) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: database.backupDirectoryURL, withIntermediateDirectories: true)

        // Fold the WAL back into the main file so the copy is complete.
        // Result (row count) is intentionally discarded; the checkpoint's
        // effect — WAL folded into the main file — is what matters here.
        _ = try database.pool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }

        // checkpoint(TRUNCATE) can leave frames behind when concurrent
        // readers pin the WAL; a main-file-only copy would then be torn.
        // The backup is self-contained only if the WAL is empty (size 0 or
        // absent) after truncation — otherwise it must travel with the copy,
        // and a failure to secure either file aborts the migration.
        let walPath = database.databaseURL.path + "-wal"
        let walSize = (try? fm.attributesOfItem(atPath: walPath)[.size])
            .flatMap { $0 as? Int64 } ?? 0
        let stamp = Int(Date().timeIntervalSince1970)
        let prefix = database.databaseURL.deletingPathExtension().lastPathComponent
        // Two migrations can land within the same wall-clock second; a bare
        // stamp collides and copyItem aborts migrate(). Add an unpredictable
        // suffix so every backup name is collision-free.
        let uniquifier = UUID().uuidString.lowercased().prefix(8)
        let target = database.backupDirectoryURL
            .appendingPathComponent("\(prefix)-pre-v\(newestAppliedVersion)-\(stamp)-\(uniquifier).sqlite")
        if walSize > 0 {
            // Non-empty WAL after the truncate checkpoint: the main-file
            // copy alone would be torn, so the WAL travels with the backup.
            try fm.copyItem(atPath: walPath, toPath: target.path + "-wal")
        }
        try fm.copyItem(at: database.databaseURL, to: target)
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(Schema.identifier(for: 1)) { db in
            try Self.createV1Schema(db)
        }
        return migrator
    }

    static func createV1Schema(_ db: Database) throws {
        // Column lists follow §3.14 exactly (types, NULLability, defaults,
        // UNIQUE constraints). Deletions of referenced rows are restricted —
        // the spec defines no cascade behavior.
        try db.create(table: "workspaces") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("root_path", .text).notNull()
            t.column("sort_index", .integer).notNull().defaults(to: 0)
            t.column("created_at", .double).notNull()
            t.column("updated_at", .double).notNull()
            t.column("archived_at", .double)
        }

        try db.create(table: "agents") { t in
            t.primaryKey("id", .text)
            t.column("workspace_id", .text).notNull().references("workspaces")
            t.column("terminal_id", .text).unique()
            t.column("kind", .text).notNull()
            t.column("display_name", .text).notNull()
            t.column("task_summary", .text)
            t.column("cwd", .text).notNull()
            t.column("launch_descriptor_json", .blob).notNull()
            t.column("resume_policy", .text).notNull().defaults(to: "manual")
            t.column("session_ref_json", .blob)
            t.column("last_lifecycle", .text).notNull().defaults(to: "unknown")
            t.column("last_attention", .text).notNull().defaults(to: "none")
            t.column("last_state_revision", .integer).notNull().defaults(to: 0)
            t.column("last_activity_at", .double)
            t.column("resume_requested", .integer).notNull().defaults(to: 0)
            t.column("created_at", .double).notNull()
            t.column("updated_at", .double).notNull()
            t.column("archived_at", .double)
        }

        try db.create(table: "terminals") { t in
            t.primaryKey("id", .text)
            t.column("workspace_id", .text).notNull().references("workspaces")
            t.column("agent_id", .text).unique().references("agents")
            t.column("cwd", .text).notNull()
            t.column("last_runtime_status", .text).notNull()
            t.column("last_exit_code", .integer)
            t.column("last_exit_at", .double)
            t.column("created_at", .double).notNull()
            t.column("updated_at", .double).notNull()
        }

        try db.create(table: "layouts") { t in
            t.primaryKey("workspace_id", .text).references("workspaces")
            t.column("schema_version", .integer).notNull()
            t.column("tree_json", .blob).notNull()
            t.column("selected_agent_id", .text)
            t.column("updated_at", .double).notNull()
        }

        try db.create(table: "agent_events") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("agent_id", .text).notNull()
            t.column("revision", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("source", .text).notNull()
            t.column("payload_json", .blob).notNull()
            t.column("created_at", .double).notNull()
            t.column("seen_at", .double)
        }

        try db.create(table: "integration_installs") { t in
            t.column("agent_kind", .text).notNull()
            t.column("integration_version", .text).notNull()
            t.column("status", .text).notNull()
            t.column("managed_files_json", .blob).notNull()
            t.column("managed_fingerprint", .text).notNull()
            t.column("installed_at", .double).notNull()
            t.primaryKey(["agent_kind", "integration_version"])
        }

        try db.create(table: "app_runs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("started_at", .double).notNull()
            t.column("ended_at", .double)
            t.column("termination_kind", .text)
        }

        try db.create(table: "settings") { t in
            t.primaryKey("key", .text)
            t.column("value_json", .blob).notNull()
            t.column("updated_at", .double).notNull()
        }

        // Lookup indexes for FK joins and the retention scan.
        try db.create(index: "agents_workspace_id", on: "agents", columns: ["workspace_id"])
        try db.create(index: "terminals_workspace_id", on: "terminals", columns: ["workspace_id"])
        try db.create(index: "agent_events_agent_revision", on: "agent_events", columns: ["agent_id", "revision"])
    }
}

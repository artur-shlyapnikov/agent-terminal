import AgentCore
import Foundation
import GRDB

// Installed integration fingerprints (architecture §3.14/§4.4/§5.3).
// One row per (agent_kind, integration_version).

public struct IntegrationInstall: Equatable, Sendable {
    public var agentKind: AgentKind
    public var integrationVersion: String
    /// e.g. "installed" | "degraded" | "removed".
    public var status: String
    public var managedFilesJSON: Data
    public var managedFingerprint: String
    public var installedAt: Date

    public init(
        agentKind: AgentKind,
        integrationVersion: String,
        status: String,
        managedFilesJSON: Data,
        managedFingerprint: String,
        installedAt: Date
    ) {
        self.agentKind = agentKind
        self.integrationVersion = integrationVersion
        self.status = status
        self.managedFilesJSON = managedFilesJSON
        self.managedFingerprint = managedFingerprint
        self.installedAt = installedAt
    }
}

public final class IntegrationRepository: Sendable {
    private let transactor: any StoreTransacting

    public init(transactor: any StoreTransacting) {
        self.transactor = transactor
    }

    public convenience init(database: AgentDatabase) {
        self.init(transactor: PoolTransactor(pool: database.pool))
    }

    public func upsert(_ install: IntegrationInstall) async throws {
        try await transactor.write { db in
            try db.execute(
                sql: """
                INSERT INTO integration_installs
                    (agent_kind, integration_version, status, managed_files_json, managed_fingerprint, installed_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(agent_kind, integration_version) DO UPDATE SET
                    status = excluded.status,
                    managed_files_json = excluded.managed_files_json,
                    managed_fingerprint = excluded.managed_fingerprint,
                    installed_at = excluded.installed_at
                """,
                arguments: [
                    install.agentKind.rawValue,
                    install.integrationVersion,
                    install.status,
                    install.managedFilesJSON,
                    install.managedFingerprint,
                    install.installedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    public func installs(agentKind: AgentKind? = nil) async throws -> [IntegrationInstall] {
        try await transactor.write { db in
            let sql: String
            let arguments: [String]
            if let agentKind {
                sql = "SELECT * FROM integration_installs WHERE agent_kind = ? ORDER BY installed_at DESC"
                arguments = [agentKind.rawValue]
            } else {
                sql = "SELECT * FROM integration_installs ORDER BY installed_at DESC"
                arguments = []
            }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .compactMap(Self.install(from:))
        }
    }

    public func updateStatus(_ status: String, agentKind: AgentKind, integrationVersion: String) async throws {
        try await transactor.write { db in
            try db.execute(
                sql: """
                UPDATE integration_installs SET status = ?
                WHERE agent_kind = ? AND integration_version = ?
                """,
                arguments: [status, agentKind.rawValue, integrationVersion]
            )
        }
    }

    static func install(from row: Row) -> IntegrationInstall? {
        guard let kindRaw: String = row["agent_kind"],
              let kind = AgentKind(rawValue: kindRaw),
              let version: String = row["integration_version"],
              let files: Data = row["managed_files_json"],
              let fingerprint: String = row["managed_fingerprint"],
              let installed: Double = row["installed_at"]
        else { return nil }
        return IntegrationInstall(
            agentKind: kind,
            integrationVersion: version,
            status: row["status"] ?? "installed",
            managedFilesJSON: files,
            managedFingerprint: fingerprint,
            installedAt: Date(timeIntervalSince1970: installed)
        )
    }
}

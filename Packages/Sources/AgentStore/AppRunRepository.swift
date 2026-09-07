import AgentCore
import Foundation
import GRDB

// App run tracking (architecture §3.14): one row per app launch. A previous
// row without `ended_at` at startup means the last run terminated uncleanly.

public enum TerminationKind: String, Sendable {
    /// Clean quit (§3.15 shutdown flow completed).
    case clean
    /// Crash, kill -9, power loss — detected via the unclosed row.
    case unclean
}

public struct AppRun: Equatable, Sendable {
    public var id: Int64
    public var startedAt: Date
    public var endedAt: Date?
    public var terminationKind: TerminationKind?

    public init(id: Int64, startedAt: Date, endedAt: Date?, terminationKind: TerminationKind?) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.terminationKind = terminationKind
    }
}

public final class AppRunRepository: Sendable {
    private let transactor: any StoreTransacting

    public init(transactor: any StoreTransacting) {
        self.transactor = transactor
    }

    public convenience init(database: AgentDatabase) {
        self.init(transactor: PoolTransactor(pool: database.pool))
    }

    /// Opens a new run row. Call once at app start.
    @discardableResult
    public func beginRun(startedAt: Date = Date()) async throws -> Int64 {
        try await transactor.write { db in
            try db.execute(
                sql: "INSERT INTO app_runs (started_at, ended_at, termination_kind) VALUES (?, NULL, NULL)",
                arguments: [startedAt.timeIntervalSince1970]
            )
            return db.lastInsertedRowID
        }
    }

    /// Atomically closes every unclosed run as `.unclean` AND opens the new
    /// run row in ONE transaction (§3.15): a crash mid-startup can never
    /// leave zero unclosed rows for the next launch to misread as clean.
    @discardableResult
    public func beginRun(closing unclosed: [AppRun], endedAt: Date = Date()) async throws -> Int64 {
        try await transactor.write { db in
            for run in unclosed {
                try db.execute(
                    sql: "UPDATE app_runs SET ended_at = ?, termination_kind = ? WHERE id = ?",
                    arguments: [endedAt.timeIntervalSince1970, TerminationKind.unclean.rawValue, run.id]
                )
            }
            try db.execute(
                sql: "INSERT INTO app_runs (started_at, ended_at, termination_kind) VALUES (?, NULL, NULL)",
                arguments: [Date().timeIntervalSince1970]
            )
            return db.lastInsertedRowID
        }
    }

    /// Closes a run row with its termination kind.
    public func endRun(_ id: Int64, kind: TerminationKind = .clean, endedAt: Date = Date()) async throws {
        try await transactor.write { db in
            try db.execute(
                sql: "UPDATE app_runs SET ended_at = ?, termination_kind = ? WHERE id = ?",
                arguments: [endedAt.timeIntervalSince1970, kind.rawValue, id]
            )
        }
    }

    /// Run rows left open by a previous process — unclean termination
    /// detection (§3.14). Called before opening the new run row; the caller
    /// marks them `.unclean` after surfacing crash recovery (stage 12).
    public func detectUnclosedRuns() async throws -> [AppRun] {
        try await transactor.write { db in
            let rows = try AppRunRow
                .filter(Column("ended_at") == nil)
                .order(Column("id").asc)
                .fetchAll(db)
            return rows.compactMap(Self.run(from:))
        }
    }

    static func run(from row: AppRunRow) -> AppRun? {
        guard let id = row.id else { return nil }
        return AppRun(
            id: id,
            startedAt: Date(timeIntervalSince1970: row.startedAt),
            endedAt: row.endedAt.map(Date.init(timeIntervalSince1970:)),
            terminationKind: row.terminationKind.flatMap(TerminationKind.init(rawValue:))
        )
    }
}

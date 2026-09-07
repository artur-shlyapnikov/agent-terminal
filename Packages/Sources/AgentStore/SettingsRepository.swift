import AgentCore
import Foundation
import GRDB

// Typed settings persistence (architecture §4.4). Values are JSON-encoded
// blobs keyed by a stable string.

public final class SettingsRepository: Sendable {
    private let transactor: any StoreTransacting

    public init(transactor: any StoreTransacting) {
        self.transactor = transactor
    }

    public convenience init(database: AgentDatabase) {
        self.init(transactor: PoolTransactor(pool: database.pool))
    }

    public func set(_ value: some Encodable, forKey key: String, now: Date = Date()) async throws {
        let data = try JSONEncoder().encode(value)
        let updated = now.timeIntervalSince1970
        try await transactor.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
                """,
                arguments: [key, data, updated]
            )
        }
    }

    public func get<T: Decodable>(_ type: T.Type, forKey key: String) async throws -> T? {
        let data: Data? = try await transactor.write { db in
            try Data.fetchOne(db, sql: "SELECT value_json FROM settings WHERE key = ?", arguments: [key])
        }
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // A corrupt blob would poison this key forever (every read
            // rethrows); self-heal by dropping the row and reporting unset.
            try await remove(key)
            return nil
        }
    }

    public func remove(_ key: String) async throws {
        try await transactor.write { db in
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }
    }
}

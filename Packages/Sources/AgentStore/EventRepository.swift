import AgentCore
import Foundation
import GRDB

// Timeline append + retention (architecture §3.14/§4.4). Events carry no
// prompt text, no terminal output, no environment (§3.14 "не сохраняются").
// Retention: at most 1000 events per agent; older rows are removed by
// background maintenance.

public final class EventRepository: Sendable {
    /// §3.14: максимум 1000 событий на agent.
    public static let retentionCap = 1000

    private let transactor: any StoreTransacting

    /// Lock-protected diagnostics counter (shared instances may serve
    /// concurrent readers).
    private final class SkippedRowCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add(_ delta: Int) {
            lock.lock()
            value += delta
            lock.unlock()
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let skippedRows = SkippedRowCount()

    /// Rows skipped during timeline reads because their stored identity or
    /// payload was corrupt (§3.14 corruption semantics: a row that cannot be
    /// attributed is DROPPED, never re-attached to a fabricated identity).
    public var skippedCorruptRowCount: Int {
        skippedRows.current
    }

    public init(transactor: any StoreTransacting) {
        self.transactor = transactor
    }

    public convenience init(database: AgentDatabase) {
        self.init(transactor: PoolTransactor(pool: database.pool))
    }

    /// Appends one timeline event under the given state revision.
    public func append(_ event: TimelineEvent, revision: UInt64, now _: Date = Date()) async throws {
        let encoded = EventPayloadCodec.encode(event.event)
        let agentID = event.agentID.rawValue.uuidString
        let createdAt = PersistenceTime.real(event.at)
        try await transactor.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [
                    agentID,
                    Int64(bitPattern: revision),
                    encoded.kind,
                    EventPayloadCodec.runtimeSource,
                    encoded.payload,
                    createdAt,
                ]
            )
        }
    }

    /// Newest-first timeline for an agent, bounded by `limit`. Rows whose
    /// stored agent_id no longer parses are skipped and counted in
    /// `skippedCorruptRowCount` — never re-attached to a fabricated UUID.
    public func events(agentID: AgentID, limit: Int = 200) async throws -> [StoredTimelineEvent] {
        let idString = agentID.rawValue.uuidString
        return try await transactor.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, agent_id, revision, kind, source, payload_json, created_at, seen_at
                FROM agent_events WHERE agent_id = ? ORDER BY id DESC LIMIT ?
                """,
                arguments: [idString, limit]
            )
            var events: [StoredTimelineEvent] = []
            var skipped = 0
            for row in rows {
                let kind: String = row["kind"]
                let payload: Data = row["payload_json"]
                let agentString: String = row["agent_id"]
                let revision64: Int64 = row["revision"]
                let createdAt: Double = row["created_at"]
                let seenAt: Double? = row["seen_at"]
                let rowID: Int64? = row["id"]

                // Corruption semantics (§3.14): drop the row, count it — a
                // fabricated UUID() would silently attribute foreign data to
                // a random agent.
                guard let agentUUID = UUID(uuidString: agentString) else {
                    skipped += 1
                    continue
                }
                // Corruption semantics (§3.14): a payload that no longer
                // decodes drops the row like an unattributable id — one
                // corrupt row must not kill the whole timeline read.
                let restored: AgentEvent
                do {
                    restored = try EventPayloadCodec.decode(kind: kind, payload: payload)
                } catch {
                    skipped += 1
                    continue
                }
                events.append(
                    StoredTimelineEvent(
                        rowID: rowID,
                        event: TimelineEvent(
                            agentID: AgentID(rawValue: agentUUID),
                            at: PersistenceTime.monotonic(createdAt),
                            event: restored
                        ),
                        revision: UInt64(bitPattern: revision64),
                        seenAt: seenAt.map(Date.init(timeIntervalSince1970:))
                    )
                )
            }
            if skipped > 0 {
                self.skippedRows.add(skipped)
            }
            return events
        }
    }

    /// Marks events as seen (inspector timeline read state).
    public func markSeen(_ rowIDs: [Int64], at date: Date = Date()) async throws {
        guard !rowIDs.isEmpty else { return }
        // Fixed-size chunks keep the placeholder count constant so GRDB's
        // statement cache is not busted by a unique SQL string per call.
        let chunkSize = 500
        var start = 0
        while start < rowIDs.count {
            let end = min(start + chunkSize, rowIDs.count)
            let placeholders = repeatElement("?", count: end - start).joined(separator: ",")
            // Hoist the slice: the write closure is @Sendable and must not
            // capture the mutated loop cursor (Swift 6 error).
            let ids = Array(rowIDs[start ..< end])
            try await transactor.write { database in
                try database.execute(
                    sql: "UPDATE agent_events SET seen_at = ? WHERE id IN (\(placeholders))",
                    arguments: StatementArguments([date.timeIntervalSince1970] + ids)
                )
            }
            start = end
        }
    }

    public func trimRetention(agentID: AgentID, cap: Int = EventRepository.retentionCap) async throws -> Int {
        try await trim(idString: agentID.rawValue.uuidString, cap: cap)
    }

    private func trim(idString: String, cap: Int) async throws -> Int {
        try await transactor.write { db in
            try db.execute(
                sql: """
                DELETE FROM agent_events WHERE agent_id = ? AND id NOT IN (
                    SELECT id FROM agent_events WHERE agent_id = ? ORDER BY id DESC LIMIT ?
                )
                """,
                arguments: [idString, idString, cap]
            )
            return db.changesCount
        }
    }

    /// Background maintenance entry point: enforces the cap for every agent
    /// that currently exceeds it (§3.14).
    @discardableResult
    public func maintainRetention(cap: Int = EventRepository.retentionCap) async throws -> Int {
        let offenders = try await transactor.write { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT agent_id FROM agent_events GROUP BY agent_id HAVING COUNT(*) > ?
                """,
                arguments: [cap]
            )
        }
        var deleted = 0
        for offender in offenders {
            // Trim against the RAW stored string: unparseable agent_id rows
            // are garbage and must not dodge the retention cap forever.
            deleted += try await trim(idString: offender, cap: cap)
        }
        return deleted
    }
}

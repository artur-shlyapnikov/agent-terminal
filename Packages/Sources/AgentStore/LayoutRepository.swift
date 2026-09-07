import AgentCore
import Foundation
import GRDB

// Debounced layout persistence (architecture §3.14/§4.4). Rapid layout
// mutations coalesce into a single write 300 ms after the last change.
//
// §5.2 rule: when a stored layout contains unknown nodes they decode to
// placeholders and the original JSON bytes are copied to the backup
// directory before the tree is handed to the domain.

public struct RestoredLayout: Equatable, Sendable {
    public var workspaceID: WorkspaceID
    public var tree: LayoutTree
    public var selectedAgentID: AgentID?
    /// Nodes replaced by placeholders during decode (§5.2).
    public var unknownNodeCount: Int
    /// True when the original JSON was preserved in the backup directory.
    public var backedUpOriginal: Bool
}

/// §5.2 load refusal: the stored layout contained unknown nodes but the
/// original bytes could not be preserved in the backup directory.
public enum LayoutRestoreError: Error, Equatable {
    case backupFailed(workspaceKey: String)
}

public actor LayoutRepository {
    struct PendingLayout {
        var tree: LayoutTree
        var selectedAgentID: AgentID?
        /// Per-key monotonic stamp from `store`; used by `flush` to detect
        /// stale restores.
        var seq: UInt64
    }

    private let transactor: any StoreTransacting
    private let debounce: Duration
    private let backupDirectoryURL: URL?
    private var pending: [String: PendingLayout] = [:]
    /// Monotonic per-key stamp incremented on every `store`; lets `flush`
    /// detect whether a failed batch entry was superseded by a newer store
    /// that a concurrent flush already consumed (stale-overwrite guard).
    private var sequence: [String: UInt64] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    public init(
        transactor: any StoreTransacting,
        debounce: Duration = .milliseconds(300),
        backupDirectoryURL: URL? = nil
    ) {
        self.transactor = transactor
        self.debounce = debounce
        self.backupDirectoryURL = backupDirectoryURL
    }

    public func store(
        workspaceID: WorkspaceID,
        tree: LayoutTree,
        selectedAgentID: AgentID?
    ) {
        let key = workspaceID.rawValue.uuidString
        sequence[key, default: 0] += 1
        pending[key] = PendingLayout(
            tree: tree,
            selectedAgentID: selectedAgentID,
            seq: sequence[key]!
        )
        // Reset the debounce window on every change: the write lands 300 ms
        // after the LAST mutation (§3.14).
        timers[key]?.cancel()
        let interval = debounce
        timers[key] = Task { [weak self] in
            try? await Task.sleep(for: interval)
            await self?.fireTimer(key: key)
        }
    }

    private func fireTimer(key: String) async {
        guard !Task.isCancelled else { return }
        timers[key] = nil
        try? await flush()
    }

    /// Writes every pending layout immediately. Entries are removed only
    /// after a successful write: on failure they are restored (unless a
    /// newer `store` already replaced them) so the next flush retries them.
    func flush() async throws {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        do {
            try await write(batch)
        } catch {
            for (key, entry) in batch
                where pending[key] == nil && sequence[key] == entry.seq
            {
                pending[key] = entry
            }
            // Re-arm the debounce so the restored entries retry without
            // waiting for unrelated activity (transient failures such as
            // a busy DB must not stall the write until the next mutation).
            for key in batch.keys where pending[key] != nil {
                timers[key]?.cancel()
                let interval = debounce
                timers[key] = Task { [weak self] in
                    try? await Task.sleep(for: interval)
                    await self?.fireTimer(key: key)
                }
            }
            throw error
        }
    }

    /// Immediate synchronous persist of everything pending; used on quit.
    public func flushNow() async throws {
        for timer in timers.values {
            timer.cancel()
        }
        timers.removeAll()
        try await flush()
    }

    private func write(_ batch: [String: PendingLayout]) async throws {
        try await transactor.write { db in
            for (key, entry) in batch {
                // Composite-free but non-"id" PK: use an explicit upsert.
                try db.execute(
                    sql: """
                    INSERT INTO layouts (workspace_id, schema_version, tree_json, selected_agent_id, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(workspace_id) DO UPDATE SET
                        schema_version = excluded.schema_version,
                        tree_json = excluded.tree_json,
                        selected_agent_id = excluded.selected_agent_id,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        key,
                        LayoutCodec.schemaVersion,
                        LayoutCodec.encode(entry.tree),
                        entry.selectedAgentID?.rawValue.uuidString,
                        Date().timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    // MARK: - Read path

    /// Loads a persisted layout, applying the unknown-node placeholder +
    /// backup rule (§5.2).
    public func load(workspaceID: WorkspaceID) async throws -> RestoredLayout? {
        let key = workspaceID.rawValue.uuidString
        return try await transactor.write { db in
            guard let row = try LayoutRow.filter(Column("workspace_id") == key).fetchOne(db) else {
                return nil
            }

            var backedUp = false
            let decoded = try LayoutCodec.decode(row.treeJSON)
            if decoded.unknownNodeCount > 0 {
                // §5.2: placeholder substitution is only allowed once the
                // original bytes are preserved. A failed backup refuses the
                // load instead of silently handing back a lossy tree.
                guard Self.backupOriginal(decoded.originalJSON, workspaceKey: key, to: self.backupDirectoryURL) else {
                    throw LayoutRestoreError.backupFailed(workspaceKey: key)
                }
                backedUp = true
            }

            return RestoredLayout(
                workspaceID: workspaceID,
                tree: decoded.tree,
                selectedAgentID: row.selectedAgentID.flatMap(UUID.init(uuidString:)).map(AgentID.init(rawValue:)),
                unknownNodeCount: decoded.unknownNodeCount,
                backedUpOriginal: backedUp
            )
        }
    }

    static func backupOriginal(_ original: Data, workspaceKey: String, to directory: URL?) -> Bool {
        guard let directory else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let target = directory.appendingPathComponent("layout-\(workspaceKey)-\(stamp).json")
            try original.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

import AgentCore
import Foundation
import GRDB

// Workspace CRUD (architecture §4.4). Layout persistence travels with the
// workspace row; agent order is derived from agent creation order because
// §3.14's workspaces table has no order column.

public struct StoredWorkspace: Equatable, Sendable {
    public var workspace: Workspace
    public var sortIndex: Int
}

public final class WorkspaceRepository: Sendable {
    private let transactor: any StoreTransacting
    /// §5.2 corrupt-store rule: directory receiving `.corrupt-<timestamp>`
    /// sidecars for undecodable layout JSON — next to the store itself when
    /// built from an `AgentDatabase`; nil for a bare transactor.
    private let corruptLayoutDirectoryURL: URL?

    public convenience init(transactor: any StoreTransacting) {
        self.init(transactor: transactor, corruptLayoutDirectoryURL: nil)
    }

    private init(transactor: any StoreTransacting, corruptLayoutDirectoryURL: URL?) {
        self.transactor = transactor
        self.corruptLayoutDirectoryURL = corruptLayoutDirectoryURL
    }

    public convenience init(database: AgentDatabase) {
        self.init(
            transactor: PoolTransactor(pool: database.pool),
            corruptLayoutDirectoryURL: database.databaseURL.deletingLastPathComponent()
        )
    }

    /// Upserts the workspace and its layout in one transaction.
    public func save(_ workspace: Workspace, sortIndex: Int) async throws {
        try await transactor.write { db in
            let now = Date().timeIntervalSince1970
            var row = workspace.row(sortIndex: sortIndex)
            try row.upsert(db)

            var layoutRow = try LayoutRow(
                workspaceID: workspace.id.rawValue.uuidString,
                schemaVersion: LayoutCodec.schemaVersion,
                treeJSON: LayoutCodec.encode(workspace.layout),
                selectedAgentID: workspace.selectedAgentID?.rawValue.uuidString,
                updatedAt: now
            )
            try layoutRow.upsert(db)
        }
    }

    public func find(_ id: WorkspaceID) async throws -> StoredWorkspace? {
        let idString = id.rawValue.uuidString
        return try await transactor.write { db in
            guard let row = try WorkspaceRow
                .filter(Column("id") == idString)
                .fetchOne(db)
            else { return nil }
            return try Self.stored(
                from: row,
                in: db,
                corruptLayoutDirectoryURL: self.corruptLayoutDirectoryURL
            )
        }
    }

    /// All workspaces ordered by sidebar position.
    public func fetchAll() async throws -> [StoredWorkspace] {
        try await transactor.write { db in
            let rows = try WorkspaceRow.order(Column("sort_index").asc).fetchAll(db)
            return try rows.compactMap {
                try Self.stored(from: $0, in: db, corruptLayoutDirectoryURL: self.corruptLayoutDirectoryURL)
            }
        }
    }

    public func delete(_ id: WorkspaceID) async throws {
        let idString = id.rawValue.uuidString
        try await transactor.write { db in
            _ = try LayoutRow.deleteOne(db, key: idString)
            _ = try WorkspaceRow.deleteOne(db, key: idString)
        }
    }

    // MARK: - Reconstruction

    static func stored(
        from row: WorkspaceRow,
        in db: GRDB.Database,
        corruptLayoutDirectoryURL: URL?
    ) throws -> StoredWorkspace? {
        let idString = row.id

        let layoutRow = try LayoutRow.filter(Column("workspace_id") == idString).fetchOne(db)
        let layout = Self.restoredLayout(
            from: layoutRow,
            workspaceKey: idString,
            corruptLayoutDirectoryURL: corruptLayoutDirectoryURL
        )
        let selectedAgentID = layoutRow?
            .selectedAgentID
            .flatMap(UUID.init(uuidString:))
            .map(AgentID.init(rawValue:))

        let orderStrings = try String.fetchAll(
            db,
            sql: "SELECT id FROM agents WHERE workspace_id = ? AND archived_at IS NULL ORDER BY created_at ASC",
            arguments: [idString]
        )
        let agentOrder = orderStrings.compactMap { UUID(uuidString: $0) }.map(AgentID.init(rawValue:))

        guard let workspace = Workspace.restoring(
            row,
            agentOrder: agentOrder,
            layout: layout,
            selectedAgentID: selectedAgentID
        ) else { return nil }
        return StoredWorkspace(
            workspace: workspace,
            sortIndex: row.sortIndex
        )
    }

    /// §5.2 corrupt-store rule for the workspace read path: a layout row
    /// whose JSON no longer decodes is preserved byte-for-byte in a
    /// `.corrupt-<timestamp>` sidecar next to the store and reported through
    /// the corruption sink BEFORE restore falls back to `.empty` — startup
    /// proceeds and the corrupt bytes are never silently dropped. An absent
    /// row decodes to `.empty` silently (nothing to preserve); unknown nodes
    /// are placeholders per `LayoutCodec` and never reach this path.
    private static func restoredLayout(
        from row: LayoutRow?,
        workspaceKey: String,
        corruptLayoutDirectoryURL: URL?
    ) -> LayoutTree {
        guard let row else { return .empty }
        do {
            return try LayoutCodec.decode(row.treeJSON).tree
        } catch {
            if let path = Self.preserveCorruptLayout(
                row.treeJSON,
                workspaceKey: workspaceKey,
                to: corruptLayoutDirectoryURL
            ) {
                WorkspaceCorruptionNotice.shared.record(
                    "corrupt workspace layout JSON quarantined at \(path); " +
                        "workspace \(workspaceKey) restored empty"
                )
            } else {
                WorkspaceCorruptionNotice.shared.record(
                    "corrupt workspace layout JSON for workspace \(workspaceKey) " +
                        "could not be preserved; restored empty"
                )
            }
            return .empty
        }
    }

    /// Writes the raw bytes next to the store (mirrors LayoutRepository's
    /// §5.2 backup idiom) and returns the sidecar path, or nil on failure.
    private static func preserveCorruptLayout(
        _ original: Data,
        workspaceKey: String,
        to directory: URL?
    ) -> String? {
        guard let directory else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let target = directory.appendingPathComponent("layout-\(workspaceKey).corrupt-\(stamp).json")
            try original.write(to: target, options: .atomic)
            return target.path
        } catch {
            return nil
        }
    }
}

/// §5.2 corruption surfacing seam: the diagnostics ring lives in the App
/// target, so the package emits through this locked process-wide sink,
/// installed once at bootstrap before any restore can run. Uninstalled, the
/// sink is a no-op — the sidecar preservation happens regardless.
public final class WorkspaceCorruptionNotice: @unchecked Sendable {
    public static let shared = WorkspaceCorruptionNotice()

    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?

    /// Installs the App-side sink (composition root → DiagnosticsLogRing).
    public func install(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func record(_ line: String) {
        lock.withLock { handler }?(line)
    }
}

import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Record mappings and codecs: domain roundtrips, layout schemaVersion and
// unknown-node rule (§5.2), secret-free persistence surface (§3.14).

final class RecordRoundtripTests: XCTestCase {
    func testWorkspaceRoundtripPreservesDomainFields() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        var workspace = makeWorkspace()
        workspace.selectedAgentID = AgentID()
        let persistedWorkspace = workspace
        try await db.pool.write { database in
            var row = persistedWorkspace.row(sortIndex: 3)
            try row.upsert(database)
        }

        let stored = try await WorkspaceRepository(database: db).find(workspace.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.sortIndex, 3)
        XCTAssertEqual(stored?.workspace.name, workspace.name)
        XCTAssertEqual(stored?.workspace.rootPath, workspace.rootPath)
        XCTAssertEqual(stored?.workspace.createdAt, workspace.createdAt)
        XCTAssertEqual(stored?.workspace.updatedAt, workspace.updatedAt)
    }

    func testAgentRoundtripPersistsProjectionOnly() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await db.pool.write { database in
            var row = workspace.row(sortIndex: 0)
            try row.upsert(database)
        }
        let session = makeSession(workspace: workspace, revision: 42)

        let repo = AgentRepository(database: db)
        try await repo.save(session)
        let restored = try await repo.find(session.id)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.id, session.id)
        XCTAssertEqual(restored?.kind, session.kind)
        XCTAssertEqual(restored?.displayName, session.displayName)
        XCTAssertEqual(restored?.taskSummary, session.taskSummary)
        XCTAssertEqual(restored?.cwd, session.cwd)
        XCTAssertEqual(restored?.launchDescriptor, session.launchDescriptor)
        XCTAssertEqual(restored?.resumePolicy, .automatic)
        XCTAssertEqual(restored?.state.revision, 42)
        // §3.11: queued prompts / turns are never persisted.
        XCTAssertNil(restored?.queuedPrompt)
        XCTAssertNil(restored?.turn)
        // Coarse lifecycle survives; parameterized phases restore to .unknown.
        XCTAssertEqual(restored?.state.lifecycle, .idle)

        // Parameterized lifecycle phase loses its payload by design.
        var waiting = session
        waiting.state.lifecycle = .waitingForInput(.screenSourced(kind: .freeText, summary: "needs input"))
        try await repo.save(waiting)
        let restoredWaiting = try await repo.find(session.id)
        XCTAssertEqual(restoredWaiting?.state.lifecycle, .unknown)
    }

    func testTerminalRoundtrip() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await db.pool.write { database in
            var row = workspace.row(sortIndex: 0)
            try row.upsert(database)
        }
        let terminal = TerminalSession(
            workspaceID: workspace.id,
            cwd: "/tmp/project",
            processPhase: .exited(exitCode: 3, signal: nil, userInitiated: true)
        )

        let repo = TerminalRepository(database: db)
        try await repo.save(terminal)
        let restored = try await repo.find(terminal.id)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.id, terminal.id)
        XCTAssertEqual(restored?.workspaceID, workspace.id)
        XCTAssertEqual(restored?.cwd, "/tmp/project")
        guard case let .exited(code, _, _) = restored?.processPhase else {
            return XCTFail("expected exited phase")
        }
        XCTAssertEqual(code, 3)
    }

    func testLayoutRoundtripCarriesSchemaVersionAndSelection() throws {
        let tree = makeSplitTree()
        let treeData = try LayoutCodec.encode(tree)
        // Own schemaVersion travels inside the JSON (§5.2).
        let document = try JSONSerialization.jsonObject(with: treeData) as? [String: Any]
        XCTAssertEqual(document?["schemaVersion"] as? Int, LayoutCodec.schemaVersion)

        let decoded = try LayoutCodec.decode(treeData)
        XCTAssertEqual(decoded.unknownNodeCount, 0)
        XCTAssertEqual(decoded.tree, tree)
    }

    func testUnknownLayoutNodeBecomesPlaceholderAndIsBackedUp() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await db.pool.write { database in
            var row = workspace.row(sortIndex: 0)
            try row.upsert(database)
        }

        // Hand-crafted layout from a hypothetical future version containing
        // an unknown node type AND an unknown content type.
        let paneID = UUID().uuidString
        let futureJSON = """
        {"schemaVersion":999,"root":{"type":"quad","pane":"\(paneID)","content":{"type":"agent","id":"\(UUID()
            .uuidString)"}}}
        """.data(using: .utf8)!
        let backupDir = dir.appendingPathComponent("layout-backups")
        try await db.pool.write { database in
            var row = LayoutRow(
                workspaceID: workspace.id.rawValue.uuidString,
                schemaVersion: 999,
                treeJSON: futureJSON,
                selectedAgentID: nil,
                updatedAt: 1
            )
            try row.upsert(database)
        }

        let repo = LayoutRepository(
            transactor: PoolTransactor(pool: db.pool),
            debounce: .milliseconds(20),
            backupDirectoryURL: backupDir
        )
        let restored = try await repo.load(workspaceID: workspace.id)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.tree.leafCount, 1)
        XCTAssertEqual(restored?.tree.leaves.first?.content, .placeholder)
        XCTAssertTrue((restored?.unknownNodeCount ?? 0) >= 1, "unknown node must be counted")

        // Original bytes preserved in the backup directory (§5.2).
        XCTAssertTrue(restored?.backedUpOriginal ?? false)
        let backups = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), futureJSON)
    }

    /// The commit write-path has no channel for prompts or output: the only
    /// agent columns a StateCommit may touch are the state projection ones.
    func testCommitPathTouchesOnlyStateColumns() async throws {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)
        let writer = DatabaseWriter(transactor: PoolTransactor(pool: db.pool))

        func snapshotRow() async throws -> [String: DatabaseValue] {
            try await db.pool.read { database in
                let row = try Row.fetchOne(
                    database,
                    sql: "SELECT * FROM agents WHERE id = ?",
                    arguments: [session.id.rawValue.uuidString]
                )
                var values: [String: DatabaseValue] = [:]
                if let row {
                    for column in row.columnNames {
                        values[column] = row[column]
                    }
                }
                return values
            }
        }

        let before = try await snapshotRow()
        let event = TimelineEvent(agentID: session.id, at: .ns(9000), event: .turnCompleted(hadPrompt: false))
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 7, observedAt: .ns(10000)),
            events: [event],
            sessionReference: SessionReference(agentKind: .claudeCode, opaquePayload: "ref-123", capturedAtRevision: 7)
        ))
        let after = try await snapshotRow()

        // The commit path can only touch the state projection columns —
        // there is no channel for prompts, output or environment.
        let allowedChanges: Set = [
            "last_lifecycle", "last_attention", "last_state_revision",
            "last_activity_at", "session_ref_json", "updated_at",
        ]
        var changed: Set<String> = []
        for (column, value) in after where before[column] != value {
            changed.insert(column)
        }
        XCTAssertTrue(
            changed.isSubset(of: allowedChanges),
            "unexpected columns changed: \(changed.subtracting(allowedChanges))"
        )
        XCTAssertEqual(Int64.fromDatabaseValue(after["last_state_revision"] ?? .null), 7)

        // Session reference round-trips through its dedicated column only.
        let refJSON: Data? = try await db.pool.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT session_ref_json FROM agents WHERE id = ?",
                arguments: [session.id.rawValue.uuidString]
            )
        }
        let reference = refJSON.flatMap { try? JSONDecoder().decode(SessionReference.self, from: $0) }
        XCTAssertEqual(reference?.opaquePayload, "ref-123")
    }

    private func makeSplitTree() -> LayoutTree {
        let leftAgent = AgentID()
        let rightTerminal = TerminalID()
        return LayoutTree(root: .split(
            .horizontal,
            0.4,
            .leaf(PaneID(), .agent(leftAgent)),
            .leaf(PaneID(), .terminal(rightTerminal))
        ))
    }

    // MARK: §5.2 corrupt-layout quarantine on the workspace read path

    /// Locked spy over the process-wide corruption sink; every test resets
    /// the shared handler in defer so no other suite observes it.
    private final class NoticeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func install() {
            WorkspaceCorruptionNotice.shared.install { [weak self] line in
                self?.lock.withLock { self?.lines.append(line) }
            }
        }

        func recorded() -> [String] {
            lock.withLock { lines }
        }
    }

    private static func corruptFiles(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return contents.filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    /// R10-B1: a layout row whose JSON no longer decodes is preserved
    /// byte-for-byte in a `.corrupt-<ms>` sidecar next to the store,
    /// reported through the corruption sink, and the workspace still
    /// restores — with an `.empty` tree instead of throwing.
    func testCorruptLayoutJSONIsPreservedInSidecarNoticedAndWorkspaceRestoresEmpty() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        try await db.pool.write { database in
            var row = LayoutRow(
                workspaceID: workspace.id.rawValue.uuidString,
                schemaVersion: LayoutCodec.schemaVersion,
                treeJSON: Data("NOT LAYOUT JSON".utf8),
                selectedAgentID: nil,
                updatedAt: 1
            )
            try row.upsert(database)
        }

        let spy = NoticeSpy()
        spy.install()
        defer { WorkspaceCorruptionNotice.shared.install { _ in } }

        let repo = WorkspaceRepository(database: db)
        let restored = try await repo.find(workspace.id)

        XCTAssertNotNil(restored, "corrupt layout must not lose the workspace")
        XCTAssertEqual(restored?.workspace.layout, .empty)
        let notices = spy.recorded()
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("quarantined at"), "notice: \(notices)")
        XCTAssertTrue(
            notices[0].contains(workspace.id.rawValue.uuidString),
            "notice must carry the workspace key: \(notices)"
        )

        // Byte-for-byte sidecar next to the store — and nothing else.
        let sidecars = try Self.corruptFiles(in: dir).filter {
            $0.lastPathComponent.hasPrefix("layout-\(workspace.id.rawValue.uuidString).corrupt-")
        }
        XCTAssertEqual(sidecars.count, 1)
        XCTAssertEqual(try Data(contentsOf: sidecars[0]), Data("NOT LAYOUT JSON".utf8))
        XCTAssertEqual(try Self.corruptFiles(in: dir).count, sidecars.count, "no stray sidecars")
    }

    /// R10-B2: an absent layout row is NOT corruption — restore falls back
    /// to `.empty` silently, without sidecar noise or a notice.
    func testAbsentLayoutRowDecodesSilentlyToEmptyWithoutSidecarsOrNotice() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)

        let spy = NoticeSpy()
        spy.install()
        defer { WorkspaceCorruptionNotice.shared.install { _ in } }

        let repo = WorkspaceRepository(database: db)
        let restored = try await repo.find(workspace.id)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.workspace.layout, .empty)
        XCTAssertTrue(spy.recorded().isEmpty, "absence must stay silent")
        XCTAssertEqual(try Self.corruptFiles(in: dir).count, 0)
    }

    /// R10-B3: without a store directory (bare-transactor convenience init)
    /// preservation is impossible, but the notice must STILL surface the
    /// rot ("could not be preserved") and the read must not throw.
    func testBareTransactorRepoReportsUnpreservableCorruptLayoutWithoutSidecar() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        try await db.pool.write { database in
            var row = LayoutRow(
                workspaceID: workspace.id.rawValue.uuidString,
                schemaVersion: LayoutCodec.schemaVersion,
                treeJSON: Data("{not json".utf8),
                selectedAgentID: nil,
                updatedAt: 1
            )
            try row.upsert(database)
        }

        let spy = NoticeSpy()
        spy.install()
        defer { WorkspaceCorruptionNotice.shared.install { _ in } }

        let repo = WorkspaceRepository(transactor: PoolTransactor(pool: db.pool))
        let restored = try await repo.find(workspace.id)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.workspace.layout, .empty)
        let notices = spy.recorded()
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("could not be preserved"), "notice: \(notices)")

        // No sidecar anywhere under the temp store directory.
        XCTAssertEqual(try Self.corruptFiles(in: dir).count, 0)
        let backups = dir.appendingPathComponent("backups")
        if FileManager.default.fileExists(atPath: backups.path) {
            XCTAssertEqual(try Self.corruptFiles(in: backups).count, 0)
        }
    }

    // MARK: Round 17 — exit-at store persistence (8613329 store half)

    /// A1: `row(now:exitAt:)` computes `exitAt ?? now` — once the true exit
    /// instant is captured, every later row built from the SAME session
    /// carries it regardless of how far `now` drifts. A late periodic save
    /// must not re-stamp the operator-visible exit time (§3.14).
    func testRowKeepsCapturedExitAtStableAcrossReRowsAtLaterNow() {
        let session = TerminalSession(
            workspaceID: WorkspaceID(),
            cwd: "/tmp",
            processPhase: .exited(exitCode: 7, signal: nil, userInitiated: false),
            exitAt: 1234.5
        )

        let first = session.row(now: 999.0, exitAt: session.exitAt)
        XCTAssertEqual(first.lastExitAt, 1234.5)
        XCTAssertEqual(first.lastExitCode, 7)
        XCTAssertEqual(first.lastRuntimeStatus, "exited")

        // `now` moving 8× must not move the captured stamp.
        let second = session.row(now: 8888.0, exitAt: session.exitAt)
        XCTAssertEqual(second.lastExitAt, 1234.5)
        XCTAssertEqual(second.lastExitCode, 7)
        XCTAssertEqual(second.lastRuntimeStatus, "exited")
    }

    /// A2: `TerminalRepository.save` threads `terminal.exitAt` (not `now`)
    /// through `row(now:exitAt:)` and upserts `last_exit_at` — saving the
    /// SAME already-exited session twice at two different wall clocks leaves
    /// the stored column byte-stable.
    func testRepositoryResaveDoesNotRestampLastExitAt() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        // terminals.workspace_id REFERENCES workspaces — install the parent.
        let workspace = makeWorkspace(name: "WS-EXITAT")
        try await installWorkspace(db, workspace)

        let repo = TerminalRepository(database: db)
        let session = TerminalSession(
            workspaceID: workspace.id,
            cwd: "/tmp",
            processPhase: .exited(exitCode: 7, signal: nil, userInitiated: false),
            exitAt: 1234.5
        )

        try await repo.save(session, now: Date(timeIntervalSince1970: 999))
        let storedExitAt = try await TestEnv.scalar(
            db,
            "SELECT last_exit_at FROM terminals WHERE id = ?",
            [session.id.rawValue.uuidString]
        ) as? String
        XCTAssertEqual(storedExitAt, "1234.5")
        let storedExitCode = try await TestEnv.scalar(
            db,
            "SELECT last_exit_code FROM terminals WHERE id = ?",
            [session.id.rawValue.uuidString]
        ) as? String
        XCTAssertEqual(storedExitCode, "7")

        // The second save's upsert writes the SAME value — proves save maps
        // terminal.exitAt into the row; dropping `exitAt:` from the call site
        // would silently re-stamp to 5555 here.
        try await repo.save(session, now: Date(timeIntervalSince1970: 5555))
        let resavedExitAt = try await TestEnv.scalar(
            db,
            "SELECT last_exit_at FROM terminals WHERE id = ?",
            [session.id.rawValue.uuidString]
        ) as? String
        XCTAssertEqual(resavedExitAt, "1234.5")

        // Roundtrip control: find restores the exited phase AND its persisted
        // exit stamp (stability across re-saves — pinned separately by A3
        // leg 3).
        let restored = try await repo.find(session.id)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.processPhase, .exited(exitCode: 7, signal: nil, userInitiated: false))
    }

    /// A3: the `?? now` fallback fires only for an EXITED session whose stamp
    /// was never captured; the phase gate means NON-exited phases produce nil
    /// exit columns even if `exitAt` is somehow set on the struct.
    func testNilExitAtFallsBackToNowAndNonExitedPhasesNeverCarryExitColumns() {
        // Leg 1: exited with no captured stamp → falls back to `now`.
        let exitedNoStamp = TerminalSession(
            workspaceID: WorkspaceID(),
            cwd: "/tmp",
            processPhase: .exited(exitCode: 7, signal: nil, userInitiated: false),
            exitAt: nil
        )
        let fallbackRow = exitedNoStamp.row(now: 777.0)
        XCTAssertEqual(fallbackRow.lastExitAt, 777.0)
        XCTAssertEqual(fallbackRow.lastExitCode, 7)

        // Leg 2: the phase gate dominates the field — a RUNNING session with
        // a stale exitAt grows NO exit columns.
        let running = TerminalSession(
            workspaceID: WorkspaceID(),
            cwd: "/tmp",
            processPhase: .running(pid: 42, processGroupID: 43),
            exitAt: 1234.5
        )
        let runningRow = running.row(now: 999.0, exitAt: running.exitAt)
        XCTAssertNil(runningRow.lastExitAt)
        XCTAssertNil(runningRow.lastExitCode)

        // Leg 3 (current contract): restoring rebuilds the phase from the
        // status token AND carries the persisted exit stamp through
        // (`restoring(_:)` maps `exitAt: row.lastExitAt`) — the stamp is a
        // stable persisted value that must survive re-saves, so nulling it
        // on restore would re-fallback every subsequent save to a fresh
        // `now`. The §3.3 ephemera list is surface generation / presentation
        // / output revision only — NOT exitAt.
        let restored = TerminalSession.restoring(exitedNoStamp.row(now: 1234.0))
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.exitAt, 1234.0)
    }
}

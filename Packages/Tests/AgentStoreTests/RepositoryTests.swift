import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Repository behavior: retention cap, unclean-run detection, settings,
// integrations, debounced layouts.

final class RepositoryTests: XCTestCase {
    // MARK: Events

    func testRetentionKeepsOnlyNewest1000EventsPerAgent() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let agentID = AgentID()
        let repo = EventRepository(database: db)

        // Bulk-insert 1200 events in one transaction.
        try await db.pool.write { database in
            for index in 0 ..< 1200 {
                try database.execute(
                    sql: """
                    INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                    VALUES (?, ?, 'turn_completed', 'runtime', ?, ?, NULL)
                    """,
                    arguments: [agentID.rawValue.uuidString, index, Data("{}".utf8), Double(index)]
                )
            }
        }

        var count = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertEqual(count, 1200)

        try await repo.maintainRetention()

        count = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertEqual(count, EventRepository.retentionCap, "retention cap is 1000 events per agent")

        // The KEPT rows are the newest ones.
        let oldestKept: Int64? = try await db.pool.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT MIN(created_at) FROM agent_events WHERE agent_id = ?",
                arguments: [agentID.rawValue.uuidString]
            )
        }
        XCTAssertEqual(oldestKept, 200)

        // Per-agent trim also works standalone and is a no-op when under cap.
        _ = try await repo.trimRetention(agentID: agentID)
        count = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertEqual(count, EventRepository.retentionCap)
    }

    func testEventAppendAndTimelineReadback() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let agentID = AgentID()
        let repo = EventRepository(database: db)

        let original = TimelineEvent(
            agentID: agentID,
            at: .ns(777),
            event: .processExited(exitCode: 2, signal: nil, userInitiated: true)
        )
        try await repo.append(original, revision: 12)

        let timeline = try await repo.events(agentID: agentID)
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline[0].revision, 12)
        XCTAssertEqual(timeline[0].event.event, .processExited(exitCode: 2, signal: nil, userInitiated: true))
        XCTAssertEqual(timeline[0].event.at, .ns(777))
        XCTAssertNil(timeline[0].seenAt)

        try await repo.markSeen([XCTUnwrap(timeline[0].rowID)])
        let seen = try await repo.events(agentID: agentID)
        XCTAssertNotNil(seen[0].seenAt)
    }

    /// §3.14 corruption semantics: a row whose stored agent_id no longer
    /// parses must NEVER be re-attached to a fabricated UUID — it is dropped
    /// and counted in diagnostics instead.
    func testCorruptAgentIDRowIsSkippedAndCountedNotFabricated() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let agentID = AgentID()
        let repo = EventRepository(database: db)
        try await repo.append(
            TimelineEvent(agentID: agentID, at: .ns(1), event: .turnCompleted(hadPrompt: false)),
            revision: 1
        )

        // A corrupted row (hand-edited / partially migrated DB).
        try await db.pool.write { database in
            try database.execute(
                sql: """
                INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                VALUES ('not-a-uuid', 2, 'turn_completed', 'runtime', ?, ?, NULL)
                """,
                arguments: [Data("{}".utf8), Double(2)]
            )
        }

        let timeline = try await repo.events(agentID: agentID)
        XCTAssertEqual(timeline.count, 1, "only the well-formed row may be returned")
        XCTAssertFalse(timeline.contains { $0.event.agentID != agentID },
                       "no event may carry a fabricated identity")
    }

    func testEventPayloadRoundtripsEveryKind() throws {
        let references = [
            SessionReference(agentKind: .codex, opaquePayload: "sess_abc", capturedAtRevision: 5),
        ]
        let all: [AgentEvent] = [
            .stateChanged(from: .idle, to: .working, authority: .integration),
            .turnStarted(reason: .promptDelivered(CommandID())),
            .turnStarted(reason: .spontaneousWork),
            .turnCompleted(hadPrompt: true),
            .attentionRaised(kind: .inputRequired),
            .attentionCleared(kind: .completionUnread),
            .promptDelivered(commandID: CommandID()),
            .promptDeliveryUnconfirmed(commandID: CommandID()),
            .queuedPromptCancelled,
            .queuedPromptDeliveryFailed(commandID: CommandID()),
            .processExited(exitCode: nil, signal: 9, userInitiated: false),
            .sessionIdentityCaptured(references[0]),
            .integrationSequenceGap(expected: 4, received: 6),
            .authorityLost(previous: .screen),
            .stopCommanded(mode: .gracefulStop),
            .restartInitiated(generation: SurfaceGeneration(rawValue: 3)),
            .resumeAttempted(references[0]),
        ]
        for event in all {
            let encoded = EventPayloadCodec.encode(event)
            XCTAssertFalse(encoded.payload.isEmpty, "\(encoded.kind): payload must exist")
            let decoded = try EventPayloadCodec.decode(kind: encoded.kind, payload: encoded.payload)
            XCTAssertEqual(decoded, event, "roundtrip failed for \(encoded.kind)")
        }
    }

    /// R9-C1: a row with a VALID agent_id whose payload no longer decodes is
    /// skipped and counted in `skippedCorruptRowCount` — one poison row must
    /// not kill (or truncate) the whole timeline read.
    func testUndecodablePayloadRowIsDroppedCountedInSkippedCorruptRowCount() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let agentID = AgentID()
        let repo = EventRepository(database: db)
        // Positive control: two well-formed events.
        try await repo.append(
            TimelineEvent(agentID: agentID, at: .ns(1), event: .turnCompleted(hadPrompt: false)),
            revision: 1
        )
        try await repo.append(
            TimelineEvent(agentID: agentID, at: .ns(2), event: .turnStarted(reason: .spontaneousWork)),
            revision: 2
        )

        // Poison rows: valid identity, undecodable content. One row has an
        // UNKNOWN kind (decode default arm throws); the other a known kind
        // whose required field is missing (decodeCommand throws malformed).
        try await db.pool.write { database in
            try database.execute(
                sql: """
                INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                VALUES (?, 3, 'vanished_event', 'runtime', ?, ?, NULL)
                """,
                arguments: [agentID.rawValue.uuidString, Data("{}".utf8), Double(3)]
            )
            try database.execute(
                sql: """
                INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                VALUES (?, 4, 'prompt_delivered', 'runtime', ?, ?, NULL)
                """,
                arguments: [agentID.rawValue.uuidString, Data("{}".utf8), Double(4)]
            )
        }

        let timeline = try await repo.events(agentID: agentID)
        XCTAssertEqual(timeline.count, 2, "poison rows dropped, healthy rows intact")
        XCTAssertEqual(timeline.map(\.event.at), [.ns(2), .ns(1)], "newest-first row order preserved")
        XCTAssertEqual(repo.skippedCorruptRowCount, 2, "each poison row counted once")

        // The counter is cumulative across reads.
        _ = try await repo.events(agentID: agentID)
        XCTAssertEqual(repo.skippedCorruptRowCount, 4)
    }

    // MARK: App runs

    func testUnclosedPreviousRunSignalsUncleanTermination() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let firstRepo = AppRunRepository(database: db)
        let runID = try await firstRepo.beginRun(startedAt: Date(timeIntervalSince1970: 100))
        // Process dies without endRun — simulating crash/kill.

        // A NEW process opens the same database.
        let secondRepo = AppRunRepository(database: db)
        let unclosed = try await secondRepo.detectUnclosedRuns()
        XCTAssertEqual(unclosed.map(\.id), [runID])
        XCTAssertNil(unclosed.first?.endedAt)

        // Mark it unclean (stage-12 recovery flow will own the UI).
        try await secondRepo.endRun(runID, kind: .unclean)
        let afterMarking = try await secondRepo.detectUnclosedRuns()
        XCTAssertTrue(afterMarking.isEmpty)

        // A clean quit leaves no unclosed rows at all.
        let cleanRun = try await secondRepo.beginRun()
        try await secondRepo.endRun(cleanRun, kind: .clean)
        let final = try await secondRepo.detectUnclosedRuns()
        XCTAssertTrue(final.isEmpty)
        let runs = try await secondRepo.detectUnclosedRuns()
        _ = runs
    }

    // MARK: Settings

    func testSettingsRoundtripAndUpsert() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        struct Appearance: Codable, Equatable { var theme: String; var density: Int }
        let repo = SettingsRepository(database: db)

        try await repo.set(Appearance(theme: "dark", density: 2), forKey: "appearance")
        var value = try await repo.get(Appearance.self, forKey: "appearance")
        XCTAssertEqual(value, Appearance(theme: "dark", density: 2))

        try await repo.set(Appearance(theme: "light", density: 1), forKey: "appearance")
        value = try await repo.get(Appearance.self, forKey: "appearance")
        XCTAssertEqual(value, Appearance(theme: "light", density: 1))

        try await repo.remove("appearance")
        value = try await repo.get(Appearance.self, forKey: "appearance")
        XCTAssertNil(value)
    }

    // MARK: Integrations

    func testIntegrationInstallUpsertAndStatus() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let repo = IntegrationRepository(database: db)
        var install = IntegrationInstall(
            agentKind: .claudeCode,
            integrationVersion: "1.2.0",
            status: "installed",
            managedFilesJSON: Data(#"{"files":["settings.json"]}"#.utf8),
            managedFingerprint: "sha256:abc",
            installedAt: Date(timeIntervalSince1970: 500)
        )
        try await repo.upsert(install)

        // Upsert same (kind, version) replaces the row.
        install.managedFingerprint = "sha256:def"
        try await repo.upsert(install)

        var fetched = try await repo.installs(agentKind: .claudeCode)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.managedFingerprint, "sha256:def")

        try await repo.updateStatus("degraded", agentKind: .claudeCode, integrationVersion: "1.2.0")
        fetched = try await repo.installs()
        XCTAssertEqual(fetched.first?.status, "degraded")

        let other = try await repo.installs(agentKind: .codex)
        XCTAssertTrue(other.isEmpty)
    }

    // MARK: Layout debounce

    func testLayoutDebounceCoalescesRapidMutationsIntoSingleWrite() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await db.pool.write { database in
            var row = workspace.row(sortIndex: 0)
            try row.upsert(database)
        }

        let gate = GatedTransactor(base: PoolTransactor(pool: db.pool))
        let repo = LayoutRepository(transactor: gate, debounce: .milliseconds(50), backupDirectoryURL: nil)

        let treeA = LayoutTree(leaf: .agent(AgentID()))
        let treeB = LayoutTree(leaf: .terminal(TerminalID()))

        gate.hold()
        await repo.store(workspaceID: workspace.id, tree: treeA, selectedAgentID: nil)
        await repo.store(workspaceID: workspace.id, tree: treeB, selectedAgentID: nil)
        // First timer fires into the held gate; second reset must supersede.
        // Event-driven arm check: the first flush is provably parked in the
        // gate before release (replaces a fixed 150 ms settle sleep).
        try await TestEnv.waitFor(timeout: 3) { @Sendable in gate.waitingCount > 0 }

        gate.release()
        // Timer firing may lag under scheduler jitter — poll for the write.
        // Poll through the pool directly so gate.writeCount counts flushes only.
        let key = workspace.id.rawValue.uuidString
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            let data: Data? = try await db.pool.read { database in
                try Data.fetchOne(
                    database,
                    sql: "SELECT tree_json FROM layouts WHERE workspace_id = ?",
                    arguments: [key]
                )
            }
            guard let data else { return false }
            return (try? LayoutCodec.decode(data).tree) == treeB
        }
        XCTAssertEqual(gate.writeCount, 1, "rapid mutations must coalesce into one write")
    }

    func testLayoutFlushNowPersistsImmediately() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await db.pool.write { database in
            var row = workspace.row(sortIndex: 0)
            try row.upsert(database)
        }

        let repo = LayoutRepository(transactor: PoolTransactor(pool: db.pool), debounce: .seconds(10))
        let selected = AgentID()
        let tree = LayoutTree(leaf: .agent(selected))
        await repo.store(workspaceID: workspace.id, tree: tree, selectedAgentID: selected)
        try await repo.flushNow() // e.g. on quit — no waiting out the window

        let restored = try await repo.load(workspaceID: workspace.id)
        XCTAssertEqual(restored?.tree, tree)
        XCTAssertEqual(restored?.selectedAgentID, selected)
    }

    /// R10-C1: a failed `flush()` restores its batch into `pending` AND
    /// re-arms each key's debounce timer, so the entries land once the
    /// transient failure clears — without any further `store()` call.
    /// Deleting either loop stalls persistence until unrelated activity.
    func testFailedFlushReArmsDebounceAndRetriesWithoutNewMutation() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)

        // Exactly ONE write fails; afterwards the transactor passes through.
        let flaky = FlakyTransactor(base: PoolTransactor(pool: db.pool), failuresRemaining: 1)
        let repo = LayoutRepository(transactor: flaky, debounce: .milliseconds(30))

        let selected = AgentID()
        let tree = LayoutTree(leaf: .agent(selected))
        await repo.store(workspaceID: workspace.id, tree: tree, selectedAgentID: selected)

        // First debounce fires into the failing transactor; the re-armed
        // timer must retry the restored batch on its own. Read through the
        // pool so assertions bypass the now-pass-through flakiness wrapper.
        let key = workspace.id.rawValue.uuidString
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            let json: Data? = try await db.pool.read { database in
                try Data.fetchOne(
                    database,
                    sql: "SELECT tree_json FROM layouts WHERE workspace_id = ?",
                    arguments: [key]
                )
            }
            guard let json else { return false }
            return (try? LayoutCodec.decode(json).tree) == tree
        }
        let restored = try await repo.load(workspaceID: workspace.id)
        XCTAssertEqual(restored?.tree, tree)
        XCTAssertEqual(restored?.selectedAgentID, selected)
    }

    // MARK: Round 19 C1 — stale flush-restore sequence guard (cd7c66b)

    /// When a flush FAILS but a newer `store()` for the same key already
    /// superseded the failed batch entry (higher per-key sequence), the catch
    /// leg must NOT restore the stale entry into pending — its retry would
    /// roll the workspace back to a stale layout. The arrange is
    /// INTERLEAVED: store(A) → flush parks mid-write (batch snapshotted,
    /// pending cleared) → store(B) lands while the write is provably
    /// suspended → release makes the write throw. Without the
    /// `sequence[key] == entry.seq` conjunction the unconditional restore
    /// clobbers pending's treeB and the retry persists treeA.
    func testFailedFlushDoesNotRestoreEntriesSupersededByNewerStore() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)

        let parkFail = ParkAndFailTransactor(base: PoolTransactor(pool: db.pool))
        // Long debounce: no timer may fire naturally — the flush is driven
        // by hand so the interleaving stays deterministic.
        let repo = LayoutRepository(transactor: parkFail, debounce: .seconds(10))

        let treeA = LayoutTree(leaf: .agent(AgentID()))
        let treeB = LayoutTree(leaf: .terminal(TerminalID()))
        await repo.store(workspaceID: workspace.id, tree: treeA, selectedAgentID: nil)

        parkFail.armFailureOnce()
        parkFail.hold()
        let flushTask = Task { try? await repo.flush() }
        // Batch snapshot happened ⇔ the write is parked inside the failing
        // transaction (pending consumed, sequence stamp already fixed).
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            parkFail.parkedCount > 0
        }

        // The superseding store lands WHILE the failing write is suspended.
        await repo.store(workspaceID: workspace.id, tree: treeB, selectedAgentID: nil)
        parkFail.release()
        _ = await flushTask.value

        // Whatever the catch leg left in pending must persist treeB — a
        // stale restoration persists treeA here and fails the poll below.
        try await repo.flushNow()
        let key = workspace.id.rawValue.uuidString
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            let json: Data? = try await db.pool.read { database in
                try Data.fetchOne(
                    database,
                    sql: "SELECT tree_json FROM layouts WHERE workspace_id = ?",
                    arguments: [key]
                )
            }
            guard let json else { return false }
            return (try? LayoutCodec.decode(json).tree) == treeB
        }
        // Further flushes never resurrect the stale treeA.
        try await repo.flushNow()
        let finalJSON: Data? = try await db.pool.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT tree_json FROM layouts WHERE workspace_id = ?",
                arguments: [key]
            )
        }
        XCTAssertEqual(try finalJSON.map(LayoutCodec.decode)?.tree, treeB)
    }

    /// R20-EV1: background maintenance must trim EVERY agent exceeding the
    /// cap — including agents whose stored agent_id no longer parses,
    /// trimmed against the RAW stored string — and return the SUM of deleted
    /// rows. A garbage identity must never dodge the retention cap forever.
    func testMaintainRetentionTrimsEveryOffenderIncludingCorruptIDsByRawString() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let agentA = AgentID()
        let agentB = AgentID()
        let corruptID = "not-a-uuid"
        let repo = EventRepository(database: db)

        try await db.pool.write { database in
            for index in 0 ..< 1100 {
                try database.execute(
                    sql: """
                    INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                    VALUES (?, ?, 'turn_completed', 'runtime', ?, ?, NULL)
                    """,
                    arguments: [agentA.rawValue.uuidString, index, Data("{}".utf8), Double(index)]
                )
            }
            for index in 0 ..< 1050 {
                try database.execute(
                    sql: """
                    INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                    VALUES (?, ?, 'turn_completed', 'runtime', ?, ?, NULL)
                    """,
                    arguments: [agentB.rawValue.uuidString, index, Data("{}".utf8), Double(index)]
                )
            }
            for index in 0 ..< 1005 {
                try database.execute(
                    sql: """
                    INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                    VALUES (?, ?, 'turn_completed', 'runtime', ?, ?, NULL)
                    """,
                    arguments: [corruptID, index, Data("{}".utf8), Double(index)]
                )
            }
        }
        let deleted = try await repo.maintainRetention()
        XCTAssertEqual(deleted, 100 + 50 + 5,
                       "the sweep returns the SUM of deletions across EVERY offender, corrupt ids included")

        // Every identity group — including the corrupt raw string — sits at
        // exactly the cap, keeping its NEWEST rows.
        for (idString, expectedOldest) in [
            (agentA.rawValue.uuidString, Int64(100)),
            (agentB.rawValue.uuidString, Int64(50)),
            (corruptID, Int64(5)),
        ] {
            let count = try await TestEnv.rowCount(db, "agent_events WHERE agent_id = '\(idString)'")
            XCTAssertEqual(count, EventRepository.retentionCap, "group \(idString) trimmed to the cap")
            let oldestKept: Int64? = try await db.pool.read { database in
                try Int64.fetchOne(
                    database,
                    sql: "SELECT MIN(created_at) FROM agent_events WHERE agent_id = ?",
                    arguments: [idString]
                )
            }
            XCTAssertEqual(oldestKept, expectedOldest,
                           "group \(idString) keeps the NEWEST rows (oldest survivor created_at)")
        }

        // Idempotent once everything sits under the cap.
        let second = try await repo.maintainRetention()
        XCTAssertEqual(second, 0, "a second sweep over capped groups deletes nothing")
    }

    // MARK: R21-R1 — corrupt integration rows dropped by the decoder,

    // NULL status defaults to "installed"

    func testCorruptIntegrationRowIsDroppedByDecoderAndNullStatusDefaultsInstalled() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let repo = IntegrationRepository(database: db)
        try await repo.upsert(IntegrationInstall(
            agentKind: .claudeCode,
            integrationVersion: "1.0.0",
            status: "installed",
            managedFilesJSON: Data(#"{"files":["settings.json"]}"#.utf8),
            managedFingerprint: "sha256:control",
            installedAt: Date(timeIntervalSince1970: 100)
        ))

        // Poison row whose agent_kind no longer parses (hand-edited DB).
        try await db.pool.write { database in
            try database.execute(
                sql: """
                INSERT INTO integration_installs
                    (agent_kind, integration_version, status, managed_files_json, managed_fingerprint, installed_at)
                VALUES ('no-such-adapter', '1.0.0', 'installed', ?, ?, ?)
                """,
                arguments: [Data(#"{"files":[]}"#.utf8), "sha256:poison", Double(200)]
            )
        }

        var fetched = try await repo.installs()
        XCTAssertEqual(fetched.count, 1, "unknown-kind row silently dropped, control kept")
        XCTAssertTrue(fetched.allSatisfy { $0.agentKind == .claudeCode }, "no fabricated kind may survive")

        fetched = try await repo.installs(agentKind: .claudeCode)
        XCTAssertEqual(fetched.count, 1, "kind filtering still works after the drop")

        // NULL status reads back as the implicit "installed" default at the
        // decode boundary. The column is NOT NULL in today's schema, so the
        // arm is exercised over the pure decoder with a row-shaped GRDB Row
        // carrying a NULL status instead of violating the constraint.
        let nullStatusRow = Row([
            "agent_kind": "codex",
            "integration_version": "2.0.0",
            "status": nil,
            "managed_files_json": Data(#"{"files":[]}"#.utf8),
            "managed_fingerprint": "sha256:null-status",
            "installed_at": 300.0,
        ] as [String: (any DatabaseValueConvertible)?])
        let decoded = IntegrationRepository.install(from: nullStatusRow)
        XCTAssertEqual(decoded?.status, "installed", "NULL status must default to installed")
        XCTAssertEqual(decoded?.agentKind, .codex)
        XCTAssertEqual(decoded?.integrationVersion, "2.0.0")

        // Decoder purity: a second identical read is stable.
        let again = try await repo.installs()
        XCTAssertEqual(again.count, 1)
    }

    // MARK: R21-R2 — repository-side stale-save full no-op

    func testStaleSnapshotSaveIsFullNoOpAndNeverRegressesPersistedRevision() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let repo = AgentRepository(database: db)
        let id = AgentID()

        func session(displayName: String, revision: UInt64) -> AgentSession {
            AgentSession(
                id: id,
                workspaceID: workspace.id,
                kind: .claudeCode,
                displayName: displayName,
                cwd: "/tmp/project",
                launchDescriptor: LaunchDescriptor(
                    agentKind: .claudeCode,
                    program: "claude",
                    arguments: [],
                    workingDirectory: "/tmp/project"
                ),
                resumePolicy: .manual,
                state: AgentState(lifecycle: .working, revision: revision, observedAt: MonotonicInstant.zero),
                createdAt: MonotonicInstant.zero,
                lastActivityAt: MonotonicInstant.zero
            )
        }
        func rawRow() async throws -> (displayName: String, revision: Int64, updatedAt: Double) {
            try await db.pool.read { database in
                let row = try Row.fetchOne(
                    database,
                    sql: "SELECT display_name, last_state_revision, updated_at FROM agents WHERE id = ?",
                    arguments: [id.rawValue.uuidString]
                )
                return (
                    displayName: row?["display_name"] ?? "",
                    revision: row?["last_state_revision"] ?? -1,
                    updatedAt: row?["updated_at"] ?? -1
                )
            }
        }

        // Fresh snapshot at rev 10.
        try await repo.save(session(displayName: "Fresh", revision: 10))
        var row = try await rawRow()
        XCTAssertEqual(row.revision, 10)
        XCTAssertEqual(row.displayName, "Fresh")
        let updatedAtBefore = row.updatedAt

        // Stale snapshot (rev 4, different name): save must be a FULL no-op.
        try await Task.sleep(for: .milliseconds(20)) // let updated_at move if anything writes
        try await repo.save(session(displayName: "STALE", revision: 4))
        row = try await rawRow()
        XCTAssertEqual(row.revision, 10, "stale save must never regress last_state_revision")
        XCTAssertEqual(row.displayName, "Fresh", "the stale save wrote NOTHING, not even non-revision columns")
        XCTAssertEqual(row.updatedAt, updatedAtBefore, "statement must be skipped entirely, not re-run with old values")
        let found = try await repo.find(id)
        XCTAssertEqual(found?.state.revision, 10)

        // Complement boundary: an EQUAL-revision save MUST proceed (guard is
        // strictly >). Pinning this prevents "fixing" the gate to `<`.
        try await repo.save(session(displayName: "Corrected", revision: 10))
        row = try await rawRow()
        XCTAssertEqual(row.displayName, "Corrected")
        XCTAssertEqual(row.revision, 10)
    }

    // MARK: R21-R3 — full-column save preserves resume_requested/archived_at

    func testFullColumnSavePreservesResumeRequestedAndArchivedAtOwnership() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let repo = AgentRepository(database: db)
        let id = AgentID()
        let descriptor = LaunchDescriptor(
            agentKind: .claudeCode,
            program: "claude",
            arguments: [],
            workingDirectory: "/tmp/project"
        )

        let saved = AgentSession(
            id: id,
            workspaceID: workspace.id,
            kind: .claudeCode,
            displayName: "Owner",
            cwd: "/tmp/project",
            launchDescriptor: descriptor,
            state: AgentState(lifecycle: .working, revision: 3, observedAt: MonotonicInstant.zero),
            createdAt: MonotonicInstant.zero,
            lastActivityAt: MonotonicInstant.zero
        )
        try await repo.save(saved)

        // Domain-unowned columns are armed by their owning APIs only.
        try await repo.setResumeRequested(true, agentID: id)
        try await repo.archive(id) // also nulls terminal_id

        // A NEWER legitimate snapshot with a fresh terminal association.
        let newer = AgentSession(
            id: id,
            workspaceID: workspace.id,
            terminalID: TerminalID(),
            kind: .claudeCode,
            displayName: "Owner",
            cwd: "/tmp/project",
            launchDescriptor: descriptor,
            state: AgentState(lifecycle: .working, revision: 4, observedAt: MonotonicInstant.zero),
            createdAt: MonotonicInstant.zero,
            lastActivityAt: MonotonicInstant.zero
        )
        try await repo.save(newer)

        let (resume, archived, revision): (Int64, Double?, Int64) = try await db.pool.read { database in
            let resume: Int64 = try Int64.fetchOne(
                database,
                sql: "SELECT resume_requested FROM agents WHERE id = ?",
                arguments: [id.rawValue.uuidString]
            ) ?? -1
            let archived: Double? = try Double.fetchOne(
                database,
                sql: "SELECT archived_at FROM agents WHERE id = ?",
                arguments: [id.rawValue.uuidString]
            )
            let revision: Int64 = try Int64.fetchOne(
                database,
                sql: "SELECT last_state_revision FROM agents WHERE id = ?",
                arguments: [id.rawValue.uuidString]
            ) ?? -1
            return (resume, archived, revision)
        }
        XCTAssertEqual(resume, 1, "routine state commit silently disarmed resume intent")
        XCTAssertNotNil(archived, "routine state commit resurrected the archived flag")
        XCTAssertEqual(revision, 4, "the legitimate write must land")

        // Archived law composes with the preserved columns: excluded from
        // the live list, returned under includeArchived with the new revision.
        let live = try await repo.list(workspaceID: workspace.id, includeArchived: false)
        XCTAssertTrue(live.isEmpty)
        let withArchived = try await repo.list(workspaceID: workspace.id, includeArchived: true)
        XCTAssertEqual(withArchived.map(\.id), [id])
        XCTAssertEqual(withArchived.first?.state.revision, 4)
    }
}

// MARK: - Round 19 file-local fixture

/// Arms EXACTLY ONE failing write that PARKS mid-write until `release()`
/// and only then throws — letting a test land newer state while the failing
/// write is provably still suspended. Combines GatedTransactor's
/// hold/release pattern with FlakyTransactor's one-shot injection.
private final class ParkAndFailTransactor: StoreTransacting, @unchecked Sendable {
    struct InjectedFailure: Error {}

    private let lock = NSLock()
    private var armed = false
    private var holding = false
    private var parkedCountValue = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let base: PoolTransactor

    init(base: PoolTransactor) {
        self.base = base
    }

    func armFailureOnce() {
        lock.withLock { armed = true }
    }

    func hold() {
        lock.withLock { holding = true }
    }

    var parkedCount: Int {
        lock.withLock { parkedCountValue }
    }

    func release() {
        lock.lock()
        holding = false
        parkedCountValue = 0
        let resumed = waiting
        waiting.removeAll()
        lock.unlock()
        for continuation in resumed {
            continuation.resume()
        }
    }

    func write<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        let shouldParkAndFail = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            parkedCountValue += 1
            return true
        }
        if shouldParkAndFail {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let enqueued = self.lock.withLock { () -> Bool in
                    guard self.holding else { return false }
                    self.waiting.append(continuation)
                    return true
                }
                if !enqueued {
                    // Released between the two checks; no gate to wait on.
                    continuation.resume()
                }
            }
            lock.withLock { parkedCountValue -= 1 }
            throw InjectedFailure()
        }
        return try await base.write(body)
    }

    func read<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await base.read(body)
    }
}

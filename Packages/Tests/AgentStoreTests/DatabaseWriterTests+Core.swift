import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

extension DatabaseWriterTests {
    // MARK: Revision gate

    func testStaleRevisionRejectedAndEqualRevisionAccepted() async throws {
        let (db, context) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.dir) }

        let agentID = context.agentID

        func storedState() async throws -> (revision: UInt64, lifecycle: String) {
            try await db.pool.read { database in
                let row = try Row.fetchOne(
                    database,
                    sql: "SELECT last_state_revision, last_lifecycle FROM agents WHERE id = ?",
                    arguments: [agentID.rawValue.uuidString]
                )
                return (UInt64((row?["last_state_revision"] as Int64?) ?? 0), row?["last_lifecycle"] ?? "unknown")
            }
        }

        func commit(_ revision: UInt64, _ lifecycle: LifecyclePhase) async {
            let state = AgentState(
                lifecycle: lifecycle,
                authority: .screen,
                revision: revision,
                observedAt: .ns(revision > 0 ? Int64(revision) * 1000 : 0)
            )
            await context.writer.commit(StateCommit(agentID: agentID, state: state, events: [], sessionReference: nil))
        }

        await commit(5, .idle)
        var state = try await storedState()
        XCTAssertEqual(state.revision, 5)
        XCTAssertEqual(state.lifecycle, LifecycleToken(phase: .idle).rawValue)

        // Stale revision must NOT regress the snapshot (§3.14 step 5).
        await commit(3, .working)
        state = try await storedState()
        XCTAssertEqual(state.revision, 5)
        XCTAssertEqual(state.lifecycle, LifecycleToken(phase: .idle).rawValue)

        // Equal revision is accepted idempotently (>= rule).
        await commit(5, .working)
        state = try await storedState()
        XCTAssertEqual(state.revision, 5)
        XCTAssertEqual(state.lifecycle, LifecycleToken(phase: .working).rawValue)
    }

    // MARK: Atomicity

    func testMidWriteFailurePersistsNeitherSnapshotNorEvents() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)

        // Fail after the snapshot statement, then pause the retry BEFORE its
        // transaction starts. Blocking inside a write transaction can stall
        // reader setup or retention work and make the test race a timeout.
        let retryGate = GatedTransactor(base: PoolTransactor(pool: db.pool))
        defer { retryGate.release() }
        final class OnceInjector: @unchecked Sendable {
            private var fired = false
            private let lock = NSLock()
            private let gate: GatedTransactor

            init(gate: GatedTransactor) {
                self.gate = gate
            }

            func error() -> Error? {
                lock.lock(); defer { lock.unlock() }
                guard !fired else { return nil }
                fired = true
                gate.hold()
                return InjectorError()
            }
        }
        struct InjectorError: Error {}
        let injector = OnceInjector(gate: retryGate)
        let writer = DatabaseWriter(
            transactor: retryGate,
            retryDelay: .milliseconds(10),
            maxAttempts: 1,
            failureInjector: { _ in injector.error() },
            // This test isolates transaction atomicity from housekeeping.
            retentionMaintenance: { 0 }
        )

        let event = TimelineEvent(agentID: session.id, at: .ns(500), event: .turnCompleted(hadPrompt: true))
        let failingCommit = StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 9, observedAt: .ns(600)),
            events: [event],
            sessionReference: nil
        )
        await writer.commit(failingCommit)

        try await TestEnv.waitFor(timeout: 3) { retryGate.waitingCount == 1 }

        // Neither the snapshot nor the event survived the aborted transaction.
        let afterFailure = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertEqual(afterFailure, 0)
        let revision: Int64 = try await db.pool.read { database in
            try Int64(self.fetchRevision(database, agentID: session.id) ?? 0)
        }
        XCTAssertEqual(revision, 0)

        // The retried attempt succeeds and both halves land together.
        // The retry is parked before its transaction during the assertions.
        retryGate.release()
        let pool = db.pool
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            try await (TestEnv.rowCount(db, "agent_events")) == 1
        }
        let revisionAfterRetry = try await TestEnv.waitForResult(timeout: 3) { @Sendable () -> UInt64? in
            try await pool.read { database in
                try self.fetchRevision(database, agentID: session.id)
            }
        }
        XCTAssertEqual(revisionAfterRetry, 9)
    }

    // MARK: Degraded / recovery

    func testDegradedSignalThenRecovery() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)

        let flaky = FlakyTransactor(base: PoolTransactor(pool: db.pool), failuresRemaining: .max)
        let writer = DatabaseWriter(
            transactor: flaky,
            retryDelay: .milliseconds(10),
            maxAttempts: 2
        )

        let healthUpdates = await writer.healthUpdates()
        let healthTask = Task { () -> [StoreWriter.Health] in
            var seen: [StoreWriter.Health] = []
            for await health in healthUpdates where seen.last != health {
                seen.append(health)
            }
            return seen
        }
        // Cancel even on assertion failure: the collector iterates forever.
        defer { healthTask.cancel() }

        // All writes fail → persistence degrades (§3.14 step 8).
        let event = TimelineEvent(agentID: session.id, at: .ns(100), event: .turnStarted(reason: .spontaneousWork))
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 1, observedAt: .ns(200)),
            events: [event],
            sessionReference: nil
        ))
        try await TestEnv.waitFor(timeout: 2) { @Sendable in
            if case .degraded = await writer.health {
                return true
            } else {
                return false
            }
        }
        guard case .degraded = await writer.health else {
            return await XCTFail("expected degraded, got \(writer.health)")
        }

        // Writes succeed again → backlog drains → healthy again.
        flaky.setFailuresRemaining(0)
        try await TestEnv.waitFor(timeout: 5) { @Sendable in
            await writer.health == .healthy
        }
        let persistedEvents = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertGreaterThanOrEqual(persistedEvents, 1)
    }

    // MARK: Coalescing under pressure

    func testQueueCoalescesWithoutDroppingNewestSnapshot() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)

        let gate = GatedTransactor(base: PoolTransactor(pool: db.pool))
        let writer = DatabaseWriter(transactor: gate, maxAttempts: 1, coalesceThreshold: 4)

        // Hold writes open so a backlog builds up in the queue.
        gate.hold()
        let highestRevision: UInt64 = 30
        let commits = (21 ... highestRevision).map { revision -> Task<Void, Never> in
            let event = TimelineEvent(
                agentID: session.id,
                at: .ns(Int64(revision)),
                event: .turnCompleted(hadPrompt: false)
            )
            let commit = StateCommit(
                agentID: session.id,
                state: session.state.with(revision: revision, observedAt: .ns(Int64(revision))),
                events: [event],
                sessionReference: nil
            )
            return Task { await writer.commit(commit) }
        }

        // Enqueue-wait is event-driven: poll until coalescing pulls the
        // queue below the threshold (strictly stronger than the old fixed
        // 150 ms snapshot, which could pass before all tasks enqueued).
        let coalesceDeadline = Date().addingTimeInterval(2)
        var pending = await writer.pendingCount
        while pending > 4, Date() < coalesceDeadline {
            try await Task.sleep(for: .milliseconds(5))
            pending = await writer.pendingCount
        }
        XCTAssertLessThanOrEqual(pending, 4, "queue should have coalesced same-agent commits")

        gate.release()
        // Every commit returns once its own drain pass ends; commits that
        // piggybacked on an in-flight drain may land moments later — wait for
        // the writer to go fully quiescent before asserting.
        for commitTask in commits {
            await commitTask.value
        }
        // Inline poll so a timeout still reports the writer's final state.
        var diag = ""
        let quiescentDeadline = Date().addingTimeInterval(10)
        var quiescent = false
        while Date() < quiescentDeadline {
            let pendingNow = await writer.pendingCount
            let eventsNow = await (try? TestEnv.rowCount(db, "agent_events")) ?? -1
            if pendingNow == 0, eventsNow == 10 {
                quiescent = true; break
            }
            diag = "pending=\(pendingNow) events=\(eventsNow)"
            try await Task.sleep(for: .milliseconds(20))
        }
        let healthNow = await writer.health
        XCTAssertTrue(quiescent, "writer never quiesced: \(diag) health=\(healthNow)")

        // Newest snapshot applied; folded events all present (≤ keep cap).
        let pool = db.pool
        let revision = try await TestEnv.waitForResult(timeout: 5) { @Sendable () -> UInt64? in
            let stored = try await pool.read { database in
                try self.fetchRevision(database, agentID: session.id)
            }
            return stored == highestRevision ? stored : nil
        }
        XCTAssertEqual(revision, highestRevision)
        let events = try await TestEnv.rowCount(db, "agent_events")
        if events != 10 {
            let pendingAfter = await writer.pendingCount
            let healthAfter = await writer.health
            let revAfter = try await db.pool.read { database in
                try self.fetchRevision(database, agentID: session.id)
            }
            XCTFail(
                "diagnostics: pending=\(pendingAfter) health=\(healthAfter) rev=\(String(describing: revAfter)) events=\(events)"
            )
        }
        XCTAssertEqual(events, 10)
    }

    // MARK: Incremental append (§3.14 sequence watermarks)

    /// A commit whose event window is a SUPERSET of the previous commit's
    /// must insert ONLY its unseen tail. The runtime ships its whole
    /// ≤1000-event window on every commit; re-inserting all of it would
    /// duplicate the entire timeline on every state change.
    func testSupersetWindowInsertsOnlyDeltaRows() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)

        // The second commit literally re-carries the first commit's events
        // (same TimelineEvent values) plus two new ones — the production
        // shape of `persist`, which ships `timelines[agentID] ?? []`.
        let firstEvents = [
            TimelineEvent(agentID: session.id, at: .ns(1), event: .turnStarted(reason: .spontaneousWork)),
            TimelineEvent(agentID: session.id, at: .ns(2), event: .turnCompleted(hadPrompt: true)),
        ]
        let secondEvents = firstEvents + [
            TimelineEvent(agentID: session.id, at: .ns(3), event: .attentionRaised(kind: .failure)),
            TimelineEvent(agentID: session.id, at: .ns(4), event: .attentionCleared(kind: .failure)),
        ]

        let writer = DatabaseWriter(transactor: PoolTransactor(pool: db.pool))
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 1, observedAt: .ns(10)),
            events: firstEvents,
            sessionReference: nil
        ))
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 2, observedAt: .ns(20)),
            events: secondEvents,
            sessionReference: nil
        ))

        // Exactly four rows: the delta was inserted, the overlap was not.
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            try await TestEnv.rowCount(db, "agent_events") == 4
        }
        let pool = db.pool
        let (kinds, revisions) = try await pool.read { database -> (kinds: [String], revisions: [UInt64]) in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT kind, revision FROM agent_events ORDER BY id ASC"
            )
            return (
                kinds: rows.map { row -> String in
                    let kind: String = row["kind"]
                    return kind
                },
                revisions: rows.map { row -> UInt64 in
                    let revision: Int64 = row["revision"]
                    return UInt64(bitPattern: revision)
                }
            )
        }
        XCTAssertEqual(kinds, ["turn_started", "turn_completed", "attention_raised", "attention_cleared"])
        XCTAssertEqual(revisions, [1, 1, 2, 2], "the two new rows carry the newer commit's revision")
        let health = await writer.health
        XCTAssertEqual(health, .healthy)
    }

    /// A mid-write-failed commit retries under the SAME revision. Because
    /// the watermark advances only AFTER a successful COMMIT, the aborted
    /// attempt left its whole tail unseen: the retry re-records exactly
    /// those events — once — without duplicating what an earlier successful
    /// commit already persisted.
    func testFailedCommitRetryInsertsExactlyItsUnseenEventsOnce() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        // The snapshot half only applies to a REGISTERED agent (R9-B1:
        // unknown agents record events but never mint identity), so seed
        // the agents row — otherwise fetchRevision below stays nil.
        try await AgentRepository(database: db).save(session)
        // Rev 2 fails exactly once (mid-write abort), then succeeds on retry.
        let injector = ScriptedFailureInjector(poisonedForever: [], exhaustIntoRetry: [2: 1])
        let writer = DatabaseWriter(
            transactor: PoolTransactor(pool: db.pool),
            retryDelay: .milliseconds(5),
            maxAttempts: 2,
            failureInjector: { injector.error(for: $0.state.revision) }
        )

        let firstEvents = [
            TimelineEvent(agentID: session.id, at: .ns(1), event: .turnStarted(reason: .spontaneousWork)),
        ]
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 1, observedAt: .ns(10)),
            events: firstEvents,
            sessionReference: nil
        ))

        // The failed commit's window re-carries the already-persisted event.
        let retryWindow = firstEvents + [
            TimelineEvent(agentID: session.id, at: .ns(2), event: .turnCompleted(hadPrompt: false)),
            TimelineEvent(
                agentID: session.id,
                at: .ns(3),
                event: .processExited(exitCode: 0, signal: nil, userInitiated: true)
            ),
        ]
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 2, observedAt: .ns(20)),
            events: retryWindow,
            sessionReference: nil
        ))

        // Three rows total: the retried commit inserted ONLY its two unseen
        // events; neither its own overlap nor the first commit's event was
        // duplicated by the retry.
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            try await TestEnv.rowCount(db, "agent_events") == 3
        }
        let pool = db.pool
        let kinds = try await pool.read { database in
            try String.fetchAll(database, sql: "SELECT kind FROM agent_events ORDER BY id ASC")
        }
        XCTAssertEqual(kinds, ["turn_started", "turn_completed", "process_exited"])
        XCTAssertEqual(Set(kinds).count, kinds.count, "no duplicated event kinds")
        let revision = try await pool.read { database in
            try self.fetchRevision(database, agentID: session.id)
        }
        XCTAssertEqual(revision, 2)
    }

    // MARK: §3.14 background retention wiring

    /// The forced seam runs a REAL maintenance pass immediately and reports
    /// removed rows; the automatic pass fires on the drain success path once
    /// the (here zero-length) threshold elapses — no timers anywhere, so no
    /// uncontrolled firings during unit tests.
    func testRetentionMaintenanceRunsOnDemandAndAfterSuccessfulCommits() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)

        // Preload cap + 3 rows directly: three beyond the §3.14 retention cap.
        let idString = session.id.rawValue.uuidString
        try await db.pool.write { database in
            for index in 0 ..< (EventRepository.retentionCap + 3) {
                try database.execute(
                    sql: """
                    INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
                    VALUES (?, ?, 'turn_completed', 'runtime', ?, ?, NULL)
                    """,
                    arguments: [idString, Int64(index), Data("{}".utf8), Double(index)]
                )
            }
        }
        let passes = RetentionPassLog()
        let repository = EventRepository(transactor: PoolTransactor(pool: db.pool))
        let writer = DatabaseWriter(
            transactor: PoolTransactor(pool: db.pool),
            retentionMaintenance: {
                passes.record()
                return try await repository.maintainRetention()
            },
            retentionInterval: 0
        )

        // Forced, deterministic pass: trims exactly the three overflow rows.
        let removed = await writer.runRetentionMaintenanceNow()
        XCTAssertEqual(removed, 3)
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            try await TestEnv.rowCount(db, "agent_events") == EventRepository.retentionCap
        }
        XCTAssertEqual(passes.total, 1)

        // Automatic pass: a successful commit drains, the zero threshold has
        // elapsed since the stamped pass, maintenance fires once more.
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 1, observedAt: .ns(10)),
            events: [],
            sessionReference: nil
        ))
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            passes.total >= 2
        }
        let health = await writer.health
        XCTAssertEqual(health, .healthy, "retention must never degrade commit health")
    }
}

import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

extension DatabaseWriterTests {
    // MARK: No-fabrication for unknown agents

    /// R9-B1: a commit for an agent never registered in `agents` records its
    /// events (no FK on agent_events.agent_id) but must NEVER fabricate an
    /// identity row or degrade writer health.
    func testCommitForUnknownAgentRecordsEventsButNeverFabricatesIdentity() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()

        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)

        let ghost = AgentID()
        let writer = DatabaseWriter(
            transactor: PoolTransactor(pool: db.pool),
            retryDelay: .milliseconds(10),
            maxAttempts: 1
        )

        let state = AgentState(
            lifecycle: .idle,
            authority: .screen,
            revision: 7,
            observedAt: .ns(7000)
        )
        await writer.commit(StateCommit(
            agentID: ghost,
            state: state,
            events: [TimelineEvent(agentID: ghost, at: .ns(7000), event: .turnCompleted(hadPrompt: true))],
            sessionReference: nil
        ))

        // Events recorded…
        let events = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertEqual(events, 1, "the event half must still be recorded")
        if events == 1 {
            let storedAgentID: String? = try await db.pool.read { database in
                try String.fetchOne(database, sql: "SELECT agent_id FROM agent_events LIMIT 1")
            }
            XCTAssertEqual(storedAgentID, ghost.rawValue.uuidString)
        }
        // …but identity NOT fabricated.
        let identityRows: Int64 = try await db.pool.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM agents WHERE id = ?",
                arguments: [ghost.rawValue.uuidString]
            ) ?? -1
        }
        XCTAssertEqual(identityRows, 0, "committing for an unknown agent must not mint an agents row")
        let revision = try await db.pool.read { database in
            try self.fetchRevision(database, agentID: ghost)
        }
        XCTAssertNil(revision)
        let health = await writer.health
        XCTAssertEqual(health, .healthy)
        let pending = await writer.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// R10-A (§3.14 step 5): a strictly-older commit for a REGISTERED agent
    /// must drop BOTH halves — the snapshot is frozen by applySnapshot's
    /// `>=` guard and its events are dropped by appendEvents' `<` gate. A
    /// regression of the gate to `<=` would silently discard every registered
    /// commit's events; dropping the gate entirely would let late retried
    /// commits interleave the timeline.
    func testStrictlyOlderCommitDropsEventsAndFreezesSnapshot() async throws {
        let (db, context) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: context.dir) }

        let agentID = context.agentID

        // Stored revision 5 with one event.
        let current = AgentState(
            lifecycle: .working,
            authority: .screen,
            revision: 5,
            observedAt: .ns(5000)
        )
        await context.writer.commit(StateCommit(
            agentID: agentID,
            state: current,
            events: [TimelineEvent(agentID: agentID, at: .ns(5000), event: .turnCompleted(hadPrompt: true))],
            sessionReference: nil
        ))

        // Late commit carrying revision 3 WITH an event.
        let stale = AgentState(
            lifecycle: .idle,
            authority: .screen,
            revision: 3,
            observedAt: .ns(3000)
        )
        await context.writer.commit(StateCommit(
            agentID: agentID,
            state: stale,
            events: [TimelineEvent(agentID: agentID, at: .ns(3000), event: .turnStarted(reason: .spontaneousWork))],
            sessionReference: nil
        ))

        // Snapshot frozen by the >= guard: no revision or lifecycle regression.
        let stored = try await db.pool.read { database -> (revision: UInt64, lifecycle: String) in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT last_state_revision, last_lifecycle FROM agents WHERE id = ?",
                arguments: [agentID.rawValue.uuidString]
            )
            return (
                revision: UInt64((row?["last_state_revision"] as Int64?) ?? 0),
                lifecycle: (row?["last_lifecycle"] as String?) ?? "unknown"
            )
        }
        XCTAssertEqual(stored.revision, 5, "a strictly-older commit must not regress the snapshot")
        XCTAssertEqual(
            stored.lifecycle,
            LifecycleToken(phase: .working).rawValue,
            "the rev-5 lifecycle token must survive"
        )

        // Events dropped by the < gate: exactly the rev-5 turnCompleted row.
        let events = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertEqual(events, 1, "the stale commit's turnStarted must NOT appear")
        if events == 1 {
            let kind: String? = try await db.pool.read { database in
                try String.fetchOne(database, sql: "SELECT kind FROM agent_events LIMIT 1")
            }
            XCTAssertEqual(kind, "turn_completed", "only the rev-5 event may survive")
        }

        // The gate drop is a healthy outcome, never a degradation.
        let health = await context.writer.health
        XCTAssertEqual(health, .healthy)
        let pending = await context.writer.pendingCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: Coalescing fold-reference laws (7dfa094, pure `coalesced(_:)`)

    /// D1: when an older-enqueued but higher-revision commit survives
    /// coalescing, the survivor keeps its OWN session reference — a stale
    /// commit's reference must never override it (crash recovery could
    /// otherwise resume a superseded session identity).
    func testCoalescingSurvivorCarriesItsOwnSessionReferenceNotTheStaleOne() {
        let id = AgentID()
        let refA = SessionReference(agentKind: .genericShell, opaquePayload: "session-A", capturedAtRevision: 10)
        let refB = SessionReference(agentKind: .genericShell, opaquePayload: "session-B", capturedAtRevision: 5)
        let newest = StateCommit(
            agentID: id,
            state: AgentState(lifecycle: .working, authority: .screen, revision: 10, observedAt: .ns(10000)),
            events: [TimelineEvent(agentID: id, at: .ns(10000), event: .turnCompleted(hadPrompt: true))],
            sessionReference: refA
        )
        // Arrives LATER but loses on revision; its stale identity must lose too.
        let stale = StateCommit(
            agentID: id,
            state: AgentState(lifecycle: .idle, authority: .screen, revision: 5, observedAt: .ns(5000)),
            events: [TimelineEvent(agentID: id, at: .ns(5000), event: .turnStarted(reason: .spontaneousWork))],
            sessionReference: refB
        )

        let out = DatabaseWriter.coalesced([newest, stale])

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].state.revision, 10)
        XCTAssertEqual(
            out[0].sessionReference, refA,
            "the surviving snapshot's reference must win over the stale commit's"
        )
        XCTAssertEqual(out[0].events.count, 2, "older events still fold into the survivor")
    }

    /// D2: the `??` arm — when the revision-surviving snapshot has NO
    /// reference, the folded commit's reference is kept rather than dropped:
    /// identity evidence must survive coalescing even when it arrives
    /// attached to the older snapshot.
    func testNilSurvivorReferenceFallsBackToNewerCommitsReference() {
        let id = AgentID()
        let refX = SessionReference(agentKind: .genericShell, opaquePayload: "session-X", capturedAtRevision: 4)
        let highNil = StateCommit(
            agentID: id,
            state: AgentState(lifecycle: .idle, authority: .screen, revision: 9, observedAt: .ns(9000)),
            events: [TimelineEvent(agentID: id, at: .ns(9000), event: .turnCompleted(hadPrompt: false))],
            sessionReference: nil
        )
        let lowWithRef = StateCommit(
            agentID: id,
            state: AgentState(lifecycle: .working, authority: .screen, revision: 4, observedAt: .ns(4000)),
            events: [TimelineEvent(agentID: id, at: .ns(4000), event: .turnStarted(reason: .spontaneousWork))],
            sessionReference: refX
        )

        let out = DatabaseWriter.coalesced([highNil, lowWithRef])

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].state.revision, 9)
        XCTAssertEqual(
            out[0].sessionReference, refX,
            "the reference attached to the losing commit must survive the fold"
        )

        // Control: when NEITHER side carries a reference, none is fabricated.
        let lowNil = StateCommit(
            agentID: id,
            state: AgentState(lifecycle: .working, authority: .screen, revision: 4, observedAt: .ns(4000)),
            events: [TimelineEvent(agentID: id, at: .ns(4000), event: .turnStarted(reason: .spontaneousWork))],
            sessionReference: nil
        )
        let bareOut = DatabaseWriter.coalesced([highNil, lowNil])
        XCTAssertEqual(bareOut.count, 1)
        XCTAssertNil(bareOut[0].sessionReference, "no reference may be invented by coalescing")
    }

    /// D3: output order follows FIRST-SEEN agent order (not dictionary
    /// iteration), and merged events cap at `keepPerAgentEvents` keeping the
    /// NEWEST suffix.
    func testCoalescingPreservesFirstSeenAgentOrderAndEventCap() throws {
        let x = AgentID(), y = AgentID(), z = AgentID()
        func event(_ agent: AgentID, _ atNanos: Int64) -> TimelineEvent {
            TimelineEvent(agentID: agent, at: .ns(atNanos), event: .turnCompleted(hadPrompt: false))
        }
        func commit(_ agent: AgentID, revision: UInt64, atNanos: Int64, events: [TimelineEvent]) -> StateCommit {
            StateCommit(
                agentID: agent,
                state: AgentState(
                    lifecycle: .working,
                    authority: .screen,
                    revision: revision,
                    observedAt: .ns(atNanos)
                ),
                events: events,
                sessionReference: nil
            )
        }
        // Enqueue order: X, Y, X, Z — X's six events split across two commits.
        // Events must be created IN TIMELINE ORDER (sequences are assigned at
        // construction), and the watermark references the LAST one's sequence.
        let xFirstWindow = [event(x, 1), event(x, 2), event(x, 3)]
        let xSecondWindow = [event(x, 4), event(x, 5), event(x, 6)]
        let commits = [
            commit(x, revision: 1, atNanos: 100, events: xFirstWindow),
            commit(y, revision: 1, atNanos: 200, events: [event(y, 10)]),
            commit(x, revision: 2, atNanos: 300, events: xSecondWindow),
            commit(z, revision: 1, atNanos: 400, events: [event(z, 20)]),
        ]

        // Watermark covers ALL of X's events: the whole merged history counts
        // as persisted, so the cap law below is exercised unchanged (S2 made
        // the default treat unwatermarked agents as persisting nothing).
        let out = try DatabaseWriter.coalesced(
            commits,
            watermarks: [x: XCTUnwrap(xSecondWindow.last?.sequence)],
            keepPerAgentEvents: 4
        )

        XCTAssertEqual(out.map(\.agentID), [x, y, z], "first-seen order, deduplicated")
        let xMerged = out[0].events
        XCTAssertEqual(xMerged.count, 4, "merged history caps at keepPerAgentEvents")
        XCTAssertEqual(
            xMerged.map(\.at.nanosecondsSinceEpoch), [3, 4, 5, 6],
            "the NEWEST suffix of existing.events + commit.events is retained"
        )
        XCTAssertEqual(out[1].events.map(\.at.nanosecondsSinceEpoch), [10], "Y keeps its single event untouched")
        XCTAssertEqual(out[2].events.map(\.at.nanosecondsSinceEpoch), [20], "Z keeps its single event untouched")
    }

    /// S2: `keepPerAgentEvents` must never fold away an event above the
    /// agent's watermark — those payloads were never written, and once
    /// coalesced out no future runtime window carries them again. Pre-fix
    /// the fold took `.suffix(keepPerAgentEvents)` of the WHOLE merged
    /// window, silently discarding unwritten event #2 here.
    func testCoalescingNeverFoldsAwayUnpersistedEventsAboveWatermark() {
        let id = AgentID()
        func event(_ atNanos: Int64) -> TimelineEvent {
            TimelineEvent(agentID: id, at: .ns(atNanos), event: .turnCompleted(hadPrompt: false))
        }
        let persisted = event(1)
        let unwritten = (2 ... 6).map(event)
        let commits = [
            StateCommit(
                agentID: id,
                state: AgentState(lifecycle: .working, authority: .screen, revision: 1, observedAt: .ns(100)),
                events: [persisted],
                sessionReference: nil
            ),
            StateCommit(
                agentID: id,
                state: AgentState(lifecycle: .working, authority: .screen, revision: 2, observedAt: .ns(600)),
                events: unwritten,
                sessionReference: nil
            ),
        ]

        // Only event #1 is persisted; FIVE unwritten events face a cap of 4.
        let out = DatabaseWriter.coalesced(commits, watermarks: [id: persisted.sequence], keepPerAgentEvents: 4)

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(
            out[0].events.map(\.at.nanosecondsSinceEpoch), [1, 2, 3, 4, 5, 6],
            "the persisted prefix may cap, but every unwritten event survives"
        )
    }

    // MARK: Round 29 S1 — drain×retry exclusivity

    /// A retry racing an in-flight drain for the SAME agent used to
    /// double-append their shared tail: the reentrant actor let the retry
    /// loop start its transaction while the drain loop's transaction was
    /// still in flight, so BOTH windows filtered against the same
    /// pre-overlap watermark and inserted event #2 twice. The apply slot now
    /// spans watermark read → COMMIT → watermark advance, so whichever
    /// attempt lands second filters against the advanced watermark.
    ///
    /// Determinism: the gate holds every write open until both attempts have
    /// read the (frozen) watermark, so pre-fix the duplication appears in
    /// EVERY interleaving; post-fix exactly one copy lands in all of them.
    func testDrainAndRetryOverlapForSameAgentDoesNotDuplicateRows() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)

        let gate = GatedTransactor(base: PoolTransactor(pool: db.pool))
        // Rev 2 fails exactly maxAttempts times inline so it enters the
        // backlog; its BACKGROUND attempt then parks inside the held gate.
        let injector = ScriptedFailureInjector(poisonedForever: [], exhaustIntoRetry: [2: 2])
        let writer = DatabaseWriter(
            transactor: gate,
            retryDelay: .milliseconds(300),
            maxAttempts: 2,
            failureInjector: { injector.error(for: $0.state.revision) }
        )

        // Baseline: rev 1 persists event #1, advancing the watermark past it.
        let e1 = TimelineEvent(agentID: session.id, at: .ns(1), event: .turnStarted(reason: .spontaneousWork))
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 1, observedAt: .ns(10)),
            events: [e1],
            sessionReference: nil
        ))

        // Rev 2 re-carries #1 plus new #2: two inline failures push it into
        // the backlog; the loop sleeps retryDelay before its first rotation.
        let e2 = TimelineEvent(agentID: session.id, at: .ns(2), event: .turnCompleted(hadPrompt: true))
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 2, observedAt: .ns(20)),
            events: [e1, e2],
            sessionReference: nil
        ))

        // Hold every write BEFORE the background retry wakes, then enqueue a
        // drain window overlapping the retried payload on event #2.
        gate.hold()
        let e3 = TimelineEvent(agentID: session.id, at: .ns(3), event: .attentionRaised(kind: .failure))
        let drainTask = Task {
            await writer.commit(StateCommit(
                agentID: session.id,
                state: session.state.with(revision: 3, observedAt: .ns(30)),
                events: [e1, e2, e3],
                sessionReference: nil
            ))
        }

        // Wait out the retry loop's full delay plus slack: by now the retried
        // attempt has read the still-frozen watermark and parked beside the
        // drain's transaction (post-fix only one of them fits inside the gate
        // at once — the other waits on the apply slot — hence >= 1).
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThanOrEqual(gate.waitingCount, 1, "a writer must be parked inside the gate")
        gate.release()

        await drainTask.value
        try await TestEnv.waitFor(timeout: 5) { @Sendable in
            await writer.pendingCount == 0
        }

        let pool = db.pool
        let kinds = try await pool.read { database in
            try String.fetchAll(database, sql: "SELECT kind FROM agent_events ORDER BY id ASC")
        }
        XCTAssertEqual(
            kinds, ["turn_started", "turn_completed", "attention_raised"],
            "the shared event #2 must be appended exactly once"
        )
    }

    // MARK: Round 19 B1 — retry-loop rotation fairness (cd7c66b)

    /// A permanently failing backlog HEAD must not starve later commits:
    /// `retryLoop` rotates the backlog instead of retrying `retryPending[0]`
    /// forever. Rev 11 is pushed THROUGH inline exhaustion (exactly
    /// `maxAttempts` scripted failures) into `retryPending` behind the
    /// poisoned rev 10 head, then lands via rotation while rev 10 never
    /// applies.
    func testRetryLoopRotationLetsLaterCommitLandBehindPoisonedHead() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)

        let injector = ScriptedFailureInjector(poisonedForever: [10], exhaustIntoRetry: [11: 2])
        let writer = DatabaseWriter(
            transactor: PoolTransactor(pool: db.pool),
            retryDelay: .milliseconds(1),
            maxAttempts: 2,
            failureInjector: { injector.error(for: $0.state.revision) }
        )

        func commit(_ revision: UInt64, _ event: TimelineEvent) async {
            await writer.commit(StateCommit(
                agentID: session.id,
                state: session.state.with(revision: revision, observedAt: .ns(Int64(revision))),
                events: [event],
                sessionReference: nil
            ))
        }

        // Rev 10 poisons the head: inline retries exhaust → degrade → retryPending.
        await commit(10, TimelineEvent(agentID: session.id, at: .ns(10), event: .turnStarted(reason: .spontaneousWork)))
        let poisonWindowHealth = await writer.health
        guard case .degraded = poisonWindowHealth else {
            return XCTFail("the poison window must be degraded, got \(poisonWindowHealth)")
        }

        // Rev 11 rides THROUGH the retry path: two inline failures enqueue it
        // behind the poisoned head; rotation must land it rather than starve.
        await commit(11, TimelineEvent(agentID: session.id, at: .ns(11), event: .turnCompleted(hadPrompt: false)))

        let pool = db.pool
        try await TestEnv.waitFor(timeout: 5) { @Sendable in
            let revision = try await pool.read { try self.fetchRevision($0, agentID: session.id) }
            let kinds = try await pool.read { database in
                try String.fetchAll(database, sql: "SELECT kind FROM agent_events")
            }
            return revision == 11 && kinds == ["turn_completed"]
        }
        // The loop quiesced on the poisoned entry instead of spinning.
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            await writer.pendingCount == 0
        }
        let eventsAfterRotation = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertEqual(eventsAfterRotation, 1, "rev 10's event must never land")
    }

    // MARK: Round 19 B2 — drop-after-maxAttempts + degraded-until-recovery

    /// After `maxAttempts` failed rotations the poisoned entry is DROPPED
    /// with a degrade and the loop TERMINATES instead of spinning forever;
    /// health recovers to `.healthy` only when a later commit succeeds with
    /// an empty backlog. Under the pre-cd7c66b head-only loop the queue never
    /// empties and "retry dropped" never appears.
    func testRetryLoopDropsPoisonedEntryAfterMaxAttemptsAndStaysDegradedUntilRecovery() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)

        let injector = ScriptedFailureInjector(poisonedForever: [7], exhaustIntoRetry: [:])
        let writer = DatabaseWriter(
            transactor: PoolTransactor(pool: db.pool),
            retryDelay: .milliseconds(1),
            maxAttempts: 2,
            failureInjector: { injector.error(for: $0.state.revision) }
        )

        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 7, observedAt: .ns(7)),
            events: [TimelineEvent(agentID: session.id, at: .ns(7), event: .turnStarted(reason: .spontaneousWork))],
            sessionReference: nil
        ))

        // Degraded with the drop marker once maxAttempts rotations exhausted,
        // AND the backlog actually emptied (loop terminated, no busy spin).
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            let pending = await writer.pendingCount
            guard case let .degraded(reason) = await writer.health else { return false }
            return reason.contains("retry dropped") && pending == 0
        }

        // Recovery law: a later commit succeeds with an empty backlog and
        // flips health back to `.healthy` — the dropped rev 7 stays gone.
        await writer.commit(StateCommit(
            agentID: session.id,
            state: session.state.with(revision: 8, observedAt: .ns(8)),
            events: [TimelineEvent(agentID: session.id, at: .ns(8), event: .turnCompleted(hadPrompt: true))],
            sessionReference: nil
        ))
        let revision = try await db.pool.read { try self.fetchRevision($0, agentID: session.id) }
        XCTAssertEqual(revision, 8)
        let kinds = try await db.pool.read { database in
            try String.fetchAll(database, sql: "SELECT kind FROM agent_events")
        }
        XCTAssertEqual(kinds, ["turn_completed"], "rev 7's dropped snapshot/event must never be fabricated")
        let finalHealth = await writer.health
        XCTAssertEqual(finalHealth, .healthy)
    }

    // MARK: Round 22 DW1 — per-entry retry budget across interleaved successes (f493a7a)

    /// f493a7a: a successful apply clears ONLY its own entry's counter
    /// (`attempts[head.state.revision] = nil`, :308); other entries' accrued
    /// failure counts survive. Pre-fix, ANY success reset the whole table, so
    /// a poisoned commit rotating among succeeding ones NEVER reached
    /// `maxAttempts` and the loop spun forever — defeating its own
    /// terminate-rather-than-spin guarantee.
    ///
    /// Arrange honesty: rev 11 burns exactly `maxAttempts` inline failures so
    /// it enters the backlog behind rev 10 and lands on a rotation. The exact
    /// interleaving of rev 10's counted failures and rev 11's backlog success
    /// is the LOOP's business (orchestrator note: trace-agnostic), so the law
    /// is asserted through observables that hold in EVERY interleaving: the
    /// "retry dropped" degradation MUST have been emitted, the backlog MUST
    /// drain, rev 11 must land while rev 10's event never does, and a later
    /// commit recovers health. Pre-fix, the drain never completes — the first
    /// waitFor timing out IS the regression signal.
    func testRetryBudgetSurvivesInterleavedSuccessesAndStillDropsPoisonedEntry() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)

        let injector = ScriptedFailureInjector(poisonedForever: [10], exhaustIntoRetry: [11: 3])
        let writer = DatabaseWriter(
            transactor: PoolTransactor(pool: db.pool),
            retryDelay: .milliseconds(1),
            maxAttempts: 3,
            failureInjector: { injector.error(for: $0.state.revision) }
        )

        // Health-transition log: whichever entry drains last decides the FINAL
        // health value, but the drop degradation itself is interleaving-agnostic.
        let degradations = DegradationLog()
        let healthStream = await writer.healthUpdates()
        let collector = Task {
            for await health in healthStream {
                if case let .degraded(reason) = health {
                    degradations.record(reason)
                }
            }
        }

        func commit(_ revision: UInt64, _ event: TimelineEvent) async {
            await writer.commit(StateCommit(
                agentID: session.id,
                state: session.state.with(revision: revision, observedAt: .ns(Int64(revision))),
                events: [event],
                sessionReference: nil
            ))
        }

        // Rev 10 poisons the head: inline retries exhaust → degrade → backlog.
        await commit(10, TimelineEvent(agentID: session.id, at: .ns(10), event: .turnStarted(reason: .spontaneousWork)))
        // Rev 11 fails maxAttempts times INLINE → enters the backlog behind
        // rev 10 → lands on a later rotation.
        await commit(11, TimelineEvent(agentID: session.id, at: .ns(11), event: .turnCompleted(hadPrompt: false)))

        // The loop TERMINATES instead of spinning: backlog drains and rev 11
        // landed. Pre-fix, rev 11's success resets rev 10's count every
        // rotation → pendingCount never reaches zero → THIS WAIT TIMES OUT.
        let pool = db.pool
        try await TestEnv.waitFor(timeout: 5) { @Sendable in
            guard await writer.pendingCount == 0 else { return false }
            let revision = try await pool.read { try self.fetchRevision($0, agentID: session.id) }
            return revision == 11
        }

        // The poisoned entry was DROPPED with the retry-budget degrade — in
        // every interleaving, because its count survives rev 11's successes.
        try await TestEnv.waitFor(timeout: 2) { @Sendable in
            degradations.contains("retry dropped")
        }
        collector.cancel()

        let kinds = try await pool.read { database in
            try String.fetchAll(database, sql: "SELECT kind FROM agent_events")
        }
        XCTAssertEqual(kinds, ["turn_completed"], "rev 10's event must never land")

        // Recovery-after-drop composed with budget survival: a follow-up
        // commit succeeds with an empty backlog and flips health healthy.
        await commit(12, TimelineEvent(agentID: session.id, at: .ns(12), event: .turnCompleted(hadPrompt: true)))
        let finalRevision = try await pool.read { try self.fetchRevision($0, agentID: session.id) }
        XCTAssertEqual(finalRevision, 12)
        let finalHealth = await writer.health
        XCTAssertEqual(finalHealth, .healthy)
    }

    // MARK: Round 28 S8 — retry attempt keys are per agent AND revision

    /// The retry loop's attempt counter is keyed (agentID, revision). Under
    /// a bare-revision key, agent A's accrued failure count on revision 5
    /// would be charged against agent B's healthy revision-5 commit riding
    /// through the same backlog, silently dropping B's write.
    ///
    /// Interleaving honesty: with maxAttempts = 2 and B exhausting inline
    /// right after A did, B enters the backlog between A's first rotation
    /// (count 1) and A's second (drop) in every non-starving schedule — the
    /// loop's own retryDelay spacing guarantees B's inline path (one sleep)
    /// lands inside that window. Pre-fix, B's FIRST backlog failure would
    /// see the shared count at 2 and be dropped; post-fix it survives on its
    /// own budget.
    func testRetryAttemptKeysArePerAgentSoHealthyCommitIsNotDropped() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let sessionA = makeSession(workspace: workspace)
        let sessionB = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(sessionA)
        try await AgentRepository(database: db).save(sessionB)

        // Per-agent failure predicate (file-local extension of the poison
        // mechanism): A's commits fail persistently; B's fail exactly
        // maxAttempts times so they ride THROUGH inline exhaustion into the
        // backlog and land on a rotation.
        let injector = PerAgentFailureInjector(
            persistentFailures: [sessionA.id],
            exhaustIntoRetry: [sessionB.id: 2]
        )
        let writer = DatabaseWriter(
            transactor: PoolTransactor(pool: db.pool),
            retryDelay: .milliseconds(150),
            maxAttempts: 2,
            failureInjector: { injector.error(for: $0) }
        )

        let degradations = DegradationLog()
        let healthStream = await writer.healthUpdates()
        let collector = Task {
            for await health in healthStream {
                if case let .degraded(reason) = health {
                    degradations.record(reason)
                }
            }
        }
        defer { collector.cancel() }

        // Act: A's revision-5 commit fails first (inline exhaustion →
        // degrade → backlog); B's revision-5 commit is enqueued AFTER that.
        await writer.commit(StateCommit(
            agentID: sessionA.id,
            state: sessionA.state.with(revision: 5, observedAt: .ns(500)),
            events: [TimelineEvent(agentID: sessionA.id, at: .ns(500), event: .turnStarted(reason: .spontaneousWork))],
            sessionReference: nil
        ))
        await writer.commit(StateCommit(
            agentID: sessionB.id,
            state: sessionB.state.with(revision: 5, observedAt: .ns(500)),
            events: [TimelineEvent(agentID: sessionB.id, at: .ns(500), event: .turnCompleted(hadPrompt: true))],
            sessionReference: nil
        ))

        // Assert: B's healthy revision-5 commit IS persisted — A's failures
        // never shortened B's retry budget. Pre-fix, B's row would be missing.
        let pool = db.pool
        let revisionB = try await TestEnv.waitForResult(timeout: 5) { @Sendable () -> UInt64? in
            let stored = try await pool.read { database in
                try self.fetchRevision(database, agentID: sessionB.id)
            }
            return stored == 5 ? stored : nil
        }
        XCTAssertEqual(revisionB, 5)

        // A's poisoned commit was dropped after exactly maxAttempts rotations
        // (the drop degrade); its inline exhaustion named A's rev-5 commit.
        // (B also legitimately degrades once — its own inline exhaustion is
        // how it enters the backlog.)
        try await TestEnv.waitFor(timeout: 3) { @Sendable in
            degradations.contains("retry dropped")
        }
        XCTAssertTrue(degradations.contains("commit \(sessionA.id.rawValue.uuidString) rev 5"))
        let eventsA = try await TestEnv.rowCount(db, "agent_events")
        XCTAssertEqual(eventsA, 1, "only B's event landed; A's must never do")
        let kinds = try await pool.read { database in
            try String.fetchAll(database, sql: "SELECT kind FROM agent_events")
        }
        XCTAssertEqual(kinds, ["turn_completed"], "the surviving event is B's")
        let pending = await writer.pendingCount
        XCTAssertEqual(pending, 0, "the loop terminated instead of spinning")
    }
}

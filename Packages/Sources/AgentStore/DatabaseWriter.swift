import AgentCore
import Foundation
import GRDB

// Ordered revision-gated commit queue (architecture §3.14 commit ordering,
// §4.4). The runtime hands over StateCommits without blocking; this writer:
// - applies snapshots only when revision >= stored (upsert gate);
// - writes snapshot + events in ONE transaction;
// - retries transient failures, then degrades and keeps a retry backlog;
// - recovers to healthy once the backlog drains;
// - coalesces queued commits under pressure but never drops the newest
//   snapshot of any agent nor any event not yet written to disk;

/// Transaction boundary abstraction so tests can inject write failures.
public protocol StoreTransacting: Sendable {
    func write<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T
    /// Read-only access on the pool's reader connection (WAL readers never
    /// contend with the writer). Implementations may fall back to `write`
    /// where a separate reader is unavailable.
    func read<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T
}

/// Production transactor over the shared GRDB pool.
public struct PoolTransactor: StoreTransacting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func write<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await pool.write(body)
    }

    public func read<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await pool.read(body)
    }
}

/// Durable state persistence for AgentRuntime (AgentCore port).
public actor DatabaseWriter: StatePersisting {
    /// Persistence health exposed to the app's degraded-persistence banner
    /// (§3.14 step 8).
    public enum Health: Equatable, Sendable {
        case healthy
        case degraded(reason: String)
    }

    private let transactor: any StoreTransacting
    private let retryDelay: Duration
    private let maxAttempts: Int
    /// Queue depth at which same-agent commits coalesce (§3.14 step 7).
    private let coalesceThreshold: Int

    /// Incremental-append watermark (§3.14): per agent, the highest
    /// `TimelineEvent.sequence` known to be persisted. Events at or below it
    /// are already on disk, so a commit window that overlaps previously
    /// persisted history inserts only its strictly-newer tail instead of the
    /// whole ≤1000-event window.
    ///
    /// Correctness invariants:
    /// a) advances ONLY after a commit's write transaction succeeded
    ///    (`recordPersistedThrough`, called from the applyWithRetries /
    ///    retryLoop success paths — never inside the transaction);
    /// b) therefore a failed or mid-write-aborted commit keeps its events
    ///    unseen, and its equal-revision retry re-records them;
    /// c) the strictly-older revision gate still drops stale commits BEFORE
    ///    any filtering, unchanged;
    /// d) a newer commit landing while an older one sits in retryPending is
    ///    safe: when the older one later retries, either the newer window
    ///    already carried (and persisted) the older's unpersisted tail — the
    ///    watermark now covers it — or those rows were only ever carried by
    ///    the older retry payload itself, which re-inserts them; trimmed-from-
    ///    front window events are absent from newer windows only because they
    ///    were already persisted (or are carried by the older payload);
    /// e) the counter behind `sequence` is process-global and fresh each
    ///    launch, and so is this dictionary: runtime timelines also start
    ///    empty each launch (RestoreCoordinator never repopulates them), so
    ///    watermark and sequences stay consistent across relaunches.
    ///
    /// Drain×retry exclusivity (S1): the drain loop and the retry loop are
    /// independent tasks on this reentrant actor, so without a gate both can
    /// hold an in-flight transaction for the SAME agent at once, each having
    /// filtered against the same pre-overlap watermark — double-appending
    /// the shared tail. A UNIQUE(agent_id, sequence) index cannot provide
    /// the durable guarantee here: the V1 schema stores no sequence column
    /// at all (`agent_events` rows are keyed by autoincrement id), so the
    /// index would require a column-adding V2 migration to fix what one
    /// non-reentrant critical section fixes. Instead, watermark read →
    /// transaction COMMIT → watermark advance runs inside one apply slot
    /// (acquireApplySlot/releaseApplySlot): same-agent applies can no longer
    /// interleave between filtering and recording, so a retried commit always
    /// sees the watermark a concurrent drain has already advanced. Global
    /// rather than per-agent exclusivity costs nothing — the pool serializes
    /// every write on its single writer connection anyway.
    private var persistedThroughSequence: [AgentID: UInt64] = [:]

    /// §3.14 background retention hook (removes rows beyond the per-agent
    /// cap). Defaults to an EventRepository over this writer's transactor;
    /// tests inject a counting closure for deterministic triggering.
    private let retentionMaintenance: (@Sendable () async throws -> Int)?
    /// Minimum seconds between automatic retention passes.
    private let retentionInterval: TimeInterval
    private var lastRetentionAt: Date?
    /// Test seam: invoked inside the commit transaction between the snapshot
    /// upsert and event insert; a non-nil error aborts mid-write.
    private let failureInjector: (@Sendable (StateCommit) -> (any Error)?)?

    public private(set) var health: Health = .healthy

    private var queue: [StateCommit] = []
    private var draining = false
    /// Apply-slot state (S1): see the exclusivity note above the watermark.
    private var applySlotBusy = false
    private var applySlotWaiters: [CheckedContinuation<Void, Never>] = []
    private var retryPending: [StateCommit] = []
    private var retryTask: Task<Void, Never>?
    private var healthContinuations: [UUID: AsyncStream<Health>.Continuation] = [:]

    public init(
        transactor: any StoreTransacting,
        retryDelay: Duration = .milliseconds(250),
        maxAttempts: Int = 3,
        coalesceThreshold: Int = 256,
        failureInjector: (@Sendable (StateCommit) -> (any Error)?)? = nil,
        retentionMaintenance: (@Sendable () async throws -> Int)? = nil,
        retentionInterval: TimeInterval = 300
    ) {
        self.transactor = transactor
        self.retryDelay = retryDelay
        self.maxAttempts = max(1, maxAttempts)
        self.coalesceThreshold = max(2, coalesceThreshold)
        self.failureInjector = failureInjector
        if let retentionMaintenance {
            self.retentionMaintenance = retentionMaintenance
        } else {
            // Production wiring of §3.14 background maintenance: the writer
            // owns an EventRepository over its own transactor, so retention
            // needs no call-site changes anywhere in the app.
            let repository = EventRepository(transactor: transactor)
            self.retentionMaintenance = { try await repository.maintainRetention() }
        }
        self.retentionInterval = retentionInterval
    }

    /// Stream of health transitions for the persistent banner.
    public func healthUpdates() -> AsyncStream<Health> {
        AsyncStream { continuation in
            let token = UUID()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeHealthContinuation(token) }
            }
            // Registration must happen inside the actor.
            Task { self.registerHealthContinuation(token, continuation) }
        }
    }

    private func registerHealthContinuation(_ token: UUID, _ continuation: AsyncStream<Health>.Continuation) {
        // Termination may race registration in either order (onTermination
        // is installed before the registration Task runs): a token whose
        // consumer is already gone must never become a live entry, or the
        // dead continuation leaks and every health transition yields into it.
        guard !terminatedHealthTokens.contains(token) else { return }
        continuation.yield(health)
        healthContinuations[token] = continuation
    }

    private func removeHealthContinuation(_ token: UUID) {
        terminatedHealthTokens.insert(token)
        healthContinuations[token] = nil
    }

    /// Tokens observed terminated. UUIDs are never reused, so entries are
    /// permanent but tiny; the alternative — a dead continuation entry —
    /// grows with every health transition instead.
    private var terminatedHealthTokens: Set<UUID> = []

    private func setHealth(_ newHealth: Health) {
        guard health != newHealth else { return }
        health = newHealth
        for continuation in healthContinuations.values {
            continuation.yield(newHealth)
        }
    }

    // MARK: - StatePersisting

    /// Never throws and never blocks on more than its own application: after
    /// exhausting inline attempts a failed commit moves to the retry backlog
    /// and persistence degrades (§3.14 steps 6–8).
    public func commit(_ commit: StateCommit) async {
        enqueue(commit)
        await drainIfNeeded()
    }

    // MARK: - Queue

    /// Test/observability hook: current pending commit count.
    public var pendingCount: Int {
        queue.count + retryPending.count
    }

    private func enqueue(_ commit: StateCommit) {
        queue.append(commit)
        if queue.count > coalesceThreshold {
            queue = Self.coalesced(queue, watermarks: persistedThroughSequence)
        }
    }

    /// Merges consecutive commits of the same agent: the newest state wins,
    /// older events fold into it. The newest snapshot of every agent is
    /// never dropped (§3.14 step 7), and neither is any UNWRITTEN event
    /// (S2): `keepPerAgentEvents` caps only already-persisted history
    /// (sequences at or below the agent's watermark). An event above the
    /// watermark exists solely inside these queued payloads — folding it
    /// away loses it forever, because no future runtime window carries it.
    /// Agents absent from `watermarks` are treated as having watermark 0:
    /// nothing of theirs counts as persisted, so nothing is dropped.
    static func coalesced(
        _ commits: [StateCommit],
        watermarks: [AgentID: UInt64] = [:],
        keepPerAgentEvents: Int = 100
    ) -> [StateCommit] {
        var order: [AgentID] = []
        var byAgent: [AgentID: StateCommit] = [:]
        for commit in commits {
            if byAgent[commit.agentID] == nil {
                order.append(commit.agentID)
            }

            var events: [TimelineEvent] = commit.events
            var state = commit.state
            var reference = commit.sessionReference
            var session = commit.session
            if let existing = byAgent[commit.agentID] {
                // Fold older events into the survivor; cap PERSISTED history
                // only — the unwritten tail above the watermark survives the
                // fold whole (S2).
                let merged = existing.events + commit.events
                let watermark = watermarks[commit.agentID] ?? 0
                events = Array(
                    merged.filter { $0.sequence <= watermark }.suffix(keepPerAgentEvents)
                        + merged.filter { $0.sequence > watermark }
                )
                // Newest by REVISION, not enqueue order: concurrent same-agent
                // commits can enqueue out of order, and the apply-time gate
                // only protects the stored row — a folded-out higher revision
                // would never reach it (§3.14 step 7).
                if existing.state.revision > state.revision {
                    state = existing.state
                    // The reference must belong to the surviving snapshot:
                    // letting a stale commit's reference override it could
                    // resume a superseded session identity after crash recovery.
                    reference = existing.sessionReference ?? commit.sessionReference
                    // Identity travels with the surviving snapshot too —
                    // folding must never drop the only copy that could
                    // fabricate the row on first insert.
                    session = existing.session ?? commit.session
                }
            }
            byAgent[commit.agentID] = StateCommit(
                agentID: commit.agentID,
                state: state,
                events: events,
                sessionReference: reference,
                session: session
            )
        }
        return order.compactMap { byAgent[$0] }
    }

    private func drainIfNeeded() async {
        guard !draining else { return }
        draining = true
        while !queue.isEmpty {
            let commit = queue.removeFirst()
            await applyWithRetries(commit)
        }
        draining = false
        // Opportunistic §3.14 retention: once per drained burst, gated by the
        // time threshold — a no-op (one Date comparison) when not yet due.
        await maintainRetentionIfDue()
    }

    // MARK: - Application

    private func applyWithRetries(_ commit: StateCommit) async {
        for attempt in 1 ... maxAttempts {
            do {
                try await applyAndRecord(commit)
                noteSuccess()
                return
            } catch {
                guard attempt < maxAttempts else {
                    degrade("commit \(commit.agentID) rev \(commit.state.revision) failed: \(error)")
                    retryPending.append(commit)
                    startRetryLoop()
                    return
                }
                try? await Task.sleep(for: retryDelay)
            }
        }
    }

    // MARK: - Apply slot (S1)

    /// FIFO ticket for the watermark-read → transaction → watermark-advance
    /// critical section. A resumed waiter inherits `applySlotBusy = true`,
    /// so the slot is never double-granted.
    private func acquireApplySlot() async {
        if !applySlotBusy {
            applySlotBusy = true
            return
        }
        await withCheckedContinuation { applySlotWaiters.append($0) }
    }

    private func releaseApplySlot() {
        if let next = applySlotWaiters.first {
            applySlotWaiters.removeFirst()
            next.resume()
        } else {
            applySlotBusy = false
        }
    }

    /// One serialized attempt (S1): apply + watermark record inside the
    /// apply slot, so a concurrent drain/retry apply for the same agent
    /// observes the advanced watermark instead of re-inserting this
    /// attempt's tail. `noteSuccess`/retention stay outside the slot at the
    /// call sites — they are not part of the append invariant.
    private func applyAndRecord(_ commit: StateCommit) async throws {
        await acquireApplySlot()
        do {
            let appliedThrough = try await apply(commit)
            recordPersistedThrough(commit: commit, appliedThrough: appliedThrough)
        } catch {
            releaseApplySlot()
            throw error
        }
        releaseApplySlot()
    }

    /// One transaction: snapshot upsert + event append (§3.14 step 4).
    ///
    /// - Returns: the highest event sequence actually inserted, threaded up
    ///   to the caller so the watermark advances ONLY once this transaction
    ///   has committed (invariant a). A thrown error aborts the transaction,
    ///   nothing persists, and the value never reaches the watermark.
    private func apply(_ commit: StateCommit) async throws -> UInt64? {
        let injector = failureInjector
        // Snapshot of the watermark BEFORE the transaction: it defines which
        // events this window may insert. Taken INSIDE the apply slot (S1),
        // so no concurrent same-agent attempt can commit between this read
        // and ours — the overlap that previously duplicated rows is closed.
        let watermark = persistedThroughSequence[commit.agentID]
        return try await transactor.write { db in
            try Self.applySnapshot(commit, on: db)
            if let injector, let error = injector(commit) {
                throw error
            }
            return try Self.appendEvents(commit, watermark: watermark, on: db)
        }
    }

    /// Watermark advance (invariant a): called exclusively on the success
    /// paths AFTER `apply` returned without throwing, i.e. after COMMIT.
    private func recordPersistedThrough(commit: StateCommit, appliedThrough: UInt64?) {
        guard let appliedThrough else { return }
        let current = persistedThroughSequence[commit.agentID] ?? 0
        if appliedThrough > current {
            persistedThroughSequence[commit.agentID] = appliedThrough
        }
    }

    /// Revision-gated snapshot upsert (§3.14 step 5): applies only when the
    /// incoming revision is not older than what is stored. A commit carrying
    /// runtime-owned session identity for an UNREGISTERED agent inserts the
    /// full row here — persistence is self-sufficient, callers never
    /// pre-register a DB identity row. Operator/store-owned columns
    /// (`resume_requested`, `archived_at`) are only written by their own
    /// repository APIs and stay untouched on both paths.
    static func applySnapshot(_ commit: StateCommit, on db: GRDB.Database) throws {
        // Cached statements (§3.14 hot path): these two run on every commit;
        // re-preparing them per commit re-parses SQL per state change. The
        // writer serializes on one connection, so the per-connection cache
        // is always warm.
        let storedRevision = try UInt64.fetchOne(
            db.cachedStatement(sql: "SELECT last_state_revision FROM agents WHERE id = ?"),
            arguments: [commit.agentID.rawValue.uuidString]
        )
        guard let stored = storedRevision else {
            // First sight of this agent: fabricate the durable identity row
            // from the runtime-owned snapshot (§3.14 self-sufficient commit).
            guard let session = commit.session, var row = try? session.row(now: Date().timeIntervalSince1970)
            else { return }
            try row.insert(db)
            return
        }
        guard commit.state.revision >= stored else { return }
        let referenceJSON = commit.sessionReference.flatMap { try? Self.sessionRefEncoder.encode($0) }
        try db.cachedStatement(sql: """
        UPDATE agents SET
            last_lifecycle = ?,
            last_attention = ?,
            last_state_revision = ?,
            last_activity_at = ?,
            session_ref_json = ?,
            updated_at = ?
        WHERE id = ?
        """).execute(arguments: [
            LifecycleToken(phase: commit.state.lifecycle).rawValue,
            AttentionToken(state: commit.state.attention).rawValue,
            commit.state.revision,
            PersistenceTime.real(commit.state.observedAt),
            referenceJSON,
            Date().timeIntervalSince1970,
            commit.agentID.rawValue.uuidString,
        ])
    }

    /// Shared encoder for the per-commit `session_ref_json` column: the
    /// writer serializes on one queue, so reuse beats a fresh JSONEncoder
    /// allocation on every commit.
    private static let sessionRefEncoder = JSONEncoder()

    /// Appends ONLY the commit window's unpersisted tail (§3.14 incremental
    /// append): events are keyed by `TimelineEvent.sequence` against the
    /// caller-supplied watermark.
    /// - Returns: the highest `TimelineEvent.sequence` inserted, or nil when
    ///   nothing was written (stale-gate drop, or every event already
    ///   persisted under the given watermark).
    static func appendEvents(
        _ commit: StateCommit,
        watermark: UInt64?,
        on db: GRDB.Database
    ) throws -> UInt64? {
        // Unified gate (§3.14 step 5): events append exactly when the
        // snapshot half applies (same transaction, §3.14 step 4) — strictly
        // older commits are dropped so a late retried commit cannot
        // interleave the timeline, while an equal-revision retry of a
        // MID-WRITE failure re-records its events (nothing persisted on
        // failure, so the watermark did not advance — invariant b).
        // Unknown agents (no stored revision) record — the applySnapshot
        // contract: they contribute events but no identity.
        // Invariant c: this gate runs BEFORE watermark filtering, unchanged.
        // Same cached SELECT as applySnapshot (same SQL string → same
        // per-connection cache slot): one prepare, reused per commit.
        let storedRevision = try UInt64.fetchOne(
            db.cachedStatement(sql: "SELECT last_state_revision FROM agents WHERE id = ?"),
            arguments: [commit.agentID.rawValue.uuidString]
        )
        if let stored = storedRevision, commit.state.revision < stored {
            return nil
        }

        // Incremental append (§3.14): the runtime ships its whole ≤1000-event
        // window on every commit; only the tail above the watermark is new.
        var appliedThrough: UInt64?
        for timelineEvent in commit.events
            where timelineEvent.sequence > (watermark ?? 0)
        {
            let encoded = EventPayloadCodec.encode(timelineEvent.event)
            try db.cachedStatement(sql: """
            INSERT INTO agent_events (agent_id, revision, kind, source, payload_json, created_at, seen_at)
            VALUES (?, ?, ?, ?, ?, ?, NULL)
            """).execute(arguments: [
                timelineEvent.agentID.rawValue.uuidString,
                Int64(bitPattern: commit.state.revision),
                encoded.kind,
                EventPayloadCodec.runtimeSource,
                encoded.payload,
                PersistenceTime.real(timelineEvent.at),
            ])
            appliedThrough = max(appliedThrough ?? 0, timelineEvent.sequence)
        }
        return appliedThrough
    }

    // MARK: - §3.14 background retention

    /// Runs one maintenance pass when `retentionInterval` has elapsed since
    /// the last attempt. Called from the drain/retry success paths only —
    /// never from a timer — so unit tests see no uncontrolled firings.
    private func maintainRetentionIfDue(now: Date = Date()) async {
        guard let maintenance = retentionMaintenance else { return }
        if let last = lastRetentionAt, now.timeIntervalSince(last) < retentionInterval {
            return
        }
        // Stamp BEFORE running: a failing pass must not turn every following
        // commit into an immediate retry hammer.
        lastRetentionAt = now
        _ = await performRetention(maintenance)
    }

    /// Deterministic test/observability seam: forces one retention pass NOW,
    /// independent of the time threshold.
    ///
    /// - Returns: rows removed, or nil when no maintenance hook is configured
    ///   or the pass failed (retention failures never degrade commit health).
    @discardableResult
    public func runRetentionMaintenanceNow() async -> Int? {
        guard let maintenance = retentionMaintenance else { return nil }
        return await performRetention(maintenance)
    }

    private func performRetention(_ maintenance: @Sendable () async throws -> Int) async -> Int? {
        do {
            return try await maintenance()
        } catch {
            // Housekeeping failure ≠ commit failure: §3.14 step 8 degradation
            // is reserved for lost commits. The next due pass retries.
            return nil
        }
    }

    // MARK: - Degraded / recovery

    private func degrade(_ reason: String) {
        setHealth(.degraded(reason: reason))
    }

    private func noteSuccess() {
        if retryPending.isEmpty {
            setHealth(.healthy)
        }
    }

    private func startRetryLoop() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            await self?.retryLoop()
        }
    }

    private func retryLoop() async {
        // Rotation instead of head-only retry: a permanently failing entry
        // must not block later commits that would succeed, and the loop must
        // terminate rather than spin on a poisoned head forever.
        // Attempt counts are keyed per agent AND revision: revisions are
        // per-agent monotonic, so a bare revision key collides across agents
        // and one agent's commit gets dropped early on the other's count.
        var attempts: [AgentID: [UInt64: Int]] = [:]
        while !retryPending.isEmpty {
            try? await Task.sleep(for: retryDelay)
            let head = retryPending.removeFirst()
            do {
                try await applyAndRecord(head)
                attempts[head.agentID]?[head.state.revision] = nil
                noteSuccess()
                await maintainRetentionIfDue()
            } catch {
                let count = (attempts[head.agentID]?[head.state.revision] ?? 0) + 1
                attempts[head.agentID, default: [:]][head.state.revision] = count
                if count >= maxAttempts {
                    degrade("retry dropped after \(count) attempts: \(error)")
                    attempts[head.agentID]?[head.state.revision] = nil
                } else {
                    retryPending.append(head)
                }
            }
        }
        // Deliberate: a POLICY DROP is not recovery — a commit was just
        // lost, so health stays .degraded until the next successful commit
        // proves the writer works again (noteSuccess; pinned by
        // testRetryLoopDropsPoisonedEntryAfterMaxAttemptsAndStaysDegradedUntilRecovery).
        retryTask = nil
        // A drain may have appended while the loop was finishing.
        if !retryPending.isEmpty {
            startRetryLoop()
        }
    }
}

import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// DatabaseWriter semantics (architecture §3.14 commit ordering):
// revision gating, single-transaction snapshot+event, retry/degraded/recovery,
// coalescing under queue pressure.

final class DatabaseWriterTests: XCTestCase {
    nonisolated func fetchRevision(_ database: GRDB.Database, agentID: AgentID) throws -> UInt64? {
        try UInt64.fetchOne(
            database,
            sql: "SELECT last_state_revision FROM agents WHERE id = ?",
            arguments: [agentID.rawValue.uuidString]
        )
    }

    // MARK: Shared context

    struct Context {
        var dir: URL
        var db: AgentDatabase
        var writer: StoreWriter
        var agentID: AgentID
    }

    func makeContext() async throws -> (AgentDatabase, Context) {
        let dir = try TestEnv.makeTempDirectory()
        let db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        let session = makeSession(workspace: workspace)
        try await AgentRepository(database: db).save(session)
        let writer = DatabaseWriter(transactor: PoolTransactor(pool: db.pool), retryDelay: .milliseconds(1))
        return (db, Context(dir: dir, db: db, writer: writer, agentID: session.id))
    }
}

// MARK: - Round 22 file-local fixture

/// Lock-guarded log of degraded-health reasons, filled by a healthUpdates()
/// collector task; lets DW1 assert the drop degradation fired regardless of
/// which backlog entry drains last.
final class DegradationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []

    func record(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        reasons.append(reason)
    }

    func contains(_ fragment: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reasons.contains { $0.contains(fragment) }
    }
}

// MARK: - Round 19 file-local fixtures

struct WriterPoisonError: Error {}

/// Lock-guarded failure script keyed by revision: `poisonedForever` revisions
/// fail EVERY apply; `exhaustIntoRetry` revisions fail exactly the scripted
/// number of times (pushing them THROUGH inline exhaustion into the retry
/// backlog) and succeed afterwards. Mirrors DatabaseWriterTests' OnceInjector
/// pattern.
final class ScriptedFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let poisonedForever: Set<UInt64>
    private var exhaustRemaining: [UInt64: Int]

    init(poisonedForever: Set<UInt64>, exhaustIntoRetry: [UInt64: Int]) {
        self.poisonedForever = poisonedForever
        exhaustRemaining = exhaustIntoRetry
    }

    func error(for revision: UInt64) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if poisonedForever.contains(revision) {
            return WriterPoisonError()
        }
        if let left = exhaustRemaining[revision], left > 0 {
            exhaustRemaining[revision] = left - 1
            return WriterPoisonError()
        }
        return nil
    }
}

// MARK: - Round 28 file-local fixture

/// Failure predicate keyed by AGENT (not revision): `persistentFailures`
/// agents fail EVERY apply; `exhaustIntoRetry` agents fail exactly the
/// scripted number of times and succeed afterwards. Extends the
/// ScriptedFailureInjector poison mechanism to a per-agent seam.
final class PerAgentFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let persistentFailures: Set<AgentID>
    private var exhaustRemaining: [AgentID: Int]

    init(persistentFailures: Set<AgentID>, exhaustIntoRetry: [AgentID: Int]) {
        self.persistentFailures = persistentFailures
        exhaustRemaining = exhaustIntoRetry
    }

    func error(for commit: StateCommit) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if persistentFailures.contains(commit.agentID) {
            return WriterPoisonError()
        }
        if let left = exhaustRemaining[commit.agentID], left > 0 {
            exhaustRemaining[commit.agentID] = left - 1
            return WriterPoisonError()
        }
        return nil
    }
}

// MARK: - Retention wiring fixture

/// Lock-guarded pass counter for injected retention maintenance closures
/// (@Sendable closures cannot mutate captured locals — Swift 6).
final class RetentionPassLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock { count += 1 }
    }

    var total: Int {
        lock.withLock { count }
    }
}

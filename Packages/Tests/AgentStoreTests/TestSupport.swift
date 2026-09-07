import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Shared fixtures for the AgentStore behavioral suite.

enum TestEnv {
    /// Isolated temporary directory per test.
    static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeDatabase(in dir: URL, name: String = "test.sqlite") throws -> AgentDatabase {
        try AgentDatabase(
            databaseURL: dir.appendingPathComponent(name),
            backupDirectoryURL: dir.appendingPathComponent("backups")
        )
    }

    static func rowCount(_ db: AgentDatabase, _ table: String) async throws -> Int {
        let poolTransactor = PoolTransactor(pool: db.pool)
        return try await poolTransactor.write { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    static func scalar(_ db: AgentDatabase, _ sql: String,
                       _ arguments: [any DatabaseValueConvertible] = []) async throws -> (any DatabaseValueConvertible)?
    {
        let databaseValues = arguments.map(\.databaseValue)
        let poolTransactor = PoolTransactor(pool: db.pool)
        return try await poolTransactor.write { database in
            try String.fetchOne(database, sql: sql, arguments: StatementArguments(databaseValues))
        }
    }

    static func backupFiles(in dir: URL) throws -> [URL] {
        let backups = dir.appendingPathComponent("backups")
        guard FileManager.default.fileExists(atPath: backups.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
    }

    /// Polls an async predicate until satisfied or timeout (concurrency tests).
    static func waitFor(
        timeout: TimeInterval = 3,
        interval: TimeInterval = 0.01,
        _ predicate: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    /// Polls until the async body returns non-nil.
    static func waitForResult<T: Equatable>(
        timeout: TimeInterval = 3,
        interval: TimeInterval = 0.01,
        _ body: () async throws -> T?
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try await body() {
                return value
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        XCTFail("value not produced within \(timeout)s")
        throw CancellationError()
    }
}

/// GRDB also declares a `DatabaseWriter` protocol; qualify the store type.
typealias StoreWriter = AgentStore.DatabaseWriter

/// Persists a workspace row first — agents.terminals reference it via FK.
func installWorkspace(_ db: AgentDatabase, _ workspace: Workspace) async throws {
    try await db.pool.write { database in
        var row = workspace.row(sortIndex: 0)
        try row.upsert(database)
    }
}

@discardableResult
func makeWorkspace(name: String = "WS") -> Workspace {
    Workspace(
        name: name,
        rootPath: "/tmp/project-\(name)",
        createdAt: MonotonicInstant(nanosecondsSinceEpoch: 1_000_000_000),
        updatedAt: MonotonicInstant(nanosecondsSinceEpoch: 2_000_000_000)
    )
}

func makeDescriptor(kind: AgentKind = .claudeCode) -> LaunchDescriptor {
    LaunchDescriptor(
        agentKind: kind,
        program: "/usr/local/bin/agent",
        arguments: ["--model", "default"],
        workingDirectory: "/tmp/project",
        environment: ["AGENT_MODE": "workspace"]
    )
}

@discardableResult
func makeSession(workspace: Workspace, revision: UInt64 = 0) -> AgentSession {
    AgentSession(
        workspaceID: workspace.id,
        kind: .claudeCode,
        displayName: "Claude #1",
        taskSummary: "refactor store",
        cwd: "/tmp/project",
        launchDescriptor: makeDescriptor(),
        resumePolicy: .automatic,
        state: AgentState(
            process: .running(pid: 4242, processGroupID: 4242),
            lifecycle: .idle,
            attention: .none,
            authority: .process,
            revision: revision,
            observedAt: MonotonicInstant(nanosecondsSinceEpoch: 3_000_000_000)
        ),
        createdAt: MonotonicInstant(nanosecondsSinceEpoch: 1_500_000_000),
        lastActivityAt: MonotonicInstant(nanosecondsSinceEpoch: 2_500_000_000)
    )
}

// MARK: - Injectable transactors

/// Fails the first `failuresRemaining` writes, then passes through.
final class FlakyTransactor: StoreTransacting, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int
    private let base: PoolTransactor
    private(set) var lastError: Error?

    init(base: PoolTransactor, failuresRemaining: Int) {
        self.base = base
        self.failuresRemaining = failuresRemaining
    }

    func setFailuresRemaining(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        failuresRemaining = count
    }

    func write<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        let shouldInjectFailure = lock.withLock {
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        if shouldInjectFailure {
            throw TransactorError.injected
        }
        return try await base.write(body)
    }

    /// Reads bypass the failure injection: FlakyTransactor exists to inject
    /// WRITE failures, and reads never touched the injection path before.
    func read<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await base.read(body)
    }

    enum TransactorError: Error { case injected }
}

/// Blocks every write until `release()` is called; then passes through.
final class GatedTransactor: StoreTransacting, @unchecked Sendable {
    private let lock = NSLock()
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let base: PoolTransactor
    private(set) var writeCount = 0

    init(base: PoolTransactor) {
        self.base = base
    }

    func hold() {
        lock.lock(); defer { lock.unlock() }
        holding = true
    }

    func release() {
        lock.lock()
        holding = false
        let resumed = waiting
        waiting.removeAll()
        lock.unlock()
        for continuation in resumed {
            continuation.resume()
        }
    }

    /// Number of writes currently parked inside the gate — lets tests
    /// confirm a write armed instead of sleeping a fixed settle time.
    var waitingCount: Int {
        lock.withLock { waiting.count }
    }

    func write<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        let wasHolding = lock.withLock { holding }
        if wasHolding {
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
        }
        let result = try await base.write(body)
        lock.withLock { writeCount += 1 }
        return result
    }

    /// Reads pass straight through: the gate exists to hold WRITES open
    /// while a backlog builds.
    func read<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await base.read(body)
    }
}

extension MonotonicInstant {
    static func ns(_ value: Int64) -> MonotonicInstant {
        MonotonicInstant(nanosecondsSinceEpoch: value)
    }
}

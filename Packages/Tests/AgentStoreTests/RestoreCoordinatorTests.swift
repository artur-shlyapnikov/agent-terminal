import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Stage-12 behavioral suite (§3.15): restore plan generation, crash recovery,
// app_runs transitions and the quit-path persistence seams.

final class RestoreCoordinatorTests: XCTestCase {
    // MARK: - Fixtures

    private var dir: URL!
    private var db: AgentDatabase!

    override func setUpWithError() throws {
        dir = try TestEnv.makeTempDirectory()
        db = try TestEnv.makeDatabase(in: dir)
        try db.migrate()
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeCoordinator(catalog: AgentCatalog = .standard()) -> RestoreCoordinator {
        RestoreCoordinator(transactor: PoolTransactor(pool: db.pool), catalog: catalog)
    }

    /// Persists a workspace + agent row exactly the way the runtime's
    /// DatabaseWriter/AgentRepository would, with explicit control over the
    /// lifecycle token, terminal id, session reference and resume flag.
    @discardableResult
    private func installAgent(
        kind: AgentKind,
        lifecycle: LifecycleToken,
        terminal: Bool = true,
        reference: SessionReference? = nil,
        refJSON: Data? = nil,
        resumeRequested: Bool = false,
        archived: Bool = false,
        displayName: String = "Agent"
    ) async throws -> AgentRow {
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        // Explicit resolution: `??` cannot chain two optionals.
        var resolvedSessionRef = refJSON
        if resolvedSessionRef == nil, let reference {
            resolvedSessionRef = try JSONEncoder().encode(reference)
        }
        var row = try AgentRow(
            id: UUID().uuidString,
            workspaceID: workspace.id.rawValue.uuidString,
            terminalID: terminal ? UUID().uuidString : nil,
            kind: kind.rawValue,
            displayName: displayName,
            taskSummary: nil,
            cwd: "/tmp/project",
            launchDescriptorJSON: JSONEncoder().encode(makeDescriptor(kind: kind)),
            resumePolicy: reference == nil ? ResumePolicy.none.rawValue : ResumePolicy.automatic.rawValue,
            sessionRefJSON: resolvedSessionRef,
            lastLifecycle: lifecycle.rawValue,
            lastAttention: AttentionToken.none.rawValue,
            lastStateRevision: 7,
            lastActivityAt: 1000,
            resumeRequested: resumeRequested,
            createdAt: 500,
            updatedAt: 1500,
            archivedAt: archived ? 2000 : nil
        )
        row = try await db.pool.write { [row] database -> AgentRow in
            var updated = row
            try updated.upsert(database)
            return updated
        }
        return row
    }

    private func flaggedClaudeReference(payload: String = "session-abc") -> SessionReference {
        SessionReference(agentKind: .claudeCode, opaquePayload: payload)
    }

    // MARK: - Clean restore (§3.15 steps 5–9)

    func testCleanRestoreHonorsResumeRequestedWithValidReference() async throws {
        let claude = try await installAgent(
            kind: .claudeCode, lifecycle: .idle,
            reference: flaggedClaudeReference(), resumeRequested: true
        )
        // Not flagged — must never appear in the plan.
        _ = try await installAgent(
            kind: .codex, lifecycle: .working,
            reference: SessionReference(agentKind: .codex, opaquePayload: "t-1")
        )

        let plan = try await makeCoordinator().prepareStartup()

        guard case let .clean(clean) = plan else {
            return XCTFail("expected clean plan, got \(plan)")
        }
        XCTAssertEqual(clean.resumes.count, 1)
        let action = try XCTUnwrap(clean.resumes.first)
        XCTAssertEqual(action.persistedAgentID, try AgentID(rawValue: XCTUnwrap(UUID(uuidString: claude.id))))
        XCTAssertEqual(action.kind, .claudeCode)
        XCTAssertEqual(action.sessionReference.opaquePayload, "session-abc")
        XCTAssertEqual(action.resumeSpec.argv, ["claude", "--resume", "session-abc"])
        XCTAssertTrue(clean.unsupported.isEmpty)
        // A fresh run row opened for this process.
        XCTAssertGreaterThan(plan.currentRunID, 0)
    }

    func testCleanRestoreExcludesAndReportsInvalidReferences() async throws {
        // Flagged but NO reference captured.
        try await installAgent(
            kind: .claudeCode, lifecycle: .idle, reference: nil, resumeRequested: true,
            displayName: "NoRef"
        )
        // Flagged with a reference the adapter rejects (kind mismatch).
        try await installAgent(
            kind: .claudeCode, lifecycle: .idle,
            reference: SessionReference(agentKind: .codex, opaquePayload: "wrong-kind"),
            resumeRequested: true, displayName: "KindMismatch"
        )
        // Flagged with undecodable reference JSON.
        try await installAgent(
            kind: .claudeCode, lifecycle: .idle, refJSON: Data("not-json".utf8),
            resumeRequested: true, displayName: "CorruptRef"
        )
        // Flagged generic shell — never resumable (§3.10).
        try await installAgent(
            kind: .genericShell, lifecycle: .idle,
            reference: SessionReference(agentKind: .genericShell, opaquePayload: "sh"),
            resumeRequested: true, displayName: "Shell"
        )

        let plan = try await makeCoordinator().prepareStartup()

        guard case let .clean(clean) = plan else {
            return XCTFail("expected clean plan")
        }
        XCTAssertTrue(clean.resumes.isEmpty, "invalid refs must be excluded, not launched")
        // An undecodable reference blob is data corruption (§3.15), not an
        // adapter-capability report: it surfaces as a crash candidate.
        XCTAssertEqual(clean.unsupported.count, 3, clean.unsupported.map(\.displayName).debugDescription)
        let byName = Dictionary(uniqueKeysWithValues: clean.unsupported.map { ($0.displayName, $0) })
        XCTAssertEqual(byName["NoRef"]?.reason, .missingSessionReference)
        XCTAssertEqual(byName["KindMismatch"]?.reason, .adapterUnsupported)
        XCTAssertEqual(byName["Shell"]?.reason, .adapterUnsupported)
        XCTAssertEqual(clean.crashCandidates.count, 1, clean.crashCandidates.map(\.displayName).debugDescription)
        XCTAssertEqual(clean.crashCandidates.first?.displayName, "CorruptRef")
    }

    func testCleanRestoreAfterCleanQuitHasNoUnclosedRuns() async throws {
        let runs = AppRunRepository(transactor: PoolTransactor(pool: db.pool))
        let oldRun = try await runs.beginRun()
        try await runs.endRun(oldRun, kind: .clean)
        // Nothing left open BEFORE this startup opens its own row.
        let openBefore = try await runs.detectUnclosedRuns()
        XCTAssertTrue(openBefore.isEmpty)

        let plan = try await makeCoordinator().prepareStartup()
        guard case .clean = plan else { return XCTFail("clean quit must restore, not recover") }
        // Exactly one unclosed row remains: THIS process's fresh run row.
        let open = try await runs.detectUnclosedRuns()
        XCTAssertEqual(open.map(\.id), [plan.currentRunID])
    }

    // MARK: - Crash recovery (§3.15: no automatic starts)

    func testCrashRecoveryListsRunningAgentsWithoutAutoStart() async throws {
        // Previous run never ended — the crash.
        _ = try await AppRunRepository(transactor: PoolTransactor(pool: db.pool)).beginRun()
        _ = try await installAgent(
            kind: .claudeCode, lifecycle: .idle,
            reference: flaggedClaudeReference(), displayName: "IdleClaude"
        )
        _ = try await installAgent(
            kind: .openCode, lifecycle: .working, displayName: "WorkingOpen"
        )
        _ = try await installAgent(
            kind: .codex, lifecycle: .stoppedCompleted,
            reference: SessionReference(agentKind: .codex, opaquePayload: "t-9"),
            displayName: "StoppedCodex"
        )

        let plan = try await makeCoordinator().prepareStartup()

        guard case let .crashRecovery(recovery) = plan else {
            return XCTFail("unclosed run must produce a recovery plan, got \(plan)")
        }
        XCTAssertEqual(recovery.unclosedRuns.count, 1)
        // Only previously-RUNNING agents become candidates; stopped ones do not.
        let names = recovery.candidates.map(\.displayName).sorted()
        XCTAssertEqual(names, ["IdleClaude", "WorkingOpen"])
        // Old session reference preserved until successful new launch.
        let claudeCandidate = try XCTUnwrap(recovery.candidates.first { $0.displayName == "IdleClaude" })
        XCTAssertEqual(claudeCandidate.sessionReference?.opaquePayload, "session-abc")
        XCTAssertTrue(claudeCandidate.canResume)
        let openCandidate = try XCTUnwrap(recovery.candidates.first { $0.displayName == "WorkingOpen" })
        XCTAssertNil(openCandidate.sessionReference)
        XCTAssertFalse(openCandidate.canResume)
        XCTAssertEqual(openCandidate.unsupportedReason, .missingSessionReference)
        // §3.15 structural guarantee: CrashRecoveryPlan carries NO launch or
        // resume actions — only candidates for the Recovery Center — so
        // nothing can auto-start after a crash. That law is enforced by the
        // type's shape (no action collection exists to assert against); the
        // candidate list above already proves stopped agents are excluded.
    }

    func testCrashRecoveryMarksPreviousRunsUncleanAndOpensNewRun() async throws {
        let runs = AppRunRepository(transactor: PoolTransactor(pool: db.pool))
        let crashed = try await runs.beginRun()
        _ = try await installAgent(kind: .claudeCode, lifecycle: .idle)

        let plan = try await makeCoordinator().prepareStartup()

        guard case .crashRecovery = plan else { return XCTFail("expected recovery plan") }
        try await TestEnv.waitFor {
            let closed = try await self.db.pool.read { db in
                try AppRunRow.filter(Column("id") == crashed).fetchOne(db)
            }
            return closed?.endedAt != nil
                && closed?.terminationKind == TerminationKind.unclean.rawValue
        }
        XCTAssertGreaterThan(plan.currentRunID, crashed)
    }

    func testUncleanCrashWithNoCandidatesDegradesToCleanPlan() async throws {
        // Previous run died uncleanly (never ended) but left nothing
        // recoverable: the only agent row is stopped. A zero-candidate
        // recovery plan must not wedge startup as recovery-pending — the
        // app skips the empty Recovery Center yet defers keying the main
        // window, so every subsequent launch would start as an unkeyed
        // zombie (observed with automation harnesses that kill instances).
        let runs = AppRunRepository(transactor: PoolTransactor(pool: db.pool))
        let crashed = try await runs.beginRun()
        _ = try await installAgent(
            kind: .claudeCode, lifecycle: .stoppedCompleted,
            reference: flaggedClaudeReference(), resumeRequested: true
        )

        let plan = try await makeCoordinator().prepareStartup()

        guard case let .clean(clean) = plan else {
            return XCTFail("zero-candidate crash must degrade to a clean plan, got \(plan)")
        }
        // §3.15: no automatic restarts after a crash — the resumeRequested
        // row stays suppressed even though its reference is valid.
        XCTAssertTrue(clean.resumes.isEmpty)
        XCTAssertTrue(clean.crashCandidates.isEmpty)
        XCTAssertTrue(clean.unsupported.isEmpty)
        XCTAssertGreaterThan(clean.currentRunID, crashed)
        // The stale run row is still closed as unclean: audit trail kept.
        let closed = try await db.pool.read { database in
            try AppRunRow.filter(Column("id") == crashed).fetchOne(database)
        }
        XCTAssertEqual(closed?.terminationKind, TerminationKind.unclean.rawValue)
        XCTAssertNotNil(closed?.endedAt)
    }

    func testArchivedAgentsNeverAppearInAnyPlan() async throws {
        _ = try await AppRunRepository(transactor: PoolTransactor(pool: db.pool)).beginRun()
        try await installAgent(
            kind: .claudeCode, lifecycle: .idle,
            reference: flaggedClaudeReference(), resumeRequested: true, archived: true
        )

        let plan = try await makeCoordinator().prepareStartup()
        switch plan {
        case let .clean(clean):
            XCTAssertTrue(clean.resumes.isEmpty)
            XCTAssertTrue(clean.unsupported.isEmpty)
        case let .crashRecovery(recovery):
            XCTAssertTrue(recovery.candidates.isEmpty)
        }
    }

    func testPreviouslyRunningDetectionCoversLiveTokensOnly() {
        func row(_ lifecycle: LifecycleToken, terminal: Bool = true) -> AgentRow {
            AgentRow(
                id: UUID().uuidString, workspaceID: UUID().uuidString,
                terminalID: terminal ? UUID().uuidString : nil,
                kind: AgentKind.claudeCode.rawValue, displayName: "A", taskSummary: nil,
                cwd: "/tmp", launchDescriptorJSON: Data("{}".utf8),
                resumePolicy: "manual", sessionRefJSON: nil,
                lastLifecycle: lifecycle.rawValue, lastAttention: "none",
                lastStateRevision: 0, lastActivityAt: nil, resumeRequested: false,
                createdAt: 0, updatedAt: 0, archivedAt: nil
            )
        }
        for live: LifecycleToken in [.starting, .idle, .working, .waitingForInput, .stopping] {
            XCTAssertTrue(RestoreCoordinator.isPreviouslyRunning(row(live)), live.rawValue)
        }
        for dead: LifecycleToken in [.stoppedUserRequested, .stoppedCompleted, .failed, .unknown] {
            XCTAssertFalse(RestoreCoordinator.isPreviouslyRunning(row(dead)), dead.rawValue)
        }
        XCTAssertFalse(RestoreCoordinator.isPreviouslyRunning(row(.idle, terminal: false)),
                       "no persisted terminal → not previously running")
    }

    // MARK: - Round 19 (cd7c66b store laws)

    /// A1: `beginRun(closing:)` must close every unclosed run `.unclean` at
    /// the supplied `endedAt` AND insert the new open row inside ONE
    /// `transactor.write` call. Pre-cd7c66b these were two writes
    /// (`endRun` loop then `beginRun`), leaving a crash window where zero
    /// unclosed rows make the next launch misread a crash as clean (§3.15).
    func testBeginRunClosingIsASingleTransactionAndStampsUncleanTermination() async throws {
        let counting = CountingTransactor(base: PoolTransactor(pool: db.pool))
        let runs = AppRunRepository(transactor: counting)
        _ = try await runs.beginRun()
        _ = try await runs.beginRun()
        let endedAt = Date(timeIntervalSince1970: 1000)

        // Detection is its own call; the ACT under test starts afterwards.
        let unclosed = try await runs.detectUnclosedRuns()
        XCTAssertEqual(unclosed.count, 2)
        let before = counting.writeCalls
        let newID = try await runs.beginRun(closing: unclosed, endedAt: endedAt)
        // THE atomicity pin: close-everything + open-new-row is exactly ONE
        // write. A regression back to the two-call shape fails here even if
        // the end state looks right.
        XCTAssertEqual(counting.writeCalls - before, 1)

        // Read through the pool, bypassing the counting wrapper.
        let rows = try db.pool.read { database -> [Row] in
            try Row.fetchAll(
                database,
                sql: "SELECT id, ended_at, termination_kind FROM app_runs ORDER BY id ASC"
            )
        }
        XCTAssertEqual(rows.count, 3)
        for row in rows.dropLast() {
            XCTAssertEqual(row["ended_at"] as Double?, endedAt.timeIntervalSince1970, "old run must close at endedAt")
            XCTAssertEqual(row["termination_kind"] as String?, TerminationKind.unclean.rawValue)
        }
        let fresh = try XCTUnwrap(rows.last)
        XCTAssertEqual(fresh["id"] as Int64?, newID)
        XCTAssertNil(fresh["ended_at"] as Double?, "the new run row must be open")
        XCTAssertNil(fresh["termination_kind"] as String?)

        // Degenerate case folded in: an empty closing list still opens the
        // new run row in exactly one write.
        let beforeEmpty = counting.writeCalls
        let emptyID = try await runs.beginRun(closing: [], endedAt: endedAt)
        XCTAssertEqual(counting.writeCalls - beforeEmpty, 1)
        XCTAssertGreaterThan(emptyID, newID)
    }

    /// A2: a persisted agent whose adapter builds a VALID reference but an
    /// EMPTY argv must yield NO resume launch material — pre-cd7c66b an
    /// empty-argv "valid" spec auto-launched a commandless process at boot.
    /// It surfaces as a recovery candidate that cannot resume
    /// (`canResume == false`, reason `.adapterUnsupported`).
    func testEmptyArgvResumeSpecClassifiesAsRecoveryNotResumeAction() async throws {
        // An unclosed previous run forces the crash-recovery branch (§3.15).
        _ = try await AppRunRepository(transactor: PoolTransactor(pool: db.pool)).beginRun()
        _ = try await installAgent(
            kind: .claudeCode,
            lifecycle: .idle,
            reference: flaggedClaudeReference(),
            resumeRequested: true,
            displayName: "EmptyArgv"
        )
        let catalog = AgentCatalog(adapters: [EmptyArgvStubAdapter(servedKind: .claudeCode)])

        let plan = try await makeCoordinator(catalog: catalog).prepareStartup()

        guard case let .crashRecovery(recovery) = plan else {
            return XCTFail("expected recovery plan, got \(plan)")
        }
        XCTAssertEqual(recovery.candidates.map(\.displayName), ["EmptyArgv"])
        let candidate = try XCTUnwrap(recovery.candidates.first)
        XCTAssertFalse(candidate.canResume, "an empty-argv spec must never become launchable")
        XCTAssertEqual(candidate.unsupportedReason, .adapterUnsupported)
        XCTAssertNotNil(candidate.sessionReference, "the reference decodes — only argv emptiness blocks resume")
    }
}

// MARK: - Round 19 file-local fixtures

/// Counts transactor writes BEFORE the body runs, so a throwing write is
/// counted too (mirrors the FlakyTransactor pattern in TestSupport).
private final class CountingTransactor: StoreTransacting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let base: PoolTransactor

    init(base: PoolTransactor) {
        self.base = base
    }

    var writeCalls: Int {
        lock.withLock { calls }
    }

    func write<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        lock.withLock { calls += 1 }
        return try await base.write(body)
    }

    func read<T: Sendable>(_ body: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await base.read(body)
    }
}

/// Test-only adapter whose resume spec is VALID but carries an EMPTY argv —
/// protocol conformance mirrors GenericShellAdapter's shape.
private struct EmptyArgvStubAdapter: AgentAdapter {
    let servedKind: AgentKind

    var id: String {
        "empty-argv-stub"
    }

    var displayName: String {
        "EmptyArgvStub"
    }

    var capabilities: AgentIntegrationCapability {
        AgentIntegrationCapability(sessionIdentity: true, lifecycle: .none, screenFallback: false)
    }

    var executableCandidates: [String] {
        []
    }

    var bundledManifestName: String? {
        nil
    }

    var bundledAgentKind: AgentKind? {
        servedKind
    }

    func makeLaunchDescriptor(request _: AgentLaunchRequest) throws -> LaunchDescriptor {
        LaunchDescriptor(agentKind: servedKind, program: "/usr/local/bin/agent", workingDirectory: "/tmp/project")
    }

    func buildLaunchSpec(descriptor: LaunchDescriptor) -> LaunchSpec {
        LaunchSpec(
            argv: [descriptor.program] + descriptor.arguments,
            environment: descriptor.environment,
            workingDirectory: descriptor.workingDirectory
        )
    }

    func buildResumeSpec(sessionReference _: SessionReference) -> ResumeSpec? {
        ResumeSpec(argv: [], environment: [:], workingDirectory: "/tmp/project")
    }

    func integrationInstallPlan() -> IntegrationInstallPlan {
        .empty(adapterID: id)
    }
}

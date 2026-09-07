import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Final-fix regression coverage:
//
//  1. superseded resume rows — a confirmed resume ARCHIVES the persisted
//     row (§3.15 step 9), so a later crash lists only agents that were
//     genuinely running (dead terminal_id + live lifecycle token can no
//     longer pollute the Recovery Center);
//  2. quit-and-stop teardown — clearResumeRequested() disarms every stale
//     flag so the next boot never auto-executes a superseded resume intent.

final class SupersededResumeTests: XCTestCase {
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

    private func makeCoordinator() -> RestoreCoordinator {
        RestoreCoordinator(transactor: PoolTransactor(pool: db.pool))
    }

    private func makeRepository() -> AgentRepository {
        AgentRepository(transactor: PoolTransactor(pool: db.pool))
    }

    /// Persists a workspace + agent row with explicit control over the
    /// lifecycle token, terminal id, session reference and resume flag.
    @discardableResult
    private func installAgent(
        kind: AgentKind,
        lifecycle: LifecycleToken,
        reference: SessionReference? = nil,
        resumeRequested: Bool = false,
        displayName: String = "Agent"
    ) async throws -> AgentRow {
        let workspace = makeWorkspace()
        try await installWorkspace(db, workspace)
        var row = try AgentRow(
            id: UUID().uuidString,
            workspaceID: workspace.id.rawValue.uuidString,
            terminalID: UUID().uuidString,
            kind: kind.rawValue,
            displayName: displayName,
            taskSummary: nil,
            cwd: "/tmp/project",
            launchDescriptorJSON: JSONEncoder().encode(makeDescriptor(kind: kind)),
            resumePolicy: ResumePolicy.automatic.rawValue,
            sessionRefJSON: reference.map { try JSONEncoder().encode($0) },
            lastLifecycle: lifecycle.rawValue,
            lastAttention: AttentionToken.none.rawValue,
            lastStateRevision: 7,
            lastActivityAt: 1000,
            resumeRequested: resumeRequested,
            createdAt: 500,
            updatedAt: 1500,
            archivedAt: nil
        )
        row = try await db.pool.write { [row] database -> AgentRow in
            var updated = row
            try updated.upsert(database)
            return updated
        }
        return row
    }

    private func flaggedReference(payload: String = "session-abc") -> SessionReference {
        SessionReference(agentKind: .claudeCode, opaquePayload: payload)
    }

    // MARK: 1 — archived superseded row never resurfaces

    func testResumeCycleThenCrashExcludesArchivedSupersededRow() async throws {
        // Resume cycle: flagged claude row → validated resume action.
        let old = try await installAgent(
            kind: .claudeCode, lifecycle: .idle,
            reference: flaggedReference(), resumeRequested: true,
            displayName: "Superseded"
        )
        let plan = try await makeCoordinator().prepareStartup()
        guard case let .clean(clean) = plan else {
            return XCTFail("expected clean plan, got \(plan)")
        }
        XCTAssertEqual(clean.resumes.count, 1)

        // Confirmed launch tail (AgentExecutionCoordinator §3.15 step 9): consume the
        // flag AND archive the superseded row once the launch is confirmed;
        // the successor session registers its own fresh row.
        let repository = makeRepository()
        let oldID = try AgentID(rawValue: XCTUnwrap(UUID(uuidString: old.id)))
        try await repository.setResumeRequested(false, agentID: oldID)
        try await repository.archive(oldID)
        _ = try await installAgent(
            kind: .claudeCode, lifecycle: .working,
            reference: flaggedReference(payload: "successor"),
            displayName: "Resumed"
        )

        // Simulated crash: this process's run row stays open → next boot.
        let relaunch = try await makeCoordinator().prepareStartup()
        guard case let .crashRecovery(recovery) = relaunch else {
            return XCTFail("expected crash-recovery plan after unclean run, got \(relaunch)")
        }
        XCTAssertFalse(recovery.candidates.contains { $0.displayName == "Superseded" },
                       "the archived superseded row must never list as previously-running")
        XCTAssertTrue(recovery.candidates.contains { $0.displayName == "Resumed" },
                      "the live successor IS a genuine recovery candidate")
        let archivedCount = try await TestEnv.scalar(
            db, "SELECT COUNT(*) FROM agents WHERE archived_at IS NOT NULL"
        )
        XCTAssertEqual(archivedCount as? String, "1")
        let detachedTerminal = try await TestEnv.scalar(
            db, "SELECT terminal_id FROM agents WHERE id = '\(old.id)'"
        )
        XCTAssertNil(detachedTerminal)
    }

    // MARK: 2 — quit-and-stop clears stale resume intent

    func testClearResumeRequestedDisarmsStaleFlagsBeforeNextBoot() async throws {
        // A FAILED resume cycle left the flag armed (launch never confirmed).
        _ = try await installAgent(
            kind: .claudeCode, lifecycle: .idle,
            reference: flaggedReference(), resumeRequested: true,
            displayName: "StaleFlag"
        )
        _ = try await installAgent(
            kind: .codex, lifecycle: .idle,
            reference: SessionReference(agentKind: .codex, opaquePayload: "t-2"),
            resumeRequested: true, displayName: "StaleFlag2"
        )

        // 'Quit and Stop Agents' teardown (markResumeRequested == false).
        try await makeRepository().clearResumeRequested()

        // Next boot: NO auto-resume against the stale intent.
        let plan = try await makeCoordinator().prepareStartup()
        guard case let .clean(clean) = plan else {
            return XCTFail("expected clean plan, got \(plan)")
        }
        XCTAssertTrue(clean.resumes.isEmpty, "no flagged row may auto-resume after quit-and-stop")
        let flaggedCount = try await TestEnv.scalar(
            db, "SELECT COUNT(*) FROM agents WHERE resume_requested = 1"
        )
        XCTAssertEqual(flaggedCount as? String, "0")
    }
}

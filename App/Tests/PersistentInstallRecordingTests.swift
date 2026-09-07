import AgentCore
import AgentStore
@testable import AgentTerminal
import XCTest

// R2-1 — `PersistentInstallRecording` mirror/persistence semantics:
// replace-per-adapter recording, previous-run load joined at init, and the
// `mutatedAdapters` shield that keeps a deferred loader from resurrecting
// rows this run already replaced or removed.
//
// Persistence assertions poll through the repository (`persist` runs on
// `Task.detached`) — bounded polling only, never fixed sleeps. The init load
// joins a semaphore, so mirror state is synchronous right after construction.

final class PersistentInstallRecordingTests: XCTestCase {
    // MARK: - Fixtures

    /// Fresh temp dir + real on-disk AgentDatabase + IntegrationRepository.
    private func makeRepository() throws -> (dir: URL, repo: IntegrationRepository) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-install-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let database = try AgentDatabase(
            databaseURL: dir.appendingPathComponent("test.sqlite"),
            backupDirectoryURL: dir.appendingPathComponent("backups")
        )
        try database.migrate()
        return (dir, IntegrationRepository(database: database))
    }

    /// fp("claude-code", "/tmp/a") style shorthand — deterministic content so
    /// exact-content equality is meaningful.
    private func fp(_ adapterID: String, _ targetPath: String) -> ManagedEntryFingerprint {
        ManagedEntryFingerprint(
            adapterID: adapterID,
            targetPath: targetPath,
            entryKeyPath: [],
            marker: "agentterminal-test",
            managedContent: "managed-content-for-\(targetPath)"
        )
    }

    /// Previous-run row written straight through the repository.
    private func seedInstall(
        repo: IntegrationRepository,
        adapterKind: AgentKind,
        entries: [ManagedEntryFingerprint],
        status: String = "installed",
        integrationVersion: String = PersistentInstallRecording.integrationVersion
    ) async throws {
        let data = try JSONEncoder().encode(entries)
        try await repo.upsert(IntegrationInstall(
            agentKind: adapterKind,
            integrationVersion: integrationVersion,
            status: status,
            managedFilesJSON: data,
            managedFingerprint: "seeded",
            installedAt: Date()
        ))
    }

    /// Polling helper (bounded; no bare sleeps).
    private func waitUntil(
        timeout: TimeInterval = 3,
        interval: TimeInterval = 0.01,
        _ condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    // MARK: D1

    func testRecordReplacesPriorFingerprintsPerAdapterAndPersistsThroughRepository() async throws {
        let (dir, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = PersistentInstallRecording(repository: repo)

        try recording.record([fp("claude-code", "/tmp/a")])
        try recording.record([fp("claude-code", "/tmp/b"), fp("codex", "/tmp/c")])

        // Replace-per-adapter: the second claude-code record must REPLACE,
        // never append.
        XCTAssertEqual(recording.fingerprints(adapterID: "claude-code"),
                       [fp("claude-code", "/tmp/b")])
        XCTAssertEqual(recording.fingerprints(adapterID: "codex"),
                       [fp("codex", "/tmp/c")])

        // Write-through: exactly one installed row for claude-code whose
        // managedFilesJSON decodes to the latest entry set.
        var persisted: [ManagedEntryFingerprint]?
        var statuses: [String] = []
        await waitUntil {
            guard let installs = try? await repo.installs(agentKind: .claudeCode),
                  installs.count == 1
            else { return false }
            statuses = installs.map(\.status)
            persisted = installs.first.flatMap { try? JSONDecoder().decode(
                [ManagedEntryFingerprint].self, from: $0.managedFilesJSON
            ) }
            return persisted == [self.fp("claude-code", "/tmp/b")]
        }
        XCTAssertEqual(statuses, ["installed"])
        XCTAssertEqual(persisted, [fp("claude-code", "/tmp/b")])
    }

    // MARK: D2

    func testPreviousRunRowsAreLoadedAtInitButNeverResurrectMutatedAdapters() async throws {
        let (dir, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Previous run: an installed claude-code row plus a degraded row that
        // must NEVER load (the loader filters on status == "installed"). One
        // row per (kind, version), so the degraded row uses a legacy version.
        try await seedInstall(repo: repo, adapterKind: .claudeCode,
                              entries: [fp("claude-code", "/tmp/old")])
        try await seedInstall(repo: repo, adapterKind: .claudeCode,
                              entries: [fp("claude-code", "/tmp/degraded")],
                              status: "degraded", integrationVersion: "0-legacy")
        // Adapter NOT recorded this run — proves previous-run state loads.
        try await seedInstall(repo: repo, adapterKind: .codex,
                              entries: [fp("codex", "/tmp/kept")])

        let recording = PersistentInstallRecording(repository: repo)
        // Record immediately after construction — the mutatedAdapters shield
        // must hold regardless of load ordering relative to this call.
        try recording.record([fp("claude-code", "/tmp/new")])

        // Synchronously after record: no mix with /tmp/old, no degraded row.
        XCTAssertEqual(recording.fingerprints(adapterID: "claude-code"),
                       [fp("claude-code", "/tmp/new")])
        // And again after a grace window for any deferred work to settle.
        await waitUntil {
            recording.fingerprints(adapterID: "claude-code") == [self.fp("claude-code", "/tmp/new")]
        }
        XCTAssertEqual(recording.fingerprints(adapterID: "claude-code"),
                       [fp("claude-code", "/tmp/new")])
        XCTAssertEqual(recording.fingerprints(adapterID: "codex"),
                       [fp("codex", "/tmp/kept")],
                       "previous-run installed state must load for untouched adapters")
    }

    // MARK: D3

    func testRemoveAllClearsMirrorAndShieldsAdapterFromLaterLoads() async throws {
        let (dir, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await seedInstall(repo: repo, adapterKind: .openCode,
                              entries: [fp("opencode", "/tmp/doomed")])

        let recording = PersistentInstallRecording(repository: repo)
        recording.removeAll(adapterID: "opencode")

        XCTAssertTrue(recording.fingerprints(adapterID: "opencode").isEmpty)
        // Poll the LOADER side: the deferred init-load has landed once the
        // persisted /tmp/doomed row is visible through the repository.
        // Only then can an assertion on the mirror prove that the slow
        // init-load did not bring /tmp/doomed back.
        await waitUntil {
            await !((try? repo.installs(agentKind: .openCode)) ?? []).isEmpty
        }
        let seededVisible = await !((try? repo.installs(agentKind: .openCode)) ?? []).isEmpty
        XCTAssertTrue(seededVisible,
                      "precondition: seeded row must be visible to the loader")
        XCTAssertTrue(recording.fingerprints(adapterID: "opencode").isEmpty,
                      "removeAll must shield the adapter from later persisted-row loads")
    }

    // MARK: D4

    func testNilRepositoryIsMirrorOnlyAndUnknownAdapterStaysMirrorOnly() async throws {
        // (a) Nil repository: mirror-only protocol still works end-to-end.
        let degraded = PersistentInstallRecording(repository: nil)
        try degraded.record([fp("claude-code", "/tmp/mirror-a"), fp("codex", "/tmp/mirror-b")])
        XCTAssertEqual(degraded.fingerprints(adapterID: "claude-code"),
                       [fp("claude-code", "/tmp/mirror-a")])
        degraded.removeAll(adapterID: "codex")
        XCTAssertTrue(degraded.fingerprints(adapterID: "codex").isEmpty)

        // (b) Unknown adapter id: mirror-only, never misfiled under
        // .genericShell (two unknown ids would collide on that row).
        let (dir, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = PersistentInstallRecording(repository: repo)
        try recording.record([fp("some-future-agent", "/tmp/x")])

        // Mirror still serves the unknown adapter...
        XCTAssertEqual(recording.fingerprints(adapterID: "some-future-agent"),
                       [fp("some-future-agent", "/tmp/x")])
        // ...but nothing is persisted under the shared genericShell row.
        // Unknown ids fail persist()'s AgentKind guard SYNCHRONOUSLY —
        // there is no detached write to wait for, so a short settle for
        // any enqueued repository work followed by a hard assert is a real
        // absence proof (a fresh repo starts with zero installs).
        var installs: [IntegrationInstall] = []
        for _ in 0 ..< 10 {
            await Task.yield()
            installs = await (try? repo.installs(agentKind: .genericShell)) ?? []
        }
        XCTAssertTrue(installs.isEmpty,
                      "unknown adapters must never persist under genericShell")
    }
}

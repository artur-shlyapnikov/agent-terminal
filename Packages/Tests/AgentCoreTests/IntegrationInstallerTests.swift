@testable import AgentCore
import Foundation
import XCTest

// Behavioral coverage for the §3.17 integration installer: the full install
// flow (backup → temp write → validate → atomic rename → record fingerprint →
// self-test → rollback), crash-between-steps recovery, selective uninstall by
// fingerprint, upgrade-conflict detection (§5.3) and repair diagnostics.

final class IntegrationInstallerTests: XCTestCase {
    var home: URL!
    var recording: InMemoryInstallRecording!
    var installer: IntegrationInstaller!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        recording = InMemoryInstallRecording()
        installer = IntegrationInstaller(recording: recording, homeDirectory: home.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    /// A plan touching a JSON config plus an unrelated user key we must never touch.
    func claudeLikePlan(configPath: String) -> IntegrationInstallPlan {
        IntegrationInstallPlan(
            adapterID: "test-adapter",
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: configPath,
                    format: .json,
                    entries: [
                        ManagedConfigEntry(
                            keyPath: ["hooks"],
                            valueJSON: #"{"agentterminal-marker":"com.agentterminal.managed"}"#,
                            marker: IntegrationInstallPlan.namespaceMarker
                        ),
                    ]
                ),
            ]
        )
    }

    func writeUserConfig(_ path: String, content: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: url)
    }

    func readUserConfig(_ path: String) -> String {
        String(decoding: FileManager.default.contents(atPath: home.appendingPathComponent(path).path)!, as: UTF8.self)
    }

    // MARK: Fresh install roundtrip

    func testFreshInstallMergesIntoUserConfigAndRecordsFingerprint() throws {
        try writeUserConfig("cfg/settings.json", content: """
        {"model":"opus","hooks":{"user-owned":"keep-me"},"other":1}
        """)
        let report = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))

        XCTAssertEqual(report.outcome, .installed)
        XCTAssertEqual(report.fingerprintsRecorded, 1)
        XCTAssertTrue(report.selfTestRan == false)

        let document = try XCTUnwrap(try JSONSerialization
            .jsonObject(with: Data(readUserConfig("cfg/settings.json").utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        // Deep merge: our marker lands inside "hooks", user's sibling survives.
        XCTAssertEqual(hooks["agentterminal-marker"] as? String, IntegrationInstallPlan.namespaceMarker)
        XCTAssertEqual(hooks["user-owned"] as? String, "keep-me")
        XCTAssertEqual(document["model"] as? String, "opus")
        XCTAssertEqual(
            try (document["other"] as? Int) ?? Int(XCTUnwrap((document["other"] as? NSNumber)?.doubleValue)),
            1
        )

        let fingerprints = recording.fingerprints(adapterID: "test-adapter")
        XCTAssertEqual(fingerprints.count, 1)
        XCTAssertEqual(fingerprints[0].entryKeyPath, ["hooks"])
    }

    func testInstallCreatesBackupOfOriginalFile() throws {
        try writeUserConfig("cfg/settings.json", content: #"{"a":1}"#)
        let report = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        XCTAssertEqual(report.backups.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.backups[0]))
        let backupContent = try String(
            decoding: XCTUnwrap(FileManager.default.contents(atPath: report.backups[0])),
            as: UTF8.self
        )
        XCTAssertTrue(backupContent.contains(#""a""#))
    }

    // MARK: Rollback on validation / self-test failure (§3.17 step 10)

    func testSelfTestFailureRollsBackToExactOriginalBytes() throws {
        let original = "{\n  \"precious\": true\n}\n"
        try writeUserConfig("cfg/settings.json", content: original)

        XCTAssertThrowsError(try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json")) {
            throw IntegrationInstallError.selfTestFailed(reason: "simulated failure")
        })

        XCTAssertEqual(readUserConfig("cfg/settings.json"), original)
        XCTAssertTrue(recording.fingerprints(adapterID: "test-adapter").isEmpty)
    }

    func testValidationFailureRollsBackAndLeavesNoTempFiles() throws {
        let original = #"{"keep":1}"#
        try writeUserConfig("cfg/x.json", content: original)
        let rejectingInstaller = IntegrationInstaller(
            recording: recording,
            homeDirectory: home.path,
            syntaxValidator: { _, _ in SyntaxValidationResult(isValid: false, diagnostics: ["corrupted"]) }
        )

        XCTAssertThrowsError(try rejectingInstaller.install(plan: claudeLikePlan(configPath: "cfg/x.json")))

        XCTAssertEqual(readUserConfig("cfg/x.json"), original)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("cfg").path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".agentterminal-tmp-") }, "temp files must be cleaned up")
    }

    func testInvalidPlannedEntryValueFailsBeforeWritingAnything() throws {
        let plan = IntegrationInstallPlan(
            adapterID: "bad",
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: "cfg/y.json",
                    format: .json,
                    entries: [ManagedConfigEntry(
                        keyPath: ["k"],
                        valueJSON: "{not json",
                        marker: IntegrationInstallPlan.namespaceMarker
                    )]
                ),
            ]
        )
        XCTAssertThrowsError(try installer.install(plan: plan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("cfg/y.json").path))
    }

    // MARK: Crash-between-steps simulation

    func testCrashBetweenRenameAndRecordLeavesRecoverableOrphan() throws {
        // Phase 1: a full install succeeds on disk, but its fingerprint
        // recording never reaches durable storage — exactly the state left by
        // a crash between §3.17 step 7 (atomic rename) and step 8 (record).
        try writeUserConfig("cfg/settings.json", content: #"{"v":1}"#)
        let lostStore = InMemoryInstallRecording()
        let preCrashInstaller = IntegrationInstaller(recording: lostStore, homeDirectory: home.path)
        _ = try preCrashInstaller.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        XCTAssertNotNil(try ((JSONSerialization
                .jsonObject(with: Data(readUserConfig("cfg/settings.json")
                        .utf8)) as? [String: Any])?["hooks"] as? [String: Any])?["agentterminal-marker"])

        // Phase 2: the process restarts with empty recording state; the
        // managed entry carries our marker but no fingerprint — it must be
        // ADOPTED (not treated as user-owned clobber material).
        let report = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        XCTAssertEqual(report.outcome, .noChanges) // content identical — pure adoption
        XCTAssertEqual(report.fingerprintsRecorded, 1)
        XCTAssertEqual(installer.diagnose(plan: claudeLikePlan(configPath: "cfg/settings.json")), .healthy)

        // …and uninstall now removes it cleanly as owned content.
        let removal = try installer.uninstall(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        XCTAssertEqual(removal.removed.count, 1)
        XCTAssertTrue(removal.skippedUserModified.isEmpty)
        let postUninstall = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(readUserConfig("cfg/settings.json").utf8)
        ) as? [String: Any])
        // The managed leaf IS the "hooks" dict here, so uninstall's
        // exact-fingerprint branch removes the key wholesale (§3.17 step 9).
        // Tolerate the absent container; only our marker must be gone.
        XCTAssertNil((postUninstall["hooks"] as? [String: Any])?["agentterminal-marker"])
    }

    func testStaleTempFilesFromCrashedTempWriteAreCleanedUpOnNextInstall() throws {
        let dir = home.appendingPathComponent("cfg")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appendingPathComponent(".agentterminal-tmp-STALE")
        let staleData = try XCTUnwrap("partial".data(using: .utf8))
        try staleData.write(to: stale)

        try writeUserConfig("cfg/settings.json", content: #"{"v":1}"#)
        _ = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".agentterminal-tmp-") })
    }

    // MARK: Uninstall removes ONLY fingerprint-matched entries

    func testUninstallRemovesOnlyManagedEntryLeavingUserContentIntact() throws {
        try writeUserConfig("cfg/settings.json", content: #"{"model":"opus","hooks":{"user-hook":{"cmd":"run"}}}"#)
        _ = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))

        let report = try installer.uninstall(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        XCTAssertEqual(report.removed, ["\(home.path)/cfg/settings.json#hooks"])
        XCTAssertTrue(report.skippedUserModified.isEmpty)

        let document = try XCTUnwrap(try JSONSerialization
            .jsonObject(with: Data(readUserConfig("cfg/settings.json").utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        XCTAssertNil(hooks["agentterminal-marker"], "our entry must be gone")
        let userHookJSON = IntegrationInstaller.canonicalJSON(hooks["user-hook"] as Any)
        XCTAssertEqual(userHookJSON, #"{"cmd":"run"}"#, "user hooks must survive")
        XCTAssertEqual(document["model"] as? String, "opus")
        XCTAssertTrue(recording.fingerprints(adapterID: "test-adapter").isEmpty)
    }

    func testUninstallSkipsUserModifiedManagedSection() throws {
        try writeUserConfig("cfg/settings.json", content: "{}")
        _ = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))

        // User edits our managed value afterwards.
        let tampered = """
        {"hooks":{"agentterminal-marker":"user-changed-it"}}
        """
        try tampered.data(using: .utf8)?.write(to: home.appendingPathComponent("cfg/settings.json"))

        let report = try installer.uninstall(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(report.skippedUserModified.count, 1)

        let document = try XCTUnwrap(try JSONSerialization
            .jsonObject(with: Data(readUserConfig("cfg/settings.json").utf8)) as? [String: Any])
        XCTAssertEqual((document["hooks"] as? [String: Any])?["agentterminal-marker"] as? String, "user-changed-it")
    }

    func testDeepMergedSubkeysAreRemovedPreciselyOnUninstall() throws {
        // User owns "hooks" with their own hook; we merge ours alongside it.
        try writeUserConfig("cfg/settings.json", content: #"{"hooks":{"mine":{"cmd":"x"}}}"#)
        _ = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))
        let report = try installer.uninstall(plan: claudeLikePlan(configPath: "cfg/settings.json"))

        XCTAssertEqual(report.removed.count, 1)
        let rawFile = readUserConfig("cfg/settings.json")
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(rawFile.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["mine"] as? [String: String], ["cmd": "x"])
        XCTAssertNil(hooks["agentterminal-marker"])
    }

    // MARK: Upgrade path (§5.3 steps 1–5)

    func testUpgradeWithUntouchedManagedSectionAppliesAndRecordsNewFingerprint() throws {
        try writeUserConfig("cfg/settings.json", content: "{}")
        _ = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))

        // Newer plan version writes a different managed payload.
        let upgradedPlan = IntegrationInstallPlan(
            adapterID: "test-adapter",
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: "cfg/settings.json",
                    format: .json,
                    entries: [ManagedConfigEntry(
                        keyPath: ["hooks"],
                        valueJSON: #"{"agentterminal-marker":"com.agentterminal.managed","version":2}"#,
                        marker: IntegrationInstallPlan.namespaceMarker
                    )]
                ),
            ]
        )
        let report = try installer.install(plan: upgradedPlan)
        XCTAssertEqual(report.outcome, .upgraded)

        let fingerprints = recording.fingerprints(adapterID: "test-adapter")
        XCTAssertEqual(fingerprints.count, 1)
        XCTAssertEqual(
            fingerprints[0].managedContent,
            #"{"agentterminal-marker":"com.agentterminal.managed","version":2}"#
        )

        // Self-test runs as §5.3 step 5.
        var selfTestRan = false
        _ = try installer.install(plan: upgradedPlan, selfTest: { selfTestRan = true })
        XCTAssertTrue(selfTestRan)
    }

    func testUpgradeConflictsWhenUserEditedManagedSection() throws {
        try writeUserConfig("cfg/settings.json", content: "{}")
        _ = try installer.install(plan: claudeLikePlan(configPath: "cfg/settings.json"))

        let tampered = #"{"hooks":{"agentterminal-marker":"i-tweaked-this","extra":"user-data"}}"#
        try tampered.data(using: .utf8)?.write(to: home.appendingPathComponent("cfg/settings.json"))

        let upgradedPlan = IntegrationInstallPlan(
            adapterID: "test-adapter",
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: "cfg/settings.json",
                    format: .json,
                    entries: [ManagedConfigEntry(
                        keyPath: ["hooks"],
                        valueJSON: #"{"agentterminal-marker":"com.agentterminal.managed","version":2}"#,
                        marker: IntegrationInstallPlan.namespaceMarker
                    )]
                ),
            ]
        )
        let report = try installer.install(plan: upgradedPlan)

        guard case let .conflict(paths) = report.outcome else {
            return XCTFail("expected conflict, got \(report.outcome)")
        }
        XCTAssertEqual(paths.count, 1)
        // Nothing was modified — user data intact byte-for-byte.
        XCTAssertEqual(readUserConfig("cfg/settings.json"), tampered)
    }

    // MARK: User-owned values are never clobbered

    func testUserOwnedValueAtKeyPathIsNeverOverwritten() throws {
        try writeUserConfig("cfg/settings.json", content: #"{"hooks":{"entirely":"theirs"}}"#)
        let plan = IntegrationInstallPlan(
            adapterID: "test-adapter",
            files: [
                IntegrationFileEdit(
                    targetPathTemplate: "cfg/settings.json",
                    format: .json,
                    // Scalar replacing their dict → must conflict, not overwrite.
                    entries: [ManagedConfigEntry(
                        keyPath: ["hooks"],
                        valueJSON: #""ours""#,
                        marker: IntegrationInstallPlan.namespaceMarker
                    )]
                ),
            ]
        )
        let diff = try installer.diff(plan: plan)
        XCTAssertEqual(diff.files[0].actions.first?.action, .conflictUserOwned)

        let report = try installer.install(plan: plan)
        guard case .conflict = report.outcome else { return XCTFail("expected conflict") }
        let document = try XCTUnwrap(try JSONSerialization
            .jsonObject(with: Data(readUserConfig("cfg/settings.json").utf8)) as? [String: Any])
        XCTAssertEqual((document["hooks"] as? [String: Any])?["entirely"] as? String, "theirs")
    }
}

final class ThrowingInstallRecording: IntegrationInstallRecording, @unchecked Sendable {
    struct RecordFailure: Error {}

    private let lock = NSLock()
    private var storage: [ManagedEntryFingerprint]
    private(set) var removeAllObserved = false
    var failNextRecord = false

    init(seed: [ManagedEntryFingerprint]) {
        storage = seed
    }

    func record(_ fingerprints: [ManagedEntryFingerprint]) throws {
        if failNextRecord {
            throw RecordFailure()
        }
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll { stored in
            fingerprints.contains {
                $0.adapterID == stored.adapterID && $0.targetPath == stored.targetPath
                    && $0.entryKeyPath == stored.entryKeyPath
            }
        }
        storage.append(contentsOf: fingerprints)
    }

    func fingerprints(adapterID: String) -> [ManagedEntryFingerprint] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.adapterID == adapterID }
    }

    func removeAll(adapterID: String) {
        lock.lock()
        defer { lock.unlock() }
        removeAllObserved = true
        storage.removeAll { $0.adapterID == adapterID }
    }
}

/// Simulates a TORN backup copy: for the doomed destinations it writes a
/// partial artifact (as a real mid-copy failure would leave behind) and then
/// throws. Everything else passes through untouched.
final class PartialCopyFileManager: FileManager {
    var failDestinations: Set<String> = []

    override func copyItem(atPath srcPath: String, toPath dstPath: String) throws {
        if failDestinations.contains(dstPath) {
            try Data("partial".utf8).write(to: URL(fileURLWithPath: dstPath))
            throw CocoaError(.fileWriteUnknown)
        }
        try super.copyItem(atPath: srcPath, toPath: dstPath)
    }
}

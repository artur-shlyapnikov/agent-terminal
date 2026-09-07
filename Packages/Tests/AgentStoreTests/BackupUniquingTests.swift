import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Pre-migration backup names must be collision-free (wave-2 review): a bare
// '<prefix>-pre-vN-<unixSeconds>' collides when two migrations land within
// one wall-clock second, and copyItem then aborts migrate().

final class BackupUniquingTests: XCTestCase {
    func testTwoUpgradesInOneProcessProduceDistinctBackups() throws {
        let dir = try TestEnv.makeTempDirectory()
        let backupsDir = dir.appendingPathComponent("backups")

        /// Simulates a previous-generation database (applied version 0).
        func legacyV0Database(at url: URL) throws -> DatabasePool {
            var config = Configuration()
            config.foreignKeysEnabled = true
            let pool = try DatabasePool(path: url.path, configuration: config)
            var legacy = DatabaseMigrator()
            legacy.registerMigration("agentstore-v0") { db in
                try db.execute(sql: "CREATE TABLE legacy_marker (note TEXT)")
                try db.execute(sql: "INSERT INTO legacy_marker VALUES ('precious data')")
            }
            try legacy.migrate(pool)
            return pool
        }

        // Two upgrades run back-to-back inside this process. Both databases
        // share the file name (hence the backup prefix); both upgrades land
        // in the same unix second in practice, which is exactly the collision
        // window.
        let firstURL = dir.appendingPathComponent("upgrade.sqlite")
        _ = try legacyV0Database(at: firstURL)
        let first = try AgentDatabase(
            databaseURL: firstURL,
            backupDirectoryURL: backupsDir
        )
        try first.migrate()

        let secondDir = dir.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let secondURL = secondDir.appendingPathComponent("upgrade.sqlite")
        _ = try legacyV0Database(at: secondURL)
        let second = try AgentDatabase(
            databaseURL: secondURL,
            backupDirectoryURL: backupsDir
        )
        try second.migrate()

        let names = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        XCTAssertEqual(names.count, 2, "each upgrade must produce exactly one backup; got \(names)")
        XCTAssertEqual(Set(names).count, 2,
                       "backup filenames must be unique even within the same unix second: \(names)")
        for name in names {
            XCTAssertTrue(name.hasSuffix(".sqlite"), "backup \(name) must remain a sqlite file")
        }
    }
}

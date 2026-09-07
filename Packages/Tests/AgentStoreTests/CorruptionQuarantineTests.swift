
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Stage-16 gate 6a: corrupt SQLite → quarantine + fresh store, never delete.

final class CorruptionQuarantineTests: XCTestCase {
    private func makeGarbledDatabase() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("AgentTerminal.sqlite")
        try Data("THIS IS NOT A SQLITE DATABASE FILE — GARBAGE BYTES FOR THE GATE".utf8)
            .write(to: url)
        return url
    }

    func testCorruptFileIsQuarantinedAndFreshStoreOpens() throws {
        let url = try makeGarbageDatabase()
        let (database, quarantined) = try AgentDatabase.openWithCorruptionQuarantine(
            databaseURL: url
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let quarantineURL = try XCTUnwrap(quarantined)
        XCTAssertTrue(quarantineURL.lastPathComponent.contains(".corrupt-"),
                      "quarantine name: \(quarantineURL.lastPathComponent)")
        let size = try FileManager.default.attributesOfItem(
            atPath: quarantineURL.path
        )[.size] as? Int
        XCTAssertEqual(size,
                       "THIS IS NOT A SQLITE DATABASE FILE — GARBAGE BYTES FOR THE GATE".utf8.count,
                       "corrupt bytes preserved byte-for-byte")

        // Fresh store is usable.
        try database.pool.write { db in
            try db.execute(sql: "SELECT 1")
        }
    }

    func testHealthyDatabaseOpensWithoutQuarantine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-healthy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("AgentTerminal.sqlite")

        let (database, quarantined) = try AgentDatabase.openWithCorruptionQuarantine(
            databaseURL: url
        )
        try database.migrate()
        XCTAssertNil(quarantined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func makeGarbageDatabase() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("AgentTerminal.sqlite")
        try Data("THIS IS NOT A SQLITE DATABASE FILE — GARBAGE BYTES FOR THE GATE".utf8)
            .write(to: url)
        return url
    }

    // MARK: Round 9 — quarantine lifecycle laws

    private static let garbage = Data("THIS IS NOT A SQLITE DATABASE FILE".utf8)

    /// Writes arbitrary bytes as the main DB image plus optional sidecars.
    private func plantImage(at url: URL, bytes: Data, wal: Data? = nil, shm: Data? = nil) throws {
        try bytes.write(to: url)
        if let wal {
            try wal.write(to: URL(fileURLWithPath: url.path + "-wal"))
        }
        if let shm {
            try shm.write(to: URL(fileURLWithPath: url.path + "-shm"))
        }
    }

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// R9-A1: a garbled main image with a NON-EMPTY stale -wal must be
    /// quarantined by the up-front magic check — SQLite would otherwise
    /// recover pages from the WAL and open WITHOUT throwing (rotten image).
    func testGarbledMainWithStaleWALIsQuarantinedByMagicCheckAndSidecarsRemoved() throws {
        let dir = try makeTempDir("aterm-corrupt-wal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("AgentTerminal.sqlite")
        let wal = Data("STALE WAL PAGES THAT MUST NEVER BE RECOVERED".utf8)
        try plantImage(at: url, bytes: Self.garbage, wal: wal, shm: Data([0x01, 0x02]))

        let (database, quarantined) = try AgentDatabase.openWithCorruptionQuarantine(
            databaseURL: url,
            now: Date(timeIntervalSince1970: 1_000_000)
        )

        let quarantineURL = try XCTUnwrap(quarantined)
        XCTAssertTrue(quarantineURL.lastPathComponent.hasPrefix("AgentTerminal.corrupt-"),
                      "quarantine name: \(quarantineURL.lastPathComponent)")
        // The STALE sidecars were removed with the corrupt image. Any
        // -wal/-shm present afterwards belongs to the freshly opened pool
        // (WAL mode recreates them on open) and must NOT carry stale pages.
        let staleWalBytes = Data("STALE WAL PAGES".utf8)
        let currentWal = try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))
        XCTAssertEqual(currentWal.map { $0.range(of: staleWalBytes) == nil }, true,
                       "stale WAL pages must be gone from the original paths")
        try database.pool.write { db in
            try db.execute(sql: "SELECT 1")
        }
    }

    /// R9-A2: successive corruptions land under DISTINCT stamps and the
    /// first preserved copy survives the second quarantine untouched.
    func testSecondCorruptionQuarantinesToDistinctFilePreservingTheFirstCopy() throws {
        let dir = try makeTempDir("aterm-corrupt-cycle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("AgentTerminal.sqlite")
        try plantImage(at: url, bytes: Self.garbage)

        var firstDatabase: AgentDatabase? = try AgentDatabase.openWithCorruptionQuarantine(
            databaseURL: url,
            now: Date(timeIntervalSince1970: 2_000_000)
        ).database
        let firstQuarantined = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: dir.appendingPathComponent("backups"), includingPropertiesForKeys: nil
            ).first
        )
        // Scope the first pool so GRDB closes it before we re-corrupt.
        _ = firstDatabase
        firstDatabase = nil

        // Second corruption at the ORIGINAL url, distinguishable by size.
        let garbage2 = Self.garbage + Data(repeating: 0xAB, count: 8)
        try plantImage(at: url, bytes: garbage2)

        let (secondDatabase, secondQuarantined) = try AgentDatabase.openWithCorruptionQuarantine(
            databaseURL: url,
            now: Date(timeIntervalSince1970: 2_000_100)
        )

        let second = try XCTUnwrap(secondQuarantined)
        XCTAssertNotEqual(second.standardizedFileURL, firstQuarantined.standardizedFileURL,
                          "each corruption gets its own quarantine slot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstQuarantined.path),
                      "the FIRST preserved copy must never be deleted by a later one")
        XCTAssertEqual(try Data(contentsOf: firstQuarantined).count, Self.garbage.count)
        XCTAssertEqual(try Data(contentsOf: second).count, garbage2.count)
        try secondDatabase.pool.write { db in
            try db.execute(sql: "SELECT 1")
        }
    }

    /// R9-A3: a NEWER-schema refusal is NOT corruption — it must surface
    /// unchanged, without quarantining a healthy future-schema store.
    func testNewerSchemaRefusalSurfacesUnchangedWithoutQuarantine() throws {
        let dir = try makeTempDir("aterm-newer-schema")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("AgentTerminal.sqlite")

        // Forge a v99 schema (v99 > Schema.currentVersion == 1) on a raw pool.
        do {
            let pool = try DatabasePool(path: url.path)
            var m = DatabaseMigrator()
            m.registerMigration("agentstore-v99") { _ in }
            try m.migrate(pool)
            // Pool released at scope end.
        }

        var caught: Error?
        XCTAssertThrowsError(try AgentDatabase.openWithCorruptionQuarantine(databaseURL: url)) {
            caught = $0
        }
        XCTAssertEqual(
            caught as? MigrationError,
            MigrationError.databaseFromNewerSchema(appliedVersion: 99, knownVersion: 1),
            "the version refusal must surface unchanged, not as corruption"
        )
        // No quarantine artifacts anywhere under the temp dir.
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )
        XCTAssertFalse(contents.contains { $0.lastPathComponent == "backups" })
        XCTAssertFalse(contents.contains { $0.lastPathComponent.contains(".corrupt-") })
        // The original image is still the SAME healthy SQLite store (opening
        // the pool for the refusal may checkpoint WAL into the main file, so
        // byte size can change — the identity that matters is magic + content
        // of the forged migration table, i.e. it was NOT quarantined away).
        let after = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: after.prefix(16), as: UTF8.self), "SQLite format 3\u{0}")
        XCTAssertNotNil(
            after.range(of: Data("agentstore-v99".utf8)),
            "still the forged v99 store — never replaced by a fresh database"
        )
    }
}

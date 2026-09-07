import AgentCore
import Foundation
import GRDB

// AgentStore entry point (architecture §4.4). Dependency law (§3.2): this
// target imports AgentCore and GRDB only — no AppKit.
//
// Storage location (§3.14): ~/Library/Application Support/AgentTerminal/
// AgentTerminal.sqlite, WAL journal mode, foreign keys ON, busy_timeout,
// versioned migrations with pre-migration backups (§5.2).

/// Opens and owns the GRDB connection pool for the AgentTerminal database.
/// The path is injectable so tests run against temporary directories.
public final class AgentDatabase: Sendable {
    /// Canonical production location (§3.14).
    public static func defaultDatabaseURL() -> URL {
        AppPaths.applicationSupport()
            .appendingPathComponent("AgentTerminal", isDirectory: true)
            .appendingPathComponent("AgentTerminal.sqlite")
    }

    static let backupDirectoryName = "backups"

    /// Location of the database file. Kept so the migrator can copy backups.
    public let databaseURL: URL
    /// Directory receiving pre-migration database copies (§5.2).
    public let backupDirectoryURL: URL
    /// The shared reader/writer pool. File databases run in WAL mode.
    public let pool: DatabasePool

    public convenience init() throws {
        try self.init(databaseURL: Self.defaultDatabaseURL())
    }

    public init(databaseURL: URL, backupDirectoryURL: URL? = nil) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.qos = .utility
        configuration.label = "AgentTerminal.store"
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)

        self.backupDirectoryURL = backupDirectoryURL
            ?? directory.appendingPathComponent(Self.backupDirectoryName, isDirectory: true)
    }

    // Runs the versioned schema migrations (§3.14/§5.2):
    // refuses a database written by a NEWER AgentStore, otherwise takes a
    // file-level backup before applying any pending migration.

    /// Stage-16 adverse gate 6a: opens the database, and when the on-disk
    /// file is CORRUPT (not a database / malformed image), quarantines the
    /// corrupt file — never deletes it — and reopens a fresh database so the
    /// app can start. The caller surfaces the quarantine to the operator
    /// (banner + diagnostics); data loss stays impossible because the corrupt
    /// bytes are preserved byte-for-byte at the returned URL.
    /// Because a stale -wal sidecar lets SQLite recover a garbled main image
    /// and open WITHOUT throwing, the 16-byte SQLite magic is also verified
    /// up front, before any open attempt.
    public static func openWithCorruptionQuarantine(
        databaseURL: URL,
        backupDirectoryURL: URL? = nil,
        now: Date = Date()
    ) throws -> (database: AgentDatabase, quarantinedCorruptFile: URL?) {
        // WAL-recovery blind spot: with a stale -wal sidecar next to a
        // garbled main file, SQLite recovers pages from the WAL and
        // open+migrate SUCCEED — the catch below never fires and the store
        // runs on a rotten main image. A valid SQLite main image always
        // begins with this magic, so check it before even opening.
        let sqliteMagic = Data("SQLite format 3\u{0}".utf8)
        var header: Data?
        if let handle = try? FileHandle(forReadingFrom: databaseURL) {
            defer { try? handle.close() }
            header = try? handle.read(upToCount: sqliteMagic.count)
        }
        // Missing or zero-byte file (legitimate fresh DB) → normal open.
        // Any NON-EMPTY file must carry the full magic: a valid database is
        // never shorter than the header, so a short non-matching read
        // (e.g. 14 bytes of garbage) is corruption just as much as a full
        // 16-byte mismatch.
        if let header, !header.isEmpty, header != sqliteMagic {
            let (fresh, quarantined) = try Self.quarantineAndReopen(
                databaseURL: databaseURL,
                backupDirectoryURL: backupDirectoryURL,
                now: now
            )
            return (fresh, quarantined)
        }
        do {
            let database = try AgentDatabase(
                databaseURL: databaseURL, backupDirectoryURL: backupDirectoryURL
            )
            try database.migrate()
            return (database, nil)
        } catch {
            guard isCorruption(error) else { throw error }
            let (fresh, quarantined) = try Self.quarantineAndReopen(
                databaseURL: databaseURL,
                backupDirectoryURL: backupDirectoryURL,
                now: now
            )
            return (fresh, quarantined)
        }
    }

    /// Moves the corrupt image to the backup directory (never deletes it),
    /// moves its -wal/-shm sidecars alongside it (deleting them only when
    /// the move fails), and reopens a fresh database at the original URL.
    /// Shared by the up-front magic check and the corruption-shaped catch
    /// path.
    private static func quarantineAndReopen(
        databaseURL: URL,
        backupDirectoryURL: URL?,
        now: Date
    ) throws -> (database: AgentDatabase, quarantinedCorruptFile: URL) {
        let directory = databaseURL.deletingLastPathComponent()
        let backups = backupDirectoryURL
            ?? directory.appendingPathComponent(Self.backupDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        // Two corruptions can land within the same wall-clock second; a
        // bare stamp would collide and removeItem would destroy the FIRST
        // quarantine — the corrupt bytes this path exists to preserve.
        let uniquifier = UUID().uuidString.lowercased().prefix(8)
        let quarantined = backups.appendingPathComponent(
            "\(databaseURL.deletingPathExtension().lastPathComponent).corrupt-\(stamp)-\(uniquifier).sqlite"
        )
        try? FileManager.default.removeItem(at: quarantined)
        try FileManager.default.moveItem(at: databaseURL, to: quarantined)
        // WAL/SHM sidecars belong to the corrupt image too, and the WAL may
        // hold the ONLY good copy of recently committed, un-checkpointed
        // transactions — so it travels with the quarantine. Deletion is a
        // non-fatal fallback for when the move itself fails: a stale
        // sidecar must never survive at the live path, or the fresh open
        // below would try to recover from it again.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                let quarantinedSidecar = URL(
                    fileURLWithPath: quarantined.path + suffix
                )
                try? FileManager.default.removeItem(at: quarantinedSidecar)
                do {
                    try FileManager.default.moveItem(at: sidecar, to: quarantinedSidecar)
                } catch {
                    try? FileManager.default.removeItem(at: sidecar)
                }
            }
        }
        let fresh = try AgentDatabase(
            databaseURL: databaseURL, backupDirectoryURL: backupDirectoryURL
        )
        try fresh.migrate()
        return (fresh, quarantined)
    }

    /// Corruption-shaped failures only; a NEWER-schema refusal or an I/O
    /// permission error must surface unchanged (§5.2).
    static func isCorruption(_ error: any Error) -> Bool {
        if let dbError = error as? DatabaseError {
            switch dbError.resultCode {
            case .SQLITE_NOTADB, .SQLITE_CORRUPT:
                return true
            default:
                let message = (dbError.message ?? "").lowercased()
                return message.contains("malformed")
                    || message.contains("not a database")
                    || message.contains("encrypted")
            }
        }
        let text = String(describing: error).lowercased()
        return text.contains("not a database") || text.contains("malformed")
    }

    /// Runs the versioned schema migrations (§3.14/§5.2):
    /// refuses a database written by a NEWER AgentStore, otherwise takes a
    /// file-level backup before applying any pending migration.
    public func migrate() throws {
        try SchemaMigrator(database: self).migrate()
    }
}

import AgentCore
import Foundation

/// Secure one-shot acquisition of a launch ticket (architecture §3.9 rules).
///
/// Rules enforced here, in order:
///
/// 1. **Symlink rejection** — `open(O_NOFOLLOW)`; a symlinked ticket path
///    fails with `ELOOP`.
/// 2. **Owner UID match** — `fstat.st_uid` must equal `getuid()`.
/// 3. **Mode 0600** — exact permission bits (`st_mode & 07777 == 0600`) on a
///    regular file.
/// 4. **Atomic single-use claim** — before any read the ticket is atomically
///    claimed under `<path>.consuming`. POSIX `rename(2)` cannot express
///    "fail if destination exists" (it silently replaces), and macOS lacks
///    `renameat2(RENAME_NOREPLACE)`, so the claim uses `link(2)` — which
///    fails with `EEXIST` when another consumer already created
///    `.consuming` — followed by `unlink(path)`. Same inode handover as the
///    rename, but genuinely race-free: two concurrent consumers can never
///    both acquire.
/// 5. **Delete after read** — `.consuming` is unlinked immediately after the
///    bytes are read (and again defensively after parse), so the ticket is
///    gone from disk regardless of validation outcome.
enum TicketConsumer {
    struct Acquired {
        let ticket: LaunchTicket
        /// Kept only so failures after parse can be attributed; never logged.
        let consumingPath: String
    }

    enum Failure: Error, CustomStringConvertible {
        case missingArgument
        case cannotOpen(errno: Int32)
        case notRegularFile
        case ownerMismatch
        case badMode(UInt32)
        case alreadyConsuming
        case unreadable(errno: Int32)
        case oversized
        case malformedJSON
        /// Human-facing short reason; mapped to exit code 126 by `main.swift`.
        case rejected(reason: String)

        var description: String {
            switch self {
            case .missingArgument: "usage: AgentLauncher <ticket-path>"
            case let .cannotOpen(e): "ticket open failed (errno \(e)\(e == ELOOP ? ", symlink rejected" : ""))"
            case .notRegularFile: "ticket is not a regular file"
            case .ownerMismatch: "ticket owner does not match current uid"
            case let .badMode(m): String(format: "ticket mode %o is not 0600", m)
            case .alreadyConsuming: "ticket already being consumed"
            case let .unreadable(e): "ticket read failed (errno \(e))"
            case .oversized: "ticket exceeds size limit"
            case .malformedJSON: "ticket is not valid JSON"
            case let .rejected(r): "ticket rejected: \(r)"
            }
        }
    }

    static let maxTicketBytes = 1 << 20

    static func consumingPath(for path: String) -> String {
        path + ".consuming"
    }

    /// Runs rules 1–5 above. On success the ticket has been deleted from disk.
    static func acquire(argumentPath: String) -> Result<Acquired, Failure> {
        // Rule 1: reject symlinks up front (O_NOFOLLOW → ELOOP). O_NONBLOCK
        // keeps a FIFO planted at the path from blocking the launcher before
        // the S_IFREG gate can reject it (regular files are unaffected).
        let fd = open(argumentPath, O_NOFOLLOW | O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .failure(.cannotOpen(errno: errno)) }
        defer { close(fd) }

        // Rules 2 & 3: stat via the already-open fd (no path TOCTOU).
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.cannotOpen(errno: errno)) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        guard st.st_uid == UInt32(getuid()) else { return .failure(.ownerMismatch) }
        let mode = UInt32(st.st_mode) & 0o7777
        guard mode == 0o600 else { return .failure(.badMode(mode)) }

        // Rule 4: atomic no-replace claim of the single-use slot.
        let consumed = consumingPath(for: argumentPath)
        if link(argumentPath, consumed) != 0 {
            // EEXIST ⇒ another consumer won the race; anything else is also
            // a lost ticket — same silent exit either way (no diagnostics
            // leak about sibling consumers).
            return .failure(.alreadyConsuming)
        }
        // Post-link the claimed name is our private hardlink; stat() on it
        // must match the fd we opened. If the writer replaced `path` between
        // open() and link(), we claimed a ticket inode we will never read —
        // undo the claim and bow out silently (lost race).
        var consumedSt = stat()
        if stat(consumed, &consumedSt) != 0
            || consumedSt.st_dev != st.st_dev
            || consumedSt.st_ino != st.st_ino
        {
            unlink(consumed)
            return .failure(.alreadyConsuming)
        }
        if unlink(argumentPath) != 0 {
            // ENOENT ⇒ the public name is already gone while we hold the
            // exclusive claim via `.consuming`, so single-use is preserved.
            // Any other errno leaves the original ticket in place: a later
            // acquirer could link() the SAME inode and launch twice — undo
            // the claim and fail the acquire instead.
            if errno != ENOENT {
                let e = errno
                unlink(consumed)
                return .failure(.cannotOpen(errno: e))
            }
        }

        // Read through our fd (same inode that was claimed).
        let data: Data
        switch readAll(fd: fd) {
        case let .success(d): data = d
        case let .failure(f): unlink(consumed); return .failure(f)
        }

        // Rule 5: delete after read.
        unlink(consumed)

        guard let ticket = try? JSONDecoder().decode(LaunchTicket.self, from: data) else {
            return .failure(.malformedJSON)
        }
        return .success(Acquired(ticket: ticket, consumingPath: consumed))
    }

    private static func readAll(fd: Int32, limit: Int = maxTicketBytes) -> Result<Data, Failure> {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                guard errno == EINTR else { return .failure(.unreadable(errno: errno)) }
                continue
            }
            if n == 0 {
                return .success(data)
            }
            data.append(contentsOf: buffer[0 ..< n])
            if data.count > limit {
                return .failure(.oversized)
            }
        }
    }

    // MARK: - Semantic validation (post-parse)

    /// Validates the decoded ticket. Every failure maps to exit 126 in
    /// `main.swift`; reasons are safe to print to the terminal (they name the
    /// failed rule, never field contents).
    static func validate(_ ticket: LaunchTicket) -> String? {
        guard ticket.isProtocolSupported() else { return "unsupported protocolVersion" }
        guard !ticket.isExpired(atEpochSeconds: Date().timeIntervalSince1970) else { return "ticket expired" }
        guard ticket.matchesCurrentUID(UInt32(getuid())) else { return "expectedUID does not match current uid" }
        guard !ticket.argv.isEmpty else { return "argv is empty" }
        guard ticket.cwd.hasPrefix("/") else { return "cwd is not absolute" }
        // Exact-argv execve leaves no shell to resolve bare names via PATH;
        // requiring an absolute argv[0] keeps execve unambiguous and denies
        // PATH-injection games entirely.
        guard ticket.argv[0].hasPrefix("/") else { return "argv[0] is not absolute" }
        return nil
    }
}

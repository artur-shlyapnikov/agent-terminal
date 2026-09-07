import AgentCore
import Foundation

// One-shot launch ticket producer (architecture §3.9): creates
// <tickets>/<UUID>.json with mode 0600 through a secure open(O_CREAT|O_EXCL)
// flow — no symlink following, no shell, no temp-file rename on this side
// (the atomic rename to `.consuming` belongs to the LAUNCHER/consumer).
//
// Security invariants (shared contract in AgentCore.LaunchTicket):
//   - mode 0600 from the first write syscall onward;
//   - O_EXCL: creation fails when the path already exists (including when it
//     is a symlink — open() does not follow it for creation);
//   - the writer only creates and deletes its own tickets.

public final class LaunchTicketWriter: @unchecked Sendable {
    public let directory: URL

    private let lock = NSLock()
    private var writtenPaths: Set<String> = []

    /// - Parameter directory: overrides the default tickets directory (tests).
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = AppPaths.applicationSupport()
                .appendingPathComponent("AgentTerminal/runtime/tickets")
        }
    }

    /// Writes the ticket JSON to a fresh 0600 file and returns its path.
    /// Throws when the directory cannot be created or the path already exists.
    @discardableResult
    public func write(_ ticket: LaunchTicket) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let url = directory.appendingPathComponent("\(ticket.ticketID.uuidString).json")
        // Best-effort cleanup of a crash-window remnant: a consumer claims a
        // ticket by hard-linking <path> → <path>.consuming and unlinking
        // <path>; if it crashes in between, the `.consuming` file is orphaned.
        // A later writer reusing the same UUID path would then make the next
        // consumer's link() fail with EEXIST, so remove it for this url only
        // (it normally does not exist — ignore errors).
        let consumingURL = URL(fileURLWithPath: url.path + ".consuming")
        try? FileManager.default.removeItem(at: consumingURL)
        let data = try JSONEncoder().encode(ticket)

        // Secure create: O_CREAT|O_EXCL guarantees we own the fresh inode and
        // never follow an attacker-planted symlink at this path.
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else {
            throw NSError(
                domain: "LaunchTicketWriter",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "ticket create failed: \(String(cString: strerror(errno)))"]
            )
        }
        // Belt-and-braces mode enforcement on the held descriptor (umask can
        // only lower, never raise, but the explicit fchmod documents the
        // contract and fixes exotic setups).
        fchmod(fd, 0o600)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        lock.lock()
        writtenPaths.insert(url.path)
        lock.unlock()
        return url
    }

    /// Deletes a ticket this writer created (cancel-launch path). Never touches
    /// foreign files; returns false when the path is unknown to this writer.
    @discardableResult
    public func cancel(at url: URL) -> Bool {
        lock.lock()
        let known = writtenPaths.remove(url.path) != nil
        lock.unlock()
        guard known else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

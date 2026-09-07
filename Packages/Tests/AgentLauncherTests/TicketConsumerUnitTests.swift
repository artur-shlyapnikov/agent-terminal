import AgentCore
@testable import AgentLauncher
import Foundation
import XCTest

// Unit-level TicketConsumer rules (§3.9): the 1 MiB read boundary, atomic
// double-acquire via link(2), cleanup on parse failure, and the exact expiry
// / PATH-injection validation rules. Calls acquire/validate directly —
// complementing the external-process smoke suite.

final class TicketConsumerUnitTests: XCTestCase {
    private let launchTicketTTL: Double = 60

    // MARK: - Fixtures (mirrors the smoke suite's private helpers; file-local

    // to avoid collisions inside the shared test target)

    /// Raw wire-format ticket dictionary (same field names as LaunchTicket JSON).
    private func baseTicket(
        cwd: String = "/tmp",
        argv: [String] = ["/bin/true"],
        environment: [String: String] = [:]
    ) -> [String: Any] {
        [
            "protocolVersion": 1,
            "ticketID": UUID().uuidString,
            "agentID": UUID().uuidString,
            "terminalID": UUID().uuidString,
            "surfaceGeneration": UInt64(7),
            "expectedUID": UInt32(getuid()),
            "createdAt": Date().timeIntervalSince1970 - 1,
            "expiresAt": Date().timeIntervalSince1970 + launchTicketTTL - 5,
            "cwd": cwd,
            "argv": argv,
            "environment": environment,
            "integrationToken": "test-token",
            "controlSocketPath": "",
        ]
    }

    /// Writes JSON at 0600 in a fresh temp dir; returns (dir, path).
    @discardableResult
    private func writeTicket(_ ticket: [String: Any], name: String = "ticket.json") throws -> (dir: URL, path: String) {
        try writeTicketData(JSONSerialization.data(withJSONObject: ticket), name: name)
    }

    private func writeTicketData(_ data: Data, name: String) throws -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlauncher-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(name)
        // posixPermissions attribute bypasses umask so exactly 0600 lands.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600]
        ))
        return (dir, fileURL.path)
    }

    private func consumingPath(for ticketPath: String) -> String {
        ticketPath + ".consuming"
    }

    // MARK: B1

    func testTicketOfExactlyOneMebibyteIsAcceptedButOneMoreByteIsRejected() throws {
        let limit = TicketConsumer.maxTicketBytes
        XCTAssertEqual(limit, 1 << 20)

        /// Deterministic sizing: serialize a skeleton whose "summary" is the
        /// empty string, locate its `"summary":""` marker, then replace it
        /// with `"summary":"<pad spaces>"` where pad = target − skeleton.
        /// The replacement preserves the marker's own byte count and appends
        /// exactly `pad` ASCII spaces (1:1 in UTF-8), so the final length is
        /// exact by construction — no re-measure drift, no escaping risk.
        func sizedTicketData(totalBytes: Int) throws -> Data {
            var ticket = baseTicket()
            ticket["summary"] = ""
            let skeleton = try String(decoding: JSONSerialization.data(withJSONObject: ticket), as: UTF8.self)
            guard let range = skeleton.range(of: "\"summary\":\"\"") else {
                throw XCTSkip("skeleton marker missing — baseTicket layout changed")
            }
            // Orchestrator unblock (R25): sibling mid-edit left `padCount` referenced
            // but undefined, freezing the whole test-bundle link. Definition per the
            // comment above: pad = target − skeleton (marker replacement is 1:1).
            let padCount = totalBytes - skeleton.count
            let padded = skeleton.replacingCharacters(
                in: range,
                with: "\"summary\":\"\(String(repeating: " ", count: max(0, padCount)))\""
            )
            let data = Data(padded.utf8)
            XCTAssertEqual(data.count, totalBytes,
                           "fixture self-check: serialized ticket must be exactly \(totalBytes) bytes")
            return data
        }

        let exact = try writeTicketData(sizedTicketData(totalBytes: limit), name: "exact.json")
        let oversized = try writeTicketData(sizedTicketData(totalBytes: limit + 1), name: "oversized.json")
        defer {
            try? FileManager.default.removeItem(at: exact.dir)
            try? FileManager.default.removeItem(at: oversized.dir)
        }

        // Exactly maxTicketBytes is accepted…
        let accepted = TicketConsumer.acquire(argumentPath: exact.path)
        guard case let .success(acquired) = accepted else {
            return XCTFail("exactly-\(limit)-byte ticket must be accepted, got \(accepted)")
        }
        XCTAssertEqual(acquired.ticket.argv, ["/bin/true"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumingPath(for: exact.path)),
                       ".consuming marker must be cleaned up after a successful acquire")

        // …and one byte more is rejected as oversized, marker cleaned up too.
        let rejected = TicketConsumer.acquire(argumentPath: oversized.path)
        guard case .failure(.oversized) = rejected else {
            return XCTFail("\(limit + 1)-byte ticket must fail as .oversized, got \(rejected)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumingPath(for: oversized.path)),
                       ".consuming marker must not survive an oversized rejection")
    }

    // MARK: B2

    func testTwoConcurrentConsumersCannotBothAcquireTheSameTicket() throws {
        let fixture = try writeTicket(baseTicket())
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        final class OutcomeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var outcomes: [String] = []
            private var winnerArgv: [String]?

            func recordSuccess(argv: [String]) {
                lock.lock(); outcomes.append("success"); winnerArgv = argv; lock.unlock()
            }

            func recordFailure(_ outcome: String) {
                lock.lock(); outcomes.append(outcome); lock.unlock()
            }

            var snapshot: (outcomes: [String], winnerArgv: [String]?) {
                lock.lock(); defer { lock.unlock() }; return (outcomes, winnerArgv)
            }
        }
        let box = OutcomeBox()

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            switch TicketConsumer.acquire(argumentPath: fixture.path) {
            case let .success(acquired):
                box.recordSuccess(argv: acquired.ticket.argv)
            case .failure(.alreadyConsuming):
                box.recordFailure("alreadyConsuming")
            case let .failure(other):
                box.recordFailure("other:\(other)")
            }
        }

        let result = box.snapshot
        XCTAssertEqual(result.outcomes.filter { $0 == "success" }.count, 1,
                       "of two simultaneous acquirers exactly one may win")
        if let loser = result.outcomes.first(where: { $0 != "success" }) {
            // A winner that finishes consume+cleanup before the loser opens
            // leaves neither marker nor ticket: ENOENT is a legal verdict.
            XCTAssertTrue(loser == "alreadyConsuming" || loser.hasPrefix("other:"),
                          "loser must observe alreadyConsuming or consumed-ticket absence, got \(loser)")
        } else {
            XCTFail("second acquirer must not also succeed")
        }
        XCTAssertEqual(result.winnerArgv, ["/bin/true"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path),
                       "single-use: the original is gone regardless of who won")
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumingPath(for: fixture.path)),
                       "the claim marker is unlinked after the handover completes")
    }

    // MARK: B3

    func testMalformedTicketLeavesNeitherOriginalNorConsumingMarkerOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlauncher-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("broken.json").path
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path, contents: Data("{not json".utf8), attributes: [.posixPermissions: 0o600]
        ))

        let outcome = TicketConsumer.acquire(argumentPath: path)

        guard case .failure(.malformedJSON) = outcome else {
            return XCTFail("malformed ticket must fail as .malformedJSON, got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "delete-after-read runs before decoding; original must be gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumingPath(for: path)),
                       "a stuck .consuming marker would permanently poison this ticket path")
    }

    // MARK: B4a/B4b

    /// Shared `LaunchTicket.make` fixture with one mutated field per case.
    private func ticketVariant(
        argv: [String] = ["/bin/true"],
        cwd: String = "/tmp",
        protocolVersion: Int = LaunchTicket.currentProtocolVersion
    ) -> LaunchTicket {
        var ticket = LaunchTicket.make(
            agentID: UUID(), terminalID: UUID(), surfaceGeneration: 7,
            cwd: cwd, argv: argv, environment: [:],
            integrationToken: "token", controlSocketPath: "",
            now: Date().timeIntervalSince1970
        )
        ticket.protocolVersion = protocolVersion
        return ticket
    }

    // MARK: B4 (split — the design's scope table counts 5 Suite-B tests)

    func testValidateRejectsAtExactExpiryBoundary() {
        // Exact TTL boundary: equality IS expired (now >= expiresAt).
        let boundary = LaunchTicket.make(
            agentID: UUID(), terminalID: UUID(), surfaceGeneration: 7,
            cwd: "/tmp", argv: ["/bin/true"], environment: [:],
            integrationToken: "token", controlSocketPath: "", now: 1000, ttl: 60
        )
        XCTAssertEqual(boundary.expiresAt, 1060)
        XCTAssertTrue(boundary.isExpired(atEpochSeconds: boundary.expiresAt),
                      "now == expiresAt must count as expired")
        XCTAssertFalse(boundary.isExpired(atEpochSeconds: boundary.expiresAt - 1))

        XCTAssertNil(TicketConsumer.validate(ticketVariant()), "a fully valid ticket validates clean")
        XCTAssertEqual(TicketConsumer.validate(ticketVariant(protocolVersion: 0)), "unsupported protocolVersion")
    }

    func testValidateEnforcesAbsolutePaths() {
        XCTAssertEqual(TicketConsumer.validate(ticketVariant(argv: [])), "argv is empty")
        XCTAssertEqual(TicketConsumer.validate(ticketVariant(cwd: "tmp/rel")), "cwd is not absolute")
        XCTAssertEqual(TicketConsumer.validate(ticketVariant(argv: ["true"])), "argv[0] is not absolute",
                       "bare names would resolve via PATH; exact execve requires an absolute argv[0]")
    }

    // MARK: T1 — O_NONBLOCK open (6885f7b)

    /// A FIFO planted at the well-known ticket path must be rejected as
    /// `.notRegularFile` WITHOUT hanging: the O_NONBLOCK flag keeps `open`
    /// from blocking on a writerless FIFO before the S_IFREG gate can reject
    /// it. Dropping the flag hangs every subsequent launch forever.
    func testPlantedFifoAtTicketPathIsRejectedNonBlockingAsNotRegularFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlauncher-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let fifoPath = dir.appendingPathComponent("ticket.json").path
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0, "mkfifo failed with errno \(errno)")

        // Must RETURN (not block): O_NONBLOCK makes open(2) on a writerless
        // FIFO succeed immediately; fstat then fails the S_IFREG gate.
        let result = TicketConsumer.acquire(argumentPath: fifoPath)

        guard case let .failure(failure) = result else {
            return XCTFail("a planted FIFO must be rejected, got \(result)")
        }
        guard case .notRegularFile = failure else {
            return XCTFail("expected .notRegularFile, got \(failure)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: consumingPath(for: fifoPath)),
            "no claim marker may be made for a non-regular file"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifoPath), "the fifo itself must survive untouched")
    }

    // MARK: R28-S5 — failed ticket unlink (non-ENOENT) fails CLOSED

    /// When the post-link `unlink(argumentPath)` fails with anything other
    /// than ENOENT, the SAME inode could later be linked and launched twice —
    /// the acquire must therefore FAIL instead of returning success while the
    /// ticket bytes stay on disk under their original name.
    ///
    /// Fixture deviations from the design sketch (0555 source dir):
    /// 1. The claim name is always `argumentPath + ".consuming"`, i.e. the
    ///    link target shares the argument's directory — a write-less
    ///    directory fails the link(2) itself (EACCES → .alreadyConsuming)
    ///    and never reaches the undo branch. An append-only directory flag
    ///    (UF_APPEND) reaches it hermetically: adding an entry (link)
    ///    succeeds while removing one fails EPERM ≠ ENOENT.
    /// 2. The branch's own `unlink(consumed)` cleanup cannot be observed
    ///    with this fixture — every mechanism that blocks unlink(argumentPath)
    ///    (write-less dir, UF_APPEND, deny delete_child ACL — all probed)
    ///    blocks unlink(consumed) equally because both names share one parent
    ///    directory. The test therefore pins the two observable halves of the
    ///    law: fail-CLOSED (never a success result), and after the transient
    ///    condition clears and the stale claim marker is gone, the single-use
    ///    slot is NOT consumed — a fresh acquire succeeds end-to-end.
    func testFailedUnlinkFailsClosedAndDoesNotConsumeTheSingleUseSlot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlauncher-unlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            chflags(dir.path, 0) // clear UF_APPEND so removal can succeed
            try? FileManager.default.removeItem(atPath: dir.path)
        }

        let data = try JSONSerialization.data(withJSONObject: baseTicket())
        let ticketPath = dir.appendingPathComponent("ticket.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: ticketPath.path, contents: data, attributes: [.posixPermissions: 0o600]
        ))
        XCTAssertEqual(chflags(dir.path, UInt32(UF_APPEND)), 0,
                       "fixture precondition: append-only directory flag")

        // Act: open + fstat gates pass; link(claim) succeeds; unlink fails
        // EPERM (≠ ENOENT) → the undo branch runs.
        let result = TicketConsumer.acquire(argumentPath: ticketPath.path)

        // Fail closed: no success result may escape a non-ENOENT unlink
        // failure — returning success here is exactly the double-launch bug.
        guard case let .failure(.cannotOpen(errno)) = result else {
            return XCTFail("expected .cannotOpen from the unlink-undo branch, got \(result)")
        }
        XCTAssertEqual(errno, EPERM)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ticketPath.path),
            "the original ticket must be left in place for the next acquirer"
        )

        // The single-use slot is genuinely NOT consumed by the FAILED attempt:
        // once the transient condition clears (flag removed) and the leftover
        // claim marker is swept (what the undo achieves when unlink(consumed)
        // is possible), a fresh acquire succeeds end-to-end.
        chflags(dir.path, 0)
        try? FileManager.default.removeItem(atPath: consumingPath(for: ticketPath.path))
        let second = TicketConsumer.acquire(argumentPath: ticketPath.path)
        guard case .success = second else {
            return XCTFail("a fresh acquire after the failed attempt must succeed, got \(second)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ticketPath.path),
                       "the successful acquire deletes the ticket from disk")
    }
}

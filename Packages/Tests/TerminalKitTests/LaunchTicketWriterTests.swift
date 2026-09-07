import AgentCore
@testable import TerminalKit
import XCTest

// Launch ticket writer security semantics (§3.9): 0600 from creation,
// O_EXCL collision rejection, roundtrip via AgentCore.LaunchTicket, cancel
// deletes only writer-owned tickets.

final class LaunchTicketWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-tickets-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeTicket() -> LaunchTicket {
        LaunchTicket.make(
            agentID: AgentID().rawValue,
            terminalID: TerminalID().rawValue,
            surfaceGeneration: 3,
            cwd: "/tmp",
            argv: ["/bin/echo", "hello world"],
            environment: ["PATH": "/usr/bin", "AGENT_TERMINAL_TOKEN": "secret"],
            integrationToken: "tok",
            controlSocketPath: "/tmp/ctrl.sock",
            now: 100
        )
    }

    func testWriteCreatesExclusive0600FileWithRoundtrippableContent() throws {
        let writer = LaunchTicketWriter(directory: directory)
        let ticket = makeTicket()

        let url = try writer.write(ticket)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600, "ticket must be 0600")

        let decoded = try JSONDecoder().decode(LaunchTicket.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded, ticket)
        XCTAssertTrue(decoded.environment["AGENT_TERMINAL_TOKEN"] == "secret")
    }

    func testSecondWriteToSamePathFailsOEXCL() throws {
        let writer = LaunchTicketWriter(directory: directory)
        var ticket = makeTicket()
        try writer.write(ticket)

        // Same UUID → same path → O_EXCL must reject.
        ticket.createdAt += 1
        XCTAssertThrowsError(try writer.write(ticket))
    }

    func testCancelDeletesOwnTicketButNotForeignFiles() throws {
        let writer = LaunchTicketWriter(directory: directory)
        let url = try writer.write(makeTicket())

        let foreign = directory.appendingPathComponent("foreign.json")
        FileManager.default.createFile(atPath: foreign.path, contents: Data([1]))

        XCTAssertTrue(writer.cancel(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(writer.cancel(at: foreign), "foreign files must not be deletable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))

        // Cancel is single-use.
        XCTAssertFalse(writer.cancel(at: url))
    }

    func testTicketExpiryContractStillHoldsAfterRoundtrip() throws {
        let writer = LaunchTicketWriter(directory: directory)
        let url = try writer.write(makeTicket())
        let decoded = try JSONDecoder().decode(LaunchTicket.self, from: Data(contentsOf: url))
        XCTAssertTrue(decoded.isExpired(atEpochSeconds: decoded.expiresAt + 1))
        XCTAssertFalse(decoded.isExpired(atEpochSeconds: decoded.createdAt))
    }

    // MARK: Round 14 C1

    func testWriteSweepsStaleConsumingRemnantBeforeCreatingTicket() throws {
        let writer = LaunchTicketWriter(directory: directory)
        let ticket = makeTicket()

        // Write once to learn the URL shape for this UUID.
        let url = try writer.write(ticket)

        // Crash-recycle scenario: a consumer claimed the ticket by
        // hard-linking <path> → <path>.consuming and unlinking <path>,
        // then died. Reproduce both halves directly.
        let consumingPath = url.path + ".consuming"
        XCTAssertTrue(FileManager.default.createFile(atPath: consumingPath, contents: Data([0xDE, 0xAD])))
        try FileManager.default.removeItem(at: url)

        // A foreign .consuming remnant for a DIFFERENT uuid must survive
        // the sweep (scoping proof).
        let foreignConsuming = directory.appendingPathComponent("\(UUID().uuidString).json.consuming")
        XCTAssertTrue(FileManager.default.createFile(atPath: foreignConsuming.path, contents: Data([1])))

        // Fresh writer instance, same directory — mirroring the recycle.
        let recycled = LaunchTicketWriter(directory: directory)
        let rewritten = try recycled.write(ticket)
        XCTAssertEqual(rewritten, url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: consumingPath), "own remnant must be swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignConsuming.path), "sweep must stay per-url")

        let decoded = try JSONDecoder().decode(LaunchTicket.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded, ticket)
    }
}

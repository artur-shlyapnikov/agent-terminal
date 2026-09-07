import AgentCore
@testable import AgentTerminal
import TerminalKit
import XCTest

// Stage-10 regression (inherited open item new-3): the ticketed launch path
// must stamp the REQUESTED surface generation into the one-shot launch ticket.
// A restart allocates generation N+1; if the writer dropped it, the launcher
// would consume a generation-0 ticket and every hook report of the restarted
// agent would be rejected as stale (§3.9/§3.6).
//
// Strategy: launch through TerminalSessionManager.launch(surfaceGeneration: 3)
// with /usr/bin/true as a stub launcher, then decode the written ticket and
// assert its surfaceGeneration == 3 and its terminalID matches the session.

@MainActor
final class Stage10TicketGenerationTests: XCTestCase {
    func testTicketedLaunchStampsRequestedSurfaceGeneration() throws {
        // The hosted app already ran globalInit; a fresh bridge init here is
        // either an idempotent no-op or unavailable (skip, never flake).
        do { try GhosttyEngine.globalInit() } catch {
            throw XCTSkip("libghostty global init unavailable: \(error)")
        }

        let tickets = FileManager.default.temporaryDirectory
            .appendingPathComponent("aterm-stage10-tickets-\(UUID().uuidString)")
        let engine = try GhosttyEngine()
        let manager = TerminalSessionManager(
            engine: engine,
            parkingHost: TerminalParkingHost(),
            ticketWriter: LaunchTicketWriter(directory: tickets),
            inputBracketedPaste: false
        )
        defer {
            for session in manager.allSessions {
                try? manager.close(terminalID: session.id)
            }
            try? FileManager.default.removeItem(at: tickets)
        }

        let agentID = AgentID()
        let session = try manager.launch(
            workspaceID: WorkspaceID(),
            agentID: agentID,
            spec: LaunchSpec(argv: ["/bin/sh"], workingDirectory: "/tmp"),
            launcherExecutable: URL(fileURLWithPath: "/usr/bin/true"), // stub helper
            integrationToken: "stage10-ticket-test",
            controlSocketPath: "/tmp/aterm-stage10-nonexistent.sock",
            surfaceGeneration: SurfaceGeneration(rawValue: 3)
        )

        // Decode the freshly written ticket (exactly one exists).
        let files = try FileManager.default.contentsOfDirectory(at: tickets, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1, "expected exactly one launch ticket")
        let data = try Data(contentsOf: files[0])
        let ticket = try JSONDecoder().decode(LaunchTicket.self, from: data)

        XCTAssertEqual(ticket.surfaceGeneration, 3,
                       "ticket must carry the requested surface generation")
        XCTAssertEqual(ticket.terminalID, session.id.rawValue)
        XCTAssertEqual(ticket.agentID, agentID.rawValue)

        // The registry-facing session carries the same generation.
        XCTAssertEqual(session.surfaceGeneration, SurfaceGeneration(rawValue: 3))
    }
}

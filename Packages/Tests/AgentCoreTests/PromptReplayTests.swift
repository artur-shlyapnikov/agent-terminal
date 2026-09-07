@testable import AgentCore
import XCTest

// Stage-9 (Main-approved exception): client-supplied commandID replay cache.
//
//  1. the same commandID replays the ORIGINAL receipt without a second
//     terminal delivery or a second timeline event;
//  2. distinct commandIDs deliver normally;
//  3. the cache is bounded — oldest entries are evicted, after which a
//     reused key delivers again (a fresh command, not a silent drop).

@MainActor
final class PromptReplayTests: XCTestCase {
    private func makeIdleAgent(
        runtime: AgentRuntime,
        port: FakeTerminalPort,
        clock: FakeClock,
        kind: AgentKind = .openCode // not process-only → full prompt surface
    ) async throws -> (WorkspaceID, AgentID) {
        await runtime.setTerminalPort(port)
        let (workspace, agent, _) = try await runtime.makeRunningAgent(kind: kind)
        await runtime.ingest(integrationEvidence(
            agent: agent,
            lifecycle: .idle,
            sequence: 1,
            receivedAt: clock.now
        ))
        return (workspace, agent)
    }

    private func deliveredEventCount(
        _ runtime: AgentRuntime, agent: AgentID, commandID: CommandID
    ) async -> Int {
        await runtime.timeline(of: agent).filter {
            if case let .promptDelivered(id) = $0.event {
                return id == commandID
            }
            return false
        }.count
    }

    func testReplaySameCommandIDDeliversExactlyOnce() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let port = FakeTerminalPort()
        let (_, agent) = try await makeIdleAgent(runtime: runtime, port: port, clock: clock)

        let key = CommandID()
        let first = try await runtime.prompt(agent, "once only", .sendNow, commandID: key)
        let second = try await runtime.prompt(agent, "once only", .sendNow, commandID: key)

        XCTAssertEqual(first, second)
        let replayedEventCount = await deliveredEventCount(runtime, agent: agent, commandID: first.commandID)
        XCTAssertEqual(port.deliverInputCallCount, 1, "replay must NOT re-deliver")
        XCTAssertEqual(replayedEventCount, 1)
        XCTAssertEqual(first.outcome, .delivered)
    }

    func testDistinctCommandIDsDeliverNormally() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let port = FakeTerminalPort()
        let (_, agent) = try await makeIdleAgent(runtime: runtime, port: port, clock: clock)

        _ = try await runtime.prompt(agent, "first", .sendNow, commandID: CommandID())
        _ = try await runtime.prompt(agent, "second", .sendNow, commandID: CommandID())

        XCTAssertEqual(port.deliverInputCallCount, 2)
    }

    func testReplayCacheIsBoundedOldestEvicted() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let port = FakeTerminalPort()
        let (_, agent) = try await makeIdleAgent(runtime: runtime, port: port, clock: clock)

        // Fill past the cap with DISTINCT keys; the first key falls out.
        let firstKey = CommandID()
        _ = try await runtime.prompt(agent, "evict-me", .sendNow, commandID: firstKey)
        for index in 0 ..< (64 + 1) {
            _ = try await runtime.prompt(agent, "filler \(index)", .sendNow, commandID: CommandID())
        }
        XCTAssertTrue(port.deliveredTexts.contains { $0.1 == "evict-me" })
        let deliveriesAfterFill = port.deliverInputCallCount

        // Evicted key: no cached receipt anymore → treated as a NEW command.
        let evicted = try? await runtime.prompt(agent, "evict-me", .sendNow, commandID: firstKey)
        XCTAssertNotNil(evicted)
        XCTAssertEqual(port.deliverInputCallCount, deliveriesAfterFill + 1)

        // A recent key inside the cap still replays without delivering.
        let recentKey = CommandID()
        _ = try await runtime.prompt(agent, "recent", .sendNow, commandID: recentKey)
        let before = port.deliverInputCallCount
        _ = try await runtime.prompt(agent, "recent", .sendNow, commandID: recentKey)
        XCTAssertEqual(port.deliverInputCallCount, before)
    }
}

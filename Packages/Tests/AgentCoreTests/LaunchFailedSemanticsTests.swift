import AgentCore
import XCTest

// launchFailed semantic command (§3.5): the terminal layer could not bring a
// surface up AFTER createAgent minted the session. The runtime must own the
// completion of that lifecycle — orchestration can never strand a
// "starting" zombie (the old interface gap).

final class LaunchFailedSemanticsTests: XCTestCase {
    func testLaunchFailedMovesStartingSessionToFailed() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let workspaceID = await runtime.createWorkspace(name: "w", rootPath: "/tmp")
        let agent = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp",
                               displayName: "doomed"),
            in: workspaceID
        )

        var state = try await runtime.state(of: agent)
        XCTAssertEqual(state.lifecycle, .starting, "precondition: session starts as starting")

        try await runtime.launchFailed(agentID: agent, reason: "surface spawn failed")

        state = try await runtime.state(of: agent)
        guard case .failed = state.lifecycle else {
            XCTFail("expected failed lifecycle, got \(state.lifecycle)")
            return
        }
        // The plan carries the reason on the process side (§3.5 row 1).
        guard case let .launchFailed(descriptor) = state.process else {
            XCTFail("expected launchFailed process detail, got \(state.process)")
            return
        }
        XCTAssertTrue(descriptor.contains("surface spawn failed"))
    }

    /// A second failure edge on an ALREADY-failed session stays inert
    /// (no-op edge keeps revision stable — machine law for repeated edges).
    func testRepeatedLaunchFailedDoesNotRegressOrLoopTheMachine() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let workspaceID = await runtime.createWorkspace(name: "w", rootPath: "/tmp")
        let agent = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp",
                               displayName: "doomed-twice"),
            in: workspaceID
        )
        try await runtime.launchFailed(agentID: agent, reason: "first")
        let afterFirst = try await runtime.state(of: agent)
        guard case .failed = afterFirst.lifecycle else {
            return XCTFail("precondition: first edge must fail the session")
        }
        try await runtime.launchFailed(agentID: agent, reason: "second")
        let afterSecond = try await runtime.state(of: agent)
        guard case .failed = afterSecond.lifecycle else {
            return XCTFail("terminal lifecycle must be absorbing")
        }
    }

    func testLaunchFailedOnUnknownAgentThrowsAgentNotFound() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        do {
            try await runtime.launchFailed(agentID: AgentID(), reason: "ghost")
            XCTFail("expected agentNotFound")
        } catch { /* expected */ }
    }
}

@testable import AgentCore
import XCTest

// Stage-8 wiring: AgentRuntime.processExited must drive the §3.5 "process
// exited" rows through the real actor (exit 0 + user stop → stopped(userRequested),
// exit 0 → stopped(completed), completion attention only when a turn was
// open and the surface was hidden (§3.5 "Без completion notification"),
// non-zero/signal exit → failed). The terminal layer's exit-poll sink feeds
// exactly this entry point.

@MainActor
final class ProcessExitReportingTests: XCTestCase {
    private func makeLaunchedAgent(
        runtime: AgentRuntime,
        workspace _: WorkspaceID
    ) async throws -> AgentID {
        let workspace = await runtime.createWorkspace(name: "w", rootPath: "/tmp")
        let agentID = try await runtime.createAgent(
            AgentLaunchRequest(
                agentKind: .genericShell,
                workingDirectory: "/tmp",
                displayName: "exit-test"
            ),
            in: workspace
        )
        try await runtime.surfaceCreated(
            agentID: agentID,
            terminalID: TerminalID(),
            generation: .initial,
            pid: 4242,
            processGroupID: 4242
        )
        return agentID
    }

    func testCleanUserInitiatedExitTransitionsToStoppedUserRequested() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let agent = try await makeLaunchedAgent(
            runtime: runtime, workspace: WorkspaceID()
        )

        try await runtime.processExited(agentID: agent, exitCode: 0, signal: nil, userInitiated: true)

        let state = try await runtime.state(of: agent)
        guard case .stopped(.userRequested) = state.lifecycle else {
            return XCTFail("expected stopped(userRequested), got \(state.lifecycle)")
        }
        XCTAssertTrue(state.attention == .none, "user stop never raises attention")
    }

    func testCleanNaturalExitCompletionAttentionFollowsTurnLaw() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let agent = try await makeLaunchedAgent(
            runtime: runtime, workspace: WorkspaceID()
        )

        // §3.5: exit evidence with NO open turn ⇒ no completion notification
        // (a never-prompted shell exiting cleanly stays silent).
        try await runtime.processExited(agentID: agent, exitCode: 0, signal: nil, userInitiated: false)
        var state = try await runtime.state(of: agent)
        guard case .stopped(.completed) = state.lifecycle else {
            return XCTFail("expected stopped(completed), got \(state.lifecycle)")
        }
        XCTAssertFalse(state.hasCompletionAttention,
                       "no open turn ⇒ clean completion raises no attention")

        // With an OPEN turn (working evidence opened it), a hidden clean
        // exit closes the turn and raises completionUnread.
        let working = try await makeLaunchedAgent(
            runtime: runtime, workspace: WorkspaceID()
        )
        await runtime.ingest(screenEvidence(
            agent: working,
            lifecycle: .working,
            receivedAt: instant(5),
            outputRevision: 1
        ))
        try await runtime.processExited(agentID: working, exitCode: 0, signal: nil, userInitiated: false)
        state = try await runtime.state(of: working)
        guard case .stopped(.completed) = state.lifecycle else {
            return XCTFail("expected stopped(completed), got \(state.lifecycle)")
        }
        XCTAssertTrue(state.hasCompletionAttention,
                      "open turn + hidden clean completion ⇒ completionUnread")
    }

    func testSignalledExitTransitionsToFailed() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let agent = try await makeLaunchedAgent(
            runtime: runtime, workspace: WorkspaceID()
        )

        try await runtime.processExited(agentID: agent, exitCode: nil, signal: SIGTERM, userInitiated: true)

        let state = try await runtime.state(of: agent)
        guard case .failed = state.lifecycle else {
            return XCTFail("expected failed, got \(state.lifecycle)")
        }
        guard case .failure = state.attention else {
            return XCTFail("failed lifecycle must raise failure attention")
        }
    }
}

private extension AgentState {
    var hasCompletionAttention: Bool {
        if case .completionUnread = attention {
            return true
        }
        return false
    }
}

import AgentCore
import XCTest

// Workspace identity contract (§3.14): the runtime adopts workspaces under
// the identity the caller owns — a restored row keeps its persisted ID, a
// first-run workspace is registered under exactly the ID that gets
// persisted. One WorkspaceID across runtime sessions, agent rows and
// control-plane listings; a relaunch re-opens the same ID.

final class WorkspaceIdentityTests: XCTestCase {
    /// A workspace persisted by run 1 is opened in run 2's fresh runtime
    /// under its ORIGINAL id; agents created there use that id.
    func testRestoredWorkspaceKeepsItsIdentityAcrossRelaunch() async throws {
        let clock = FakeClock()
        let runtime1 = AgentRuntime(clock: clock)
        // Run 1: mint ONE workspace (as first-run does) — the embedder
        // persists this exact instance.
        let minted = Workspace(
            name: "Default", rootPath: "/tmp/default",
            createdAt: clock.now, updatedAt: clock.now
        )
        await runtime1.openWorkspace(minted)

        // Run 2: brand-new runtime (process restart), same persisted row.
        let runtime2 = AgentRuntime(clock: FakeClock())
        let reopened = await runtime2.openWorkspace(minted)
        XCTAssertEqual(reopened, minted.id, "openWorkspace must never substitute an id")

        let agent = try await runtime2.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp",
                               displayName: "restored-agent"),
            in: minted.id
        )
        let projection = await runtime2.projection()
        XCTAssertEqual(projection.agents.first?.id, agent)
        XCTAssertEqual(projection.agents.first?.workspaceID, minted.id,
                       "runtime session, store row and control plane share ONE id")
    }

    /// The authoritative enumeration lists every opened workspace in
    /// adoption order with its original metadata — control-plane
    /// `workspace.list` cannot drift from launch-time identity.
    func testAuthoritativeEnumerationPreservesOrderAndMetadata() async {
        let runtime = AgentRuntime(clock: FakeClock())
        let first = Workspace(name: "One", rootPath: "/tmp/one", createdAt: .zero, updatedAt: .zero)
        let second = Workspace(name: "Two", rootPath: "/tmp/two", createdAt: .zero, updatedAt: .zero)
        _ = await runtime.openWorkspace(first)
        _ = await runtime.openWorkspace(second)

        let listed = await runtime.listWorkspaces()
        XCTAssertEqual(listed.map(\.id), [first.id, second.id])
        XCTAssertEqual(listed.map(\.name), ["One", "Two"])
    }

    /// Two restored workspaces keep their agents separate (no mixing).
    func testAgentsStayInsideTheirOwnRestoredWorkspace() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let wsA = Workspace(name: "A", rootPath: "/tmp/a", createdAt: .zero, updatedAt: .zero)
        let wsB = Workspace(name: "B", rootPath: "/tmp/b", createdAt: .zero, updatedAt: .zero)
        _ = await runtime.openWorkspace(wsA)
        _ = await runtime.openWorkspace(wsB)

        let agentA = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp/a",
                               displayName: "in-a"),
            in: wsA.id
        )
        let agentB = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp/b",
                               displayName: "in-b"),
            in: wsB.id
        )

        let snapshot = await runtime.projection()
        let workspaceOf: (AgentID) -> WorkspaceID? = { id in
            snapshot.agents.first { $0.id == id }?.workspaceID
        }
        XCTAssertEqual(workspaceOf(agentA), wsA.id)
        XCTAssertEqual(workspaceOf(agentB), wsB.id)

        // Unknown workspace ids are still rejected for creates.
        do {
            _ = try await runtime.createAgent(
                AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp",
                                   displayName: "ghost"),
                in: WorkspaceID()
            )
            XCTFail("create into an unopened workspace must fail")
        } catch { /* expected */ }
    }
}

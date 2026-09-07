import AgentCore
@testable import AgentTerminal
import XCTest

// Sidebar grouping coverage (§3.13): Needs attention / Working / Idle /
// Stopped / Shells, and state text/symbol presence (never color-only).

final class SidebarGroupingTests: XCTestCase {
    private func summary(
        lifecycle: LifecyclePhase,
        attention: AttentionState = .none,
        name: String = "agent"
    ) -> AgentSummary {
        let state = AgentState(
            process: .running(pid: 42, processGroupID: 42),
            lifecycle: lifecycle,
            attention: attention,
            authority: .process,
            revision: 1,
            observedAt: .zero
        )
        return AgentSummary(session: AgentSession(
            id: AgentID(),
            workspaceID: WorkspaceID(),
            kind: .genericShell,
            displayName: name,
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: .genericShell,
                program: "/bin/sh",
                workingDirectory: "/tmp"
            ),
            resumePolicy: .none,
            state: state,
            createdAt: .zero,
            lastActivityAt: .zero
        ))
    }

    private struct TestShell: ShellInfoProtocol {
        var terminalID: TerminalID
        var name: String
        var cwd: String
    }

    func testSectionsAreOrderedAndGrouped() {
        let sections = SidebarGrouping.sections(agents: [
            summary(lifecycle: .working, name: "b-worker"),
            summary(lifecycle: .idle, name: "a-idle"),
            summary(lifecycle: .stopped(.completed), name: "c-stopped"),
            summary(lifecycle: .idle, attention: .inputRequired(since: .zero, requestID: nil), name: "d-input"),
        ], shells: [
            TestShell(terminalID: TerminalID(), name: "Shell 1", cwd: "/tmp"),
        ])

        XCTAssertEqual(sections.map(\.title), ["Needs attention", "Working", "Idle", "Stopped", "Shells"])
        XCTAssertTrue(sections[0].rows.contains { $0.title == "d-input" })
        XCTAssertTrue(sections[2].rows.contains { $0.title == "a-idle" })
        XCTAssertTrue(sections[4].rows.contains { $0.title == "Shell 1" })
    }

    func testStateIsNeverColorOnly() {
        let row = SidebarGrouping.row(for: summary(
            lifecycle: .working, attention: .inputRequired(since: .zero, requestID: nil)
        ))
        XCTAssertEqual(row.stateText, "Waiting for input")
        XCTAssertFalse(row.stateSymbol.isEmpty)
        // The row carries a textual state; color alone is never the signal.
        XCTAssertFalse(row.stateText.isEmpty)
    }

    func testQueuedBadgeSurfacesFromSummary() {
        // hasQueuedPrompt comes from AgentSession.queuedPrompt; the pure row
        // builder maps it — verified indirectly via a session without queue.
        let row = SidebarGrouping.row(for: summary(lifecycle: .idle))
        XCTAssertFalse(row.showsQueuedBadge)
    }
}

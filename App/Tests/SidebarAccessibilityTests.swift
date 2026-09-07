import AgentCore
@testable import AgentTerminal
import XCTest

// Sidebar accessibility contract (§3.23) — the surface the AX latency
// driver and VoiceOver both depend on:
//
//  1. every row exposes itself as ONE accessibility element with role
//     .button, a composed label (title + state text, never color-only),
//     and the "sidebar.row" identifier;
//  2. section headers and the empty state carry readable labels;
//  3. the §4.6 in-place refresh fast path keeps the accessibility label
//     in sync with the visible payload (rename within a bucket);
//  4. rows sit in the view hierarchy under the sidebar's scroll content,
//     so a system AX walk from the window reaches them.
//
// Regression context: an external AX probe once reported the sidebar as
// AXUnknown — that reading came from a crash-recovery launch whose main
// window was deliberately unkeyed (§3.15), not from missing row
// accessibility. These tests pin the view-level contract so the driver's
// assumptions hold regardless of launch state.

@MainActor
final class SidebarAccessibilityTests: XCTestCase {
    private func summary(
        id: AgentID = AgentID(),
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
            id: id,
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

    private func makeController(model: AppModel) -> AgentSidebarViewController {
        let controller = AgentSidebarViewController(model: model) { _, _ in }
        _ = controller.view
        controller.refresh()
        return controller
    }

    private func rowViews(in view: NSView) -> [AgentRowView] {
        var result: [AgentRowView] = []
        for sub in view.subviews {
            if let row = sub as? AgentRowView {
                result.append(row)
            }
            result.append(contentsOf: rowViews(in: sub))
        }
        return result
    }

    private func allTextFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        for sub in view.subviews {
            if let field = sub as? NSTextField {
                result.append(field)
            }
            result.append(contentsOf: allTextFields(in: sub))
        }
        return result
    }

    // MARK: 1 — rows are single button elements

    func testRowsExposeAsButtonElementsWithComposedLabels() {
        let model = AppModel()
        model.replaceAll(agents: [
            summary(lifecycle: .working, name: "worker-one"),
            summary(lifecycle: .idle, name: "idler"),
        ])
        model.add(shell: AppModel.ShellInfo(terminalID: TerminalID(), name: "Shell 1", cwd: "/tmp"))
        let controller = makeController(model: model)

        let rows = rowViews(in: controller.view)
        XCTAssertEqual(rows.count, 3, "two agent rows + one shell row build")
        for row in rows {
            XCTAssertTrue(row.isAccessibilityElement(), "row reads as one element, not a subtree")
            XCTAssertEqual(row.accessibilityRole(), .button, "row role is button (pressable)")
            XCTAssertEqual(row.accessibilityIdentifier(), "sidebar.row")
            let label = row.accessibilityLabel() ?? ""
            XCTAssertFalse(label.isEmpty, "row label is never empty")
            XCTAssertTrue(label.contains(row.row.title), "label carries the visible title")
            XCTAssertTrue(label.contains(row.row.stateText), "state is textual in the label — never color-only")
        }
    }

    // MARK: 2 — headers and empty state

    func testSectionHeadersAndEmptyStateCarryLabels() {
        let model = AppModel()
        model.upsert(agent: summary(lifecycle: .working, name: "worker"))
        let controller = makeController(model: model)

        // Section header: an NSTextField with the "Section …" label.
        let headers = allTextFields(in: controller.view).filter {
            ($0.accessibilityLabel() ?? "").hasPrefix("Section")
        }
        XCTAssertFalse(headers.isEmpty, "section headers carry accessibility labels")
        XCTAssertTrue(
            headers.contains { ($0.accessibilityLabel() ?? "").contains("Working") },
            "header label names the section"
        )

        // Empty state: one readable static element with a stable identifier.
        let emptyModel = AppModel()
        let empty = makeController(model: emptyModel)
        let emptyFields = allTextFields(in: empty.view).filter {
            $0.accessibilityIdentifier() == "sidebar.empty"
        }
        XCTAssertEqual(emptyFields.count, 1)
        XCTAssertTrue(emptyFields[0].isAccessibilityElement())
        XCTAssertFalse((emptyFields[0].accessibilityLabel() ?? "").isEmpty)
    }

    // MARK: 3 — in-place refresh keeps the label in sync

    func testInPlaceRenameUpdatesAccessibilityLabel() {
        let model = AppModel()
        let id = AgentID()
        model.upsert(agent: summary(id: id, lifecycle: .working, name: "before-rename"))
        let controller = makeController(model: model)

        let before = rowViews(in: controller.view)
        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(before[0].accessibilityLabel()?.contains("before-rename") ?? false)

        // Rename within the same bucket: the §4.6 in-place fast path (apply)
        // must run — not a rebuild — and the AX label must follow.
        model.upsert(agent: summary(id: id, lifecycle: .working, name: "after-rename"))
        controller.refresh()

        let after = rowViews(in: controller.view)
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after[0] === before[0], "same view instance — in-place path, no rebuild")
        XCTAssertTrue(after[0].accessibilityLabel()?.contains("after-rename") ?? false,
                      "accessibility label tracks the rename")
        XCTAssertEqual(after[0].accessibilityRole(), .button)
    }

    // MARK: 4 — rows reachable from the scroll content

    func testRowsSitUnderTheSidebarScrollContent() {
        let model = AppModel()
        model.upsert(agent: summary(lifecycle: .idle, name: "row-owner"))
        let controller = makeController(model: model)

        // The system AX walk goes window → split → scroll area → document
        // view → rows. Lock the view-graph half: a row is a descendant of
        // the controller's view (the scroll content), i.e. reachable.
        let rows = rowViews(in: controller.view)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isDescendant(of: controller.view))
    }
}

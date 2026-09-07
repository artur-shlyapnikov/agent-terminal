import AgentCore
@testable import AgentTerminal
import AppKit
@testable import TerminalKit
import XCTest

// Refresh idempotence (§4.6 whole-model fan-out): every agent delta refreshes
// the whole chrome, so each refresher must be cheap when its rendered inputs
// did not change:
//  - AgentRowView renders duration + queued badge from the RowModel (init
//    previously never wired either);
//  - PaneHeaderView no-ops on identical content;
//  - AgentInspectorController skips the rebuild + probe spawn while the
//    selection's rendered inputs are unchanged.

@MainActor
final class RefreshIdempotenceTests: XCTestCase {
    // MARK: - helpers

    private func summary(
        id: AgentID = AgentID(),
        name: String = "agent"
    ) -> AgentSummary {
        let state = AgentState(
            process: .running(pid: 42, processGroupID: 42),
            lifecycle: .idle,
            attention: .none,
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
                agentKind: .genericShell, program: "/bin/sh", workingDirectory: "/tmp"
            ),
            resumePolicy: .none,
            state: state,
            createdAt: .zero,
            lastActivityAt: .zero
        ))
    }

    private func label(in view: NSView, toolTip: String) -> NSTextField? {
        if let field = view as? NSTextField, field.toolTip == toolTip {
            return field
        }
        for subview in view.subviews {
            if let found = label(in: subview, toolTip: toolTip) {
                return found
            }
        }
        return nil
    }

    private func inspectorText(in view: NSView) -> String? {
        if let textView = view as? NSTextView {
            return textView.string
        }
        for subview in view.subviews {
            if let found = inspectorText(in: subview), !found.isEmpty {
                return found
            }
        }
        return nil
    }

    // MARK: 1 — row init renders duration + queued badge from the model

    func testRowViewRendersDurationAndQueueBadgeFromModel() {
        let id = AgentID()
        let loud = RowModel(
            item: .agent(id), title: "agent", subtitle: "task",
            stateSymbol: "circle", stateText: "Idle", durationText: "3m",
            showsQueuedBadge: true, tooltip: nil
        )
        let loudView = AgentRowView(model: loud)
        XCTAssertEqual(
            label(in: loudView, toolTip: "Time since last activity")?.stringValue, "3m",
            "the §3.13 duration label must render the row's duration text"
        )
        XCTAssertEqual(
            label(in: loudView, toolTip: "The agent has a prompt waiting to run")?.isHidden, false,
            "a queued row must show the queued badge"
        )

        let quiet = RowModel(
            item: .agent(id), title: "agent", subtitle: "task",
            stateSymbol: "circle", stateText: "Idle", durationText: "",
            showsQueuedBadge: false, tooltip: nil
        )
        let quietView = AgentRowView(model: quiet)
        XCTAssertTrue(
            label(in: quietView, toolTip: "Time since last activity")?.isHidden ?? false,
            "an empty duration must hide the duration label"
        )
        XCTAssertEqual(
            label(in: quietView, toolTip: "The agent has a prompt waiting to run")?.isHidden, true,
            "a row without a queued prompt must hide the queued badge"
        )
    }

    // MARK: 2 — pane header short-circuit

    func testPaneHeaderUpdateKeepsContentStableAcrossRedundantUpdates() {
        let header = PaneHeaderView()
        header.update(title: "agent", state: "Working", cwd: "/tmp")
        let applied = header.accessibilityLabel()
        XCTAssertNotNil(applied)

        // Identical re-update (the per-delta fan-out) keeps the rendering.
        header.update(title: "agent", state: "Working", cwd: "/tmp")
        XCTAssertEqual(header.accessibilityLabel(), applied)

        // Any rendered-input change is still reflected.
        header.update(title: "agent", state: "Idle", cwd: "/tmp")
        XCTAssertNotEqual(header.accessibilityLabel(), applied)
        header.update(title: "agent", state: "Idle", cwd: nil)
        XCTAssertNotEqual(header.accessibilityLabel(), applied)
    }

    // MARK: 3 — inspector skip-gate

    func testInspectorRefreshSkipsRebuildWhileSelectionInputsUnchanged() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let workspace = await runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "gate-agent"),
            in: workspace
        )
        let model = AppModel()
        model.upsert(agent: summary(id: id, name: "gate-agent"))

        let manager = TerminalSessionManager(
            engine: GateHarnessEngine(),
            parkingHost: GateHarnessParkingHost(),
            inputBracketedPaste: false
        )
        let seam = RuntimeSeam(runtime: runtime, sessionManager: manager, model: model)
        let controller = AgentInspectorController(model: model, seam: seam)
        _ = controller.view // force loadView()
        controller.setSelected(RowModel(
            item: .agent(id),
            title: "gate-agent",
            subtitle: "",
            stateSymbol: "",
            stateText: "",
            durationText: "",
            showsQueuedBadge: false,
            tooltip: nil
        ))

        // Pump until the async probes settled (diagnostics replaced its
        // placeholder) so the baseline text is final.
        let deadline = Date().addingTimeInterval(3)
        var settled: String?
        while Date() < deadline {
            if let current = inspectorText(in: controller.view),
               current.contains("health:"), !current.contains("probing…")
            {
                settled = current
                break
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let baseline = try XCTUnwrap(settled, "serialized refresh never completed")

        // An UNRELATED agent's delta must not rebuild the selection's text:
        // a real rebuild would reset the integration section to its
        // "probing…" placeholder synchronously.
        let otherID = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "unrelated"),
            in: workspace
        )
        model.upsert(agent: summary(id: otherID, name: "unrelated"))
        controller.refresh()
        let afterUnrelated = try XCTUnwrap(inspectorText(in: controller.view))
        XCTAssertEqual(afterUnrelated, baseline, "unchanged selection inputs must keep the built text")
        XCTAssertFalse(afterUnrelated.contains("probing…"), "the gate must not respawn probes for unrelated deltas")

        // A delta to the SELECTED agent reopens the gate.
        model.upsert(agent: summary(id: id, name: "renamed"))
        controller.refresh()
        let rebuilt = try XCTUnwrap(inspectorText(in: controller.view))
        XCTAssertNotEqual(rebuilt, baseline, "a selected-agent delta must rebuild")
        XCTAssertTrue(rebuilt.contains("renamed"), "the rebuilt text must show the new name")
    }

    // MARK: 4 — sidebar diff: same-structure deltas update rows in place

    private func allSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func rowViews(in view: NSView) -> [NSView] {
        allSubviews(of: view).filter { $0.accessibilityIdentifier() == "sidebar.row" }
    }

    func testSidebarRefreshReusesRowViewsForSameStructureDeltas() {
        let model = AppModel()
        let first = AgentID()
        model.upsert(agent: summary(id: first, name: "alpha"))
        model.upsert(agent: summary(id: AgentID(), name: "beta"))
        let controller = AgentSidebarViewController(model: model) { _, _ in }
        _ = controller.view

        let before = rowViews(in: controller.view)
        XCTAssertEqual(before.count, 2)

        // Same-structure delta — rename within the same attention bucket —
        // must update the EXISTING row views in place: no teardown, no
        // replacement, labels current.
        model.upsert(agent: summary(id: first, name: "renamed"))
        controller.refresh()

        let after = rowViews(in: controller.view)
        XCTAssertEqual(after.count, 2)
        for (index, view) in after.enumerated() {
            XCTAssertTrue(view === before[index], "row view at index \(index) must be reused, not rebuilt")
        }
        let labels = after.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains { $0.contains("renamed") }, "renamed row must show its new title: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("beta") })
    }

    func testSidebarRefreshRebuildsOnStructuralChange() {
        let model = AppModel()
        model.upsert(agent: summary(id: AgentID(), name: "alpha"))
        let controller = AgentSidebarViewController(model: model) { _, _ in }
        _ = controller.view

        let before = rowViews(in: controller.view)
        XCTAssertEqual(before.count, 1)

        // Adding an agent changes the entry count: the diff must rebuild and
        // produce fresh views rather than mutating the old row in place.
        model.upsert(agent: summary(id: AgentID(), name: "second"))
        controller.refresh()

        let after = rowViews(in: controller.view)
        XCTAssertEqual(after.count, 2)
        XCTAssertFalse(after.contains { $0 === before[0] }, "structural change must rebuild, not mutate")
        let labels = after.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains { $0.contains("alpha") })
    }
}

// MARK: - file-local harness fakes (mirror FinalFixTests)

@MainActor
private final class GateHarnessEngine: TerminalEngine {
    var eventSink: (@MainActor (GhosttyEvent) -> Void)?

    func tick() {}

    func createSurface(
        view _: NSView,
        spec _: TerminalLaunchSpec,
        box _: SurfaceCallbackBox
    ) throws -> any NativeTerminalSurface {
        struct NeverLaunched: Error {}
        throw NeverLaunched()
    }

    func shutdown() {}
}

@MainActor
private final class GateHarnessParkingHost: TerminalParkingHosting {
    let parkingContentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func park(_ view: NSView) {
        view.removeFromSuperview()
    }
}

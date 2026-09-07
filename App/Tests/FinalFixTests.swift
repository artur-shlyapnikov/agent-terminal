import AgentCore
@testable import AgentTerminal
import AppKit
@testable import TerminalKit
import XCTest

// Final-fix regression coverage (external review wave):
//
//  1. option-click split — the sidebar row reads ⌥ off the press and
//     delivers ClickKind.option (§3.13 option-click split); a press
//     carrying ⌥ NEVER arms the drag source;
//  2. clean-restore step 3 — restored layout leaves re-bind to THIS run's
//     reality: resumed agents remount through their id mapping, dead
//     shells/agents degrade to placeholders, selection survives only when
//     visible;
//  3. menu-bar 'needs input' counts ONLY .inputRequired attention.

@MainActor
final class FinalFixTests: XCTestCase {
    // MARK: - helpers

    private func summary(
        id: AgentID = AgentID(),
        lifecycle: LifecyclePhase = .idle,
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
                agentKind: .genericShell, program: "/bin/sh", workingDirectory: "/tmp"
            ),
            resumePolicy: .none,
            state: state,
            createdAt: .zero,
            lastActivityAt: .zero
        ))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    /// Click recorder backed by a reference box so closures stay observable
    /// after the helper returns (a captured local array would be copied out).
    private final class ClickRecorder {
        var received: [(SidebarItem, ClickKind)] = []
    }

    private func makeRow() -> (AgentRowView, AgentID, ClickRecorder) {
        let id = AgentID()
        let row = SidebarGrouping.row(for: summary(id: id, name: "row-agent"))
        let view = AgentRowView(model: row)
        let recorder = ClickRecorder()
        view.onClicked = { item, kind in recorder.received.append((item, kind)) }
        return (view, id, recorder)
    }

    // MARK: 1 — option-click split (§3.13)

    func testOptionClickDeliversOptionSelectionKind() {
        let (view, id, recorder) = makeRow()

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 5, y: 5), modifiers: [.option]))

        XCTAssertEqual(recorder.received.count, 1)
        XCTAssertEqual(recorder.received.first?.0, .agent(id))
        XCTAssertEqual(recorder.received.first?.1, .option, "⌥-press must reach the planner as .option")
    }

    func testPlainClickStillDeliversPlainAndArmsDragSource() {
        let (view, id, recorder) = makeRow()

        // Plain press delivers immediately…
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 5, y: 5), modifiers: []))
        XCTAssertEqual(recorder.received.count, 1)
        XCTAssertEqual(recorder.received.first?.0, .agent(id))
        XCTAssertEqual(recorder.received.first?.1, .plain)

        // …and arms the drag source: a sub-threshold move stays inert (no
        // drag session opens — one would crash this windowless view).
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 7, y: 6), modifiers: []))
        XCTAssertEqual(recorder.received.count, 1, "sub-threshold drag must not re-deliver")
    }

    func testOptionPressNeverOpensADragSession() {
        let (view, _, _) = makeRow()

        // The option press arms NOTHING: a drag far past the threshold on a
        // windowless view would crash in beginDraggingSession if the guard
        // regressed. Passing at all proves the session never opened.
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 5, y: 5), modifiers: [.option]))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 200, y: 200), modifiers: [.option]))
    }

    func testPlannerSplitsOnOptionClickDecision() {
        // Decision law: hidden item + ⌥ → splitFocused below max leaves.
        let item = SidebarItem.agent(AgentID())
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: item, kind: .option, visiblePane: nil,
                                       focusedPane: PaneID(), leafCount: 1),
            .splitFocused(axis: .horizontal, ratio: 0.5)
        )
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: item, kind: .option, visiblePane: nil,
                                       focusedPane: nil, leafCount: LayoutTree.maxLeaves),
            .rejectedMaxLeaves
        )
    }

    // MARK: 2 — clean-restore step 3 mapping

    private func treeWithLeaves(_ contents: [PaneContent]) -> LayoutTree {
        var tree = LayoutTree(leaf: contents[0])
        for content in contents.dropFirst() {
            guard let pane = tree.leaves.first(where: { $0.content != .placeholder })?.paneID
                ?? tree.leaves.first?.paneID else { break }
            _ = try? tree.splitting(paneID: pane, axis: .horizontal, ratio: 0.5, newContent: content)
        }
        return tree
    }

    func testRestoredTreeRemapsResumedAgentAndDegradesDeadLeaves() throws {
        let oldAgent = AgentID()
        let newAgent = AgentID()
        let deadAgent = AgentID()
        // Persisted: split(oldAgent | terminal) then a dead agent split in.
        var persisted = LayoutTree(leaf: .agent(oldAgent))
        let rootPane = persisted.leaves[0].paneID
        _ = try? persisted.splitting(
            paneID: rootPane, axis: .vertical, ratio: 0.5, newContent: .terminal(TerminalID())
        )
        let rightPane = try XCTUnwrap(persisted.leaves.first { $0.content != .agent(oldAgent) }?.paneID)
        _ = try? persisted.splitting(
            paneID: rightPane, axis: .horizontal, ratio: 0.5, newContent: .agent(deadAgent)
        )

        let live = AppCompositionRoot.liveTree(
            from: persisted,
            resumedMappings: [oldAgent: newAgent],
            liveAgentTerminals: [newAgent: TerminalID()]
        )

        let leaves = live.leaves
        XCTAssertEqual(leaves.count, 3, "structure is preserved under stable pane keys")
        XCTAssertTrue(leaves.contains { $0.content == .agent(newAgent) },
                      "the resumed agent remounts under its LIVE id")
        XCTAssertFalse(leaves.contains { $0.paneID == rootPane && $0.content == .placeholder },
                       "the resumed agent keeps its original pane")
        XCTAssertEqual(leaves.filter { $0.content == .placeholder }.count, 2,
                       "dead shells and non-resumed agents degrade to placeholders")
    }

    func testRestoredSelectionFollowsMappingAndVisibility() {
        let oldAgent = AgentID()
        let newAgent = AgentID()
        let tree = treeWithLeaves([.agent(newAgent), .placeholder])

        XCTAssertEqual(
            AppCompositionRoot.liveSelection(oldAgent, resumedMappings: [oldAgent: newAgent], tree: tree),
            newAgent
        )
        XCTAssertEqual(
            AppCompositionRoot.liveSelection(newAgent, resumedMappings: [:], tree: tree),
            newAgent
        )
        XCTAssertNil(
            AppCompositionRoot.liveSelection(AgentID(), resumedMappings: [:], tree: tree),
            "a selection that is not visible in the live tree is dropped"
        )
        XCTAssertNil(AppCompositionRoot.liveSelection(nil, resumedMappings: [:], tree: tree))
    }

    // MARK: 3 — menu-bar needs-input segment (§3.13)

    func testNeedsInputSegmentCountsOnlyInputRequired() {
        let model = AppModel()
        model.upsert(agent: summary(
            lifecycle: .working,
            attention: .failure(since: MonotonicInstant(nanosecondsSinceEpoch: 1), eventID: RuntimeEventID()),
            name: "failed"
        ))
        model.upsert(agent: summary(
            lifecycle: .idle,
            attention: .completionUnread(since: MonotonicInstant(nanosecondsSinceEpoch: 2), eventID: RuntimeEventID()),
            name: "done"
        ))
        model.upsert(agent: summary(
            lifecycle: .waitingForInput(InputRequestDescriptor(
                kind: .approval, summary: "allow?",
                safeReplyMode: .terminalOnly, source: .integration
            )),
            attention: .inputRequired(since: MonotonicInstant(nanosecondsSinceEpoch: 3), requestID: "r"),
            name: "waiting"
        ))

        XCTAssertEqual(model.attentionCount, 3, "sidebar bucket still counts every attention state")
        XCTAssertEqual(model.inputRequiredCount, 1, "menu-bar segment counts ONLY .inputRequired")

        // The failure/completion agents alone must NOT raise 'needs input'.
        let statusText = StatusItemController.statusText(
            working: model.workingCount, attention: model.inputRequiredCount
        )
        XCTAssertEqual(statusText, "1 working · 1 needs input")
    }

    // MARK: 4 — §6.x soak gate: leak-slope least-squares detector

    func testLeakSlopeDetectorComputesLeastSquaresSlopeWithDegenerateGuards() {
        // Flat footprint must NOT trip the gate.
        XCTAssertEqual(
            DetectionGateMath.leakSlopeBytesPerSecond([
                (t: 0, bytes: 1000), (t: 1, bytes: 1000), (t: 2, bytes: 1000)
            ]), 0, accuracy: 0
        )

        // Perfect linear growth: slope +100 B/s.
        XCTAssertEqual(
            DetectionGateMath.leakSlopeBytesPerSecond([
                (t: 0, bytes: 1000), (t: 1, bytes: 1100), (t: 2, bytes: 1200)
            ]), 100, accuracy: 1e-6
        )

        // Decreasing variant: SIGN matters — a flipped sign fires on frees
        // and sleeps through real leaks.
        XCTAssertEqual(
            DetectionGateMath.leakSlopeBytesPerSecond([
                (t: 0, bytes: 1050), (t: 1, bytes: 1000), (t: 2, bytes: 950)
            ]), -50, accuracy: 1e-6
        )

        // Noisy linear series (robustness band, not textbook input).
        // Exact OLS over these four samples: num = 217.5, den = 2.1875 → ≈ 99.43.
        let noisy = DetectionGateMath.leakSlopeBytesPerSecond([
            (t: 0, bytes: 10000), (t: 0.5, bytes: 10080),
            (t: 1, bytes: 10090), (t: 2, bytes: 10210)
        ])
        XCTAssertTrue(noisy > 90 && noisy < 110, "noisy linear slope \(noisy) outside robustness band")

        // Short-series guards: count <= 2 → 0.
        XCTAssertEqual(
            DetectionGateMath.leakSlopeBytesPerSecond([(t: 0, bytes: 5)]), 0, accuracy: 0
        )
        XCTAssertEqual(
            DetectionGateMath.leakSlopeBytesPerSecond([
                (t: 0, bytes: 5), (t: 1, bytes: 9)
            ]), 0, accuracy: 0
        )

        // Degenerate-t guard: zero time-variance (den <= 0) → 0.
        XCTAssertEqual(
            DetectionGateMath.leakSlopeBytesPerSecond([
                (t: 7, bytes: 1), (t: 7, bytes: 2), (t: 7, bytes: 3)
            ]), 0, accuracy: 0
        )
    }

    // MARK: 5 — R19-E1 serialized inspector probes (ffe1ca2)

    /// Walks the controller's view tree for the single text view.
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

    /// The refresh spawns ONE Task awaiting the timeline probe THEN the
    /// diagnostics probe, so section order in the text view is deterministic:
    /// timeline bullets under the TIMELINE header BEFORE the diagnostics
    /// block replaces its "probing…" placeholder. Pre-ffe1ca2 two racing
    /// Tasks appended in completion order.
    func testInspectorTimelineAndDiagnosticsProbesRenderInSerializedOrder() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let workspace = await runtime.createWorkspace(name: "W", rootPath: "/tmp")
        let id = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: .genericShell, workingDirectory: "/tmp", displayName: "inspector-probe"),
            in: workspace
        )
        // Public ingestion so `seam.timelineLines` resolves non-empty (the
        // same path RuntimeSeamTests/DetectionPipelineTests drive).
        try await runtime.processExited(agentID: id, exitCode: 0, signal: nil, userInitiated: false)
        let timeline = await runtime.timeline(of: id)
        XCTAssertFalse(timeline.isEmpty, "precondition: the probe needs timeline content")

        let model = AppModel()
        model.upsert(agent: summary(id: id, name: "inspector-probe"))

        let manager = TerminalSessionManager(
            engine: InspectorHarnessEngine(),
            parkingHost: InspectorHarnessParkingHost(),
            inputBracketedPaste: false
        )
        let seam = RuntimeSeam(runtime: runtime, sessionManager: manager, model: model)
        let controller = AgentInspectorController(model: model, seam: seam)
        _ = controller.view // force loadView()
        controller.setSelected(RowModel(
            item: .agent(id),
            title: "inspector-probe",
            subtitle: "",
            stateSymbol: "",
            stateText: "",
            durationText: "",
            showsQueuedBadge: false,
            tooltip: nil
        ))

        // Pump until BOTH probes resolved: the diagnostics replacement ran
        // ("probing…" gone) — by construction the timeline await completed
        // first, since one Task awaits them in order.
        let deadline = Date().addingTimeInterval(3)
        var rendered = ""
        while Date() < deadline {
            if let current = inspectorText(in: controller.view),
               current.contains("health:"), !current.contains("probing…")
            {
                rendered = current
                break
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(rendered.isEmpty, "serialized refresh never completed")

        // Serialization law: TIMELINE header → timeline bullets → the
        // diagnostics section; exactly ONE diagnostics header survives the
        // section swap; no placeholder residue (the section model replaces
        // the placeholder wholesale, so no "executable: resolving…" line can
        // linger either).
        let timelineHeader = rendered.range(of: "TIMELINE")
        let bullet = rendered.range(of: "\n  • ")
        let diagnosticsBlock = rendered.range(of: "\n\nINTEGRATION DIAGNOSTICS\n  executable: ")
        XCTAssertNotNil(bullet, "timeline bullets must render under the TIMELINE header")
        XCTAssertNotNil(diagnosticsBlock, "the appended diagnostics block must render")
        XCTAssertLessThan(try XCTUnwrap(timelineHeader).lowerBound, try XCTUnwrap(bullet).lowerBound)
        XCTAssertLessThan(try XCTUnwrap(bullet).upperBound, try XCTUnwrap(diagnosticsBlock).lowerBound)
        XCTAssertFalse(rendered.contains("probing…"), "placeholder must be fully replaced")
        XCTAssertEqual(
            rendered.components(separatedBy: "INTEGRATION DIAGNOSTICS").count - 1,
            1,
            "exactly ONE diagnostics section may survive the placeholder swap"
        )
    }

    // MARK: 5b — U2 liveness watch re-arms on every selection change

    /// Selecting a second live-pid row must retarget the liveness poll:
    /// the tick that observes the NEW selection's process dying has to
    /// flip its rendered "(alive)" to "(gone)". Before the fix the timer
    /// captured the FIRST armed item and `guard livenessTimer == nil`
    /// refused re-arm, so the new agent's death was never observed.
    func testInspectorLivenessWatchRetargetsWhenSelectionMovesToAnotherLiveAgent() async throws {
        let runtime = AgentRuntime(clock: FakeClock())
        let engine = LivenessHarnessEngine()
        let manager = TerminalSessionManager(
            engine: engine,
            parkingHost: InspectorHarnessParkingHost(),
            inputBracketedPaste: false
        )
        let seam = RuntimeSeam(runtime: runtime, sessionManager: manager, model: AppModel())
        let controller = AgentInspectorController(model: AppModel(), seam: seam)
        _ = controller.view // force loadView()

        // Two REAL long-lived children so kill(pid, 0) reports alive.
        let catA = try makeSleepChild()
        let catB = try makeSleepChild()
        defer { catA.terminate(); catB.terminate() }

        let sessionA = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        let sessionB = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        let pidA = UInt64(catA.processIdentifier)
        let pidB = UInt64(catB.processIdentifier)
        engine.surfaces[0].foregroundPIDValue = pidA
        engine.surfaces[1].foregroundPIDValue = pidB

        func select(_ id: TerminalID, _ name: String) {
            controller.setSelected(RowModel(
                item: .shell(id),
                title: name,
                subtitle: "",
                stateSymbol: "",
                stateText: "",
                durationText: "",
                showsQueuedBadge: false,
                tooltip: nil
            ))
        }

        select(sessionA.id, "A")
        // Arm precondition: A renders live once the first refresh settles.
        let armDeadline = Date().addingTimeInterval(3)
        while Date() < armDeadline {
            try await Task.sleep(for: .milliseconds(50))
            if let text = inspectorText(in: controller.view),
               text.contains("pid: \(pidA) (alive)")
            {
                break
            }
        }
        XCTAssertTrue(
            inspectorText(in: controller.view)?.contains("pid: \(pidA) (alive)") == true,
            "precondition: live pid A never rendered as alive"
        )

        // Selection flips to B while A's timer is armed; B then dies. The
        // poll must now watch B and observe the death within ~2 s cadence.
        select(sessionB.id, "B")
        catB.terminate()
        let deadDeadline = Date().addingTimeInterval(2)
        while catB.isRunning, Date() < deadDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(catB.isRunning, "precondition: child B never died")

        let observeDeadline = Date().addingTimeInterval(6)
        var observed = false
        while Date() < observeDeadline {
            try await Task.sleep(for: .milliseconds(50))
            if let text = inspectorText(in: controller.view),
               text.contains("pid: \(pidB) (gone)")
            {
                observed = true
                break
            }
        }
        XCTAssertTrue(
            observed,
            "liveness poll kept watching the STALE selection: B's death was never observed"
        )
        let final = inspectorText(in: controller.view) ?? ""
        XCTAssertFalse(final.contains("pid: \(pidB) (alive)"), "dead pid must not render as live")

        // A stays alive throughout: the stale-item guard must not fire a
        // spurious disarm/refresh for it either.
        XCTAssertTrue(catA.isRunning, "control child A unexpectedly died")
    }

    /// Spawns a long-lived `/bin/sleep` whose pid is verifiable via kill(0).
    private func makeSleepChild() throws -> Process {
        let cat = Process()
        cat.executableURL = URL(fileURLWithPath: "/bin/sleep")
        cat.arguments = ["30"]
        try cat.run()
        return cat
    }

    // MARK: 6 — R20-S16-1: fallbackReason absence-of-evidence law

    /// `fallbackReason` must return NIL whenever EITHER input is absent or
    /// unparsable — "absence of evidence must not demote detection" — and a
    /// descriptive reason embedding BOTH version and range only on a real
    /// violation. An overeager refactor treating "version unknown" as a
    /// violation would silently mass-demote detections.
    func testFallbackReasonRequiresBothRangeAndParsableVersionBeforeDemoting() throws {
        XCTAssertNil(
            DetectionGateMath.fallbackReason(manifestVersionRange: nil,
                                             detectedVersion: "opencode 999.0.0"),
            "a missing range never demotes"
        )
        XCTAssertNil(
            DetectionGateMath.fallbackReason(manifestVersionRange: "",
                                             detectedVersion: "opencode 999.0.0"),
            "an empty range never demotes (empty-range guard)"
        )
        XCTAssertNil(
            DetectionGateMath.fallbackReason(manifestVersionRange: ">=1.0.0",
                                             detectedVersion: "opencode dev"),
            "probe output with no numeric dotted token never demotes"
        )
        XCTAssertNil(
            DetectionGateMath.fallbackReason(manifestVersionRange: ">=1.0.0",
                                             detectedVersion: "codex-cli v1.2.9, protocol 5"),
            "in-range version with leading 'v' and trailing prose stays promoted"
        )

        let reason = try XCTUnwrap(
            DetectionGateMath.fallbackReason(manifestVersionRange: ">=1.0.0 <2.0.0",
                                             detectedVersion: "opencode 999.0.0"),
            "a real violation must produce a reason"
        )
        XCTAssertTrue(reason.contains("999.0.0"), "the reason embeds the version: \(reason)")
        XCTAssertTrue(reason.contains(">=1.0.0 <2.0.0"), "the reason embeds the range: \(reason)")
    }
}

// MARK: - Round 19 file-local harness fakes (InspectorHarness*)

@MainActor
private final class InspectorHarnessEngine: TerminalEngine {
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
private final class InspectorHarnessParkingHost: TerminalParkingHosting {
    let parkingContentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func park(_ view: NSView) {
        view.removeFromSuperview()
    }
}

// MARK: - U2 liveness-watch harness fakes (LivenessHarness*)

@MainActor
private final class LivenessHarnessSurface: NativeTerminalSurface {
    var screenText: String?
    var viewportText: String?
    var processExitedFlag = false
    /// Injection point for the foreground pid the liveness poll reads.
    var foregroundPIDValue: UInt64 = 0

    func setFocus(_: Bool) {}
    func setOccluded(_: Bool) {}
    func resize(widthPixels _: UInt32, heightPixels _: UInt32, scaleFactor _: Double) {}
    func sendText(_: String) {}
    func sendKey(_: GhosttyKeyEvent) -> Bool {
        true
    }

    func sendPreedit(_: String?) {}
    func mouseButton(state _: MouseButtonState, button _: MouseButton, modifiers _: KeyModifiers) -> Bool {
        true
    }

    func mousePosition(x _: Double, y _: Double, modifiers _: KeyModifiers) {}
    func mouseScroll(dx _: Double, dy _: Double, packedModifiers _: Int32) {}
    func isProcessExited() -> Bool {
        processExitedFlag
    }

    func foregroundPID() -> UInt64 {
        foregroundPIDValue
    }

    func gridSize() -> (columns: UInt32, rows: UInt32)? {
        nil
    }

    func readScreen() -> String? {
        screenText
    }

    func readViewport() -> String? {
        viewportText
    }

    func performFree() {}
}

@MainActor
private final class LivenessHarnessEngine: TerminalEngine {
    var eventSink: (@MainActor (GhosttyEvent) -> Void)?
    private(set) var surfaces: [LivenessHarnessSurface] = []

    func createSurface(
        view _: NSView,
        spec _: TerminalLaunchSpec,
        box _: SurfaceCallbackBox
    ) throws -> any NativeTerminalSurface {
        let surface = LivenessHarnessSurface()
        surfaces.append(surface)
        return surface
    }

    func tick() {}
    func shutdown() {}
}

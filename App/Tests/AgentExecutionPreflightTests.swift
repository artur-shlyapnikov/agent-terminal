import AgentControl
import AgentCore
import AgentStore
@testable import AgentTerminal
import AppKit
@testable import TerminalKit
import XCTest

// Round-3 Suite I (R3-3): AgentExecutionCoordinator §6.6 preflight-before-mutation laws.
//
// A doomed launch must throw BEFORE runtime.createAgent strands a zombie
// "starting" session, and an unbound agent's restart degrades to the bare
// runtime transition without touching surfaces. The manager INSTANCE is a
// mandatory constructor input even though the preflight paths never touch it;
// the fakes are deliberate file-private copies (SharedFakes.swift is internal
// to the SwiftPM test target).

@MainActor
private final class HarnessSurface: NativeTerminalSurface {
    var screenText: String?
    var viewportText: String?
    var processExitedFlag = false
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
private final class HarnessEngine: TerminalEngine {
    var eventSink: (@MainActor (GhosttyEvent) -> Void)?
    private(set) var surfaces: [HarnessSurface] = []

    func createSurface(
        view _: NSView,
        spec _: TerminalLaunchSpec,
        box _: SurfaceCallbackBox
    ) throws -> any NativeTerminalSurface {
        let surface = HarnessSurface()
        surfaces.append(surface)
        return surface
    }

    func tick() {}
    func shutdown() {}
}

@MainActor
private final class HarnessParkingHost: TerminalParkingHosting {
    let parkingContentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

    func park(_ view: NSView) {
        view.removeFromSuperview()
        parkingContentView.addSubview(view)
    }
}

@MainActor
final class AgentExecutionPreflightTests: XCTestCase {
    private struct Wired {
        let pipeline: AgentExecutionCoordinator
        let runtime: AgentRuntime
        let clock: FakeClock
        let hooks: HookAuthenticator
        let manager: TerminalSessionManager
        let engine: HarnessEngine
    }

    private func makeWired(launcherExecutable: URL?) -> Wired {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let engine = HarnessEngine()
        let manager = TerminalSessionManager(
            engine: engine,
            parkingHost: HarnessParkingHost(),
            inputBracketedPaste: false
        )
        let hooks = HookAuthenticator()
        let pipeline = AgentExecutionCoordinator(
            runtime: runtime,
            clock: clock,
            sessionManager: manager,
            registry: AgentTerminalRegistry(),
            model: AppModel(),
            hooks: hooks,
            agentRepository: nil,
            launcherExecutable: launcherExecutable,
            controlSocketPath: "/tmp/aterm-preflight-\(UUID()).sock"
        )
        return Wired(
            pipeline: pipeline, runtime: runtime, clock: clock,
            hooks: hooks, manager: manager, engine: engine
        )
    }

    /// Integration-authority observation (RuntimeWiringTests.lifecycleEvidence
    /// shape): the strongest §3.6 authority drives the lifecycle directly.
    private func lifecycleEvidence(
        agent: AgentID,
        terminal: TerminalID?,
        generation: SurfaceGeneration,
        outputRevision: UInt64,
        lifecycle: LifecyclePhase,
        at instant: MonotonicInstant
    ) -> Evidence {
        Evidence(
            envelope: ObservationEnvelope(
                agentID: agent,
                terminalID: terminal,
                surfaceGeneration: generation,
                sourceID: "hook:test",
                sourceKind: .integration,
                sequence: nil,
                outputRevision: outputRevision,
                observedAt: instant,
                receivedAt: instant
            ),
            payload: .integrationLifecycle(lifecycle)
        )
    }

    /// Bounded polling, no settles.
    private func waitUntil(
        timeout: TimeInterval = 3,
        interval: TimeInterval = 0.02,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    // MARK: I1 — doomed launch throws before any runtime mutation

    func testDoomedLaunchThrowsBeforeAnyRuntimeMutation() async throws {
        let wired = makeWired(launcherExecutable: nil)
        defer { wired.engine.shutdown() }

        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")

        do {
            _ = try await wired.pipeline.createAgent(
                AgentLaunchRequest(
                    agentKind: .genericShell,
                    workingDirectory: "/tmp",
                    displayName: "doomed"
                ),
                in: workspace
            )
            XCTFail("doomed launch must throw before any runtime mutation")
        } catch {
            // §6.6 preflight ordering: the failure carries the actionable
            // helper-missing message and NOTHING was mutated.
            let failure = try XCTUnwrap(error as? ControlFailure)
            XCTAssertEqual(failure.code, .launchFailed)
            XCTAssertTrue(
                failure.message.contains("AgentLauncher helper not found"),
                "unexpected preflight message: \(failure.message)"
            )
        }

        let projection = await wired.runtime.projection()
        XCTAssertTrue(projection.agents.isEmpty, "no stranded starting session")
        XCTAssertTrue(wired.pipeline.activeTokens.isEmpty, "no half-registered scoped token")
        XCTAssertTrue(wired.manager.allSessions.isEmpty, "no surface was spawned")
    }

    // MARK: I2 — unbound restart performs the bare runtime transition

    func testRestartOfUnboundAgentPerformsBareRuntimeRestartWithoutSpawning() async throws {
        let wired = makeWired(launcherExecutable: URL(fileURLWithPath: "/bin/true"))
        defer { wired.engine.shutdown() }

        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        let agent = try await wired.runtime.createAgent(
            AgentLaunchRequest(
                agentKind: .genericShell,
                workingDirectory: "/tmp",
                displayName: "unbound-agent"
            ),
            in: workspace
        )

        // Drive to `.idle` with one integration-lifecycle ingest — NO registry
        // binding, NO launch request, NO active workspace on the pipeline.
        await wired.runtime.ingest(lifecycleEvidence(
            agent: agent,
            terminal: nil,
            generation: .initial,
            outputRevision: 0,
            lifecycle: .idle,
            at: wired.clock.now
        ))
        await waitUntil {
            guard let state = try? await wired.runtime.state(of: agent) else { return false }
            return state.lifecycle == .idle
        }
        let revisionBefore = try await wired.runtime.state(of: agent).revision

        try await wired.pipeline.restartAgent(agent)

        let stateAfter = try await wired.runtime.state(of: agent)
        XCTAssertEqual(stateAfter.lifecycle, .starting, "bare restart transition applied")
        XCTAssertGreaterThan(stateAfter.revision, revisionBefore, "state revision incremented")
        XCTAssertTrue(wired.manager.allSessions.isEmpty, "no surface was touched")
        XCTAssertTrue(wired.pipeline.activeTokens.isEmpty, "no token minted")
    }

    // MARK: D1 (round 6) — resume empty-cwd guard precedes resolution and mutation

    func testResumeWithEmptyCwdFailsBeforeExecutableResolutionAndAnyMutation() async throws {
        let wired = makeWired(launcherExecutable: nil)
        defer { wired.engine.shutdown() }
        let workspace = await wired.runtime.createWorkspace(name: "Default", rootPath: "/tmp")

        // Transport-only fields — the pipeline rebuilds the spec (P4
        // precedent). NO stub PATH: if execution survived past the cwd guard,
        // opencode would be unresolvable and fail with a DIFFERENT error.
        let action = RestoreResumeAction(
            persistedAgentID: AgentID(),
            workspaceID: workspace,
            kind: .openCode,
            displayName: "Resumed",
            cwd: "",
            sessionReference: SessionReference(agentKind: .openCode, opaquePayload: "sess-42"),
            resumeSpec: ResumeSpec(argv: [], environment: [:], workingDirectory: "")
        )

        do {
            _ = try await wired.pipeline.executeResume(action, in: workspace)
            XCTFail("empty-cwd resume must throw before any runtime mutation")
        } catch {
            // Specifically NOT the missing-executable message — proving the
            // guard fired BEFORE argv[0] PATH resolution.
            let failure = try XCTUnwrap(error as? ControlFailure)
            XCTAssertEqual(failure.code, .launchFailed)
            XCTAssertEqual(failure.message, "resume requires a working directory")
        }

        // No phantom 'starting' row, no half-registered token, no hook lease.
        let projection = await wired.runtime.projection()
        XCTAssertTrue(projection.agents.isEmpty, "no phantom session row minted")
        XCTAssertTrue(wired.pipeline.activeTokens.isEmpty)
        let registered = await wired.hooks.isRegistered(agentID: action.persistedAgentID)
        XCTAssertFalse(registered)
    }
}

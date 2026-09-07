import AppKit
import TerminalKit

// ACCEPTANCE entry point (§4.6 + stage-5/8/12/15/16 harness): the FULL
// launch dispatcher — AGENTTERMINAL_AUTOSHELL / AUTOAGENT / ATERM_MINIMAL /
// ATERM_SCENARIO branches included. Compiled ONLY into the
// AgentTerminalAcceptance target; the shipping app carries none of this.
//
// Reopen/quit policy (§3.15) is identical to production.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var root: AppCompositionRoot?

    func applicationDidFinishLaunching(_: Notification) {
        print("[LAUNCH] didFinishLaunching")
        // Unit-test host: the app must NOT claim the process-wide libghostty
        // runtime (§3.8 one-runtime-per-process) — engine-dependent tests
        // create their own. Tests run against an inert host.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            print("[LAUNCH] XCTest host — skipping app bootstrap")
            return
        }
        // Match the verified spike launch path: explicit activation policy
        // before any ghostty surface exists.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        if ProcessInfo.processInfo.environment["ATERM_MINIMAL"] == "1" {
            Task { await MinimalHarness().run() }
            return
        }

        do {
            if AppCompositionRoot.autoShellCount > 0 {
                // Bootstrap phase (proven ordering): terminal stack + shell
                // surfaces exist before the rest of the shell is built.
                AutomationBootstrap.pending = try AutomationBootstrap.spawnShells(
                    count: AppCompositionRoot.autoShellCount
                )
            }

            let composition: AppCompositionRoot
            if let stack = AutomationBootstrap.pending {
                composition = AppCompositionRoot(adopting: stack)
                AutomationBootstrap.pending = nil
                composition.mainWindowController.showAndKey()
            } else {
                composition = try AppCompositionRoot()
                // §3.15 review fix: a crash-recovery launch must NOT key the
                // empty main window behind the Recovery Center — keying is
                // DEFERRED until bootstrapRuntime resolves recoveryPending
                // (see the Task below). Interactive-scenario branches that
                // bypass the deferred path key their own window here.
                if AppCompositionRoot.autoAgentScenario
                    || ProcessInfo.processInfo.environment["ATERM_SCENARIO"] == "new-agent"
                    || Stage16GatesScenario.mode != nil
                {
                    composition.mainWindowController.showAndKey()
                }
            }
            root = composition
            // Review5 #1: AppCommands is constructed and RETAINED by the
            // composition root (menu items target it weakly).
            composition.statusItem.refresh()
            if AppCompositionRoot.autoShellCount == 0 {
                composition.focusCoordinator.start()
            }

            Task { @MainActor in
                // §3.18 ordering: surface creation is pure
                // AppKit/TerminalKit on the main actor; AgentRuntime awaits
                // must not precede or interleave the first spawn.
                if AppCompositionRoot.autoShellCount > 0 {
                    let scenario = AutomationScenario(root: composition)
                    await scenario.run()
                } else if AppCompositionRoot.autoAgentScenario {
                    // Stage-8/10/15 agent-lifecycle acceptance scenario.
                    let scenario = AgentLifecycleScenario(root: composition)
                    await scenario.run()
                } else if ProcessInfo.processInfo.environment["ATERM_SCENARIO"] == "new-agent" {
                    // Stage-15: New Agent sheet scenario (stage-6 gap proof).
                    await NewAgentScenario(root: composition).run()
                } else if let s16Mode = Stage16GatesScenario.mode {
                    // Stage-16 hardening gates (capacity/soak/adverse).
                    await Stage16GatesScenario(root: composition, mode: s16Mode).run()
                } else if ProcessInfo.processInfo.environment["ATERM_SCENARIO"] != nil {
                    // Stage-12 live verification scenarios drive their own
                    // flows after the runtime is up.
                    await composition.bootstrapRuntime()
                    composition.mainWindowController.showAndKey()
                    let scenario = Stage12RestoreScenario(root: composition)
                    await scenario.run()
                } else {
                    // §4.6 onboarding: first run (no persisted workspaces)
                    // defers the implicit Default workspace to the operator's
                    // folder choice. Scenario runs never onboard.
                    let firstRun = await composition.shouldShowOnboarding()
                    composition.onboardingPending = firstRun
                    await composition.bootstrapRuntime()
                    if composition.recoveryPending {
                        // §3.15 crash recovery: Recovery Center INSTEAD of the
                        // normal window content; nothing auto-starts.
                        composition.presentRecoveryCenter()
                    } else if firstRun {
                        composition.presentOnboarding()
                    } else {
                        composition.mainWindowController.showAndKey()
                        composition.focusCoordinator.start()
                    }
                }
            }
        } catch {
            fputs("FATAL: composition failed: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Architecture §3.15: window close parks surfaces; app keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// §3.12F: Dock-icon click / reopen re-keys the main window — unless a
    /// crash recovery is pending, in which case the Recovery Center stays
    /// the key UI until every candidate is resolved (§3.15).
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        root?.reopenPrimaryUI()
        return true
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    /// §3.15 full-quit policy. With running agents a four-way sheet appears;
    /// without them the app tears down directly. Both paths reply
    /// asynchronously via NSApp.reply(toApplicationShouldTerminate:).
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let root, let coordinator = root.shutdownCoordinator as ShutdownCoordinator? else {
            // Nothing composed to tear down: let AppKit terminate immediately
            // instead of parking the quit on a reply that never arrives.
            return .terminateNow
        }
        // Synchronous gate BEFORE spawning the async Task below: two rapid
        // ⌘Q must not both pass and each drive teardown + reply.
        guard coordinator.beginQuit() else {
            // A quit is already in flight with its own pending reply;
            // consuming this request would orphan a second reply.
            return .terminateCancel
        }

        Task { @MainActor in
            let preview = await coordinator.makePreview()
            guard preview.hasRunningWork else {
                // Nothing running. During crash recovery (recoveryPending,
                // Recovery Center up, model intentionally empty) a plain
                // .quitAndStopAgents would wipe the previous run's armed
                // resume-request flags and mark the run clean — abandoning
                // recovery the operator never chose. .quitAndResumeLater
                // preserves that intent; with no resumable entries its
                // persist loops no-op, so it is otherwise equivalent.
                let choice: ShutdownCoordinator.QuitChoice =
                    root.recoveryPending ? .quitAndResumeLater : .quitAndStopAgents
                let proceed = await coordinator.performQuit(choice)
                NSApp.reply(toApplicationShouldTerminate: proceed)
                return
            }
            let windowVisible = root.mainWindowController.window?.isVisible ?? false
            coordinator.presentQuitSheet(preview: preview, windowVisible: windowVisible) { choice in
                Task { @MainActor in
                    let proceed = await coordinator.performQuit(choice)
                    NSApp.reply(toApplicationShouldTerminate: proceed)
                }
            }
        }
        return .terminateLater
    }
}

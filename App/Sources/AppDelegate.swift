import AppKit
import TerminalKit

// Launch, reopen, quit policy (§4.6). Closing the last window parks surfaces;
// the app keeps running (§3.15). Reopen re-keys the main window (§3.12F).
//
// PRODUCTION entry point: no scenario/acceptance branches compile into this
// target — the full dispatcher (AGENTTERMINAL_AUTOSHELL / AUTOAGENT /
// ATERM_SCENARIO / ATERM_MINIMAL) lives in the AgentTerminalAcceptance
// target's AppDelegate.

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

        do {
            let composition = try AppCompositionRoot()
            root = composition
            // Review5 #1: AppCommands is constructed and RETAINED by the
            // composition root (menu items target it weakly).
            composition.statusItem.refresh()
            composition.focusCoordinator.start()

            Task { @MainActor in
                // §3.18 ordering: surface creation is pure
                // AppKit/TerminalKit on the main actor; AgentRuntime awaits
                // must not precede or interleave the first spawn.
                // §4.6 onboarding: first run (no persisted workspaces)
                // defers the implicit Default workspace to the operator's
                // folder choice.
                let firstRun = await composition.shouldShowOnboarding()
                composition.onboardingPending = firstRun
                await composition.bootstrapRuntime()
                if composition.recoveryPending {
                    // §3.15 crash recovery: Recovery Center INSTEAD of the
                    // normal window content; nothing auto-starts. An empty
                    // plan (crash with zero running agents) presents nothing
                    // and clears the pending flag — fall through to the
                    // normal window so launch cannot deadlock on a
                    // buttonless dialog.
                    if !composition.presentRecoveryCenter() {
                        composition.mainWindowController.showAndKey()
                        composition.focusCoordinator.start()
                    }
                } else if firstRun {
                    composition.presentOnboarding()
                } else {
                    composition.mainWindowController.showAndKey()
                    composition.focusCoordinator.start()
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

import AgentCore
import AgentStore
import AppKit
import Darwin

// §3.15 shutdown flow: applicationShouldTerminate presents the four-way quit
// sheet whenever agents are running, then executes the chosen path:
//
//   Hide Window            — park surfaces + orderOut; the app keeps running
//                            in the Dock/menu bar. Never terminates anything.
//   Quit and Resume Later  — resume_requested=1 ONLY for adapters with a
//                            valid session reference; unsupported sessions are
//                            listed to the operator BEFORE quitting; graceful
//                            process stop (SIGTERM → 2 s → SIGKILL); layout
//                            flush; app_runs marked clean.
//   Quit and Stop Agents   — identical teardown WITHOUT resume flags.
//   Cancel                 — nothing happens.
//
// Ordering law: persist (flags → processes → layout → run row) … engine last.

@MainActor
final class ShutdownCoordinator {
    enum QuitChoice {
        case hideWindow
        case quitAndResumeLater
        case quitAndStopAgents
        case cancel
    }

    struct QuitSession: Equatable {
        let id: AgentID
        let displayName: String
        let kindName: String
        let resumable: Bool
        let reasonText: String?
    }

    struct QuitPreview: Equatable {
        var runningAgents: [QuitSession] = []
        var liveShellCount = 0
        var hasRunningWork: Bool {
            !runningAgents.isEmpty || liveShellCount > 0
        }

        var resumable: [QuitSession] {
            runningAgents.filter(\.resumable)
        }

        var unsupported: [QuitSession] {
            runningAgents.filter { !$0.resumable }
        }

        /// Operator-facing listing for the sheet's informative text.
        var unsupportedSummary: String? {
            guard !unsupported.isEmpty else { return nil }
            let lines = unsupported.map {
                "• \($0.displayName) (\($0.kindName)) — \($0.reasonText ?? "will start fresh")"
            }
            return "These sessions cannot be resumed and will start fresh:\n" + lines.joined(separator: "\n")
        }
    }

    private weak var root: AppCompositionRoot?
    /// Store-level seam (§4.4): the debounced layout writer flushed on quit.
    private let flushLayout: () async throws -> Void
    private let catalog = AgentCatalog.standard()
    /// Set while a quit decision is in flight so a second ⌘Q cannot stack a
    /// second sheet.
    private(set) var quitInFlight = false
    /// Latched for the process lifetime: once the quit ladder starts, no new
    /// work may be spawned — teardown scans would miss anything launched after
    /// stopAllProcesses walks the registry.
    private(set) var isTerminating = false

    /// Arms the quit gate SYNCHRONOUSLY, before applicationShouldTerminate
    /// spawns its async Task: two rapid ⌘Q must not both pass the guard and
    /// each drive teardown + reply. Returns false when already in flight;
    /// performQuit releases quitInFlight on every exit path and also clears
    /// isTerminating when no teardown runs (Cancel / Hide Window).
    func beginQuit() -> Bool {
        if quitInFlight || isTerminating {
            return false
        }
        quitInFlight = true
        // Set before any await so menu commands racing the async teardown
        // see it; cleared again in performQuit unless teardown proceeds.
        isTerminating = true
        return true
    }

    // MARK: - Quit sheet (§3.15 four-way choice)

    /// Exactly FOUR options whenever agents are running; Hide Window is the
    /// default. Unsupported sessions are listed BEFORE quitting.
    func presentQuitSheet(
        preview: QuitPreview,
        windowVisible: Bool,
        completion: @escaping @MainActor (QuitChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = preview.runningAgents.count == 1
            ? "1 agent is running"
            : "\(preview.runningAgents.count) agents are running"
        var info = "Choose what happens before AgentTerminal quits."
        if preview.liveShellCount > 0 {
            info += "\n\(preview.liveShellCount) plain shell(s) will be stopped."
        }
        if let unsupported = preview.unsupportedSummary {
            info += "\n\n" + unsupported
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Hide Window") // 1000 — default
        alert.addButton(withTitle: "Quit and Resume Later") // 1001
        alert.addButton(withTitle: "Quit and Stop Agents") // 1002
        alert.addButton(withTitle: "Cancel") // 1003

        func deliver(_ response: NSApplication.ModalResponse) {
            completion(Self.choice(for: response))
        }
        if windowVisible, let window = root?.mainWindowController.window {
            alert.beginSheetModal(for: window) { response in
                deliver(response)
            }
        } else {
            deliver(alert.runModal())
        }
    }

    static func choice(for response: NSApplication.ModalResponse) -> QuitChoice {
        switch response.rawValue {
        case 1001: .quitAndResumeLater
        case 1002: .quitAndStopAgents
        case 1003: .cancel
        default: .hideWindow
        }
    }

    init(root: AppCompositionRoot, flushLayout: @escaping () async throws -> Void) {
        self.root = root
        self.flushLayout = flushLayout
    }

    // MARK: - Preview (sheet content)

    /// Classifies every live runtime agent through its adapter's resume
    /// capability (§3.10 table: claude/codex/opencode yes with a reference,
    /// generic shell never).
    func makePreview() async -> QuitPreview {
        var preview = QuitPreview()
        guard let root else { return preview }
        let summaries = Array(root.model.agents.values)
        for summary in summaries where Self.isLive(summary.state.lifecycle) {
            let reference = await root.runtime.capturedSessionReference(of: summary.id)
            let adapter = catalog.adapter(for: summary.kind)
            let spec = reference.flatMap { adapter?.buildResumeSpec(sessionReference: $0) }
            let reason: String? = if spec != nil {
                nil
            } else if reference == nil {
                "no session reference was captured"
            } else {
                "adapter cannot resume sessions"
            }
            preview.runningAgents.append(QuitSession(
                id: summary.id,
                displayName: summary.displayName,
                kindName: summary.kind.displayName,
                resumable: spec != nil,
                reasonText: reason
            ))
        }
        preview.runningAgents.sort { $0.displayName < $1.displayName }
        preview.liveShellCount = root.model.shells.values.count
        return preview
    }

    static func isLive(_ phase: LifecyclePhase) -> Bool {
        switch phase {
        case .starting, .idle, .working, .waitingForInput, .stopping:
            true
        case .unknown, .stopped, .failed:
            false
        }
    }

    // MARK: - Execution

    /// Runs the chosen quit path to completion. Returns true when the caller
    /// should proceed with termination (`NSApp.reply(toApplicationShouldTerminate:)`).
    func performQuit(_ choice: QuitChoice) async -> Bool {
        // beginQuit() armed both flags synchronously; quitInFlight must be
        // released on every exit path. isTerminating stays latched only on
        // the two quit paths (teardown really runs); Cancel / Hide Window
        // clear it so later ⌘Q and menu commands are not refused forever.
        defer { quitInFlight = false }
        switch choice {
        case .hideWindow:
            root?.mainWindowController.parkAndOrderOut()
            isTerminating = false
            return false
        case .cancel:
            isTerminating = false
            return false
        case .quitAndResumeLater:
            return await finishShutdown(markResumeRequested: true)
        case .quitAndStopAgents:
            return await finishShutdown(markResumeRequested: false)
        }
    }

    /// Shared teardown for both quit-and-terminate choices; the in-flight
    /// gate itself is owned by performQuit/beginQuit.
    private func finishShutdown(markResumeRequested: Bool) async -> Bool {
        guard let root else { return true }

        // Classify ONCE, BEFORE any process dies: after stopAllProcesses()
        // every agent is .stopped and makePreview()'s isLive filter yields an
        // empty resumable list — so the post-stop bridge must reuse this.
        let preview = await makePreview()

        // 1. PERSIST resume intent BEFORE any process dies (§3.15 ordering):
        //    only adapters with a valid session reference get the flag.
        if markResumeRequested {
            for session in preview.resumable {
                do {
                    try await root.agentRepository?.setResumeRequested(true, agentID: session.id)
                } catch {
                    DiagnosticsLogRing.shared.record(
                        "quit resume-flag persist failed for \(session.id): \(error)"
                    )
                }
            }
        } else {
            // 'Quit and Stop Agents' is the operator's LATEST explicit
            // choice: a resume flag armed by an earlier failed resume cycle
            // must not survive teardown, or the next launch would
            // auto-execute a resume against that stale intent (§3.15).
            do {
                try await root.agentRepository?.clearResumeRequested()
            } catch {
                DiagnosticsLogRing.shared.record("quit resume-flag clear failed: \(error)")
            }
        }

        // 2. Graceful stop of every live process (SIGTERM → 2 s grace →
        //    SIGKILL via the runtime's stop mode / shell ladder).
        await stopAllProcesses()

        // 2b. Drain any superseded-surface retire ladders still in flight
        //     (SIGTERM → 2 s → SIGKILL, §3.11): a mid-ladder quit would
        //     otherwise orphan the Task and leave the process un-killed.
        //     Processes must be dead before the run row closes (§3.15).
        await root.coordinator.awaitPendingRetires()

        // 3. Flush the debounced layout writer NOW — no 300 ms window left.
        do {
            try await flushLayout()
        } catch {
            DiagnosticsLogRing.shared.record("quit layout flush failed: \(error)")
        }

        // Packages gap bridge: the ledger-held session reference never
        // reaches StateCommit, and snapshot commits NULL it back out — so
        // re-persist it AFTER the last lifecycle commit has fired, together
        // with the (idempotent) flag (stage-16 hardening item).
        if markResumeRequested {
            for session in preview.resumable {
                guard let repository = root.agentRepository else { continue }
                do {
                    guard let existing = try await repository.find(session.id),
                          let captured = await root.runtime.capturedSessionReference(of: session.id)
                    else { continue }
                    var updated = existing
                    updated.sessionReference = captured
                    try await repository.save(updated)
                    try await repository.setResumeRequested(true, agentID: session.id)
                } catch {
                    DiagnosticsLogRing.shared.record(
                        "quit session-reference re-persist failed for \(session.id): \(error)"
                    )
                }
            }
        }

        // 4. Mark this app run clean, then tear the engine stack down LAST.
        if let runID = root.currentRunID {
            do {
                try await root.appRunRepository?.endRun(runID, kind: .clean)
            } catch {
                DiagnosticsLogRing.shared.record("quit run-row close failed for \(runID): \(error)")
            }
        }
        await root.shutdown()
        return true
    }

    private func stopAllProcesses() async {
        guard let root else { return }
        let summaries = Array(root.model.agents.values)
        var failedTerminalIDs: Set<TerminalID> = []
        for summary in summaries where Self.isLive(summary.state.lifecycle) {
            do {
                // Full semantic stop: user-intent marking + detection
                // suspension + compensation all live in the coordinator.
                try await root.coordinator.stop(summary.id, mode: .gracefulStop)
            } catch {
                // Stop threw before any signal was sent (validation/socket
                // error); fall back to the shell ladder so the process is not
                // orphaned at quit.
                DiagnosticsLogRing.shared.record(
                    "quit graceful stop failed for \(summary.id): \(error)"
                )
                if let terminalID = root.model.agentTerminal[summary.id] {
                    failedTerminalIDs.insert(terminalID)
                }
            }
        }
        // Plain shells are not runtime sessions; mirror the graceful ladder
        // (SIGTERM → 2 s grace → SIGKILL, §3.11). Agents whose stop threw
        // join the same ladder.
        for terminalID in root.model.shells.keys {
            try? await root.sessionManager.sendSignal(.terminate, to: terminalID)
        }
        for terminalID in failedTerminalIDs {
            try? await root.sessionManager.sendSignal(.terminate, to: terminalID)
        }
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        for terminalID in root.model.shells.keys {
            try? await root.sessionManager.sendSignal(.kill, to: terminalID)
        }
        for terminalID in failedTerminalIDs {
            try? await root.sessionManager.sendSignal(.kill, to: terminalID)
        }
        // Wait until no tracked foreground process survives (bounded — the
        // quit path must always reach termination).
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if !hasAliveProcess() {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func isAlive(_ terminalID: TerminalID) -> Bool {
        guard let root,
              let pid = root.sessionManager.foregroundPID(for: terminalID),
              pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    private func hasAliveProcess() -> Bool {
        guard let root else { return false }
        for terminalID in root.model.agentTerminal.values where isAlive(terminalID) {
            return true
        }
        for terminalID in root.model.shells.keys where isAlive(terminalID) {
            return true
        }
        return false
    }
}

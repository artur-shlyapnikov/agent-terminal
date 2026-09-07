import AgentCore
import AgentStore
@testable import AgentTerminal
import AppKit
import Foundation
import XCTest

// Stage-9 acceptance (§6.9): prompt orchestration at the app boundary over
// the REAL AgentRuntime with a recording terminal port and the deterministic
// FakeClock — no libghostty dependency.
//
//  1. duplicate commandID through the runtime/composer contract delivers once;
//  2. watchdog: unconfirmed delivery surfaces in the UI model, NEVER retries,
//     confirmed deliveries stay silent;
//  3. queue-while-working delivers exactly once on validated idle;
//  4. waitingForInput(terminalOnly) blocks composer AND runtime sends;
//  5. unknown lifecycle permits ONLY explicit sendNow;
//  6. when-ready initial prompts deliver at first validated idle or return to
//     the composer draft after the domain timeout — never blind-sent.

@MainActor
final class Stage9PromptOrchestrationTests: XCTestCase {
    // MARK: - fakes

    /// Records everything the runtime asks the terminal layer to do.
    private final class RecordingTerminalPort: TerminalControlling, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var deliveredTexts: [(TerminalID, String, Bool)] = []

        var deliverInputCallCount: Int {
            lock.lock(); defer { lock.unlock() }
            return deliveredTexts.count
        }

        func deliverInput(_ terminalID: TerminalID, text: String, submit: Bool) async throws {
            recordDelivery((terminalID, text, submit))
        }

        /// Synchronous so NSLock usage stays out of async contexts
        /// (`lock` is unavailable there under Swift 6 upcoming-feature strictness).
        private func recordDelivery(_ entry: (TerminalID, String, Bool)) {
            lock.lock()
            defer { lock.unlock() }
            deliveredTexts.append(entry)
        }

        func sendKeys(_: TerminalID, keys _: [String]) async throws {}
        func sendSignal(_: SignalIntent, to _: TerminalID) async throws {}
        func read(_: TerminalID, source _: TerminalReadSource) async throws -> TerminalSnapshot? {
            nil
        }
    }

    private var clock: FakeClock!
    private var runtime: AgentRuntime!
    private var port: RecordingTerminalPort!
    private var model: AppModel!

    override func setUp() {
        clock = FakeClock()
        runtime = AgentRuntime(clock: clock)
        port = RecordingTerminalPort()
        model = AppModel()
    }

    @discardableResult
    private func makeAgent(kind: AgentKind = .openCode) async throws -> (agent: AgentID, terminal: TerminalID) {
        await runtime.setTerminalPort(port)
        let workspace = await runtime.createWorkspace(name: "Default", rootPath: "/tmp")
        let agentID = try await runtime.createAgent(
            AgentLaunchRequest(agentKind: kind, workingDirectory: "/tmp", displayName: "stage9"),
            in: workspace
        )
        let terminalID = TerminalID()
        try await runtime.surfaceCreated(
            agentID: agentID, terminalID: terminalID,
            generation: .initial, pid: 4242, processGroupID: 4242
        )
        return (agentID, terminalID)
    }

    private func integrationEvidence(
        _ agentID: AgentID, _ lifecycle: LifecyclePhase, sequence: UInt64
    ) -> Evidence {
        Evidence(
            envelope: ObservationEnvelope(
                agentID: agentID, terminalID: nil, surfaceGeneration: .initial,
                sourceID: "hook:test", sourceKind: .integration, sequence: sequence,
                outputRevision: nil, observedAt: clock.now, receivedAt: clock.now
            ),
            payload: .integrationLifecycle(lifecycle)
        )
    }

    private func ingestIdle(_ agentID: AgentID, sequence: UInt64) async {
        await runtime.ingest(integrationEvidence(agentID, .idle, sequence: sequence))
    }

    private func deliveredCount(_ agentID: AgentID) async -> Int {
        await runtime.timeline(of: agentID).filter {
            if case .promptDelivered = $0.event {
                return true
            }
            return false
        }.count
    }

    private func unconfirmedCount(_ agentID: AgentID) async -> Int {
        await runtime.timeline(of: agentID).filter {
            if case .promptDeliveryUnconfirmed = $0.event {
                return true
            }
            return false
        }.count
    }

    /// Advances virtual time in small steps so concurrently running tasks
    /// (watchdog arming, coordinator polling) make progress between steps.
    /// The condition is checked BEFORE each advance so zero-advance cases
    /// still resolve.
    private func advanceUntil(
        timeout: TimeInterval, step: Duration = .milliseconds(250),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            clock.advance(by: step)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private nonisolated func waitUntil(
        _ label: String, timeout: TimeInterval = 8, file: StaticString = #filePath,
        line: UInt = #line, _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let final = await condition()
        XCTAssertTrue(final, "condition not met in \(timeout)s: \(label)", file: file, line: line)
        return final
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        for subview in view.subviews {
            if let button = subview as? NSButton {
                found.append(button)
            }
            found.append(contentsOf: buttons(in: subview))
        }
        return found
    }

    // MARK: 1 — duplicate commandID single delivery

    func testDuplicateCommandIDDeliversExactlyOnce() async throws {
        let (agentID, _) = try await makeAgent()
        await ingestIdle(agentID, sequence: 1)

        let key = CommandID()
        let first = try await runtime.prompt(agentID, "once", .sendNow, commandID: key)
        let replay = try await runtime.prompt(agentID, "once", .sendNow, commandID: key)

        XCTAssertEqual(first, replay, "replay must return the ORIGINAL receipt")
        XCTAssertEqual(port.deliverInputCallCount, 1, "duplicate commandID must not re-deliver")
        let deliveredEvents = await deliveredCount(agentID)
        XCTAssertEqual(deliveredEvents, 1)
    }

    // MARK: 2 — delivery watchdog surfacing (§3.11 rules 5–7)

    func testUnconfirmedDeliverySurfacesAndNeverRetries() async throws {
        let (agentID, _) = try await makeAgent()
        await ingestIdle(agentID, sequence: 1)
        let coordinator = PromptCoordinator(runtime: runtime, clock: clock, model: model)

        let receipt = try await runtime.prompt(agentID, "silent send", .sendNow)
        coordinator.surfaceDeliveryOutcome(agentID: agentID, commandID: receipt.commandID)

        // Arm BEFORE advancing virtual time past the deadline.
        _ = await waitUntil("watchdog armed") { await self.runtime.isDeliveryWatchArmed(agentID) }

        let surfaced = await advanceUntil(timeout: 12) {
            self.model.unconfirmedDeliveries[agentID] != nil
        }
        XCTAssertTrue(surfaced, "unconfirmed delivery must surface in the UI model")
        let unconfirmedEvents = await unconfirmedCount(agentID)
        XCTAssertEqual(unconfirmedEvents, 1)
        XCTAssertEqual(port.deliverInputCallCount, 1, "NO auto-retry (§3.11 rule 7)")
    }

    func testConfirmedDeliveryStaysSilent() async throws {
        let (agentID, terminalID) = try await makeAgent()
        await ingestIdle(agentID, sequence: 1)
        let coordinator = PromptCoordinator(runtime: runtime, clock: clock, model: model)

        let receipt = try await runtime.prompt(agentID, "echoing send", .sendNow)
        coordinator.surfaceDeliveryOutcome(agentID: agentID, commandID: receipt.commandID)
        _ = await waitUntil("watchdog armed") { await self.runtime.isDeliveryWatchArmed(agentID) }

        // Output moved after delivery → confirmation signal (§3.11 rule 5).
        try await runtime.outputRevisionChanged(agentID: agentID, terminalID: terminalID, revision: 7)

        // Drain PAST the 5 s confirmationTimeout on the FakeClock: silence
        // after the deadline is what proves a confirmed delivery can never
        // late-fire the watchdog.
        _ = await advanceUntil(timeout: 6) { false }
        XCTAssertNil(model.unconfirmedDeliveries[agentID])
        let confirmedSilent = await unconfirmedCount(agentID)
        XCTAssertEqual(confirmedSilent, 0)
    }

    // MARK: 3 — queue while working → exactly one delivery on validated idle

    func testQueueWhileWorkingDeliversExactlyOnceOnValidatedIdle() async throws {
        let (agentID, _) = try await makeAgent()
        await runtime.ingest(integrationEvidence(agentID, .idle, sequence: 1))
        await runtime.ingest(integrationEvidence(agentID, .working, sequence: 2))

        let receipt = try await runtime.prompt(agentID, "queued job", .queueWhenIdle)
        XCTAssertEqual(receipt.outcome, .queued)
        let countWhileWorking = port.deliverInputCallCount

        _ = await advanceUntil(timeout: 1) { false } // deterministic pump: no delivery while working
        XCTAssertEqual(port.deliverInputCallCount, countWhileWorking,
                       "queued prompt must NOT deliver while working")

        await ingestIdle(agentID, sequence: 3)
        let queuedSettled = await waitUntil("queued prompt delivered exactly once") {
            let events = await self.deliveredCount(agentID)
            // Exactly ONE new delivery: the queued prompt itself.
            return self.port.deliverInputCallCount == countWhileWorking + 1 && events == 1
        }
        XCTAssertTrue(queuedSettled)
    }

    // MARK: 4 — waitingForInput(terminalOnly) blocks composer + runtime

    func testWaitingForTerminalInputBlocksComposerAndRuntime() async throws {
        let (agentID, _) = try await makeAgent()
        await ingestIdle(agentID, sequence: 1)
        let approval = InputRequestDescriptor(
            kind: .approval, summary: "Allow?", safeReplyMode: .terminalOnly, source: .integration
        )
        await runtime.ingest(integrationEvidence(agentID, .waitingForInput(approval), sequence: 2))

        do {
            _ = try await runtime.prompt(agentID, "nope", .sendNow)
            XCTFail("sendNow into terminalOnly waiting state must throw")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .waitingForTerminalInput)
        }
        do {
            _ = try await runtime.prompt(agentID, "also nope", .queueWhenIdle)
            XCTFail("queueWhenIdle into waiting state must throw")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .waitingForTerminalInput)
        }
        // UI boundary: the composer blocks sending entirely (§5.1 critical).
        let composer = PromptComposerView(model: model, sessionManager: nil)
        composer.configure(for: "waitingForInput")
        XCTAssertFalse(composer.fieldEnabled)
        XCTAssertTrue(composer.ctaVisible)
        var sent: (String, PromptPolicy)?
        composer.onSend = { text, policy, _ in sent = (text, policy); return .accepted }
        composer.sendFocusedPrompt(text: "blocked", policy: .sendNow)
        XCTAssertNil(sent, "composer send must be blocked during waitingForInput")
    }

    // MARK: 4b — waitingForInput(composerAllowed) KEEPS the composer (§3.4)

    func testWaitingComposerAllowedKeepsComposerAndSends() async throws {
        let (agentID, _) = try await makeAgent()
        await ingestIdle(agentID, sequence: 1)
        let freeText = InputRequestDescriptor(
            kind: .freeText, summary: "continue?",
            safeReplyMode: .composerAllowed, source: .integration
        )
        await runtime.ingest(integrationEvidence(agentID, .waitingForInput(freeText), sequence: 2))

        // Runtime accepts sendNow into composerAllowed waiting states.
        let receipt = try await runtime.prompt(agentID, "via runtime", .sendNow)
        XCTAssertEqual(receipt.outcome, .delivered)
        XCTAssertEqual(port.deliverInputCallCount, 1)

        // UI boundary: the composer STAYS — only terminalOnly blocks (§5.1).
        let composer = PromptComposerView(model: model, sessionManager: nil)
        composer.configure(for: "waitingComposerAllowed")
        XCTAssertTrue(composer.fieldEnabled, "composerAllowed keeps the field enabled")
        XCTAssertFalse(composer.ctaVisible)
        var sent: (String, PromptPolicy)?
        composer.onSend = { text, policy, _ in sent = (text, policy); return .accepted }
        composer.sendFocusedPrompt(text: "allowed", policy: .sendNow)
        // dispatch() completes on a Task; wait for the outcome, don't race it.
        _ = await waitUntil("composer dispatch completed") { sent != nil }
        XCTAssertEqual(sent?.0, "allowed")

        // And the hard block STILL applies to terminalOnly.
        let blocked = PromptComposerView(model: model, sessionManager: nil)
        blocked.configure(for: "waitingForInput")
        blocked.onSend = { _, _, _ in XCTFail("terminalOnly must never send"); return .accepted }
        blocked.sendFocusedPrompt(text: "nope", policy: .sendNow)
    }

    // MARK: 4c — queued indicator is clickable and cancels (§3.11)

    func testQueuedIndicatorClickInvokesCancel() throws {
        let composer = PromptComposerView(model: model, sessionManager: nil)
        var cancelled = false
        composer.onCancelQueued = { cancelled = true }

        // The indicator sits in the view tree even while hidden (visibility
        // is refresh()-driven); a real click routes through its target/action,
        // so assert that wiring and fire it the way AppKit would.
        let indicator = try XCTUnwrap(
            Self.buttons(in: composer).first { $0.title.contains("Queued") },
            "queued indicator button must exist in the composer"
        )
        XCTAssertNotNil(indicator.target)
        let action = try XCTUnwrap(
            indicator.action,
            "queued indicator must wire an action — without one §3.11 click-to-cancel is dead UI"
        )
        _ = indicator.target?.perform(action, with: indicator)
        XCTAssertTrue(cancelled, "clicking the queued indicator must invoke onCancelQueued")
    }

    // MARK: 5 — unknown lifecycle allows only explicit sendNow

    func testUnknownLifecycleAllowsOnlyExplicitSendNow() async throws {
        let (agentID, _) = try await makeAgent()
        await ingestIdle(agentID, sequence: 1)
        await runtime.ingest(integrationEvidence(agentID, .unknown, sequence: 2))

        do {
            _ = try await runtime.prompt(agentID, "auto queue", .queueWhenIdle)
            XCTFail("unknown must reject automatic queueing")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .invalidLifecycle)
        }
        _ = try await runtime.prompt(agentID, "explicit only", .sendNow)
        XCTAssertEqual(port.deliverInputCallCount, 1)
        let explicitSettled = await waitUntil("explicit sendNow delivered exactly once") {
            await self.deliveredCount(agentID) == 1
        }
        XCTAssertTrue(explicitSettled)
    }

    // MARK: 6 — when-ready initial prompts (§3.9 bottom)

    func testInitialPromptDeliversAtFirstValidatedIdleNeverLogged() async throws {
        let (agentID, _) = try await makeAgent() // starting — no validated idle yet
        let marker = "SECRET-INITIAL-PROMPT"
        let coordinator = PromptCoordinator(runtime: runtime, clock: clock, model: model)
        coordinator.scheduleInitialPrompt(agentID: agentID, text: marker)

        _ = await advanceUntil(timeout: 1) { false } // deterministic pump: no delivery before validated idle
        XCTAssertEqual(port.deliverInputCallCount, 0, "must wait for VALIDATED idle")

        await ingestIdle(agentID, sequence: 1)
        _ = await waitUntil("initial prompt delivered at first idle") {
            let events = await self.deliveredCount(agentID)
            return self.port.deliverInputCallCount == 1 && events == 1
        }

        // Content never persisted/logged: no persistence writer was ever
        // attached in this test, and we prove it over the REAL store payload
        // codec — every timeline event is encoded exactly as
        // EventPayloadCodec.encode would persist it, and no kind/payload may
        // contain the prompt text. The switch is exhaustive over the
        // AgentEvent grammar: a future event case carrying text fails here.
        for event in await runtime.timeline(of: agentID) {
            let encoded = EventPayloadCodec.encode(event.event)
            let encodedText = encoded.kind + " " + (String(data: encoded.payload, encoding: .utf8) ?? "")
            XCTAssertFalse(encodedText.contains(marker), "persisted payload leaked prompt text: \(encodedText)")
            switch event.event {
            case .stateChanged, .turnStarted, .turnCompleted,
                 .attentionRaised, .attentionCleared:
                break // no text-bearing fields (verified by the codec above)
            case let .promptDelivered(commandID):
                XCTAssertFalse("\(commandID.rawValue.uuidString)".contains(marker))
            case let .promptDeliveryUnconfirmed(commandID):
                XCTAssertFalse("\(commandID.rawValue.uuidString)".contains(marker))
            case .queuedPromptCancelled:
                break
            case let .queuedPromptDeliveryFailed(commandID):
                XCTAssertFalse("\(commandID.rawValue.uuidString)".contains(marker))
            case .processExited:
                break
            case .sessionIdentityCaptured, .integrationSequenceGap,
                 .authorityLost, .stopCommanded, .restartInitiated, .resumeAttempted:
                break
            }
        }
    }

    func testInitialPromptTimeoutRestoresDraftInsteadOfBlindSend() async throws {
        let (agentID, _) = try await makeAgent() // never reaches idle
        let marker = "DRAFT-ON-TIMEOUT"
        var restored: String?
        let coordinator = PromptCoordinator(runtime: runtime, clock: clock, model: model)
        coordinator.onInitialPromptTimeout = { _, text in restored = text }
        coordinator.scheduleInitialPrompt(agentID: agentID, text: marker)
        let timedOut = await advanceUntil(timeout: 15) { restored != nil }
        XCTAssertTrue(timedOut, "domain timeout must fire the draft-restoration path")
        XCTAssertEqual(restored, marker)
        XCTAssertEqual(port.deliverInputCallCount, 0, "timeout NEVER blind-sends")
    }

    // MARK: - Round 16 (test-design-16): commandID-matched delivery clear (18f2d2b)

    func testClearWithMismatchedCommandIDKeepsNewerSlotSilently() {
        // §3.11: a poll for an OLDER command must not wipe a NEWER command's
        // surfaced slot — clear is guarded on `slot == commandID` and is
        // otherwise silent (no removal, no onChange).
        let agentID = AgentID()
        let older = CommandID()
        let newer = CommandID()
        var emissions = 0
        model.onChange = { emissions += 1 }

        model.setUnconfirmedDelivery(agentID: agentID, commandID: newer)
        XCTAssertEqual(emissions, 1, "positive control: the upsert emits once")

        model.clearUnconfirmedDelivery(agentID: agentID, commandID: older)

        XCTAssertEqual(model.unconfirmedDeliveries[agentID], newer,
                       "an older poll must not remove a newer command's slot")
        XCTAssertEqual(emissions, 1, "a mismatched clear is silent: no onChange")
    }

    func testClearWithMatchingCommandIDRemovesSlotAndEmitsOnce() {
        // The genuine confirmation path: matched id removes the slot and
        // emits exactly once — the fix must not overcorrect into a no-op.
        let agentID = AgentID()
        let commandID = CommandID()
        var emissions = 0
        model.onChange = { emissions += 1 }

        model.setUnconfirmedDelivery(agentID: agentID, commandID: commandID)
        XCTAssertEqual(emissions, 1)

        model.clearUnconfirmedDelivery(agentID: agentID, commandID: commandID)

        XCTAssertNil(model.unconfirmedDeliveries[agentID])
        XCTAssertEqual(emissions, 2, "the removal emits exactly one additional onChange")
    }

    func testClearOfUnknownAgentSlotIsEquallySilent() {
        // nil lookup ≠ commandID hits the same early return: no spurious
        // objectWillChange storm from stale polls for long-gone agents.
        let untouched = AgentID()
        var emissions = 0
        model.onChange = { emissions += 1 }

        model.clearUnconfirmedDelivery(agentID: untouched, commandID: CommandID())

        XCTAssertTrue(model.unconfirmedDeliveries.isEmpty)
        XCTAssertEqual(emissions, 0, "clearing an empty/unknown slot must not fire onChange")
    }
}

@testable import AgentCore
import XCTest

// §4.8: single-slot prompt queue + all §3.11 PromptPolicy safety rules.

@MainActor
final class PromptQueueTests: XCTestCase {
    // MARK: Queue unit semantics

    func testEnqueueAndTake() throws {
        var queue = PromptQueue()
        XCTAssertTrue(queue.isEmpty)
        let prompt = QueuedPrompt(commandID: CommandID(), text: "hi", queuedAt: instant(1))
        try queue.enqueue(prompt)
        XCTAssertFalse(queue.isEmpty)
        XCTAssertEqual(queue.take(), prompt)
        XCTAssertTrue(queue.isEmpty)
    }

    func testSecondEnqueueWithoutExplicitReplaceThrows() throws {
        var queue = PromptQueue()
        try queue.enqueue(QueuedPrompt(commandID: CommandID(), text: "one", queuedAt: instant(1)))
        XCTAssertThrowsError(
            try queue.enqueue(QueuedPrompt(commandID: CommandID(), text: "two", queuedAt: instant(2)))
        ) { error in
            XCTAssertEqual(error as? RuntimeErrors, .queuedPromptAlreadyExists)
        }
        XCTAssertEqual(queue.queued?.text, "one", "original prompt survives the rejected replace")
    }

    func testExplicitReplaceIsAuthorized() throws {
        var queue = PromptQueue()
        try queue.enqueue(QueuedPrompt(commandID: CommandID(), text: "one", queuedAt: instant(1)))
        let replacement = QueuedPrompt(commandID: CommandID(), text: "two", queuedAt: instant(2))
        try queue.enqueue(replacement, replacingExisting: true)
        XCTAssertEqual(queue.queued, replacement)
    }

    func testCancelClearsSlot() throws {
        var queue = PromptQueue()
        XCTAssertFalse(queue.cancel())
        try queue.enqueue(QueuedPrompt(commandID: CommandID(), text: "x", queuedAt: instant(1)))
        XCTAssertTrue(queue.cancel())
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: Runtime policy safety (§3.11)

    private func makeRuntime() async throws -> (AgentRuntime, FakeTerminalPort, AgentID, TerminalID) {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent(kind: .claudeCode)
        let port = FakeTerminalPort()
        await runtime.setTerminalPort(port)
        return (runtime, port, made.agent, made.terminal)
    }

    /// Forces the session into a lifecycle via screen evidence.
    private func forceLifecycle(_ runtime: AgentRuntime, agent: AgentID, _ phase: LifecyclePhase, at t: Int64) async {
        await runtime.ingest(screenEvidence(
            agent: agent,
            lifecycle: phase,
            receivedAt: instant(t),
            outputRevision: UInt64(t)
        ))
    }

    func testIdleAcceptsAnyPolicyAndDeliversImmediately() async throws {
        let (runtime, port, agent, _) = try await makeRuntime()

        // A freshly launched agent is `starting`; move it to a validated idle.
        await forceLifecycle(runtime, agent: agent, .idle, at: 5)
        for policy in [PromptPolicy.sendNow, .queueWhenIdle, .rejectUnlessIdle] {
            let receipt = try await runtime.prompt(agent, "hello", policy)
            XCTAssertEqual(receipt.outcome, .delivered)
        }
        await eventually("three deliveries expected") { port.deliverInputCallCount == 3 }
    }

    func testWaitingForTerminalInputRejectsComposerPrompt() async throws {
        let (runtime, _, agent, _) = try await makeRuntime()
        let terminalOnly = LifecyclePhase.waitingForInput(
            InputRequestDescriptor(kind: .approval, summary: nil, safeReplyMode: .terminalOnly, source: .screen)
        )
        await forceLifecycle(runtime, agent: agent, terminalOnly, at: 10)

        do {
            _ = try await runtime.prompt(agent, "y", .sendNow)
            XCTFail("terminalOnly waiting must reject composer prompts")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .waitingForTerminalInput)
        }
    }

    func testWaitingWithComposerAllowedSendsImmediately() async throws {
        let (runtime, port, agent, _) = try await makeRuntime()
        let composerAllowed = LifecyclePhase.waitingForInput(
            InputRequestDescriptor(kind: .freeText, summary: nil, safeReplyMode: .composerAllowed, source: .integration)
        )
        await forceLifecycle(runtime, agent: agent, composerAllowed, at: 10)

        // Even queueWhenIdle coerces to immediate delivery for composerAllowed.
        let receipt = try await runtime.prompt(agent, "answer", .queueWhenIdle)
        XCTAssertEqual(receipt.outcome, .delivered)
        await eventually { port.deliverInputCallCount == 1 }
    }

    func testUnknownAllowsOnlyExplicitSendNow() async throws {
        let (runtime, port, agent, _) = try await makeRuntime()
        await forceLifecycle(runtime, agent: agent, .unknown, at: 10)

        do {
            _ = try await runtime.prompt(agent, "x", .queueWhenIdle)
            XCTFail("unknown must reject queueWhenIdle")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .invalidLifecycle)
        }
        do {
            _ = try await runtime.prompt(agent, "x", .rejectUnlessIdle)
            XCTFail("unknown must reject rejectUnlessIdle")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .invalidLifecycle)
        }

        let receipt = try await runtime.prompt(agent, "explicit", .sendNow)
        XCTAssertEqual(receipt.outcome, .delivered)
        await eventually { port.deliverInputCallCount == 1 }
    }

    func testWorkingQueuesSinglePromptAndDeliversOnNextValidatedIdle() async throws {
        let (runtime, port, agent, _) = try await makeRuntime()
        await forceLifecycle(runtime, agent: agent, .working, at: 10)

        let first = try await runtime.prompt(agent, "first", .queueWhenIdle)
        XCTAssertEqual(first.outcome, .queued)

        do {
            _ = try await runtime.prompt(agent, "second", .queueWhenIdle)
            XCTFail("only one queued prompt allowed")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .queuedPromptAlreadyExists)
        }

        // The ORIGINAL prompt survives the rejected second queue and is
        // delivered exactly once on the next validated idle (§3.11).
        await forceLifecycle(runtime, agent: agent, .idle, at: 20)
        await eventually("queued prompt delivered on idle") {
            port.deliveredTexts.contains { $0.1 == "first" }
        }
        await eventually("delivery settles") { port.deliverInputCallCount == 1 }
        XCTAssertFalse(port.deliveredTexts.contains { $0.1 == "second" },
                       "the rejected prompt must never be delivered")
    }

    func testCancelQueuedPromptRemovesWithoutSideEffects() async throws {
        let (runtime, port, agent, _) = try await makeRuntime()
        await forceLifecycle(runtime, agent: agent, .working, at: 10)

        _ = try await runtime.prompt(agent, "queued", .queueWhenIdle)
        try await runtime.cancelQueuedPrompt(agent)

        // Next idle delivers nothing: the §3.11 law is that a cancelled
        // prompt must NEVER reach the port or the timeline.
        await forceLifecycle(runtime, agent: agent, .idle, at: 20)
        await eventually("idle settles after cancel") {
            await (try? runtime.state(of: agent))?.lifecycle == .idle
        }
        XCTAssertTrue(port.deliveredTexts.isEmpty,
                      "a cancelled prompt must never be delivered")
        let timeline = await runtime.timeline(of: agent)
        XCTAssertFalse(
            timeline.contains { event in
                if case .promptDelivered = event.event {
                    return true
                }
                return false
            },
            "no promptDelivered event may exist after cancellation"
        )
    }

    /// §3.11 regression: a drained queued prompt whose delivery fails used to
    /// vanish silently (`try?`). The failure must surface as a
    /// `queuedPromptDeliveryFailed` timeline event.
    func testFailedQueuedDeliverySurfacesEventInsteadOfDropping() async throws {
        let clock = FakeClock()
        // No terminal port attached: every deliverPrompt throws
        // terminalUnavailable — the simulated failure path.
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent(kind: .claudeCode)
        let agent = made.agent

        await forceLifecycle(runtime, agent: agent, .working, at: 10)
        let receipt = try await runtime.prompt(agent, "queued", .queueWhenIdle)
        XCTAssertEqual(receipt.outcome, .queued)

        // Idle evidence drains the queue; the drain's delivery then fails.
        await forceLifecycle(runtime, agent: agent, .idle, at: 20)

        await eventually("delivery failure surfaces in timeline") {
            await runtime.timeline(of: agent).contains { event in
                event.event == .queuedPromptDeliveryFailed(commandID: receipt.commandID)
            }
        }

        // Exactly one failure trace, and the queue stays empty.
        let failures = await runtime.timeline(of: agent).filter {
            if case .queuedPromptDeliveryFailed = $0.event {
                return true
            }
            return false
        }
        XCTAssertEqual(failures.count, 1)
    }

    func testProcessOnlyAdapterCannotQueueUntilIdle() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent(kind: .genericShell)
        let port = FakeTerminalPort()
        await runtime.setTerminalPort(port)

        await forceLifecycle(runtime, agent: made.agent, .working, at: 10)
        do {
            _ = try await runtime.prompt(made.agent, "nope", .queueWhenIdle)
            XCTFail("process-only adapters disallow queueWhenIdle")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .invalidLifecycle)
        }
    }

    func testRejectUnlessIdleRejectsWhileWorking() async throws {
        let (runtime, _, agent, _) = try await makeRuntime()
        await forceLifecycle(runtime, agent: agent, .working, at: 10)
        do {
            _ = try await runtime.prompt(agent, "nope", .rejectUnlessIdle)
            XCTFail("rejectUnlessIdle must reject while working")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .invalidLifecycle)
        }
    }

    func testSendNowWorksEvenWhileWorking() async throws {
        let (runtime, port, agent, _) = try await makeRuntime()
        await forceLifecycle(runtime, agent: agent, .working, at: 10)
        let receipt = try await runtime.prompt(agent, "interrupt-style send", .sendNow)
        XCTAssertEqual(receipt.outcome, .delivered)
        await eventually { port.deliverInputCallCount == 1 }
    }

    func testStoppedAgentRejectsPrompts() async throws {
        let (runtime, _, agent, _) = try await makeRuntime()
        await forceLifecycle(runtime, agent: agent, .stopped(.userRequested), at: 10)
        do {
            _ = try await runtime.prompt(agent, "x", .sendNow)
            XCTFail("stopped agents reject prompts")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .invalidLifecycle)
        }
    }

    func testPromptToUnknownAgentThrows() async {
        let runtime = AgentRuntime(clock: FakeClock())
        do {
            _ = try await runtime.prompt(AgentID(), "x", .sendNow)
            XCTFail("expected agentNotFound")
        } catch let error as RuntimeErrors {
            XCTAssertEqual(error, .agentNotFound)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Round 7: the idle drain consumes the stale `.queued` replay receipt
    /// and re-dispatches under the ORIGINAL commandID — a client retry of
    /// that commandID after queue-then-drain gets a FRESH receipt, never a
    /// stale "queued" replay, and delivery happens exactly once.
    func testDrainedQueuedPromptDeliversUnderOriginalCommandIDAndRetryGetsFreshReceipt() async throws {
        let (runtime, port, agent, _) = try await makeRuntime()
        let key = CommandID()

        await forceLifecycle(runtime, agent: agent, .working, at: 10)
        let r1 = try await runtime.prompt(agent, "deploy", .queueWhenIdle, commandID: key)
        XCTAssertEqual(r1.outcome, .queued)

        // Validated idle drains the queue and delivers under `key`.
        await forceLifecycle(runtime, agent: agent, .idle, at: 20)
        await eventually("queued prompt delivered") { port.deliverInputCallCount == 1 }

        // The retry must NOT answer with the stale `.queued` receipt.
        let r2 = try await runtime.prompt(agent, "deploy", .sendNow, commandID: key)
        XCTAssertEqual(r2.outcome, .delivered)
        XCTAssertEqual(port.deliveredTexts.last?.1, "deploy")

        // The drain delivered exactly once; the retry replayed `r2` and
        // delivered nothing further.
        let deliveredEvents = await runtime.timeline(of: agent).filter {
            if case let .promptDelivered(id) = $0.event {
                return id == key
            }
            return false
        }.count
        XCTAssertEqual(deliveredEvents, 1)

        // A third call with the same key replays again without delivering.
        let r3 = try await runtime.prompt(agent, "deploy", .sendNow, commandID: key)
        XCTAssertEqual(r3.outcome, .delivered)
        XCTAssertEqual(port.deliverInputCallCount, 1)
    }
}

@testable import AgentCore
import XCTest

// §4.8: 5-second prompt delivery confirmation — and the never-auto-retry rule.

@MainActor
final class PromptWatchdogTests: XCTestCase {
    // MARK: Unit behavior

    func testConfirmationByOutputRevisionSignal() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let commandID = CommandID()

        let watchTask = Task { await watchdog.watch(commandID: commandID) }
        await watchdog.confirm(.outputRevisionChanged, for: commandID)

        let result = await watchTask.value
        XCTAssertEqual(result, .confirmed(.outputRevisionChanged))
    }

    func testConfirmationByIntegrationOperationStart() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let commandID = CommandID()

        let watchTask = Task { await watchdog.watch(commandID: commandID) }
        await watchdog.confirm(.integrationOperationStart, for: commandID)

        let result = await watchTask.value
        XCTAssertEqual(result, .confirmed(.integrationOperationStart))
    }

    func testConfirmationByWorkingTransition() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let commandID = CommandID()

        let watchTask = Task { await watchdog.watch(commandID: commandID) }
        await watchdog.confirm(.lifecycleBecameWorking, for: commandID)

        let result = await watchTask.value
        XCTAssertEqual(result, .confirmed(.lifecycleBecameWorking))
    }

    func testTimeoutAfterFiveSecondsWithoutSignals() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let commandID = CommandID()

        // The unstructured task inherits this @MainActor context, so `watch`
        // can only arm once this test suspends. Arm it at virtual time zero
        // BEFORE moving the clock: if the clock is advanced first, `watch`
        // computes its deadline from the already-advanced time, the sleeper
        // never fires, and `await watchTask.value` deadlocks the suite.
        let watchTask = Task { await watchdog.watch(commandID: commandID) }
        await eventually("watch armed") { await watchdog.isWatching(commandID: commandID) }

        clock.advance(by: .milliseconds(4999))
        clock.advance(by: .milliseconds(1))
        let result = await watchTask.value
        XCTAssertEqual(result, .timedOut)

        // Confirming after timeout is a no-op (watch already resolved).
        await watchdog.confirm(.lifecycleBecameWorking, for: commandID)
    }

    func testConfirmBeforeDeadlineWins() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let commandID = CommandID()

        let watchTask = Task { await watchdog.watch(commandID: commandID) }
        clock.advance(by: .seconds(2))
        await watchdog.confirm(.outputRevisionChanged, for: commandID)

        let result = await watchTask.value
        XCTAssertEqual(result, .confirmed(.outputRevisionChanged))
    }

    func testWrongCommandIDDoesNotResolveWatch() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let commandID = CommandID()

        let watchTask = Task { await watchdog.watch(commandID: commandID) }
        await eventually("watch armed") { await watchdog.isWatching(commandID: commandID) }

        await watchdog.confirm(.outputRevisionChanged, for: CommandID())
        clock.advance(by: .seconds(5))

        let result = await watchTask.value
        XCTAssertEqual(result, .timedOut, "only a matching command ID confirms")
    }

    func testTimeoutConstantIsFiveSeconds() {
        XCTAssertEqual(PromptWatchdog.confirmationTimeout, .seconds(5))
    }

    /// Regression: confirmations for command IDs that are never watched used
    /// to accumulate without bound. The buffer is insertion-ordered and capped
    /// with oldest-entry eviction.
    func testEarlyConfirmationsForStaleCommandsStayBounded() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let limit = PromptWatchdog.earlyConfirmationBufferLimit

        var ids: [CommandID] = []
        for _ in 0 ..< (limit + 2) {
            let id = CommandID()
            ids.append(id)
            await watchdog.confirm(.outputRevisionChanged, for: id)
        }

        let buffered = await watchdog.bufferedEarlyConfirmationCount
        XCTAssertLessThanOrEqual(buffered, limit,
                                 "stale confirmations must not grow the buffer past the cap")
        let oldestEvicted = await !(watchdog.isWatching(commandID: ids[0]))
        let secondOldestEvicted = await !(watchdog.isWatching(commandID: ids[1]))
        let newestBuffered = await watchdog.isWatching(commandID: ids[ids.count - 1])
        XCTAssertTrue(oldestEvicted, "the oldest stale confirmation was evicted")
        XCTAssertTrue(secondOldestEvicted, "the second-oldest stale confirmation was evicted")
        XCTAssertTrue(newestBuffered, "the newest confirmations survive")
    }

    /// A signal arriving BEFORE the watch arms buffers and must satisfy the
    /// watch of the SAME delivery — this is the legitimate early-confirmation
    /// path that generation binding must preserve.
    func testFreshEarlyConfirmationIsConsumedByLaterWatch() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let commandID = CommandID()

        await watchdog.confirm(.outputRevisionChanged, for: commandID)
        let watchTask = Task { await watchdog.watch(commandID: commandID) }
        let outcome = await watchTask.value
        XCTAssertEqual(outcome, .confirmed(.outputRevisionChanged))
    }

    /// Regression (§3.11): a confirmation buffered for an EARLIER delivery of
    /// a command ID must not satisfy a later watch for a redelivery of the
    /// SAME ID (queue-drain replays deliberately reuse the commandID). The
    /// new delivery invalidates the stale buffer entry, so the redelivered
    /// prompt times out instead of being falsely confirmed.
    func testRedeliveryInvalidatesStaleBufferedConfirmation() async {
        let clock = FakeClock()
        let watchdog = PromptWatchdog(clock: clock)
        let commandID = CommandID()

        // First delivery confirms; a late duplicate signal then buffers.
        let firstTask = Task { await watchdog.watch(commandID: commandID) }
        await watchdog.confirm(.outputRevisionChanged, for: commandID)
        let firstOutcome = await firstTask.value
        XCTAssertEqual(firstOutcome, .confirmed(.outputRevisionChanged))
        await watchdog.confirm(.lifecycleBecameWorking, for: commandID)
        let bufferedAfterLateSignal = await watchdog.bufferedEarlyConfirmationCount
        XCTAssertEqual(bufferedAfterLateSignal, 1,
                       "the post-confirm late signal buffers")

        // Redelivery invalidates everything buffered for the previous
        // delivery generation of this command.
        await watchdog.invalidateBufferedConfirmation(for: commandID)
        let bufferedNow = await watchdog.bufferedEarlyConfirmationCount
        XCTAssertEqual(bufferedNow, 0)

        let secondTask = Task { await watchdog.watch(commandID: commandID) }
        await eventually("redelivered watch armed") { await watchdog.isWatching(commandID: commandID) }
        clock.advance(by: .seconds(6))
        let secondOutcome = await secondTask.value
        XCTAssertEqual(secondOutcome, .timedOut,
                       "the stale buffered signal must not falsely confirm the redelivery")
    }

    // MARK: Runtime integration — unconfirmed delivery is recorded, never retried

    func testUnconfirmedDeliveryRecordsEventAndNeverRetries() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent()
        let port = FakeTerminalPort()
        await runtime.setTerminalPort(port)

        _ = try await runtime.prompt(made.agent, "did you get this?", .sendNow)
        await eventually("watch armed") { await runtime.isDeliveryWatchArmed(made.agent) }
        XCTAssertEqual(port.deliverInputCallCount, 1, "exactly one delivery attempt")
        // §3.11 watchdog step 1: the state revision is recorded at ARM time.
        let watch = await runtime.deliveryWatchStatus(made.agent)
        let currentState = try await runtime.state(of: made.agent)
        XCTAssertEqual(watch?.stateRevisionAtArm, currentState.revision,
                       "armed watch must snapshot the session's lifecycle revision")

        // No output revision change, no working transition, no integration
        // confirmation → deadline passes.
        clock.advance(by: .seconds(6))
        await eventually("unconfirmed event recorded") {
            let timeline = await runtime.timeline(of: made.agent)
            return timeline.contains { event in
                if case .promptDeliveryUnconfirmed = event.event {
                    return true
                }
                return false
            }
        }
        XCTAssertEqual(port.deliverInputCallCount, 1, "NEVER auto-retry")
    }

    func testOutputRevisionChangeConfirmsDeliveryInRuntime() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent()
        let port = FakeTerminalPort()
        await runtime.setTerminalPort(port)

        _ = try await runtime.prompt(made.agent, "hello", .sendNow)
        await eventually("watch armed") { await runtime.isDeliveryWatchArmed(made.agent) }

        // The agent echoes output: revision moves.
        try await runtime.outputRevisionChanged(
            agentID: made.agent,
            terminalID: made.terminal,
            revision: 42
        )
        clock.advance(by: .seconds(6))

        // Wait for a POSITIVE observable first: the watch must have
        // RESOLVED (disarmed by the confirmation). Polling only the
        // timeline's absence is trivially true before the advanced clock's
        // sleeper could record a timeout, so a broken confirm path would
        // still pass.
        await eventually("delivery watch resolved") {
            await runtime.deliveryWatchStatus(made.agent) == nil
        }
        let timeline = await runtime.timeline(of: made.agent)
        XCTAssertFalse(
            timeline.contains { event in
                if case .promptDeliveryUnconfirmed = event.event {
                    return true
                }
                return false
            },
            "confirmation must prevent the unconfirmed-timeout event"
        )
    }

    /// Regression (§3.11 rule 6): arming a new watch while a predecessor is
    /// still pending supersedes it — the displaced prompt must get its
    /// `promptDeliveryUnconfirmed` record under ITS OWN command ID instead of
    /// being silently dropped by the moved DeliveryWatch slot. The successor
    /// watch stays armed and reports on its own.
    func testSupersededWatchRecordsUnconfirmedForDisplacedCommand() async throws {
        let clock = FakeClock()
        let runtime = AgentRuntime(clock: clock)
        let made = try await runtime.makeRunningAgent()
        let port = FakeTerminalPort()
        await runtime.setTerminalPort(port)

        let first = CommandID()
        _ = try await runtime.prompt(made.agent, "first", .sendNow, commandID: first)
        await eventually("first watch armed") { await runtime.isDeliveryWatchArmed(made.agent) }

        // The second delivery supersedes the still-pending first watch.
        _ = try await runtime.prompt(made.agent, "second", .sendNow)

        await eventually("superseded command recorded unconfirmed") {
            await runtime.timeline(of: made.agent).contains { event in
                if case let .promptDeliveryUnconfirmed(id) = event.event {
                    return id == first
                }
                return false
            }
        }
        // NEVER auto-retry (§3.11 rule 7): exactly two delivery attempts.
        await eventually("exactly two deliveries") { port.deliverInputCallCount == 2 }
    }
}

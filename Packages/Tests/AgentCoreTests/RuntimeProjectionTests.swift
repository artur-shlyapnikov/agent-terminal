@testable import AgentCore
import XCTest

// RuntimeDeltaStream single-consumer contract (EventStreamBroker holds the
// SINGLE runtime subscription *because* the stream is single-consumer) and
// RuntimeProjectionBuilder createdAt ordering (§4.2).

final class RuntimeProjectionTests: XCTestCase {
    /// Sendable accumulation box for consumer tasks (AgentCore compiles with
    /// -strict-concurrency=complete; tasks capture only this actor).
    private actor DeltaBox {
        private(set) var items: [RuntimeDelta] = []
        private(set) var subscribed = false
        private(set) var iterationEnded = false

        func markSubscribed() {
            subscribed = true
        }

        func append(_ delta: RuntimeDelta) {
            items.append(delta)
        }

        func markIterationEnded() {
            iterationEnded = true
        }
    }

    /// Starts a consumer task that registers its subscription synchronously
    /// (the continuation swap in `stream.stream` happens during `let subscribed
    /// = stream.stream`), signals registration, then iterates. Deterministic
    /// arming via `eventually` — no sleeps.
    private func startConsumer(_ stream: RuntimeDeltaStream, box: DeltaBox) -> Task<Void, Never> {
        Task {
            let subscribed = stream.stream
            await box.markSubscribed()
            for await delta in subscribed {
                await box.append(delta)
            }
            await box.markIterationEnded()
        }
    }

    // MARK: C1

    func testYieldBeforeAnySubscriberIsDroppedWithoutCrashing() async {
        let stream = RuntimeDeltaStream()

        // Publisher starts before the UI subscribes: a safe no-op, no trap.
        stream.yield(.agentRemoved(AgentID()))

        // A later subscription is an empty, normally-finishable stream.
        let late = stream.stream
        stream.finish()
        var iterator = late.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next, "deltas yielded before any subscription are dropped, never replayed")
    }

    // MARK: C2

    func testSecondSubscriptionReplacesFirstWhichStopsReceivingDeltas() async {
        let stream = RuntimeDeltaStream()
        let firstBox = DeltaBox()
        let firstTask = startConsumer(stream, box: firstBox)
        await eventually("first subscriber armed") { await firstBox.subscribed }

        let delta1 = RuntimeDelta.agentRemoved(AgentID())
        stream.yield(delta1)
        await eventually("first subscriber received delta1") { await firstBox.items == [delta1] }

        // Second subscription silently replaces the stored continuation.
        let secondBox = DeltaBox()
        let secondTask = startConsumer(stream, box: secondBox)
        await eventually("second subscriber armed") { await secondBox.subscribed }

        let delta2 = RuntimeDelta.agentRemoved(AgentID())
        stream.yield(delta2)
        await eventually("second subscriber received delta2") { await secondBox.items == [delta2] }

        // The replaced first subscription saw nothing more — and was not
        // finished behind its back (only the active one gets finish()).
        let firstItems = await firstBox.items
        XCTAssertEqual(firstItems, [delta1], "the replaced subscription must stop receiving deltas")
        let firstEnded = await firstBox.iterationEnded
        XCTAssertFalse(firstEnded, "replacing a subscription must not finish the old stream")

        // Cleanup: release the (still pending) first consumer.
        firstTask.cancel()
        secondTask.cancel()
        stream.finish()
        await firstTask.value
        await secondTask.value
    }

    // MARK: C3

    func testFinishTerminatesTheActiveSubscriptionWithNormalCompletion() async {
        let stream = RuntimeDeltaStream()
        let box = DeltaBox()
        let consumer = startConsumer(stream, box: box)
        await eventually("consumer armed") { await box.subscribed }

        let delta = RuntimeDelta.agentRemoved(AgentID())
        stream.yield(delta)
        await eventually("delta delivered") { await box.items == [delta] }

        stream.finish()
        await eventually("for await loop exits on finish (no subscriber leak)") {
            await box.iterationEnded
        }
        let items = await box.items
        XCTAssertEqual(items, [delta])
        await consumer.value
    }

    // MARK: C4

    func testProjectionBuilderOrdersSummariesByCreationTimeNotCollectionOrder() {
        // Shuffled insertion order [C, A, B] with distinct createdAt values.
        let sessions = [
            makeSession(displayName: "C", createdAt: instant(3)),
            makeSession(displayName: "A", createdAt: instant(1)),
            makeSession(displayName: "B", createdAt: instant(2)),
        ]

        let projection = RuntimeProjectionBuilder.build(sessions: sessions, generatedAt: instant(99))

        XCTAssertEqual(projection.agents.map(\.displayName), ["A", "B", "C"],
                       "summaries must be ordered by createdAt, not collection order")
        XCTAssertEqual(projection.generatedAt, instant(99))
    }

    /// Minimal AgentSession fixture (AgentStoreTests' makeSession shape).
    private func makeSession(displayName: String, createdAt: MonotonicInstant) -> AgentSession {
        AgentSession(
            workspaceID: WorkspaceID(),
            kind: .claudeCode,
            displayName: displayName,
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: .claudeCode,
                program: "/usr/local/bin/agent",
                arguments: [],
                workingDirectory: "/tmp",
                environment: [:]
            ),
            state: AgentState.fresh(at: createdAt),
            createdAt: createdAt,
            lastActivityAt: createdAt
        )
    }
}

import AgentCore
@testable import TerminalKit
import XCTest

// Two-phase teardown state machine (ADR-0002): phase 1 synchronous at
// enqueue, phase 2 native free strictly later on the main thread, completion
// (registry removal) strictly after the free, double-enqueue rejected.

@MainActor final class TerminalTeardownQueueTests: XCTestCase {
    final class FakeTarget: TerminalTeardownTarget, @unchecked Sendable {
        private(set) var closing = false
        private(set) var began = false
        private(set) var freed = false
        var events: [String] {
            ["begin:\(began)", "free:\(freed)"]
        }

        var isClosing: Bool {
            closing
        }

        func beginTeardown() {
            XCTAssertFalse(began)
            began = true
            closing = true
        }

        func performNativeFree() {
            XCTAssertTrue(closing, "native free must run after beginTeardown")
            XCTAssertTrue(Thread.isMainThread, "phase 2 must be main-thread")
            XCTAssertFalse(freed)
            freed = true
        }
    }

    func testTwoPhaseOrderAndCompletionAfterFree() {
        let target = FakeTarget()
        let queue = TerminalTeardownQueue()
        var completionRanAfterFree = false

        queue.enqueue(target) {
            completionRanAfterFree = target.freed // registry removal ordering
        }

        XCTAssertTrue(target.began, "phase 1 must run synchronously at enqueue")
        XCTAssertFalse(target.freed, "phase 2 must not run synchronously")

        queue.drainForTesting()

        XCTAssertTrue(target.freed, "phase 2 native free must have run")
        XCTAssertTrue(completionRanAfterFree)
        XCTAssertEqual(queue.completedCount, 1)
    }

    func testDoubleEnqueueIsRejectedWhileClosing() {
        let target = FakeTarget()
        let queue = TerminalTeardownQueue()
        var completions = 0

        queue.enqueue(target) { completions += 1 }
        queue.enqueue(target) { completions += 1 } // rejected: already closing
        queue.drainForTesting()

        XCTAssertEqual(completions, 1, "second enqueue of a closing target must be rejected")
        XCTAssertEqual(queue.completedCount, 1)
    }

    func testMultipleTargetsDrainSequentially() {
        let first = FakeTarget()
        let second = FakeTarget()
        let queue = TerminalTeardownQueue()
        var order: [String] = []

        queue.enqueue(first) { order.append("first-done") }
        queue.enqueue(second) { order.append("second-done") }
        queue.drainForTesting()

        XCTAssertEqual(order, ["first-done", "second-done"])
        XCTAssertTrue(first.freed && second.freed)
    }

    @MainActor
    func testSurfaceClosingRejectsCommands() async throws {
        let engine = FakeEngine()
        let parking = FakeParkingHost()
        let manager = TerminalSessionManager(engine: engine, parkingHost: parking)

        let session = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )

        try manager.close(terminalID: session.id)
        manager.teardownQueueForTesting().drainForTesting()

        // After the drain the registry entry is gone: both commands must
        // throw the SPECIFIC unknown-terminal error — a bare catch would
        // also swallow unrelated regressions.
        do {
            _ = try await manager.read(session.id, source: .detection)
            XCTFail("read on closed terminal must throw")
        } catch {
            guard case TerminalKitError.unknownTerminal(session.id) = error else {
                return XCTFail("expected unknownTerminal, got \(error)")
            }
        }

        do {
            try await manager.deliverInput(session.id, text: "x", submit: false)
            XCTFail("input on closed terminal must throw")
        } catch {
            guard case TerminalKitError.unknownTerminal(session.id) = error else {
                return XCTFail("expected unknownTerminal, got \(error)")
            }
        }
    }

    /// R20-TQ1: a completion that enqueues ANOTHER target mid-drain must not
    /// double-free, lose the entry, or run the new completion BEFORE its
    /// native free — `drainForTesting`'s while-loop picks up appends made
    /// during the drain (the guarded pump would defer them behind
    /// `isDraining`). FakeTarget.performNativeFree asserts exactly-once.
    func testReentrantEnqueueDuringDrainFreesExactlyOnceWithCompletionAfterFree() {
        let queue = TerminalTeardownQueue()
        var order: [String] = []

        let a = FakeTarget()
        let b = FakeTarget()
        let c = FakeTarget()

        queue.enqueue(a) {
            XCTAssertTrue(a.freed, "completion runs strictly after its own native free")
            order.append("A-done")
            // Reentrant append DURING the drain.
            queue.enqueue(b) {
                XCTAssertTrue(b.freed)
                order.append("B-done")
            }
        }
        queue.enqueue(c) {
            XCTAssertTrue(c.freed)
            order.append("C-done")
        }

        queue.drainForTesting()

        // Pending FIFO was [A, C] when the drain started; A's completion
        // enqueues B giving [C, B]; FIFO pops A, C, B.
        XCTAssertEqual(order, ["A-done", "C-done", "B-done"])
        XCTAssertTrue(a.freed && b.freed && c.freed, "each target freed EXACTLY once")
        XCTAssertEqual(queue.completedCount, 3)
        XCTAssertEqual(queue.pendingCount, 0)

        // A second drain is a no-op: no double free, no re-run completions.
        queue.drainForTesting()
        XCTAssertEqual(queue.completedCount, 3)
        XCTAssertEqual(order, ["A-done", "C-done", "B-done"], "completions never re-run")
    }
}

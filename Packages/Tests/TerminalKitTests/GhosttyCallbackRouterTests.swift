import AgentCore
import GhosttyBridge
@testable import TerminalKit
import XCTest

// Callback router copy + generation guard (§3.18): a callback racing teardown
// must be a no-op; delivered events carry the captured identity.

final class GhosttyCallbackRouterTests: XCTestCase {
    @MainActor
    func testDeliveryBeforeTeardownArrivesOnMainActor() async {
        let box = SurfaceCallbackBox(terminalID: TerminalID(), generation: SurfaceGeneration(rawValue: 7))
        let expectation = expectation(description: "event delivered")
        expectation.assertForOverFulfill = false
        nonisolated(unsafe) var received: GhosttyEvent?
        box.setSink { event in
            received = event
            expectation.fulfill()
        }

        // Deliver from background tasks — the router hop must land on main.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    box.deliver(.render)
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(received?.generation, SurfaceGeneration(rawValue: 7))
        XCTAssertEqual(received?.payload, .render)
    }

    @MainActor
    func testLateCallbackAfterTeardownIsNoOp() async throws {
        let box = SurfaceCallbackBox(terminalID: TerminalID(), generation: .initial)
        var deliveries = 0
        box.setSink { _ in
            Task { @MainActor in
                deliveries += 1
            }
        }

        box.clearSink() // teardown phase 1

        // Late callbacks from multiple tasks after teardown.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 16 {
                group.addTask {
                    box.deliver(.render)
                    box.deliver(.title("late"))
                }
            }
        }
        // Give any (incorrectly) scheduled hops a chance to run.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(deliveries, 0, "late callback after teardown must be a no-op")
    }

    func testEventConversionCopiesBorrowedStrings() throws {
        var raw = AGTEvent()
        raw.kind = AGTEventNotification
        let title = try XCTUnwrap(strdup("Claude Code"))
        let body = try XCTUnwrap(strdup("needs approval"))
        defer {
            free(title); free(body)
        }
        raw.title = title
        raw.body = body

        guard case let .notification(titleValue, bodyValue)? =
            GhosttyCallbackRouter.convert(raw)
        else {
            return XCTFail("expected notification payload")
        }
        XCTAssertEqual(titleValue, "Claude Code")
        XCTAssertEqual(bodyValue, "needs approval")
    }

    @MainActor
    func testChildExitedConversion() {
        var raw = AGTEvent()
        raw.kind = AGTEventChildExited
        raw.exit_code = 42
        XCTAssertEqual(GhosttyCallbackRouter.convert(raw), .childExited(exitCode: 42))
    }

    // MARK: Round 6 — pre-sink payload buffering

    @MainActor
    func testPayloadsDeliveredBeforeSinkAreFlushedOldestFirstAtSetSink() async {
        let box = SurfaceCallbackBox(terminalID: TerminalID(), generation: .initial)
        let recorder = PayloadRecorder()

        // Early events fired during surface creation, before any sink exists.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                box.deliver(.title("early"))
                box.deliver(.render)
                box.deliver(.title("pwd:/tmp"))
            }
        }

        let flushed = expectation(description: "3 buffered payloads flushed")
        flushed.expectedFulfillmentCount = 3
        box.setSink { event in
            recorder.append(event.payload)
            flushed.fulfill()
        }

        await fulfillment(of: [flushed], timeout: 2)
        XCTAssertEqual(
            recorder.payloads,
            [.title("early"), .render, .title("pwd:/tmp")],
            "flush must preserve delivery order and drop nothing"
        )
    }

    @MainActor
    func testPreSinkBufferCapDropsOldestBeyondThirtyTwo() async {
        let box = SurfaceCallbackBox(terminalID: TerminalID(), generation: .initial)
        let recorder = PayloadRecorder()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 1 ... 40 {
                    box.deliver(.title("n-\(index)"))
                }
            }
        }

        let flushed = expectation(description: "32 buffered payloads flushed")
        flushed.expectedFulfillmentCount = 32
        box.setSink { event in
            recorder.append(event.payload)
            flushed.fulfill()
        }

        await fulfillment(of: [flushed], timeout: 2)
        let titles = recorder.payloads.map { payload -> String in
            guard case let .title(title) = payload else { return "<non-title>" }
            return title
        }
        // Exactly 32 survive; the OLDEST 8 were dropped, never the newest —
        // the most recent early events are the ones detection needs.
        XCTAssertEqual(titles, (9 ... 40).map { "n-\($0)" })
    }

    // MARK: render coalescing — contentless bursts fold into one hop

    /// Driven entirely on main: performOnMain runs the hop SYNCHRONOUSLY
    /// here, so the whole burst lands inside one lock-held stack — the
    /// first render opens the hop, every later render sees the pending
    /// flag and folds into it. The flag reset is deferred to the next
    /// main-queue turn, so a tight deliver loop can never reopen a hop
    /// mid-burst (this determinism is exactly why the reset is dispatched).
    @MainActor
    func testRenderBurstCoalescesToSingleSinkCallWhileNonRendersEachDeliver() async throws {
        let box = SurfaceCallbackBox(terminalID: TerminalID(), generation: .initial)
        let recorder = PayloadRecorder()
        box.setSink { event in
            recorder.append(event.payload)
        }

        box.deliver(.title("a"))
        for _ in 0 ..< 16 {
            box.deliver(.render)
        }
        box.deliver(.title("pwd:/tmp"))

        // Let the deferred flag reset (next main-queue turn) run.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            recorder.payloads,
            [.title("a"), .render, .title("pwd:/tmp")],
            "render burst must collapse into one delivery; non-renders never coalesce"
        )

        // After the reset ran, a fresh render starts its own hop again.
        box.deliver(.render)
        try await Task.sleep(nanoseconds: 100_000_000)
        let renderCalls = recorder.payloads.filter { payload -> Bool in
            if case .render = payload {
                return true
            } else {
                return false
            }
        }
        XCTAssertEqual(renderCalls.count, 2, "post-reset render must get its own hop")
    }

    @MainActor
    func testRenderBetweenTitlesIsDeliveredOnceAndInOrder() async throws {
        let box = SurfaceCallbackBox(terminalID: TerminalID(), generation: .initial)
        let recorder = PayloadRecorder()
        box.setSink { event in
            recorder.append(event.payload)
        }

        box.deliver(.title("t1"))
        box.deliver(.render)
        box.deliver(.title("t2"))
        box.deliver(.render) // folds into the pending render hop

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            recorder.payloads,
            [.title("t1"), .render, .title("t2")],
            "interleaved render must survive exactly once, in delivery order"
        )
    }

    // MARK: T3 — total order across background-queued and on-main deliveries

    /// Event A is delivered from a background thread and lands as an async
    /// hop on the serial main queue; event B arrives while already ON the
    /// main thread BEFORE A's hop has run. The synchronous fast path must
    /// be suppressed (the box has a hop pending on the main queue) so B
    /// queues behind A instead of overtaking it. Before the fix this test
    /// read [B, A] because performOnMain ran B inline.
    @MainActor
    func testOnMainDeliveryQueuesBehindEarlierBackgroundPayload() async {
        let box = SurfaceCallbackBox(terminalID: TerminalID(), generation: .initial)
        let recorder = PayloadRecorder()
        let delivered = expectation(description: "both events delivered")
        delivered.expectedFulfillmentCount = 2
        box.setSink { event in
            recorder.append(event.payload)
            delivered.fulfill()
        }

        // Enqueue A's hop from a background thread, then BLOCK the main
        // thread (not the actor) until the enqueue is done. A blocked main
        // thread cannot drain the queue, so A is provably still pending
        // when the on-main delivery below happens — no timing race.
        let enqueued = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.deliver(.title("A"))
            enqueued.signal()
        }
        XCTAssertEqual(
            enqueued.wait(timeout: .now() + 2), .success,
            "background delivery must enqueue its main-queue hop"
        )

        box.deliver(.title("B"))

        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(
            recorder.payloads,
            [.title("A"), .title("B")],
            "an on-main delivery must not overtake an earlier background payload"
        )
    }

    // MARK: R27-TK1 — leaked-userdata contract: trampolines after drop-without-shutdown

    /// The retained runtime box is deliberately NEVER released (classic
    /// C-userdata pattern): a native trampoline firing after the router was
    /// dropped WITHOUT shutdown() must resolve valid memory — the box's weak
    /// slot observes the dealloc and every trampoline degrades to a no-op.
    /// Restoring the pre-fix release-in-deinit makes this test read freed
    /// memory (use-after-free): it is the safety net for the leak decision.
    func testTrampolinesThroughRetainedBoxAfterRouterDropWithoutShutdownResolveToNilAndDoNotCrash() throws {
        var router: GhosttyCallbackRouter? = GhosttyCallbackRouter()
        let box = try XCTUnwrap(router?.retainedBox)
        // Positive identity control WHILE ALIVE: the box resolves its owner.
        XCTAssertNotNil(
            Unmanaged<GhosttyCallbackRouter.RuntimeBox>.fromOpaque(box).takeUnretainedValue().router,
            "a live router must resolve from its retained box"
        )

        // Drop WITHOUT shutdown — the real-world shape the retainedBox
        // comment calls out (owners/tests that never call shutdown()).
        router = nil

        // Drive every runtime-level C entry point straight through the
        // leaked userdata: memory-safe no-ops with the weak slot nilled.
        GhosttyCallbackRouter.handleWakeup(userdata: box)
        GhosttyCallbackRouter.handleCloseSurface(processAlive: true, userdata: box)
        XCTAssertFalse(
            GhosttyCallbackRouter.handleReadClipboard(clipboard: 0, userdata: box),
            "a nil router denies OSC52 reads by default"
        )
        GhosttyCallbackRouter.handleEvent(event: nil, userdata: box)

        // The box is still valid memory whose weak slot observed the dealloc.
        XCTAssertNil(
            Unmanaged<GhosttyCallbackRouter.RuntimeBox>.fromOpaque(box).takeUnretainedValue().router,
            "the weak slot must observe the router dealloc through the leaked box"
        )
    }
}

/// Lock-guarded payload sink recorder (closures are @Sendable; strict
/// concurrency forbids capturing mutable locals).
private final class PayloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [GhosttyEvent.Payload] = []

    func append(_ payload: GhosttyEvent.Payload) {
        lock.lock()
        received.append(payload)
        lock.unlock()
    }

    var payloads: [GhosttyEvent.Payload] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

@testable import AgentCore
import XCTest

// §4.8: observation-envelope ordering (§3.6) — duplicates, stale generations,
// stale output revisions, sequence gaps, observedAt distrust.

@MainActor
final class RuntimeOrderingTests: XCTestCase {
    private let agent = AgentID()

    func testStaleGenerationObservationIsDiscarded() {
        var ledger = EvidenceLedger()
        ledger.generationChanged(SurfaceGeneration(rawValue: 3))

        let stale = screenEvidence(
            agent: agent,
            lifecycle: .working,
            receivedAt: instant(10),
            generation: SurfaceGeneration(rawValue: 2)
        )
        XCTAssertEqual(ledger.accept(stale), .discardedStaleGeneration)
        XCTAssertNil(ledger.screenObservation)
    }

    func testNewerGenerationResetsAllObservations() {
        var ledger = EvidenceLedger()
        ledger.accept(screenEvidence(agent: agent, lifecycle: .working, receivedAt: instant(10)))
        ledger.accept(integrationEvidence(agent: agent, lifecycle: .idle, sequence: 4, receivedAt: instant(11)))

        ledger.generationChanged(SurfaceGeneration(rawValue: 5))

        XCTAssertNil(ledger.screenObservation)
        XCTAssertTrue(ledger.integrationObservations.isEmpty, "restart discards every old observation")
        XCTAssertTrue(ledger.diagnostics.isEmpty)
    }

    func testDuplicateSequenceIsAcknowledgedWithoutStateChange() {
        var ledger = EvidenceLedger()
        let first = integrationEvidence(agent: agent, lifecycle: .working, sequence: 7, receivedAt: instant(10))
        XCTAssertEqual(ledger.accept(first), .accepted)

        let duplicate = integrationEvidence(agent: agent, lifecycle: .working, sequence: 7, receivedAt: instant(20))
        XCTAssertEqual(ledger.accept(duplicate), .acknowledgedDuplicate)

        // Stale (lower) sequence is also a duplicate.
        let stale = integrationEvidence(agent: agent, lifecycle: .idle, sequence: 6, receivedAt: instant(30))
        XCTAssertEqual(ledger.accept(stale), .acknowledgedDuplicate)

        // The stored observation is still the FIRST accepted one.
        guard case .integrationLifecycle(.working)? = ledger.integrationObservations["hook:test"]?.payload else {
            return XCTFail("duplicate must not overwrite the accepted observation")
        }
    }

    func testSequenceGapIsAcceptedButLogged() {
        var ledger = EvidenceLedger()
        _ = ledger.accept(integrationEvidence(agent: agent, lifecycle: .working, sequence: 1, receivedAt: instant(10)))

        let gapped = integrationEvidence(agent: agent, lifecycle: .idle, sequence: 5, receivedAt: instant(20))
        XCTAssertEqual(ledger.accept(gapped), .acceptedWithSequenceGap(expectedNext: 2))
        XCTAssertEqual(ledger.lastAcceptedSequences["hook:test"], 5)

        XCTAssertTrue(ledger.diagnostics.contains {
            $0.message.contains("gap") && $0.message.contains("expected 2") && $0.message.contains("received 5")
        })
    }

    func testLateScreenResultWithOldOutputRevisionIsDropped() {
        var ledger = EvidenceLedger()

        // Current revision floor moves to 9 via a fresh render event.
        ledger.outputRevisionChanged(9)

        // An in-flight evaluation that started at revision 4 arrives late.
        let late = screenEvidence(
            agent: agent,
            lifecycle: .working,
            receivedAt: instant(50),
            outputRevision: 4
        )
        XCTAssertEqual(ledger.accept(late), .discardedStaleOutputRevision)
        XCTAssertNil(ledger.screenObservation)
    }

    func testCurrentRevisionScreenResultIsAcceptedAndRaisesFloor() throws {
        var ledger = EvidenceLedger()
        ledger.outputRevisionChanged(9)

        let current = screenEvidence(agent: agent, lifecycle: .working, receivedAt: instant(50), outputRevision: 9)
        XCTAssertEqual(ledger.accept(current), .accepted)
        XCTAssertNotNil(try XCTUnwrap(ledger.screenObservation))

        // A subsequent result from an older revision is now stale.
        let older = screenEvidence(agent: agent, lifecycle: .idle, receivedAt: instant(60), outputRevision: 8)
        XCTAssertEqual(ledger.accept(older), .discardedStaleOutputRevision)
    }

    func testObservedAtNeverInfluencesAcceptanceOrder() {
        var ledger = EvidenceLedger()
        // seq 2 carries an absurd external timestamp but arrives second —
        // acceptance follows seq/receipt, not observedAt.
        _ = ledger.accept(integrationEvidence(
            agent: agent,
            lifecycle: .working,
            sequence: 1,
            receivedAt: instant(10),
            observedAt: instant(1000)
        ))
        let decision = ledger.accept(integrationEvidence(
            agent: agent,
            lifecycle: .idle,
            sequence: 2,
            receivedAt: instant(20),
            observedAt: instant(-500)
        ))

        XCTAssertEqual(decision, .accepted)
        guard case .integrationLifecycle(.idle)? = ledger.integrationObservations["hook:test"]?.payload else {
            return XCTFail("latest sequence must be stored")
        }
    }

    func testProcessObservationsAlwaysReplace() {
        var ledger = EvidenceLedger()
        _ = ledger.accept(processEvidence(agent: agent, receivedAt: instant(10)))
        let decision = ledger.accept(processEvidence(agent: agent, receivedAt: instant(20)))
        XCTAssertEqual(decision, .accepted)
        XCTAssertNotNil(ledger.processObservation)
    }

    // MARK: R21-O1 — sessionReference commits only on acceptance, duplicates

    // never roll it back, diagnostics are a bounded ring of the newest 64

    private func identityEvidence(
        _ reference: SessionReference,
        sequence: UInt64,
        receivedAt: MonotonicInstant
    ) -> Evidence {
        Evidence(
            envelope: makeEnvelope(
                agent: agent,
                sourceKind: .integration,
                sourceID: "hook:test",
                sequence: sequence,
                receivedAt: receivedAt
            ),
            payload: .sessionIdentity(reference)
        )
    }

    func testSessionIdentityCommitsOnlyOnAcceptAndDuplicatesDoNotRollItBackPlusRingCap() {
        var ledger = EvidenceLedger()
        let refA = SessionReference(agentKind: .claudeCode, opaquePayload: "ref-a")
        let refB = SessionReference(agentKind: .claudeCode, opaquePayload: "ref-b")
        let refC = SessionReference(agentKind: .claudeCode, opaquePayload: "ref-c")

        // Commit law: identity lands only when the sequence gate passes.
        XCTAssertEqual(
            ledger.accept(identityEvidence(refA, sequence: 1, receivedAt: instant(10))),
            .accepted
        )
        XCTAssertEqual(ledger.sessionReference, refA)

        // Gap (seq 3 over watermark 1): accepted but logged.
        XCTAssertEqual(
            ledger.accept(integrationEvidence(agent: agent, lifecycle: .working, sequence: 3, receivedAt: instant(20))),
            .acceptedWithSequenceGap(expectedNext: 2)
        )

        // Stale duplicate identity (seq 2 ≤ watermark): acknowledged WITHOUT
        // rolling sessionReference back to the replayed frame.
        XCTAssertEqual(
            ledger.accept(identityEvidence(refB, sequence: 2, receivedAt: instant(30))),
            .acknowledgedDuplicate
        )
        XCTAssertEqual(ledger.sessionReference, refA, "a stale duplicate must not roll sessionReference back")

        // A FRESH identity advances the reference on acceptance only.
        XCTAssertEqual(
            ledger.accept(identityEvidence(refC, sequence: 4, receivedAt: instant(40))),
            .accepted
        )
        XCTAssertEqual(ledger.sessionReference, refC)

        // Ring cap: 70 more accepted jumps each log a gap diagnostic → 71
        // diagnostics overall (seq-3 gap + 70 loop gaps), capped to the
        // newest 64. The seven OLDEST are evicted FIFO, so the surviving
        // first entry is the 7th loop gap ("expected 35, received 39") and
        // the last is the newest ("expected 350, received 354").
        var watermark: UInt64 = 4
        for index in 0 ..< 70 {
            let received = watermark + 5
            let loopRef = SessionReference(agentKind: .claudeCode, opaquePayload: "loop-\(index)")
            XCTAssertEqual(
                ledger.accept(identityEvidence(loopRef, sequence: received, receivedAt: instant(Int64(100 + index)))),
                .acceptedWithSequenceGap(expectedNext: watermark + 1),
                "each +5 jump must be accepted but logged"
            )
            watermark = received
        }
        XCTAssertEqual(ledger.diagnostics.count, 64, "diagnostics ring stays capped at 64")
        XCTAssertTrue(
            ledger.diagnostics.first?.message.contains("expected 35, received 39") == true,
            "oldest survivor should be the 7th loop gap, got \(ledger.diagnostics.first?.message ?? "nil")"
        )
        XCTAssertTrue(
            ledger.diagnostics.last?.message.contains("received 354") == true,
            "newest diagnostic must be retained, got \(ledger.diagnostics.last?.message ?? "nil")"
        )

        // Expiry removes the observation AND appends its diagnostic; the
        // ring stays capped and eviction keeps advancing FIFO.
        ledger.expireIntegration(sourceID: "hook:test", at: instant(500))
        XCTAssertNil(ledger.integrationObservations["hook:test"])
        XCTAssertEqual(ledger.diagnostics.count, 64)
        XCTAssertEqual(ledger.diagnostics.last?.message, "integration hook:test expired")
        XCTAssertTrue(
            ledger.diagnostics.first?.message.contains("expected 40, received 44") == true,
            "the previous oldest survivor was evicted FIFO by the expiry entry"
        )
    }
}

// MARK: - Round 25 S1 — FakeClock's own virtual-time contract

// The 229-test corpus consumes FakeClock everywhere but nothing pins ITS law:
// elapsed-deadline fast path, register-vs-advance race closure, (deadline,
// insertion-sequence) bucketing, catch-up exactly-once resume, negative clamp.
// Deliberately NOT @MainActor — sleeper tasks must be able to suspend on a
// non-main executor (Scripts/TEST-STALL-FIX.md arm-before-advance discipline).

/// Lock-based per-sleeper resume counter (the only shared mutable state).
private final class ResumeCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func bump(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key] ?? 0
    }
}

/// Arms a sleeper that REALLY suspends, and reports when it has started.
/// XCTestCase carries @MainActor isolation in current SDKs and a plain
/// `Task { }` inherits it even through a helper — the sleeper then can never
/// run (let alone resume) while the test body blocks. A DETACHED spawn is the
/// only way to guarantee the sleeper lives on the global executor and actually
/// parks inside FakeClock (TEST-STALL-FIX arm-before-advance rule). The task
/// bumps "<key>#armed" right before parking so tests can event-driven-wait for
/// registration instead of guessing with settle sleeps.
/// Callers MUST wait for `clock.parkedSleeperCount` to reach the armed count
/// before advancing.
private func armSleeper(
    _ clock: FakeClock,
    for duration: Duration,
    key: String,
    counts: ResumeCounterBox
) -> Task<Void, Never> {
    Task.detached {
        counts.bump("\(key)#armed")
        await clock.sleep(for: duration)
        counts.bump(key)
    }
}

final class FakeClockContractTests: XCTestCase {
    /// Event-driven bounded poll; NEVER a fixed settle sleep as synchronization.
    private func eventually(timeout: TimeInterval = 5, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("condition not reached within \(timeout)s")
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    /// (a) sleep on an already-elapsed deadline returns synchronously via the
    /// fast path — the guarantee every virtual-time suite relies on.
    func testSleepOnAlreadyElapsedDeadlineReturnsImmediatelyWithoutSuspending() async {
        let clock = FakeClock(startingAt: .seconds(3))
        let before = clock.now
        await clock.sleep(until: before - .seconds(1))
        await clock.sleep(for: .zero)
        XCTAssertEqual(clock.now, before, "elapsed-deadline sleeps never move time")

        // Auxiliary MonotonicInstant +/- Duration arithmetic rides along.
        XCTAssertEqual(before + .seconds(2), MonotonicInstant(nanosecondsSinceEpoch: 5_000_000_000))
        XCTAssertEqual(before - .seconds(3), .zero)
        XCTAssertEqual((before + .seconds(2)) - before, .seconds(2))
    }

    /// (b) a sleeper whose deadline has ALREADY passed when it registers
    /// resumes immediately — clamp-to-zero lands on the elapsed-deadline fast
    /// path and the register-race false path alike. No lost wakeup, no hang,
    /// no further advance needed.
    func testSleeperRegisteredAfterDeadlinePassedResumesImmediatelyWithoutHanging() async {
        let clock = FakeClock()
        clock.advance(by: .seconds(10))
        let afterAdvance = clock.now

        let sleeper = armSleeper(
            clock, for: .seconds(-5), key: "sleeper", counts: ResumeCounterBox()
        )
        await sleeper.value // would hang forever on a lost wakeup
        XCTAssertEqual(clock.now, afterAdvance, "no further advance may be needed")
    }

    /// (c, review-amended) one advance wakes exactly the `deadline <= target`
    /// bucket. Per-sleeper COUNTS only — cross-task wake order is scheduler-
    /// dependent and asserted nowhere. Arm-before-advance throughout.
    func testSingleAdvanceWakesExactlyTheDueDeadlineBucket() async {
        let clock = FakeClock()
        let counts = ResumeCounterBox()

        // a2@5s inserted FIRST, then a1@5s, then b@9s (insertion sequence).
        let a2 = armSleeper(clock, for: .seconds(5), key: "a2", counts: counts)
        let a1 = armSleeper(clock, for: .seconds(5), key: "a1", counts: counts)
        let b = armSleeper(clock, for: .seconds(9), key: "b", counts: counts)

        // Deterministic arm-before-advance: every sleeper has started and is
        // (at worst) a few non-suspending instructions from parking.
        eventually {
            counts.count("a1#armed") == 1 && counts.count("a2#armed") == 1
                && counts.count("b#armed") == 1
        }
        // A late-starting detached sleeper would compute its deadline from
        // post-advance time (now + duration) and park past the horizon
        // forever — arm-before-advance must be verified, not assumed.
        eventually { clock.parkedSleeperCount == 3 }

        clock.advance(by: .seconds(5))
        eventually { counts.count("a1") == 1 && counts.count("a2") == 1 }
        XCTAssertEqual(counts.count("b"), 0, "the 9s bucket must stay asleep")

        clock.advance(by: .seconds(4)) // cumulative 9s — only b is due now
        eventually { counts.count("b") == 1 }
        XCTAssertEqual(counts.count("a1"), 1, "already-resumed sleepers never re-fire")
        XCTAssertEqual(counts.count("a2"), 1)

        await a1.value; await a2.value; await b.value
    }

    /// (d) one catch-up advance past N deadlines resumes each sleeper exactly
    /// once — no double-fire, no dropped sleeper.
    func testCatchUpAdvancePastMultipleDeadlinesResumesEachExactlyOnce() async {
        let clock = FakeClock()
        let counts = ResumeCounterBox()

        let s1 = armSleeper(clock, for: .seconds(1), key: "s1", counts: counts)
        let s2 = armSleeper(clock, for: .seconds(2), key: "s2", counts: counts)
        let s3 = armSleeper(clock, for: .seconds(3), key: "s3", counts: counts)

        eventually {
            counts.count("s1#armed") == 1 && counts.count("s2#armed") == 1
                && counts.count("s3#armed") == 1
        }
        // A late-starting detached sleeper would compute its deadline from
        // post-advance time (now + duration) and park past the horizon
        // forever — arm-before-advance must be verified, not assumed.
        eventually { clock.parkedSleeperCount == 3 }

        clock.advance(by: .seconds(10))
        eventually {
            counts.count("s1") == 1 && counts.count("s2") == 1 && counts.count("s3") == 1
        }

        await s1.value; await s2.value; await s3.value
        XCTAssertEqual(clock.currentTime, .seconds(10))
    }

    /// (e) negative durations clamp to zero (`max(.zero, duration)`), return
    /// immediately, and leave `now` unmoved.
    func testNegativeSleepDurationClampsToZeroAndMovesNothing() async {
        let clock = FakeClock(startingAt: .milliseconds(250))
        let before = clock.now
        await clock.sleep(for: .nanoseconds(-7))
        XCTAssertEqual(clock.now, before, "negative sleep must not move virtual time")

        // A subsequent real advance still works normally after the clamp.
        clock.advance(by: .seconds(1))
        XCTAssertEqual(clock.currentTime, .seconds(1.25))
        XCTAssertEqual(clock.currentInstant().nanosecondsSinceEpoch, 1_250_000_000)
    }

    /// (f, round 26) parkedSleeperCount lifecycle: 0 at rest on a fresh/idle
    /// clock; counts registered-unfired sleepers during the arm-before-advance
    /// window; decrements as staged advances resume sleepers in deadline
    /// order; fast-path sleeps (already-elapsed deadline and the negative-
    /// duration clamp) never register. Every arm-before-advance predicate in
    /// this file trusts this counter.
    func testParkedSleeperCountTracksRegistrationWakeAndFastPathLifecycle() async {
        let clock = FakeClock(startingAt: .zero)
        XCTAssertEqual(clock.parkedSleeperCount, 0, "a fresh clock parks nothing")

        // Fast path: fully-elapsed and clamped-negative sleeps never park.
        await clock.sleep(for: .zero)
        await clock.sleep(for: .seconds(-5))
        XCTAssertEqual(clock.parkedSleeperCount, 0, "fast-path sleeps never register")

        // Arm window: both detached sleepers registered but not yet due.
        let counts = ResumeCounterBox()
        let task1 = armSleeper(clock, for: .seconds(1), key: "f1", counts: counts)
        let task2 = armSleeper(clock, for: .seconds(3), key: "f2", counts: counts)
        eventually { clock.parkedSleeperCount == 2 }

        clock.advance(by: .seconds(2)) // past the earlier deadline only
        await task1.value
        XCTAssertEqual(clock.parkedSleeperCount, 1,
                       "only the later-deadline sleeper stays parked after the first advance")

        clock.advance(by: .seconds(2)) // cumulative 4s — the second is due now
        await task2.value
        XCTAssertEqual(clock.parkedSleeperCount, 0,
                       "every resumed sleeper leaves the queue")
    }
}

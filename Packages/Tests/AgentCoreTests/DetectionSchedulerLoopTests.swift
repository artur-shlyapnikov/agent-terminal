@testable import AgentCore
import Foundation
import XCTest

// Round 7: DetectionScheduler idle-park run-loop laws (§3.7).
//
// The scheduler is an actor whose run loop sleeps through the injected
// FakeClock. All timing is virtual: mutations are arranged BEFORE clock
// advances (the sleeper treats already-elapsed deadlines as immediate
// return — Scripts/TEST-STALL-FIX.md), `Task.yield()` sweeps let the actor
// task reach its next suspension, and only bounded `eventually` polls are
// used — never wall-clock sleeps.

final class DetectionSchedulerLoopTests: XCTestCase {
    /// Thread-safe tick recorder keyed by terminal.
    private final class TickBox: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        private var perTerminal: [TerminalID: Int] = [:]

        func record(_ t: TerminalID) {
            lock.withLock {
                total += 1
                perTerminal[t, default: 0] += 1
            }
        }

        var tickCount: Int {
            lock.withLock { total }
        }

        func tickCount(for t: TerminalID) -> Int {
            lock.withLock { perTerminal[t] ?? 0 }
        }
    }

    private func makeScheduler() -> (DetectionScheduler, FakeClock, TerminalID, TickBox) {
        let clock = FakeClock()
        let box = TickBox()
        let scheduler = DetectionScheduler(clock: clock)
        return (scheduler, clock, TerminalID(), box)
    }

    /// Gives the scheduler's run-loop task time to reach its next suspension
    /// point (park or clock sleep) after a mutation or clock advance.
    private func sweep(_ rounds: Int = 25) async {
        for _ in 0 ..< rounds {
            await Task.yield()
        }
    }

    // MARK: A1 — parked silence + debounce coalescing

    func testParkedLoopIsSilentWhileNothingIsDueAndDebounceCoalescesRevisions() async {
        let (scheduler, clock, terminal, box) = makeScheduler()
        await scheduler.setHandler { box.record($0) }

        // Stopped agents have no cadence (Cadence.interval == nil): with no
        // pending debounce either, the loop must PARK, not spin or fire.
        await scheduler.lifecycleChanged(
            terminalID: terminal, lifecycle: .stopped(.completed), isVisible: true
        )
        await sweep()

        // Virtual time passing alone must never produce an evaluation while
        // parked (detection is off for a stopped agent).
        clock.advance(by: .seconds(30))
        await sweep()
        XCTAssertEqual(box.tickCount, 0, "parked loop must stay silent with nothing due")

        // Two revisions inside one debounce window collapse to ONE
        // evaluation: the single pendingDebounce slot is overwritten.
        await scheduler.outputRevisionChanged(terminalID: terminal)
        await scheduler.outputRevisionChanged(terminalID: terminal)
        await sweep()

        clock.advance(by: .milliseconds(149))
        await sweep()
        XCTAssertEqual(box.tickCount, 0, "debounce has not elapsed yet")

        clock.advance(by: .milliseconds(1))
        await eventually("debounced evaluation") { box.tickCount == 1 }

        // The consumed slot does not re-fire, and a stopped agent never
        // gains a cadence tick.
        clock.advance(by: .seconds(5))
        await sweep()
        XCTAssertEqual(box.tickCount, 1, "exactly one coalesced evaluation")
    }

    // MARK: A2 — one-quantum pickup of an earlier-due schedule

    func testEarlierDueMidSleepIsPickedUpWithinOneQuantum() async {
        let (scheduler, clock, a, box) = makeScheduler()
        let b = TerminalID()
        await scheduler.setHandler { box.record($0) }

        // Idle arms a 2 s cadence tick (idleHz = 0.5); the loop starts
        // sleeping toward its first maxSleepQuantum boundary.
        await scheduler.lifecycleChanged(terminalID: a, lifecycle: .idle, isVisible: true)
        await sweep()

        // b's debounce becomes due at +150 ms — far before a's 2000 ms tick.
        await scheduler.outputRevisionChanged(terminalID: b)
        await sweep()

        // Exactly one quantum later b must be served, NOT delayed until the
        // far-future cadence tick.
        clock.advance(by: .milliseconds(250))
        await eventually("b's debounced evaluation within one quantum") {
            box.tickCount(for: b) == 1
        }
        XCTAssertEqual(
            box.tickCount(for: a), 0,
            "b's evaluation must not wait for a's cadence tick"
        )

        // a still fires at its own tick (+2000 ms from arm time).
        clock.advance(by: .milliseconds(1750))
        await eventually("a's cadence tick fires") { box.tickCount(for: a) >= 1 }
    }

    // MARK: A3 — forget terminates the loop; later schedules start fresh

    func testForgetTerminatesTheLoopAndLaterSchedulesStartAFreshLoop() async {
        let (scheduler, clock, terminal, box) = makeScheduler()
        await scheduler.setHandler { box.record($0) }

        // Working + hidden arms a 500 ms hidden cadence…
        await scheduler.lifecycleChanged(terminalID: terminal, lifecycle: .working, isVisible: false)
        // …and forget removes the only schedule, draining the loop.
        await scheduler.forget(terminalID: terminal)
        await sweep()

        // Nothing may fire after the forget — the schedule is gone.
        clock.advance(by: .seconds(60))
        await sweep()
        XCTAssertEqual(box.tickCount, 0, "forget must stop every evaluation")

        // A later mutator must start a FRESH loop even though the old one
        // already exited (a stuck loopStarted flag would keep this dead).
        await scheduler.lifecycleChanged(terminalID: terminal, lifecycle: .idle, isVisible: true)
        clock.advance(by: .seconds(2))
        await eventually("fresh loop serves the new schedule") { box.tickCount >= 1 }
    }

    // MARK: S2 — promptSent without cadence neither spins nor duplicates

    /// `promptSent` before ANY `lifecycleChanged` has `cadenceInterval == nil`
    /// (the `.map` over nil in the mutator), so the immediate evaluation
    /// fires once per call and NO periodic schedule is created; the loop it
    /// starts stays parked afterwards. An overcorrection arming a default
    /// interval would produce phantom periodic evaluations for terminals the
    /// pipeline never lifecycle-classified; a double-fire would duplicate the
    /// immediate handler per mutation.
    func testPromptSentWithoutCadenceDoesNotSpinOrDuplicate() async {
        let (scheduler, clock, terminal, box) = makeScheduler()
        await scheduler.setHandler { box.record($0) }

        // Two back-to-back prompts on a never-classified terminal: each one
        // fires the synchronous handler exactly once.
        await scheduler.promptSent(terminalID: terminal)
        await scheduler.promptSent(terminalID: terminal)
        XCTAssertEqual(box.tickCount, 2, "promptSent fires the handler once per call")

        // No cadence was armed: virtual time alone must stay silent.
        clock.advance(by: .seconds(60))
        await sweep()
        XCTAssertEqual(box.tickCount, 2, "no phantom cadence may exist for an unclassified terminal")

        // Control: the loop is healthy, not wedged — a render debounce still
        // fires exactly once at +150 ms.
        await scheduler.outputRevisionChanged(terminalID: terminal)
        clock.advance(by: .milliseconds(150))
        await eventually("debounced evaluation after promptSent") { box.tickCount >= 3 }
        await sweep()
        XCTAssertEqual(box.tickCount, 3, "exactly one debounced evaluation may fire")
    }

    // MARK: Round 23 — 88a516f park-path laws (LW1/SNAP1/CAD1/PRIO1/PS1)

    /// Order-preserving sibling of TickBox: records the exact delivery
    /// sequence for phase-ordering assertions (SNAP1).
    private final class SequenceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [TerminalID] = []
        func record(_ t: TerminalID) {
            lock.withLock { hits.append(t) }
        }

        var recorded: [TerminalID] {
            lock.withLock { hits }
        }
    }

    // MARK: LW1 — lost-wakeup re-check across repeated park cycles

    /// LAW-1: an evaluation armed by ANY mutator is delivered on virtual-time
    /// passage alone, whether the mutator lands before or after `idleWake`
    /// installation — the `awaitScheduleChange` re-check makes the
    /// park-transition window loss-free. Six park→mutate→advance→fire cycles
    /// alternate the two arming mutators; `forget` at each cycle end folds in
    /// the forget/parked-loop interplay. No second mutation is ever required.
    func testMutationLandingDuringParkTransitionStillYieldsEvaluationAcrossRepeatedParkCycles() async {
        let (scheduler, clock, parked, box) = makeScheduler()
        let worker = TerminalID()
        let seq = SequenceBox()
        await scheduler.setHandler { box.record($0); seq.record($0) }

        // Park the loop: `.stopped` classifies nil ⇒ all-nil state ⇒ park.
        await scheduler.lifecycleChanged(terminalID: parked, lifecycle: .stopped(.completed), isVisible: true)
        await sweep()

        for i in 0 ..< 6 {
            if i % 2 == 0 {
                // Even cycles: debounce arm at now + 150 ms.
                await scheduler.outputRevisionChanged(terminalID: worker)
                await sweep()
                clock.advance(by: .milliseconds(150))
            } else {
                // Odd cycles: cadence arm, hidden waitingForInput ⇒ 1 s tick.
                await scheduler.lifecycleChanged(terminalID: worker, lifecycle: waitingPhase(), isVisible: false)
                await sweep()
                clock.advance(by: .seconds(1))
            }
            await eventually("cycle \(i): evaluation delivered by virtual time alone") {
                box.tickCount(for: worker) == i + 1
            }

            // End every cycle: remove the armed slot while `parked` keeps the
            // loop alive-but-parking; the slot must really be gone (no spin).
            await scheduler.forget(terminalID: worker)
            await sweep()
            clock.advance(by: .seconds(30))
            await sweep()
            XCTAssertEqual(box.tickCount(for: worker), i + 1, "cycle \(i): forgotten slot must stay silent")
            XCTAssertEqual(box.tickCount(for: parked), 0, "parked terminal stays silent under churn")
        }

        XCTAssertEqual(box.tickCount, 6, "exactly one evaluation per cycle")
        XCTAssertEqual(seq.recorded.count, 6, "sequence recorder agrees with the tally")
    }

    // MARK: SNAP1 — one fireDue pass: completeness + debounce-before-cadence

    /// LAW-2: a single `fireDue` invocation delivers BOTH due terminals
    /// exactly once, all debounce hits before any cadence hit, independent of
    /// dictionary order; the fired cadence tick re-anchors from the fire
    /// instant and respects the inclusive boundary on its next due instant.
    func testSinglePassDeliversEveryDueTerminalOnceWithDebounceBeforeCadence() async {
        let (scheduler, clock, d, box) = makeScheduler()
        let d2 = TerminalID()
        let c = TerminalID()
        let seq = SequenceBox()
        await scheduler.setHandler { box.record($0); seq.record($0) }

        // Two debounces due t₀+150 ms; hidden-working cadence due t₀+500 ms.
        await scheduler.outputRevisionChanged(terminalID: d)
        await scheduler.outputRevisionChanged(terminalID: d2)
        await scheduler.lifecycleChanged(terminalID: c, lifecycle: .working, isVisible: false)
        await sweep()

        // One jump past both deadlines ⇒ ONE fireDue invocation sees all three.
        clock.advance(by: .milliseconds(500))
        await eventually("both hits delivered") { box.tickCount == 3 }
        await sweep()

        XCTAssertEqual(seq.recorded.last, c, "the cadence hit is delivered last")
        let prefix = Array(seq.recorded.prefix(2))
        XCTAssertTrue(prefix.contains(d) && prefix.contains(d2), "both debounce hits precede any cadence hit")
        XCTAssertEqual(box.tickCount(for: d), 1, "each terminal exactly once")
        XCTAssertEqual(box.tickCount(for: d2), 1, "each terminal exactly once")
        XCTAssertEqual(box.tickCount(for: c), 1, "cadence hit exactly once")

        // Supersession silence: re-anchored to fire-instant + 500 ms (t₀+1000).
        clock.advance(by: .milliseconds(400))
        await sweep()
        XCTAssertEqual(box.tickCount(for: c), 1, "re-anchored tick must not refire early")
        clock.advance(by: .milliseconds(100))
        await eventually("second cadence tick at exact interval") { box.tickCount(for: c) == 2 }
    }

    // MARK: CAD1 — missed cadence ticks collapse into one re-anchored fire

    /// Cadence re-anchor arithmetic: a fired tick re-anchors to
    /// `fireInstant + interval`; missed intervals never backfill; boundaries
    /// are inclusive. A large frozen-clock advance then catches up with
    /// exactly one tick per loop pass — no spin, no suppression.
    func testLargeVirtualAdvanceCollapsesMissedCadenceTicksIntoASingleReAnchoredFire() async {
        let (scheduler, clock, w, box) = makeScheduler()
        await scheduler.setHandler { box.record($0) }
        await scheduler.lifecycleChanged(terminalID: w, lifecycle: .working, isVisible: true) // 4 Hz ⇒ 250 ms
        await sweep()

        // Four intervals in one jump: collapse to a single fire.
        clock.advance(by: .milliseconds(1000))
        await eventually("collapsed fire") { box.tickCount(for: w) == 1 }
        await sweep()
        XCTAssertEqual(box.tickCount(for: w), 1, "missed ticks must collapse — no backfill")

        // Re-anchored tick lives at t₀+1250: not yet due at t₀+1249…
        clock.advance(by: .milliseconds(249))
        await sweep()
        XCTAssertEqual(box.tickCount(for: w), 1, "re-anchored tick not yet due")
        // …and inclusive at t₀+1250.
        clock.advance(by: .milliseconds(1))
        await eventually("second tick at exact interval") { box.tickCount(for: w) == 2 }

        // Catch-up: a single advance jumps straight to its target
        // (RuntimeClock.advanceTo sets `now` first, THEN resumes due sleepers),
        // so the loop receives exactly ONE wakeup with now == t₀+11250. The
        // entire missed-tick backlog collapses into that one fire, which
        // re-anchors to now + interval — strictly future, so the loop goes
        // quiet again. No backfill storm, no spin.
        clock.advance(by: .seconds(10))
        await eventually("backlog collapses into a single fire") { box.tickCount(for: w) == 3 }
        await sweep()
        XCTAssertEqual(box.tickCount(for: w), 3, "quiescent: no further fires without clock movement")
    }

    // MARK: PRIO1 — both-slots-due fires once per pass; stale tick served next

    /// Else-if priority: a state due on BOTH pendingDebounce and
    /// nextCadenceTick contributes exactly ONE hit to the pass (debounce
    /// wins); the stale tick survives unconsumed and is served by the very
    /// next pass, re-anchoring from THAT pass's fire instant.
    func testTerminalDueOnBothSlotsFiresOncePerPassAndServesStaleTickNextPass() async {
        let (scheduler, clock, w, box) = makeScheduler()
        await scheduler.setHandler { box.record($0) }
        await scheduler.lifecycleChanged(terminalID: w, lifecycle: .working, isVisible: false) // 500 ms tick
        await sweep()

        // Land mid-cadence-window so both slots straddle one fire instant.
        clock.advance(by: .milliseconds(400))
        await sweep()
        await scheduler.outputRevisionChanged(terminalID: w) // debounce due t₀+550
        clock.advance(by: .milliseconds(150)) // now == t₀+550
        // Both evaluations delivered: the collision pass fires the DEBOUNCE
        // hit only (else-if), leaving tick 500 unconsumed; the follow-through
        // pass then serves the stale tick and re-anchors from ITS OWN fire
        // instant. The inter-pass boundary itself is not externally
        // observable under FakeClock — the follow-through needs no clock
        // movement (elapsed-deadline fast path) and both passes complete
        // before any poll runs — so delivery of both, not a transient ==1,
        // is what is pinned here; the one-hit-per-pass selection itself is
        // structural (:153-159) with this two-delivery timeline as its
        // observable consequence.
        await eventually("debounce hit plus stale-tick follow-through") {
            box.tickCount(for: w) == 2
        }

        // Follow-through re-anchored the tick to t₀+550+500 = t₀+1050 on the
        // NEW anchor: still silent at t₀+1049, inclusive boundary at t₀+1050.
        clock.advance(by: .milliseconds(499))
        await sweep()
        XCTAssertEqual(box.tickCount(for: w), 2, "re-anchored tick not yet due")
        clock.advance(by: .milliseconds(1))
        await eventually("third tick proves the inclusive boundary on the re-anchored tick") {
            box.tickCount(for: w) == 3
        }
    }

    // MARK: PS1 — promptSent on a cadenced terminal: immediate once + supersede

    /// `promptSent` WITH an armed cadence: synchronous immediate evaluation
    /// exactly once per call, then the re-anchor OVERWRITES the pending tick —
    /// no double-fire at the stale instant, periodic resumption measured from
    /// the prompt.
    func testPromptSentOnCadencedTerminalFiresImmediatelyOnceAndSupersedesThePendingTick() async {
        let (scheduler, clock, w, box) = makeScheduler()
        await scheduler.setHandler { box.record($0) }
        await scheduler.lifecycleChanged(terminalID: w, lifecycle: .idle, isVisible: true) // 2 s tick
        await sweep()
        clock.advance(by: .milliseconds(1500))
        await sweep()
        XCTAssertEqual(box.tickCount(for: w), 0, "no fire before either the stale tick or the prompt")

        // Act at t₀+1500: the handler call is synchronous inside the actor.
        await scheduler.promptSent(terminalID: w)
        XCTAssertEqual(box.tickCount(for: w), 1, "promptSent evaluates immediately, exactly once")

        // Old-tick supersession: the STALE instant t₀+2000 stays silent.
        clock.advance(by: .milliseconds(500))
        await sweep()
        XCTAssertEqual(box.tickCount(for: w), 1, "superseded tick must not double-fire")

        // New anchor t₀+1500+2000 = t₀+3500: silent at t₀+3000, fires at 3500.
        clock.advance(by: .seconds(1))
        await sweep()
        XCTAssertEqual(box.tickCount(for: w), 1, "periodic tick measured from the prompt instant")
        clock.advance(by: .milliseconds(500))
        await eventually("periodic tick resumed from prompt instant") { box.tickCount(for: w) == 2 }
    }
}

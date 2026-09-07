import AgentControl
import AgentCore
import XCTest

// Round 6 Suite A2: `HookAuthenticator` integration-release lease law (§3.16).
//
// After `release(sourceID:agentID:)`, later reports from that source are
// rejected even with a valid token and surface generation, the per-source
// sequence watermark is cleared, and release stays scoped to the single
// source (not the agent). The authenticator is an actor — every call is
// awaited.

private func registeredAuth(
    token: String = "t1",
    gen: SurfaceGeneration = .initial
) async -> (HookAuthenticator, AgentID) {
    let auth = HookAuthenticator()
    let agent = AgentID()
    await auth.register(agentID: agent, surfaceGeneration: gen, token: token)
    return (auth, agent)
}

final class HookAuthenticatorReleaseTests: XCTestCase {
    // MARK: A2-1

    func testReleasedSourceRejectsEvenValidTokenAndGeneration() async {
        let (auth, agent) = await registeredAuth()

        // Positive control: an identical report is accepted before release.
        let control = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 5,
            token: "t1"
        )
        XCTAssertEqual(control, .accept(sequence: 5))

        await auth.release(sourceID: "hook:x", agentID: agent)

        // The IDENTICAL report is now rejected as stale despite valid
        // token + generation — a released source must not keep mutating
        // agent state (§3.6 staleness corruption guard).
        let released = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 5,
            token: "t1"
        )
        guard case let .reject(failure) = released else {
            return XCTFail("expected rejection after release, got \(released)")
        }
        XCTAssertEqual(failure.code, .staleGeneration)
        XCTAssertTrue(
            failure.message.contains("already released"),
            "unexpected rejection message: \(failure.message)"
        )

        // Release is per-source, not per-agent: another source of the SAME
        // agent with the same token still flows.
        let otherSource = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:y",
            sequence: 1,
            token: "t1"
        )
        XCTAssertEqual(otherSource, .accept(sequence: 1))
    }

    // MARK: A2-2

    func testReleaseClearsPerSourceSequenceWatermark() async {
        let (auth, agent) = await registeredAuth()

        _ = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 5,
            token: "t1"
        )
        let expectedBefore = await auth.expectedNextSequence(agentID: agent, sourceID: "hook:x")
        XCTAssertEqual(expectedBefore, 6)

        await auth.release(sourceID: "hook:x", agentID: agent)

        // The watermark is gone: post-release duplicates can never be
        // classified against a dead counter.
        let expectedAfter = await auth.expectedNextSequence(agentID: agent, sourceID: "hook:x")
        XCTAssertNil(expectedAfter)
        let hasReleased = await auth.hasReleased(sourceID: "hook:x", agentID: agent)
        XCTAssertTrue(hasReleased)
    }

    // MARK: Round 14 B1

    func testNewGenerationRegistrationRehabilitatesReleasedSource() async {
        let (auth, agent) = await registeredAuth()

        // Positive control: accepted before release.
        let control = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 1,
            token: "t1"
        )
        XCTAssertEqual(control, .accept(sequence: 1))

        await auth.release(sourceID: "hook:x", agentID: agent)
        let releasedBefore = await auth.hasReleased(sourceID: "hook:x", agentID: agent)
        XCTAssertTrue(releasedBefore)

        // A new-generation registration implicitly re-registers the agent's
        // integration sources — the released lease is stale only until then.
        await auth.register(agentID: agent, surfaceGeneration: SurfaceGeneration(rawValue: 1), token: "t2")

        let releasedAfter = await auth.hasReleased(sourceID: "hook:x", agentID: agent)
        XCTAssertFalse(releasedAfter)
        let rehabilitated = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: SurfaceGeneration(rawValue: 1),
            sourceID: "hook:x",
            sequence: 1,
            token: "t2"
        )
        XCTAssertEqual(rehabilitated, .accept(sequence: 1))
    }

    // MARK: Round 14 B2

    func testOwnerlessReleaseStaysRejectedAcrossRegistrations() async {
        let auth = HookAuthenticator()
        let a = AgentID()
        let b = AgentID()
        await auth.register(agentID: a, surfaceGeneration: SurfaceGeneration(rawValue: 1), token: "ta")

        await auth.release(sourceID: "hook:orphan", agentID: nil)

        // Same agent re-registers; an unrelated second agent registers too.
        await auth.register(agentID: a, surfaceGeneration: SurfaceGeneration(rawValue: 2), token: "ta2")
        await auth.register(agentID: b, surfaceGeneration: SurfaceGeneration(rawValue: 1), token: "tb")

        // The orphan set is cleared by NOTHING — visible through every query.
        let forA = await auth.hasReleased(sourceID: "hook:orphan", agentID: a)
        XCTAssertTrue(forA)
        let forB = await auth.hasReleased(sourceID: "hook:orphan", agentID: b)
        XCTAssertTrue(forB)
        let ownerless = await auth.hasReleased(sourceID: "hook:orphan", agentID: nil)
        XCTAssertTrue(ownerless)

        // A validation attempt from ANY agent carrying the orphaned source
        // id rejects as already released.
        let fromA = await auth.validateReport(
            agentID: a,
            surfaceGeneration: SurfaceGeneration(rawValue: 2),
            sourceID: "hook:orphan",
            sequence: 1,
            token: "ta2"
        )
        guard case let .reject(failureA) = fromA else {
            return XCTFail("expected rejection from agent a, got \(fromA)")
        }
        XCTAssertEqual(failureA.code, .staleGeneration)
        XCTAssertTrue(failureA.message.contains("already released"))

        let fromB = await auth.validateReport(
            agentID: b,
            surfaceGeneration: SurfaceGeneration(rawValue: 1),
            sourceID: "hook:orphan",
            sequence: 1,
            token: "tb"
        )
        guard case .reject = fromB else {
            return XCTFail("expected rejection from agent b, got \(fromB)")
        }

        // Positive control: agent a's OTHER source still accepts post-register.
        let otherSource = await auth.validateReport(
            agentID: a,
            surfaceGeneration: SurfaceGeneration(rawValue: 2),
            sourceID: "hook:live",
            sequence: 1,
            token: "ta2"
        )
        XCTAssertEqual(otherSource, .accept(sequence: 1))
    }

    // MARK: Round 15 C1

    func testInvalidationRejectsEveryGenerationUntilReregistration() async {
        let (auth, agent) = await registeredAuth()

        // Positive control: an identical report is accepted before invalidation.
        let control = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 1,
            token: "t1"
        )
        XCTAssertEqual(control, .accept(sequence: 1))

        await auth.invalidate(agentID: agent)
        let registeredAfterInvalidate = await auth.isRegistered(agentID: agent)
        XCTAssertFalse(registeredAfterInvalidate)

        // The ORIGINAL valid credentials are rejected: token possession alone
        // proves nothing once the generation entry is gone — the unregistered
        // guard fires BEFORE the token comparison could produce its different
        // message.
        let invalidated = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 2,
            token: "t1"
        )
        guard case let .reject(failure) = invalidated else {
            return XCTFail("expected rejection after invalidation, got \(invalidated)")
        }
        XCTAssertEqual(failure.code, .unauthorized)
        XCTAssertTrue(
            failure.message.contains("no registered process generation"),
            "unexpected rejection message: \(failure.message)"
        )

        // Rehabilitation: registering the successor generation re-arms
        // reports from the same source under the NEW credentials.
        await auth.register(agentID: agent, surfaceGeneration: SurfaceGeneration(rawValue: 1), token: "t2")
        let registeredAfterRegister = await auth.isRegistered(agentID: agent)
        XCTAssertTrue(registeredAfterRegister)
        let rehabilitated = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: SurfaceGeneration(rawValue: 1),
            sourceID: "hook:x",
            sequence: 1,
            token: "t2"
        )
        XCTAssertEqual(rehabilitated, .accept(sequence: 1))
    }

    // MARK: Round 15 C2

    func testDuplicateSequenceIsAcknowledgedWithoutAdvancingAnything() async {
        let (auth, agent) = await registeredAuth()

        let first = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 5,
            token: "t1"
        )
        XCTAssertEqual(first, .accept(sequence: 5))

        // Resending the accepted sequence ACKS as a duplicate carrying the
        // LAST ACCEPTED value — not a rejection, not a fresh event…
        let resent = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 5,
            token: "t1"
        )
        XCTAssertEqual(resent, .duplicate(lastAcceptedSequence: 5))
        // …and so does any OLDER sequence: the verdict carries the accepted
        // sequence, never the offered one.
        let older = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 4,
            token: "t1"
        )
        XCTAssertEqual(older, .duplicate(lastAcceptedSequence: 5))

        // Both acks left the watermark EXACTLY where it was.
        let expectedAfterDuplicates = await auth.expectedNextSequence(agentID: agent, sourceID: "hook:x")
        XCTAssertEqual(expectedAfterDuplicates, 6)

        // Sequence-nil reports bypass the watermark entirely: repeated nil
        // accepts never move it either.
        for _ in 0 ..< 3 {
            let nilReport = await auth.validateReport(
                agentID: agent,
                surfaceGeneration: .initial,
                sourceID: "hook:x",
                sequence: nil,
                token: "t1"
            )
            XCTAssertEqual(nilReport, .accept(sequence: nil))
        }
        let expectedAfterNilReports = await auth.expectedNextSequence(agentID: agent, sourceID: "hook:x")
        XCTAssertEqual(expectedAfterNilReports, 6)
    }

    // MARK: Round 15 C3

    func testSequenceGapsAreAcceptedAndWatermarksStayPerSource() async {
        let (auth, agent) = await registeredAuth()

        let seed = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 2,
            token: "t1"
        )
        XCTAssertEqual(seed, .accept(sequence: 2))

        // A gap is TOLERATED: accepting 7 jumps the watermark straight to the
        // accepted value (assignment, not high-water-max over offers).
        let jumped = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 7,
            token: "t1"
        )
        XCTAssertEqual(jumped, .accept(sequence: 7))
        for stale: UInt64 in [3, 4, 5, 6] {
            let dup = await auth.validateReport(
                agentID: agent,
                surfaceGeneration: .initial,
                sourceID: "hook:x",
                sequence: stale,
                token: "t1"
            )
            XCTAssertEqual(dup, .duplicate(lastAcceptedSequence: 7), "seq \(stale) should be a duplicate of 7")
        }
        let xExpected = await auth.expectedNextSequence(agentID: agent, sourceID: "hook:x")
        XCTAssertEqual(xExpected, 8)

        // Watermarks are per-(agent, source): a gap on one source never gates
        // another source of the SAME agent.
        let otherSource = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:y",
            sequence: 1,
            token: "t1"
        )
        XCTAssertEqual(otherSource, .accept(sequence: 1))
        // y's traffic never touched x's watermark…
        let xUnmoved = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 7,
            token: "t1"
        )
        XCTAssertEqual(xUnmoved, .duplicate(lastAcceptedSequence: 7))
        // …and y's own watermark advanced independently.
        let yExpected = await auth.expectedNextSequence(agentID: agent, sourceID: "hook:y")
        XCTAssertEqual(yExpected, 2)

        // Per-agent scoping: a second agent's identical source id starts a
        // fresh watermark — no cross-agent bleed.
        let b = AgentID()
        await auth.register(agentID: b, surfaceGeneration: .initial, token: "t1")
        let fromB = await auth.validateReport(
            agentID: b,
            surfaceGeneration: .initial,
            sourceID: "hook:x",
            sequence: 1,
            token: "t1"
        )
        XCTAssertEqual(fromB, .accept(sequence: 1))
    }

    // MARK: R21-H1 — verdict ladder ordering: token mismatch and superseded

    // generation arms, plus the token-before-generation precedence pin

    func testVerdictLadderOrderingTokenMismatchAndSupersededGenerationArms() async {
        let agent = AgentID()

        // Pre-registration arm — distinct from the post-invalidation wording
        // pinned by the invalidation suite.
        let fresh = HookAuthenticator()
        let unregistered = await fresh.validateReport(
            agentID: agent,
            surfaceGeneration: SurfaceGeneration(rawValue: 1),
            sourceID: "hook:x",
            sequence: nil,
            token: "t1"
        )
        guard case let .reject(preReg) = unregistered else {
            return XCTFail("expected rejection before registration, got \(unregistered)")
        }
        XCTAssertEqual(preReg.code, .unauthorized)
        XCTAssertTrue(
            preReg.message.contains("no registered process generation"),
            "unexpected pre-registration message: \(preReg.message)"
        )

        let auth = HookAuthenticator()
        await auth.register(agentID: agent, surfaceGeneration: SurfaceGeneration(rawValue: 1), token: "t1")
        func report(_ gen: SurfaceGeneration, _ token: String) async -> HookAuthenticator.Verdict {
            await auth.validateReport(
                agentID: agent,
                surfaceGeneration: gen,
                sourceID: "hook:ladder",
                sequence: nil,
                token: token
            )
        }

        // Correct token + wrong generation → staleGeneration with the
        // superseded-generation wording.
        let superseded = await report(SurfaceGeneration(rawValue: 2), "t1")
        guard case let .reject(staleGen) = superseded else {
            return XCTFail("expected rejection for a superseded generation, got \(superseded)")
        }
        XCTAssertEqual(staleGen.code, .staleGeneration)
        XCTAssertTrue(
            staleGen.message.contains("superseded surface generation #2"),
            "unexpected superseded-generation message: \(staleGen.message)"
        )

        // Correct generation + wrong token → unauthorized.
        let wrongToken = await report(SurfaceGeneration(rawValue: 1), "WRONG")
        guard case let .reject(tokenMiss) = wrongToken else {
            return XCTFail("expected rejection for a token mismatch, got \(wrongToken)")
        }
        XCTAssertEqual(tokenMiss.code, .unauthorized)
        XCTAssertTrue(
            tokenMiss.message.contains("hook token mismatch"),
            "unexpected token-mismatch message: \(tokenMiss.message)"
        )

        // Precedence pin: token comparison runs BEFORE the generation
        // comparison, so a wrong-token + wrong-generation report is
        // unauthorized — NOT staleGeneration.
        let bothWrong = await report(SurfaceGeneration(rawValue: 9), "WRONG")
        guard case let .reject(precedence) = bothWrong else {
            return XCTFail("expected rejection when token and generation are both wrong, got \(bothWrong)")
        }
        XCTAssertEqual(precedence.code, .unauthorized, "token check must precede the generation check")
        XCTAssertTrue(
            precedence.message.contains("hook token mismatch"),
            "wrong token must not be reported as a generation complaint: \(precedence.message)"
        )

        // Positive control: the ladder is intact end-to-end.
        let accepted = await auth.validateReport(
            agentID: agent,
            surfaceGeneration: SurfaceGeneration(rawValue: 1),
            sourceID: "hook:ladder",
            sequence: 1,
            token: "t1"
        )
        XCTAssertEqual(accepted, .accept(sequence: 1))
    }
}

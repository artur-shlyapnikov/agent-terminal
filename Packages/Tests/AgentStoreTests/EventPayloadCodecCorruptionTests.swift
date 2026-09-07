import AgentCore
@testable import AgentStore
import Foundation
import GRDB
import XCTest

// Corrupt event payloads must surface as errors, never as fabricated
// identities (wave-2 review: decodeCommand minted fresh UUIDs and
// decodeReference invented empty SessionReferences for unparsable rows).

final class EventPayloadCodecCorruptionTests: XCTestCase {
    private func fields(_ pairs: [String: String]) -> Data {
        (try? JSONEncoder().encode(pairs)) ?? Data("{}".utf8)
    }

    func testRoundtripStillWorksForWellFormedPayloads() throws {
        let commandID = CommandID()
        let event = AgentEvent.promptDelivered(commandID: commandID)
        let encoded = EventPayloadCodec.encode(event)
        let decoded = try EventPayloadCodec.decode(kind: encoded.kind, payload: encoded.payload)
        XCTAssertEqual(decoded, event)
    }

    func testUnparsableCommandTokenThrowsInsteadOfMintingUUID() throws {
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "prompt_delivered",
            payload: fields(["command_id": "not-a-uuid"])
        ), "garbage token is corruption, not a new identity")

        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "prompt_delivered",
            payload: fields([:])
        ), "missing token is corruption too")
    }

    func testTurnStartedWithPromptReasonRequiresCommandID() throws {
        // Before the fix this silently fabricated a CommandID for the turn.
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "turn_started",
            payload: fields(["reason": "prompt_delivered"])
        ))
        // And an unparsable one likewise.
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "turn_started",
            payload: fields(["reason": "prompt_delivered", "command_id": "@@@"])
        ))
    }

    func testSessionIdentityCapturedNeverInventsAReference() throws {
        // Missing ref_kind previously degraded to genericShell + empty payload.
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "session_identity_captured",
            payload: fields(["ref_payload": "resume-token", "ref_revision": "3"])
        ))
        // Unknown ref_kind likewise.
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "session_identity_captured",
            payload: fields(["ref_kind": "bogus-kind", "ref_payload": "p", "ref_revision": "3"])
        ))
        // Unparsable revision.
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "session_identity_captured",
            payload: fields(["ref_kind": "claude-code", "ref_payload": "p", "ref_revision": "soon"])
        ))
        // Well-formed input still round-trips.
        let reference = SessionReference(agentKind: .claudeCode, opaquePayload: "resume-token", capturedAtRevision: 7)
        let encoded = EventPayloadCodec.encode(.sessionIdentityCaptured(reference))
        let decoded = try EventPayloadCodec.decode(kind: encoded.kind, payload: encoded.payload)
        XCTAssertEqual(decoded, .sessionIdentityCaptured(reference))
    }

    func testResumeAttemptedRequiresFullReference() throws {
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "resume_attempted",
            payload: fields([:])
        ), "empty reference fabrication is prohibited")

        let reference = SessionReference(agentKind: .genericShell, opaquePayload: "abc", capturedAtRevision: 1)
        let encoded = EventPayloadCodec.encode(.resumeAttempted(reference))
        let decoded = try EventPayloadCodec.decode(kind: encoded.kind, payload: encoded.payload)
        XCTAssertEqual(decoded, .resumeAttempted(reference))
    }

    // MARK: Round 22 (test-design-22): the 6e3a22a no-fabrication branches

    /// 6e3a22a: `turn_started` gained an EXPLICIT `integration_operation`
    /// case (:673) and unknown reason tokens now throw (:674) instead of
    /// fabricating a reason. The adjacent prompt_delivered arm's strictness
    /// is unchanged, and a missing token still throws.
    func testTurnStartedUnknownReasonTokenThrowsAndIntegrationOperationDecodesExplicitly() throws {
        let decoded = try EventPayloadCodec.decode(
            kind: "turn_started",
            payload: fields(["reason": "integration_operation"])
        )
        XCTAssertEqual(decoded, .turnStarted(reason: .integrationOperation))

        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "turn_started",
            payload: fields(["reason": "wrking"])
        ), "an unknown reason token is corruption, not spontaneous work")

        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "turn_started",
            payload: fields(["reason": "prompt_delivered", "command_id": "not-a-uuid"])
        ), "the adjacent arm must stay strict")

        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "turn_started",
            payload: fields([:])
        ), "a missing token is corruption too")
    }

    /// 6e3a22a: `integration_sequence_gap` requires PARSABLE `expected` AND
    /// `received` tokens (:698-704) — missing/unparsable previously
    /// fabricated 0/0 gap telemetry.
    func testSequenceGapRequiresParsableExpectedAndReceivedTokens() throws {
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "integration_sequence_gap", payload: fields([:])
        ), "missing both tokens must throw")
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "integration_sequence_gap", payload: fields(["expected": "3"])
        ), "missing received must throw")
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "integration_sequence_gap", payload: fields(["expected": "x", "received": "4"])
        ), "unparsable expected must throw")

        let decoded = try EventPayloadCodec.decode(
            kind: "integration_sequence_gap",
            payload: fields(["expected": "3", "received": "4"])
        )
        XCTAssertEqual(decoded, .integrationSequenceGap(expected: 3, received: 4))

        // Lossless parsing at magnitude: a value pair near 2^63 roundtrips
        // byte-exactly through the string field encoding.
        let expected = UInt64(9_223_372_036_854_775_806)
        let encoded = EventPayloadCodec.encode(.integrationSequenceGap(expected: expected, received: 7))
        let roundtripped = try EventPayloadCodec.decode(kind: encoded.kind, payload: encoded.payload)
        XCTAssertEqual(roundtripped, .integrationSequenceGap(expected: expected, received: 7))
    }

    /// 6e3a22a: `restart_initiated` requires a parsable `generation` token
    /// (:709-713) — the decoder previously fabricated generation 0, pinning
    /// the restart ledger to the wrong surface generation.
    func testRestartInitiatedRequiresParsableGenerationToken() throws {
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "restart_initiated", payload: fields([:])
        ), "missing generation must throw")
        XCTAssertThrowsError(try EventPayloadCodec.decode(
            kind: "restart_initiated", payload: fields(["generation": "soon"])
        ), "unparsable generation must throw")

        let decoded = try EventPayloadCodec.decode(
            kind: "restart_initiated",
            payload: fields(["generation": "42"])
        )
        XCTAssertEqual(decoded, .restartInitiated(generation: SurfaceGeneration(rawValue: 42)))

        let encoded = EventPayloadCodec.encode(.restartInitiated(generation: SurfaceGeneration(rawValue: 42)))
        let roundtripped = try EventPayloadCodec.decode(kind: encoded.kind, payload: encoded.payload)
        XCTAssertEqual(roundtripped, decoded, "roundtrip must preserve the exact rawValue")
    }
}

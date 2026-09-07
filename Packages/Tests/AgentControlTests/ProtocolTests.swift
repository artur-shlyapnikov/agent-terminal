@testable import AgentControl
import AgentCore
import Foundation
import XCTest

// §4.8 ProtocolTests — encoding roundtrips, version rejection, error taxonomy.

final class ProtocolTests: XCTestCase {
    // MARK: Envelope roundtrips + stable field names (§3.16)

    func testRequestEncodingUsesStableFieldNames() throws {
        let request = ControlRequest(
            requestID: "11111111-2222-3333-4444-555555555555",
            commandID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            method: ControlMethod.agentPrompt.rawValue,
            params: ["agentID": .string("x"), "text": .string("hello")]
        )
        let data = ControlWire.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Exact §3.16 envelope keys.
        XCTAssertEqual(Set(object.keys), ["protocolVersion", "requestID", "commandID", "method", "params"])
        XCTAssertEqual(object["protocolVersion"] as? Int, 1)
        XCTAssertEqual(object["method"] as? String, "agent.prompt")
        XCTAssertEqual(object["commandID"] as? String, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    func testRequestWithoutCommandIDOmitsField() throws {
        let request = ControlRequest(requestID: "r1", method: "system.ping")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ControlWire.encode(request)) as? [String: Any]
        )
        XCTAssertFalse(object.keys.contains("commandID"), "commandID is optional and must be absent")
    }

    func testRequestRoundtrip() throws {
        let request = ControlRequest(
            protocolVersion: 1,
            requestID: "r-42",
            commandID: "c-7",
            method: "agent.wait",
            params: [
                "agentID": .string("a"),
                "targetLifecycle": .array(["idle", "working"]),
                "minStateRevision": .uint64(12),
                "timeoutMs": .int(1500),
            ]
        )
        var data = ControlWire.encode(request)
        data.removeLast() // strip framing newline
        let parsed = try ControlWire.parse(line: Substring(String(decoding: data, as: UTF8.self)))
        guard case let .request(decoded) = parsed else {
            return XCTFail("expected request frame")
        }
        XCTAssertEqual(decoded, request)
    }

    func testResponseEncodingUsesStableFieldNames() throws {
        let ok = ControlResponse.success("req-1", ["matched": true], stateRevision: 9)
        let okObject = try XCTUnwrap(JSONSerialization.jsonObject(with: ControlWire.encode(ok)) as? [String: Any])
        XCTAssertEqual(okObject["requestID"] as? String, "req-1")
        XCTAssertEqual(okObject["ok"] as? Bool, true)
        XCTAssertEqual(okObject["stateRevision"] as? Int, 9)
        XCTAssertNotNil(okObject["result"])

        let failure = ControlResponse.failure(
            ControlFailure(code: .invalidLifecycle, message: "nope"),
            requestID: "req-2"
        )
        let failObject = try XCTUnwrap(JSONSerialization
            .jsonObject(with: ControlWire.encode(failure)) as? [String: Any])
        XCTAssertNil(failObject["result"], "error responses never carry result")
        let error = try XCTUnwrap(failObject["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalidLifecycle")
        XCTAssertEqual(error["message"] as? String, "nope")
    }

    func testResponseRoundtrip() throws {
        let response = ControlResponse.success("req-9", ["receipt": .object([
            "commandID": .string("c"),
            "outcome": .string("delivered"),
        ])], stateRevision: 3)
        let decoded = try ControlWire.jsonDecoder.decode(ResponseCodable.self, from: ControlWire.encode(response)).value
        XCTAssertEqual(decoded.requestID, response.requestID)
        XCTAssertEqual(decoded.ok, true)
        XCTAssertEqual(decoded.result.count, 1)
        XCTAssertEqual(decoded.stateRevision, 3)
    }

    func testCRLFToleratedByParser() throws {
        let parsed = try ControlWire
            .parse(
                line: Substring(
                    "{\"protocolVersion\":1,\"requestID\":\"r\",\"method\":\"system.ping\",\"params\":{}}\r"
                )
            )
        guard case let .request(request) = parsed else { return XCTFail() }
        XCTAssertEqual(request.method, "system.ping")
    }

    // MARK: Version negotiation

    func testVersionMismatchIsRejectedWithoutFallback() {
        XCTAssertNoThrow(try ProtocolVersion.validate(1))
        for bad in [0, 2, 99] {
            XCTAssertThrowsError(try ProtocolVersion.validate(bad)) { error in
                guard let failure = error as? ControlFailure else {
                    XCTFail("expected ControlFailure, got \(error)")
                    return
                }
                XCTAssertEqual(failure.code, .unsupportedProtocolVersion)
                XCTAssertTrue(failure.message.contains(String(bad)))
            }
        }
    }

    // MARK: Method set

    func testClosedMethodSetMatchesArchitecture316() {
        let expected: Set = [
            "system.ping",
            "workspace.list",
            "agent.create",
            "agent.list",
            "agent.get",
            "agent.prompt",
            "agent.cancelQueuedPrompt",
            "agent.focus",
            "agent.read",
            "agent.wait",
            "agent.interrupt",
            "agent.stop",
            "agent.resume",
            "events.subscribe",
            "integration.report",
            "integration.release",
            "launcher.started",
            "launcher.failed",
        ]
        XCTAssertEqual(Set(ControlMethod.allCases.map(\.rawValue)), expected)
    }

    // MARK: Error taxonomy

    func testEveryRuntimeErrorMapsToAStableCode() {
        let all: [RuntimeErrors] = [
            .agentNotFound, .terminalUnavailable, .invalidLifecycle,
            .waitingForTerminalInput, .queuedPromptAlreadyExists,
            .semanticStateUnavailable, .resumeUnsupported, .resumeReferenceMissing,
            .launchFailed, .promptDeliveryUnconfirmed, .timeout, .persistenceDegraded,
        ]
        for error in all {
            let failure = mapRuntimeError(error)
            XCTAssertNotEqual(failure.code, .internalError, "\(error) collapsed to internalError")
            XCTAssertFalse(failure.message.isEmpty)
        }
    }

    func testUnknownErrorSanitizedToInternalError() {
        struct OpaqueError: Error {}
        let failure = mapRuntimeError(OpaqueError())
        XCTAssertEqual(failure.code, .internalError)
        // Never leaks the underlying type description.
        XCTAssertEqual(failure.message, "internal error")
    }

    // MARK: Idempotency cache semantics

    func testIdempotencyCacheReplaysAndEvicts() async {
        let cache = IdempotencyCache(capacity: 2, ttl: .seconds(60))
        await cache.put("c1", Data("resp-1".utf8))
        let hit = await cache.get("c1")
        XCTAssertEqual(hit.map { String(decoding: $0, as: UTF8.self) }, "resp-1")

        await cache.put("c2", Data("resp-2".utf8))
        await cache.put("c3", Data("resp-3".utf8))
        let evicted = await cache.get("c1") // capacity 2 → oldest dropped
        XCTAssertNil(evicted)
        let kept = await cache.get("c3")
        XCTAssertNotNil(kept)

        let count = await cache.count
        XCTAssertEqual(count, 2)
    }

    func testIdempotencyCacheTTLExpires() async {
        // TTL is wall-clock based; a zero TTL expires immediately.
        let cache = IdempotencyCache(capacity: 4, ttl: .zero)
        await cache.put("k", Data("v".utf8))
        try? await Task.sleep(for: .milliseconds(5))
        let expired = await cache.get("k")
        XCTAssertNil(expired)
    }

    // MARK: R21-CM1 — JSONValue decode-ladder precedence, uint64 overflow

    // fold, accessor tolerances, empty-frame arm

    func testJSONValueDecodeLadderPrecedenceUint64OverflowFoldAndAccessorTolerances() throws {
        func decode(_ json: String) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        }

        // The Codable ladder probes bool BEFORE int (ControlMessage.swift):
        // `true` must never retype as a number.
        XCTAssertEqual(try decode("true"), .bool(true))
        XCTAssertEqual(try decode("1"), .int(1))
        XCTAssertEqual(try decode("1.5"), .double(1.5))
        let nested = try decode(#"{"a":[1,null]}"#)
        XCTAssertEqual(nested["a"], .array([.int(1), .null]))

        // Encode→decode roundtrip preserves Equatable equality of a deep
        // mixed value.
        let mixed = JSONValue.object([
            "s": "x",
            "b": false,
            "i": .int(-7),
            "d": .double(0.25),
            "a": [.null, .bool(true), .object(["k": .int(3)])],
        ])
        let redecoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mixed))
        XCTAssertEqual(redecoded, mixed)

        // uint64 fold: ≤ Int64.max stays exact; anything larger folds into
        // .double — the ONLY lossy conversion on the wire. Its intValue is
        // nil under the magnitude guard, so the pin documents WHERE the
        // cliff is rather than pretending the value survives.
        XCTAssertEqual(JSONValue.uint64(UInt64(Int64.max)), .int(Int64.max))
        let overflow = JSONValue.uint64(UInt64(Int64.max) + 1)
        guard case .double = overflow else {
            return XCTFail("expected lossy double fold above Int64.max, got \(overflow)")
        }
        XCTAssertNil(overflow.intValue, "the folded double must not pretend to be an exact int")
        // Note: Double precision collapses Int64.max and Int64.max+1 to the
        // SAME double — the fold's lossiness is total at the cliff.

        // intValue tolerates whole-number doubles but refuses fractional ones.
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertNil(JSONValue.double(3.5).intValue)

        // Subscripting a non-object yields nil; object hit/miss behave.
        XCTAssertNil(JSONValue.string("x")["k"])
        XCTAssertNil(JSONValue.int(1)["k"])
        let object = JSONValue.object(["hit": .int(1)])
        XCTAssertEqual(object["hit"], .int(1))
        XCTAssertNil(object["miss"])

        // Blank frames are rejected as "empty frame" before any decoding.
        for blank in ["   ", ""] {
            do {
                _ = try ControlWire.parse(line: Substring(blank))
                XCTFail("blank frame \(blank.debugDescription) parsed")
            } catch let failure as ControlFailure {
                XCTAssertTrue(
                    failure.message.contains("empty frame"),
                    "unexpected rejection message: \(failure.message)"
                )
            }
        }
    }
}

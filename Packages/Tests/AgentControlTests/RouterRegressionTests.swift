@testable import AgentControl
import AgentCore
import Foundation
import XCTest

// Regression tests for wave-2 architecture-review findings:
// - agent.read must report the STATE revision space at top level (§3.6);
// - integration.report must honor the §3.16 inputRequest param, with the
//   reply surface forced server-side (§5.1).

final class RouterRegressionTests: XCTestCase {
    func testAgentReadStateRevisionIsStateSpaceDistinctFromOutputRevision() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }

        // Harness fixture: agent state revision 5; fake terminal reports
        // outputRevision 1.
        let client = try harness.client()
        defer { client.close() }
        let response = try client.roundtrip(method: ControlMethod.agentRead.rawValue, params: [
            "agentID": .string(harness.agentID.rawValue.uuidString),
        ])

        XCTAssertNil(response.error)
        XCTAssertEqual(response.stateRevision, 5,
                       "top-level stateRevision must come from the agent's state revision space")
        XCTAssertEqual(response.result["outputRevision"]?.intValue, 1,
                       "outputRevision stays inside the result object")
        XCTAssertNotEqual(response.stateRevision, UInt64(1),
                          "stateRevision and outputRevision are different revision spaces (§3.6)")
    }

    func testIntegrationReportApprovalInputRequestRoundTripsKind() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }
        await harness.hooks.register(agentID: harness.agentID, surfaceGeneration: .initial, token: harness.token)

        let client = try harness.client()
        defer { client.close() }
        let response = try client.roundtrip(method: ControlMethod.integrationReport.rawValue, params: [
            "agentID": .string(harness.agentID.rawValue.uuidString),
            "surfaceGeneration": .uint64(0),
            "source": "hook:test",
            "seq": .uint64(1),
            "lifecycle": .string("waitingForInput"),
            "inputRequest": .object([
                "kind": .string("approval"),
                "summary": .string("Allow checkout of three files?"),
            ]),
            "token": .string(harness.token),
        ])

        XCTAssertTrue(response.ok, "report should be accepted: \(response.error as Any)")
        let evidence = harness.runtime.ingestedEvidence
        guard case let .integrationLifecycle(.waitingForInput(descriptor))? = evidence.last?.payload else {
            return XCTFail("expected waitingForInput evidence, got \(String(describing: evidence.last?.payload))")
        }
        XCTAssertEqual(descriptor.kind, .approval, "reported kind must survive ingestion")
        XCTAssertEqual(descriptor.summary, "Allow checkout of three files?")
        XCTAssertEqual(descriptor.source, .integration)
    }

    func testHookClaimingComposerAllowedCannotProduceComposerAllowed() async throws {
        let harness = try SocketHarness.make()
        try await harness.start()
        defer { Task { await harness.stop() } }
        await harness.hooks.register(agentID: harness.agentID, surfaceGeneration: .initial, token: harness.token)

        let client = try harness.client()
        defer { client.close() }
        // Even a freeText request that explicitly claims composerAllowed must
        // be pinned to terminalOnly — §5.1 is enforced server-side only.
        let response = try client.roundtrip(method: ControlMethod.integrationReport.rawValue, params: [
            "agentID": .string(harness.agentID.rawValue.uuidString),
            "surfaceGeneration": .uint64(0),
            "source": "hook:test",
            "seq": .uint64(1),
            "lifecycle": .string("waitingForInput"),
            "inputRequest": .object([
                "kind": .string("freeText"),
                "summary": .string("continue?"),
                "safeReplyMode": .string("composerAllowed"),
            ]),
            "token": .string(harness.token),
        ])

        XCTAssertTrue(response.ok)
        let evidence = harness.runtime.ingestedEvidence
        guard case let .integrationLifecycle(.waitingForInput(descriptor))? = evidence.last?.payload else {
            return XCTFail("expected waitingForInput evidence")
        }
        XCTAssertEqual(descriptor.safeReplyMode, .terminalOnly,
                       "composerAllowed claimed by a hook must never reach the model state")
        XCTAssertFalse(descriptor.composerPermitted)
    }
}

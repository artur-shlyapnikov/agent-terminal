@testable import AgentCore
import XCTest

// §4.8: authority precedence — integration > screen > process > unknown (§3.6).

@MainActor
final class StateAuthorityTests: XCTestCase {
    private let agent = AgentID()

    func testPrecedenceOrdering() {
        XCTAssertTrue(StateAuthority.integration > StateAuthority.screen)
        XCTAssertTrue(StateAuthority.screen > StateAuthority.process)
        XCTAssertTrue(StateAuthority.process > StateAuthority.unknown)
    }

    func testIntegrationBeatsScreenAndProcess() throws {
        var ledger = EvidenceLedger()
        ledger.accept(processEvidence(agent: agent, receivedAt: instant(10)))
        ledger.accept(screenEvidence(agent: agent, lifecycle: .working, receivedAt: instant(20)))
        ledger.accept(integrationEvidence(agent: agent, lifecycle: .idle, sequence: 1, receivedAt: instant(30)))

        let winner = try XCTUnwrap(StateAuthorityResolver.resolve(in: ledger))
        XCTAssertEqual(winner.authority, .integration)
        guard case .integrationLifecycle(.idle) = winner.payload else {
            return XCTFail("integration evidence must win")
        }
    }

    func testScreenBeatsProcess() throws {
        var ledger = EvidenceLedger()
        ledger.accept(processEvidence(agent: agent, receivedAt: instant(10)))
        ledger.accept(screenEvidence(agent: agent, lifecycle: .working, receivedAt: instant(20)))

        let winner = try XCTUnwrap(StateAuthorityResolver.resolve(in: ledger))
        XCTAssertEqual(winner.authority, .screen)
    }

    func testProcessOnlyWhenNothingHigherExists() throws {
        var ledger = EvidenceLedger()
        ledger.accept(processEvidence(agent: agent, receivedAt: instant(10)))

        let winner = try XCTUnwrap(StateAuthorityResolver.resolve(in: ledger))
        XCTAssertEqual(winner.authority, .process)
    }

    func testEmptyLedgerResolvesToUnknown() {
        let ledger = EvidenceLedger()
        XCTAssertNil(StateAuthorityResolver.resolve(in: ledger))
        XCTAssertEqual(StateAuthorityResolver.effectiveAuthority(in: ledger), .unknown)
    }

    func testSessionIdentityHookNeverBecomesLifecycleAuthority() {
        var ledger = EvidenceLedger()
        let identity = Evidence(
            envelope: makeEnvelope(
                agent: agent,
                sourceKind: .integration,
                sourceID: "hook:identity",
                sequence: 1,
                receivedAt: instant(10)
            ),
            payload: .sessionIdentity(SessionReference(agentKind: .claudeCode, opaquePayload: "sess-1"))
        )
        ledger.accept(identity)

        // Identity-only integration must not win lifecycle…
        XCTAssertNil(StateAuthorityResolver.resolve(in: ledger))
        // …but it is still captured for resume.
        XCTAssertEqual(ledger.sessionReference?.opaquePayload, "sess-1")
    }

    func testSameAuthorityTieBreaksByNewestLocalReceipt() throws {
        var ledger = EvidenceLedger()
        // Two screen observations; the older one says working, newer idle.
        ledger.accept(screenEvidence(agent: agent, lifecycle: .working, receivedAt: instant(10)))
        ledger.accept(screenEvidence(agent: agent, lifecycle: .idle, receivedAt: instant(20)))

        let winner = try XCTUnwrap(StateAuthorityResolver.resolve(in: ledger))
        guard case let .screen(payload) = winner.payload else {
            return XCTFail("expected screen payload")
        }
        XCTAssertEqual(payload.resultingLifecycle, .idle, "newest local receipt time wins")
    }

    func testObservedAtIsNeverUsedForOrdering() throws {
        var ledger = EvidenceLedger()
        // Newer seq claims a LARGER external observedAt but was received later —
        // receipt order decides, observedAt is diagnostics only.
        ledger.accept(
            integrationEvidence(
                agent: agent,
                lifecycle: .working,
                sequence: 1,
                receivedAt: instant(10),
                observedAt: instant(9999)
            )
        )
        ledger.accept(
            integrationEvidence(
                agent: agent,
                lifecycle: .idle,
                sequence: 2,
                receivedAt: instant(20),
                observedAt: instant(1)
            )
        )

        let winner = try XCTUnwrap(StateAuthorityResolver.resolve(in: ledger))
        guard case .integrationLifecycle(.idle) = winner.payload else {
            return XCTFail("latest accepted (seq 2) must win regardless of observedAt")
        }
    }

    func testExpiringIntegrationFallsBackToScreen() throws {
        var ledger = EvidenceLedger()
        ledger.accept(screenEvidence(agent: agent, lifecycle: .working, receivedAt: instant(10)))
        ledger.accept(integrationEvidence(
            agent: agent,
            lifecycle: .idle,
            sourceID: "hook:x",
            sequence: 1,
            receivedAt: instant(20)
        ))
        ledger.expireIntegration(sourceID: "hook:x", at: instant(30))

        let winner = try XCTUnwrap(StateAuthorityResolver.resolve(in: ledger))
        XCTAssertEqual(winner.authority, .screen)
        XCTAssertFalse(ledger.diagnostics.isEmpty, "expiry is recorded as diagnostics")
    }
}

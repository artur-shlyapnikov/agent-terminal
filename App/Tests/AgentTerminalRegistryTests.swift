import AgentCore
@testable import AgentTerminal
import Combine
import XCTest

// R2-3 — `AgentTerminalRegistry` invariants: restart cutover keeps BOTH maps
// consistent, a rebind of an unknown agent mutates nothing and notifies
// nobody, and remove/nextGeneration stay glued to `AgentRuntime.restart`'s
// generation arithmetic.

@MainActor
final class AgentTerminalRegistryTests: XCTestCase {
    // MARK: - Fixtures

    private func makeBinding(
        generation: UInt64 = 1,
        terminal: TerminalID = TerminalID()
    ) -> AgentBinding {
        AgentBinding(
            terminalID: terminal,
            surfaceGeneration: SurfaceGeneration(rawValue: generation),
            kind: .genericShell,
            displayName: "wired-agent",
            cwd: "/tmp/project"
        )
    }

    /// Counts objectWillChange emissions for the lifetime of the token.
    private func changeCounter(
        _ registry: AgentTerminalRegistry
    ) -> (count: () -> Int, token: AnyCancellable) {
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let counter = Counter()
        let token = registry.objectWillChange.sink { _ in counter.value += 1 }
        return ({ counter.value }, AnyCancellable(token))
    }

    // MARK: F1

    func testRebindCutsOverBothMapsWithoutStaleReverseEntry() {
        let registry = AgentTerminalRegistry()
        let agent = AgentID()
        let t1 = TerminalID()
        let t2 = TerminalID()

        registry.bind(agentID: agent, to: makeBinding(generation: 1, terminal: t1))
        registry.rebind(agentID: agent, newTerminalID: t2,
                        generation: SurfaceGeneration(rawValue: 2))

        // Old terminal's reverse entry is gone; the new one resolves back.
        XCTAssertNil(registry.agentID(for: t1),
                     "stale reverse entry would make detection evaluate the dead terminal")
        XCTAssertEqual(registry.agentID(for: t2), agent)
        // Forward entry mutated in place: new generation, identity preserved.
        let binding = registry.binding(for: agent)
        XCTAssertEqual(binding?.surfaceGeneration.rawValue, 2)
        XCTAssertEqual(binding?.displayName, "wired-agent")
        XCTAssertEqual(binding?.kind, .genericShell)
        XCTAssertEqual(binding?.cwd, "/tmp/project")
        XCTAssertEqual(registry.trackedTerminals, [t2])
    }

    // MARK: F2

    func testRebindOfUnknownAgentIsRejectedAtomically() {
        let registry = AgentTerminalRegistry()
        let other = AgentID()
        let otherTerminal = TerminalID()
        registry.bind(agentID: other,
                      to: makeBinding(generation: 1, terminal: otherTerminal))
        let (count, token) = changeCounter(registry)
        defer { _ = token }

        registry.rebind(agentID: AgentID(), newTerminalID: TerminalID(),
                        generation: SurfaceGeneration(rawValue: 9))

        // Nothing mutated…
        XCTAssertNil(registry.binding(for: AgentID()))
        XCTAssertEqual(registry.agentID(for: otherTerminal), other)
        XCTAssertEqual(registry.trackedTerminals, [otherTerminal])
        // …and no spurious notification fired (early return precedes send()).
        XCTAssertEqual(count(), 0,
                       "a rejected rebind must not invalidate SwiftUI subscriptions")
    }

    // MARK: F3

    func testRemoveClearsBothMapsAndNextGenerationMatchesRuntimeSuccessor() {
        let registry = AgentTerminalRegistry()
        let agent = AgentID()
        let t1 = TerminalID()
        registry.bind(agentID: agent,
                      to: makeBinding(generation: 7, terminal: t1))
        let (count, token) = changeCounter(registry)
        // The defer both uses the token and keeps the subscription alive
        // until every assertion (and the remove notification) has run.
        defer { _ = token }

        // App-side successor must match AgentRuntime.restart exactly —
        // asserted BEFORE removal.
        XCTAssertEqual(registry.binding(for: agent)?.nextGeneration,
                       SurfaceGeneration(rawValue: 8))

        registry.remove(agentID: agent)

        XCTAssertNil(registry.binding(for: agent))
        XCTAssertNil(registry.agentID(for: t1))
        XCTAssertTrue(registry.trackedTerminals.isEmpty,
                      "ghost terminals must not linger after removal")
        // Exactly one notification: bind happened before the counter attached.
        XCTAssertEqual(count(), 1)
    }
}

@testable import AgentCore
import XCTest

// §4.8: layout invariants — ≤4 leaves, ratio 0.2...0.8, agent uniqueness,
// replacement parks (never stops).

@MainActor
final class LayoutTreeTests: XCTestCase {
    private func agentLeaf(_ id: AgentID) -> LayoutTree {
        LayoutTree(leaf: .agent(id))
    }

    private func paneID(of tree: LayoutTree, index: Int) -> PaneID {
        tree.leaves[index].paneID
    }

    // MARK: Ratio clamping

    func testRatioClampedIntoRangeOnConstruction() {
        let low = LayoutTree(root: .split(
            .horizontal,
            0.05,
            .leaf(PaneID(), .placeholder),
            .leaf(PaneID(), .placeholder)
        ))
        let high = LayoutTree(root: .split(
            .horizontal,
            0.95,
            .leaf(PaneID(), .placeholder),
            .leaf(PaneID(), .placeholder)
        ))

        guard case let .split(_, lowRatio, _, _) = low.rootNode,
              case let .split(_, highRatio, _, _) = high.rootNode
        else {
            return XCTFail("expected splits")
        }
        XCTAssertEqual(lowRatio, 0.2)
        XCTAssertEqual(highRatio, 0.8)
        XCTAssertTrue(LayoutTree.ratioRange.contains(lowRatio))
        XCTAssertTrue(LayoutTree.ratioRange.contains(highRatio))
    }

    func testSplittingPaneClampsRequestedRatio() throws {
        var tree = LayoutTree(leaf: .placeholder)
        let pane = paneID(of: tree, index: 0)
        _ = try tree.splitting(paneID: pane, axis: .vertical, ratio: 0.01, newContent: .placeholder)

        guard case let .split(_, ratio, _, _) = tree.rootNode else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(ratio, 0.2, "out-of-range request is normalized, not rejected")
    }

    // MARK: Leaf cap

    func testFifthLeafIsRejected() throws {
        var tree = LayoutTree(leaf: .placeholder)
        for _ in 0 ..< 3 {
            let pane = paneID(of: tree, index: 0)
            _ = try tree.splitting(paneID: pane, axis: .horizontal, ratio: 0.5, newContent: .placeholder)
        }
        XCTAssertEqual(tree.leafCount, 4)

        let pane = paneID(of: tree, index: 0)
        XCTAssertThrowsError(
            try tree.splitting(paneID: pane, axis: .horizontal, ratio: 0.5, newContent: .placeholder)
        ) { error in
            XCTAssertEqual(error as? LayoutError, .tooManyLeaves)
        }
        XCTAssertEqual(tree.leafCount, 4, "failed split must not mutate the tree")
    }

    // MARK: Agent uniqueness

    func testAgentCannotAppearInTwoLeaves() throws {
        let agentA = AgentID()
        let agentB = AgentID()

        var tree = agentLeaf(agentA)
        let firstPane = paneID(of: tree, index: 0)
        _ = try tree.splitting(paneID: firstPane, axis: .horizontal, ratio: 0.5, newContent: .agent(agentB))

        // Now drag agent B onto the OTHER pane: B must vanish from its old leaf.
        let secondPane = try XCTUnwrap(tree.leaves.first { $0.content == .agent(agentB) }?.paneID)
        _ = try tree.replacing(contentOf: firstPane, with: .agent(agentB))

        let appearances = tree.leaves.filter { $0.content == .agent(agentB) }
        XCTAssertEqual(appearances.count, 1, "an agent is visible at most once")
        XCTAssertEqual(appearances[0].paneID, firstPane)

        let evictedLeaf = tree.leaves.first { $0.paneID == secondPane }
        XCTAssertEqual(evictedLeaf?.content, .placeholder, "the old leaf is parked back to placeholder")
    }

    /// §3.3 regression: splitting a leaf whose content equals the incoming
    /// agent content used to show that agent in two leaves. The new half must
    /// become a placeholder instead.
    func testSplittingLeafWithItsOwnAgentKeepsItUnique() throws {
        let agentA = AgentID()
        var tree = agentLeaf(agentA)
        let pane = paneID(of: tree, index: 0)

        let displaced = try tree.splitting(
            paneID: pane, axis: .vertical, ratio: 0.5, newContent: .agent(agentA)
        )

        XCTAssertEqual(tree.leafCount, 2)
        XCTAssertEqual(tree.leaves.filter { $0.content == .agent(agentA) }.count, 1,
                       "an agent is visible at most once, even when split with itself")
        XCTAssertEqual(tree.leaves.first { $0.paneID != pane }?.content, .placeholder)
        XCTAssertTrue(displaced.isEmpty, "no eviction happened — the agent never left its pane")
    }

    // MARK: Replacement parks, never stops

    func testReplacingLeafReportsDisplacedContentForParking() throws {
        let terminalID = TerminalID()
        var tree = LayoutTree(leaf: .terminal(terminalID))
        let pane = paneID(of: tree, index: 0)

        let newAgent = AgentID()
        let displaced = try tree.replacing(contentOf: pane, with: .agent(newAgent))

        XCTAssertEqual(displaced.count, 1)
        XCTAssertEqual(displaced[0].paneID, pane)
        XCTAssertEqual(displaced[0].previousContent, .terminal(terminalID),
                       "the previous content is returned so the caller can park it")
        XCTAssertEqual(tree.leaves[0].content, .agent(newAgent))
    }

    func testReplacingSameContentIsNoOpDisplacement() throws {
        let agentA = AgentID()
        var tree = agentLeaf(agentA)
        let pane = paneID(of: tree, index: 0)
        let displaced = try tree.replacing(contentOf: pane, with: .agent(agentA))
        XCTAssertTrue(displaced.isEmpty)
    }

    // MARK: Removal

    func testRemovingPaneCollapsesSplit() throws {
        var tree = LayoutTree(leaf: .placeholder)
        let first = paneID(of: tree, index: 0)
        _ = try tree.splitting(paneID: first, axis: .vertical, ratio: 0.5, newContent: .placeholder)
        XCTAssertEqual(tree.leafCount, 2)

        try tree.removing(paneID: first)
        XCTAssertEqual(tree.leafCount, 1)
    }

    func testLastLeafCannotBeRemoved() {
        var tree = LayoutTree(leaf: .placeholder)
        let only = paneID(of: tree, index: 0)
        XCTAssertNoThrow(try tree.removing(paneID: only), "removing the last leaf is refused silently")
        XCTAssertEqual(tree.leafCount, 1)
    }

    func testUnknownPaneThrows() {
        var tree = LayoutTree(leaf: .placeholder)
        XCTAssertThrowsError(try tree.replacing(contentOf: PaneID(), with: .placeholder)) { error in
            XCTAssertEqual(error as? LayoutError, .paneNotFound)
        }
    }

    func testContainsAgent() throws {
        let agentA = AgentID()
        var tree = agentLeaf(agentA)
        XCTAssertTrue(tree.contains(agent: agentA))

        let pane = paneID(of: tree, index: 0)
        _ = try tree.replacing(contentOf: pane, with: .placeholder)
        XCTAssertFalse(tree.contains(agent: agentA))
    }
}

import AgentCore
@testable import AgentTerminal
import XCTest

// Pure selection/layout decision coverage (contract item 5): which leaf gets
// replaced, option-click placement, max-four enforcement, next-focus.

final class CanvasLayoutPlannerTests: XCTestCase {
    private var counter = 0

    private func makeItem(_: Int) -> SidebarItem {
        counter += 1
        return .shell(TerminalID())
    }

    func testVisibleClickFocusesExistingPane() throws {
        var planner = CanvasLayoutPlanner()
        let a = makeItem(1)
        let pane = try planner.split(from: planner.leaves[0].paneID,
                                     axis: .horizontal, ratio: 0.5, newContent: CanvasLayoutPlanner.itemContent(a))
        _ = pane
        let visible = try XCTUnwrap(planner.paneID(showing: a))
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: a, kind: .plain, visiblePane: visible,
                                       focusedPane: nil, leafCount: 2),
            .focusExisting(paneID: visible)
        )
        // Option-click on a VISIBLE item still focuses (never splits twice).
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: a, kind: .option, visiblePane: visible,
                                       focusedPane: nil, leafCount: 2),
            .focusExisting(paneID: visible)
        )
    }

    func testHiddenPlainClickReplacesFocusedPane() {
        let b = makeItem(2)
        let focused = PaneID()
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: b, kind: .plain, visiblePane: nil,
                                       focusedPane: focused, leafCount: 2),
            .replaceFocused(paneID: focused)
        )
    }

    func testOptionClickSplitsUntilFourLeaves() {
        let b = makeItem(3)
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: b, kind: .option, visiblePane: nil,
                                       focusedPane: PaneID(), leafCount: 3),
            .splitFocused(axis: .horizontal, ratio: 0.5)
        )
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: b, kind: .option, visiblePane: nil,
                                       focusedPane: PaneID(), leafCount: 4),
            .rejectedMaxLeaves
        )
    }

    func testSplitCreatesNewPaneAndEnforcesMaxFour() throws {
        var planner = CanvasLayoutPlanner()
        let rootPane = planner.leaves[0].paneID
        let a = makeItem(1)
        let paneA = try planner.split(from: rootPane, axis: .horizontal, ratio: 0.5,
                                      newContent: CanvasLayoutPlanner.itemContent(a))
        XCTAssertNotEqual(paneA, rootPane)
        XCTAssertEqual(planner.leafCount, 2)

        // Fill all leaves up to four.
        var current = paneA
        for _ in 0 ..< 2 {
            current = try planner.split(from: current, axis: .vertical, ratio: 0.5, newContent: .placeholder)
        }
        XCTAssertEqual(planner.leafCount, 4)
        XCTAssertThrowsError(try planner.split(from: current, axis: .horizontal, ratio: 0.5,
                                               newContent: .placeholder))
        { error in
            XCTAssertEqual(error as? LayoutError, .tooManyLeaves)
        }
    }

    func testClosePaneParksWithoutRemovingLastLeaf() throws {
        var planner = CanvasLayoutPlanner()
        let pane = planner.leaves[0].paneID
        let a = makeItem(1)
        _ = try planner.replace(pane: pane, with: a)

        // Last leaf: close-view keeps the leaf, becomes placeholder, reports parked content.
        let parked = planner.closePane(pane)
        XCTAssertEqual(parked, [.terminal(terminalID(of: a))])
        XCTAssertEqual(planner.content(of: pane), .placeholder)
        XCTAssertEqual(planner.leafCount, 1)
    }

    func testCloseMiddleLeafCollapsesSplit() throws {
        var planner = CanvasLayoutPlanner()
        let rootPane = planner.leaves[0].paneID
        let a = makeItem(1)
        let paneA = try planner.split(from: rootPane, axis: .horizontal, ratio: 0.5,
                                      newContent: CanvasLayoutPlanner.itemContent(a))
        _ = try planner.replace(pane: rootPane, with: makeItem(2))

        let parked = planner.closePane(paneA)
        XCTAssertEqual(parked.count, 1)
        XCTAssertEqual(planner.leafCount, 1)
        XCTAssertEqual(planner.leaves.first?.paneID, rootPane)
    }

    func testNextFocusPrefersSiblingSubtree() throws {
        var planner = CanvasLayoutPlanner()
        let rootPane = planner.leaves[0].paneID
        // A | B, then split A vertically → column {A, C} | {B}.
        let a = makeItem(1)
        let b = makeItem(2)
        _ = try planner.replace(pane: rootPane, with: b)
        let paneA = try planner.split(from: rootPane, axis: .horizontal, ratio: 0.5,
                                      newContent: CanvasLayoutPlanner.itemContent(a))
        let paneC = try planner.split(from: paneA, axis: .vertical, ratio: 0.5, newContent: .placeholder)

        // Closing B focuses the sibling column's first leaf (A).
        XCTAssertEqual(planner.nextFocus(afterClosing: rootPane), paneA)
        // Closing C falls back inside its own subtree order → A still available.
        XCTAssertEqual(planner.nextFocus(afterClosing: paneC), paneA)
    }

    func testRatioClampOnResizeWriteback() throws {
        var planner = CanvasLayoutPlanner()
        let rootPane = planner.leaves[0].paneID
        _ = try planner.split(from: rootPane, axis: .horizontal, ratio: 0.5, newContent: .placeholder)
        planner.setRatio(path: [0], 0.05)
        let frames = planner.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 100))
        let leftWidth = try XCTUnwrap(frames.first { $0.paneID == rootPane }?.rect.width)
        // Clamped to ratioRange lower bound 0.2.
        XCTAssertEqual(leftWidth, 200, accuracy: 0.5)

        planner.setRatio(path: [0], 0.95)
        let frames2 = planner.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 100))
        let leftWidth2 = try XCTUnwrap(frames2.first { $0.paneID == rootPane }?.rect.width)
        XCTAssertEqual(leftWidth2, 800, accuracy: 0.5)
    }

    func testTwoByTwoGeometry() throws {
        var planner = CanvasLayoutPlanner()
        let rootPane = planner.leaves[0].paneID
        let rightPane = try planner.split(from: rootPane, axis: .horizontal, ratio: 0.5, newContent: .placeholder)
        let bottomLeft = try planner.split(from: rootPane, axis: .vertical, ratio: 0.5, newContent: .placeholder)
        let bottomRight = try planner.split(from: rightPane, axis: .vertical, ratio: 0.5, newContent: .placeholder)

        let frames = Dictionary(uniqueKeysWithValues: planner.frames(in: CGRect(x: 0, y: 0, width: 100, height: 100))
            .map {
                ($0.paneID, $0.rect)
            })
        XCTAssertEqual(frames[rootPane], CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(frames[rightPane], CGRect(x: 50, y: 0, width: 50, height: 50))
        XCTAssertEqual(frames[bottomLeft], CGRect(x: 0, y: 50, width: 50, height: 50))
        XCTAssertEqual(frames[bottomRight], CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    private func terminalID(of item: SidebarItem) -> TerminalID {
        switch item {
        case let .shell(id): id
        case let .agent(id): fatalError("unexpected \(id)")
        }
    }

    // MARK: R20-CLP1 — tiling invariants

    private func frameRects(_ planner: CanvasLayoutPlanner, bounds: CGRect) -> [PaneID: CGRect] {
        Dictionary(uniqueKeysWithValues: planner.frames(in: bounds).map { ($0.paneID, $0.rect) })
    }

    /// Leaf rects must PARTITION the container: inside bounds, pairwise
    /// disjoint, areas summing exactly to the container area.
    private func assertTilesExactly(_ rects: [CGRect], bounds: CGRect,
                                    file: StaticString = #filePath, line: UInt = #line)
    {
        var totalArea: CGFloat = 0
        for rect in rects {
            XCTAssertTrue(bounds.contains(rect), "leaf \(rect) escapes the container",
                          file: file, line: line)
            totalArea += rect.width * rect.height
        }
        XCTAssertEqual(totalArea, bounds.width * bounds.height, accuracy: 0.01,
                       "leaf areas must sum to the container area (no gaps/overlaps)",
                       file: file, line: line)
        for i in 0 ..< rects.count {
            for j in (i + 1) ..< rects.count {
                XCTAssertTrue(rects[i].intersection(rects[j]).isEmpty,
                              "leaves \(i) and \(j) overlap", file: file, line: line)
            }
        }
    }

    private func makeTwoByTwo() throws -> (CanvasLayoutPlanner, PaneID, PaneID, PaneID, PaneID) {
        var planner = CanvasLayoutPlanner()
        let rootPane = planner.leaves[0].paneID
        let right = try planner.split(from: rootPane, axis: .horizontal, ratio: 0.5,
                                      newContent: .placeholder)
        let bottomLeft = try planner.split(from: rootPane, axis: .vertical, ratio: 0.5,
                                           newContent: .placeholder)
        let bottomRight = try planner.split(from: right, axis: .vertical, ratio: 0.5,
                                            newContent: .placeholder)
        return (planner, rootPane, right, bottomLeft, bottomRight)
    }

    /// frames(in:) tiles ANY nested tree exactly; dividers(in:) emits ONE
    /// 2pt band per INTERIOR node with paths equal to child-index chains.
    func testFramesTileBoundsExactlyAndDividersCoverEveryInteriorNodeOnNestedTrees() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        // 2×2 grid.
        let (grid, rootPane, right, bottomLeft, bottomRight) = try makeTwoByTwo()
        let gridFrames = grid.frames(in: bounds)
        XCTAssertEqual(gridFrames.count, 4)
        XCTAssertEqual(Set(gridFrames.map(\.paneID)), Set([rootPane, right, bottomLeft, bottomRight]))
        assertTilesExactly(gridFrames.map(\.rect), bounds: bounds)

        let dividers = grid.dividers(in: bounds)
        XCTAssertEqual(dividers.count, 3, "one band per interior node: root + two child splits")
        XCTAssertEqual(Set(dividers.map(\.path)), Set([[], [0], [1]]),
                       "divider paths are the child-index chains from the root")
        let rootBand = try XCTUnwrap(dividers.first { $0.path.isEmpty })
        XCTAssertEqual(rootBand.axis, .horizontal)
        XCTAssertEqual(rootBand.rect.width, 2)
        XCTAssertTrue(rootBand.rect.minX <= 500 && rootBand.rect.maxX >= 500,
                      "the band straddles the split line x = 1000 * 0.5")
        for path in [[0], [1]] {
            let band = try XCTUnwrap(dividers.first { $0.path == path })
            XCTAssertEqual(band.axis, .vertical, "child splits are vertical columns")
            XCTAssertEqual(band.rect.height, 2)
        }

        // Asymmetric 3-leaf tree: root horizontal 0.5 | left column vertical 0.25.
        var asymmetric = CanvasLayoutPlanner()
        let aRoot = asymmetric.leaves[0].paneID
        _ = try asymmetric.split(from: aRoot, axis: .horizontal, ratio: 0.5, newContent: .placeholder)
        _ = try asymmetric.split(from: aRoot, axis: .vertical, ratio: 0.25, newContent: .placeholder)
        let asymFrames = asymmetric.frames(in: bounds)
        XCTAssertEqual(asymFrames.count, 3)
        assertTilesExactly(asymFrames.map(\.rect), bounds: bounds)
        let asymDividers = asymmetric.dividers(in: bounds)
        XCTAssertEqual(asymDividers.count, 2)
        XCTAssertEqual(Set(asymDividers.map(\.path)), Set([[], [0]]))
        let leftBand = try XCTUnwrap(asymDividers.first { $0.path == [0] })
        XCTAssertTrue(leftBand.rect.minY <= 200 && leftBand.rect.maxY >= 200,
                      "left column's band straddles y = 800 * 0.25")
    }

    /// R20-CLP2: setRatio guards (empty path / out-of-range first index /
    /// leaf mid-path are no-ops; deep path rewrites ONLY its subtree;
    /// clamped at ratioRange) plus decide()'s uncovered branches
    /// (.noSelection; visible-pane beats option-click even at maxLeaves).
    func testSetRatioDeepPathWritebackIgnoresEmptyAndOutOfRangePathsAndDecideUncoveredBranches() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let (baselinePlanner, rootPane, right, bottomLeft, bottomRight) = try makeTwoByTwo()
        let baseline = frameRects(baselinePlanner, bounds: bounds)

        var planner = baselinePlanner

        // Empty path is a full no-op.
        planner.setRatio(path: [], 0.9)
        XCTAssertEqual(frameRects(planner, bounds: bounds), baseline)

        // Out-of-range FIRST index ([2, 0]): withRatio's default arm returns
        // the node unchanged — geometry identical everywhere.
        planner.setRatio(path: [2, 0], 0.9)
        XCTAssertEqual(frameRects(planner, bounds: bounds), baseline)

        // Descending INTO a leaf ([0, 0, 1]) is equally inert.
        planner.setRatio(path: [0, 0, 1], 0.9)
        XCTAssertEqual(frameRects(planner, bounds: bounds), baseline)

        // Deep-path writeback moves ONLY the targeted subtree's boundary.
        // Path semantics: all-but-last indexes select the subtree; [1, 0]
        // targets root.child[1] (the right vertical split).
        planner.setRatio(path: [1, 0], 0.25)
        let after = frameRects(planner, bounds: bounds)
        XCTAssertEqual(after[rootPane], baseline[rootPane], "left column untouched")
        XCTAssertEqual(after[bottomLeft], baseline[bottomLeft], "left column untouched")
        XCTAssertEqual(after[right], CGRect(x: 500, y: 0, width: 500, height: 200))
        XCTAssertEqual(after[bottomRight], CGRect(x: 500, y: 200, width: 500, height: 600))

        // A write past ratioRange clamps to the upper bound (0.8).
        planner.setRatio(path: [1, 0], 9.0)
        let clamped = frameRects(planner, bounds: bounds)
        XCTAssertEqual(clamped[right]?.height ?? 0, bounds.height * LayoutTree.ratioRange.upperBound,
                       accuracy: 0.01)
        XCTAssertEqual(clamped[bottomRight]?.minY ?? 0,
                       bounds.height * LayoutTree.ratioRange.upperBound, accuracy: 0.01)
        XCTAssertEqual(clamped[bottomRight]?.height ?? 0,
                       bounds.height * (1 - LayoutTree.ratioRange.upperBound), accuracy: 0.01)

        // Hidden item + plain click + NO focused pane → .noSelection.
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: .shell(TerminalID()), kind: .plain, visiblePane: nil,
                                       focusedPane: nil, leafCount: 4),
            .noSelection
        )
        // Visible-pane precedence beats option-click EVEN at maxLeaves —
        // focusing never collapses into a max-leaves rejection.
        let visible = PaneID()
        XCTAssertEqual(
            CanvasLayoutPlanner.decide(item: .shell(TerminalID()), kind: .option, visiblePane: visible,
                                       focusedPane: nil, leafCount: LayoutTree.maxLeaves),
            .focusExisting(paneID: visible)
        )
    }
}

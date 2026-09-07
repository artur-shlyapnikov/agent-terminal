import AgentCore
import Foundation

/// Divider band geometry shared by the planner and the canvas view.
struct DividerGeometry {
    let path: [Int]
    let axis: SplitAxis
    let rect: CGRect
}

// Pure selection/layout decision logic (§3.13) — no UI, unit-tested.
//
// CanvasLayoutPlanner owns the LayoutTree mutation decisions: which leaf gets
// replaced on a hidden click, where option-click splits go, max-four
// enforcement and next-focus computation after close.

/// Sidebar click semantics (§3.13 "Agent selection behavior").
enum ClickKind: Equatable {
    case plain
    case option
}

enum SelectionDecision: Equatable {
    /// Item already visible in this pane: just focus it.
    case focusExisting(paneID: PaneID)
    /// Replace the content of the focused pane; caller parks the displaced
    /// terminal (it keeps running).
    case replaceFocused(paneID: PaneID)
    /// Option-click: split the focused pane; rejected at four leaves.
    case splitFocused(axis: SplitAxis, ratio: Double)
    case rejectedMaxLeaves
    case noSelection
}

struct CanvasLayoutPlanner {
    private(set) var tree: LayoutTree

    init() {
        tree = .empty
    }

    init(tree: LayoutTree) {
        self.tree = tree
    }

    static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, LayoutTree.ratioRange.lowerBound), LayoutTree.ratioRange.upperBound)
    }

    func paneID(showing item: SidebarItem) -> PaneID? {
        let target = Self.itemContent(item)
        return tree.leaves.first { $0.content == target }?.paneID
    }

    func content(of pane: PaneID) -> PaneContent? {
        tree.content(of: pane)
    }

    var leaves: [LayoutTree.LeafInfo] {
        tree.leaves
    }

    var leafCount: Int {
        tree.leafCount
    }

    static func itemContent(_ item: SidebarItem) -> PaneContent {
        switch item {
        case let .agent(id): .agent(id)
        case let .shell(id): .terminal(id)
        }
    }

    /// Decides what a sidebar click means (§3.13). `focusedPane` is the pane
    /// that currently holds keyboard focus; may be nil when nothing focused.
    static func decide(
        item _: SidebarItem,
        kind: ClickKind,
        visiblePane: PaneID?,
        focusedPane: PaneID?,
        leafCount: Int
    ) -> SelectionDecision {
        if let visiblePane {
            // Click on a visible agent → focus its pane (plain or option).
            return .focusExisting(paneID: visiblePane)
        }
        if kind == .option {
            if leafCount >= LayoutTree.maxLeaves {
                return .rejectedMaxLeaves
            }
            return .splitFocused(axis: .horizontal, ratio: 0.5)
        }
        // Hidden item, plain click → replace focused leaf content.
        if let focusedPane {
            return .replaceFocused(paneID: focusedPane)
        }
        return .noSelection
    }

    /// Applies `.splitFocused`: splits `pane` and returns the NEW pane id.
    /// Throws LayoutError.tooManyLeaves past four leaves (enforced upstream by
    /// `decide`, enforced again here by LayoutTree itself).
    mutating func split(
        from pane: PaneID,
        axis: SplitAxis,
        ratio: Double,
        newContent: PaneContent
    ) throws -> PaneID {
        let before = Set(tree.leaves.map(\.paneID))
        _ = try tree.splitting(paneID: pane, axis: axis, ratio: Self.clamp(ratio), newContent: newContent)
        guard let added = tree.leaves.first(where: { !before.contains($0.paneID) })?.paneID else {
            throw LayoutError.paneNotFound
        }
        return added
    }

    /// Replaces a pane's content; returns the previous content for parking.
    mutating func replace(pane: PaneID, with item: SidebarItem) throws -> PaneContent? {
        let previous = tree.content(of: pane)
        _ = try tree.replacing(contentOf: pane, with: Self.itemContent(item))
        return previous
    }

    /// ⌘W / close-view: removes the leaf WITHOUT touching any process. The
    /// returned contents must be parked by the caller. The last remaining
    /// leaf is never removed; it becomes a placeholder instead.
    mutating func closePane(_ pane: PaneID) -> [PaneContent] {
        var parked: [PaneContent] = []
        if let content = tree.content(of: pane), content != .placeholder {
            parked.append(content)
        }
        if tree.leafCount > 1 {
            do {
                try tree.removing(paneID: pane)
            } catch {
                // Removal must never fail silently into a "parked but still
                // shown" ghost pane: degrade the leaf to a placeholder so the
                // canvas can never re-mount a terminal that was parked.
                _ = try? tree.replacing(contentOf: pane, with: .placeholder)
            }
        } else {
            _ = try? tree.replacing(contentOf: pane, with: .placeholder)
        }
        return parked
    }

    /// Focus preference after a close (§3.13): the sibling leaf wins; else the
    /// first remaining leaf.
    func nextFocus(afterClosing pane: PaneID) -> PaneID? {
        nextFocus(in: tree.rootNode, avoiding: pane)
    }

    // MARK: dividers

    /// Divider bands (2 pt) for every interior split node, in absolute
    /// coordinates. Path = child index chain from the root.
    func dividers(in bounds: CGRect) -> [DividerGeometry] {
        dividers(in: tree.rootNode, bounds: bounds, path: [])
    }

    private func dividers(in node: LayoutTree.Node, bounds: CGRect, path: [Int]) -> [DividerGeometry] {
        switch node {
        case .leaf:
            return []
        case let .split(axis, ratio, first, second):
            let r = Self.clamp(ratio)
            var result: [DividerGeometry] = []
            let thickness: CGFloat = 2
            switch axis {
            case .horizontal:
                let x = bounds.minX + bounds.width * CGFloat(r) - thickness / 2
                result.append(DividerGeometry(
                    path: path, axis: axis,
                    rect: CGRect(x: x, y: bounds.minY, width: thickness, height: bounds.height)
                ))
                let leftW = bounds.width * CGFloat(r)
                result += dividers(
                    in: first,
                    bounds: CGRect(x: bounds.minX, y: bounds.minY, width: leftW, height: bounds.height),
                    path: path + [0]
                )
                result += dividers(
                    in: second,
                    bounds: CGRect(x: x + thickness, y: bounds.minY, width: bounds.maxX - x - thickness,
                                   height: bounds.height),
                    path: path + [1]
                )
            case .vertical:
                let y = bounds.minY + bounds.height * CGFloat(r) - thickness / 2
                result.append(DividerGeometry(
                    path: path, axis: axis,
                    rect: CGRect(x: bounds.minX, y: y, width: bounds.width, height: thickness)
                ))
                let topH = bounds.height * CGFloat(r)
                result += dividers(
                    in: first,
                    bounds: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: topH),
                    path: path + [0]
                )
                result += dividers(
                    in: second,
                    bounds: CGRect(x: bounds.minX, y: y + thickness, width: bounds.width,
                                   height: bounds.maxY - y - thickness),
                    path: path + [1]
                )
            }
            return result
        }
    }

    /// Writes back a user-dragged ratio at the given split path.
    mutating func setRatio(path: [Int], _ value: Double) {
        guard !path.isEmpty else { return }
        let newRoot = Self.withRatio(tree.rootNode, path: path, value: Self.clamp(value))
        tree = LayoutTree(root: newRoot)
    }

    private static func withRatio(
        _ node: LayoutTree.Node,
        path: [Int],
        value: Double
    ) -> LayoutTree.Node {
        guard case let .split(axis, ratio, first, second) = node else { return node }
        if path.count == 1 {
            return .split(axis, clamp(value), first, second)
        }
        switch path[0] {
        case 0:
            return .split(axis, ratio, withRatio(first, path: Array(path.dropFirst()), value: value), second)
        case 1:
            return .split(axis, ratio, first, withRatio(second, path: Array(path.dropFirst()), value: value))
        default:
            return node
        }
    }

    private func nextFocus(in node: LayoutTree.Node, avoiding closed: PaneID) -> PaneID? {
        switch node {
        case let .leaf(id, _):
            return id == closed ? nil : id
        case let .split(_, _, first, second):
            let firstIDs = Self.leafIDs(of: first)
            let secondIDs = Self.leafIDs(of: second)
            // Prefer the nearest sibling: recurse into the closed branch for
            // a remaining leaf before jumping to the other branch.
            if firstIDs.contains(closed), !secondIDs.contains(closed) {
                return nextFocus(in: first, avoiding: closed) ?? nextFocus(in: second, avoiding: closed)
            }
            if secondIDs.contains(closed), !firstIDs.contains(closed) {
                return nextFocus(in: second, avoiding: closed) ?? nextFocus(in: first, avoiding: closed)
            }
            return nextFocus(in: first, avoiding: closed) ?? nextFocus(in: second, avoiding: closed)
        }
    }

    private static func leafIDs(of node: LayoutTree.Node) -> [PaneID] {
        switch node {
        case let .leaf(id, _): [id]
        case let .split(_, _, a, b): leafIDs(of: a) + leafIDs(of: b)
        }
    }

    // MARK: geometry

    struct Frame {
        let paneID: PaneID
        let rect: CGRect
    }

    /// Computes absolute frames for every leaf inside `bounds`.
    /// Horizontal = side-by-side, vertical = stacked.
    func frames(in bounds: CGRect) -> [Frame] {
        frames(in: tree.rootNode, bounds: bounds)
    }

    private func frames(in node: LayoutTree.Node, bounds: CGRect) -> [Frame] {
        switch node {
        case let .leaf(id, _):
            return [Frame(paneID: id, rect: bounds)]
        case let .split(axis, ratio, first, second):
            let r = Self.clamp(ratio)
            switch axis {
            case .horizontal:
                let splitX = bounds.minX + bounds.width * CGFloat(r)
                let left = CGRect(x: bounds.minX, y: bounds.minY, width: splitX - bounds.minX, height: bounds.height)
                let right = CGRect(x: splitX, y: bounds.minY, width: bounds.maxX - splitX, height: bounds.height)
                return frames(in: first, bounds: left) + frames(in: second, bounds: right)
            case .vertical:
                let splitY = bounds.minY + bounds.height * CGFloat(r)
                let top = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: splitY - bounds.minY)
                let bottom = CGRect(x: bounds.minX, y: splitY, width: bounds.width, height: bounds.maxY - splitY)
                return frames(in: first, bounds: top) + frames(in: second, bounds: bottom)
            }
        }
    }

    /// Axis of the parent split for a leaf — used for alternating split
    /// placement so 2x2 grids stay balanced.
    func parentAxis(of pane: PaneID) -> SplitAxis? {
        parentAxis(in: tree.rootNode, target: pane, currentAxis: nil)
    }

    private func parentAxis(in node: LayoutTree.Node, target: PaneID, currentAxis: SplitAxis?) -> SplitAxis? {
        switch node {
        case .leaf:
            return currentAxis
        case let .split(axis, _, first, second):
            if case let .leaf(id, _) = first, id == target {
                return axis
            }
            if case let .leaf(id, _) = second, id == target {
                return axis
            }
            return parentAxis(in: first, target: target, currentAxis: axis)
                ?? parentAxis(in: second, target: target, currentAxis: axis)
        }
    }
}

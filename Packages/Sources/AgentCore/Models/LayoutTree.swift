import Foundation

// Binary split layout tree with enforced invariants (architecture §3.3):
// - at most four leaves;
// - split ratio normalized into 0.2...0.8;
// - the same agent can never be visible in two leaves at once;
// - replacing a leaf's content parks the previous terminal — never stops it
//   (parking is modeled here as returning the displaced content);
// - the layout is not an owner of processes.

public enum SplitAxis: Equatable, Sendable, Codable {
    case horizontal
    case vertical
}

public enum PaneContent: Equatable, Sendable, Codable {
    case agent(AgentID)
    case terminal(TerminalID)
    case placeholder
}

public enum LayoutError: Error, Equatable, Sendable {
    case tooManyLeaves
    case paneNotFound
    case invalidRatio
}

/// Displaced content from a replace/split. The caller parks it; the layout only
/// reports what was there before.
public struct DisplacedContent: Equatable, Sendable {
    public let paneID: PaneID
    public let previousContent: PaneContent
}

public struct LayoutTree: Equatable, Sendable {
    public static let maxLeaves = 4
    public static let ratioRange: ClosedRange<Double> = 0.2 ... 0.8

    public indirect enum Node: Equatable, Sendable {
        case leaf(PaneID, PaneContent)
        case split(SplitAxis, Double, Node, Node)
    }

    private var root: Node

    // MARK: Construction

    /// Builds a tree, clamping every split ratio into `ratioRange`.
    public init(root: Node) {
        self.root = Self.normalizing(root)
    }

    public static let empty = LayoutTree(leaf: .placeholder)

    public init(leaf: PaneContent) {
        root = .leaf(PaneID(), leaf)
    }

    private static func normalizing(_ node: Node) -> Node {
        switch node {
        case .leaf:
            node
        case let .split(axis, ratio, first, second):
            .split(axis, clamped(ratio), normalizing(first), normalizing(second))
        }
    }

    private static func clamped(_ ratio: Double) -> Double {
        min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    // MARK: Inspection

    public var rootNode: Node {
        root
    }

    public var leafCount: Int {
        countLeaves(root)
    }

    private func countLeaves(_ node: Node) -> Int {
        switch node {
        case .leaf: 1
        case let .split(_, _, first, second): countLeaves(first) + countLeaves(second)
        }
    }

    public struct LeafInfo: Equatable, Sendable {
        public let paneID: PaneID
        public let content: PaneContent
    }

    public var leaves: [LeafInfo] {
        var result: [LeafInfo] = []
        collect(root, into: &result)
        return result
    }

    private func collect(_ node: Node, into result: inout [LeafInfo]) {
        switch node {
        case let .leaf(id, content):
            result.append(LeafInfo(paneID: id, content: content))
        case let .split(_, _, first, second):
            collect(first, into: &result)
            collect(second, into: &result)
        }
    }

    public func content(of paneID: PaneID) -> PaneContent? {
        leaves.first { $0.paneID == paneID }?.content
    }

    /// True if the given agent is currently visible in any leaf.
    public func contains(agent id: AgentID) -> Bool {
        leaves.contains { $0.content == .agent(id) }
    }

    // MARK: Mutation

    /// Replaces the content of one leaf. Returns the displaced content for the
    /// caller to park. If the new content is an agent already visible in another
    /// leaf, that other leaf is reset to `.placeholder` so an agent is never
    /// visible twice.
    public mutating func replacing(contentOf paneID: PaneID,
                                   with newContent: PaneContent) throws -> [DisplacedContent]
    {
        guard content(of: paneID) != nil else { throw LayoutError.paneNotFound }

        var displaced: [DisplacedContent] = []
        // Evict the same agent from any other leaf first.
        if case let .agent(newAgentID) = newContent {
            root = try evicting(agent: newAgentID, except: paneID, from: root, displaced: &displaced)
        }

        var replacedPrevious: PaneContent?
        root = try replacing(in: root, paneID: paneID, with: newContent, previous: &replacedPrevious)
        if let previous = replacedPrevious, previous != newContent {
            displaced.insert(DisplacedContent(paneID: paneID, previousContent: previous), at: 0)
        }
        return displaced
    }

    private func evicting(
        agent: AgentID,
        except keepPane: PaneID,
        from node: Node,
        displaced: inout [DisplacedContent]
    ) throws -> Node {
        switch node {
        case let .leaf(paneID, content):
            if case let .agent(existing) = content, existing == agent, paneID != keepPane {
                displaced.append(DisplacedContent(paneID: paneID, previousContent: content))
                return .leaf(paneID, .placeholder)
            }
            return node
        case let .split(axis, ratio, first, second):
            let newFirst = try evicting(agent: agent, except: keepPane, from: first, displaced: &displaced)
            let newSecond = try evicting(agent: agent, except: keepPane, from: second, displaced: &displaced)
            return .split(axis, ratio, newFirst, newSecond)
        }
    }

    private func replacing(
        in node: Node,
        paneID: PaneID,
        with newContent: PaneContent,
        previous: inout PaneContent?
    ) throws -> Node {
        switch node {
        case let .leaf(id, content):
            guard id == paneID else { return node }
            previous = content
            return .leaf(id, newContent)
        case let .split(axis, ratio, first, second):
            return try .split(
                axis,
                ratio,
                replacing(in: first, paneID: paneID, with: newContent, previous: &previous),
                replacing(in: second, paneID: paneID, with: newContent, previous: &previous)
            )
        }
    }

    /// Splits a leaf in two, inserting `newContent` in the new half — except
    /// when `newContent` is the agent already shown in that leaf, in which case
    /// the new half is `.placeholder` (an agent is never visible twice, §3.3).
    /// Throws when the four-leaf cap would be exceeded. Returns displaced
    /// content (including any duplicate-agent eviction).
    public mutating func splitting(
        paneID: PaneID,
        axis: SplitAxis,
        ratio: Double,
        newContent: PaneContent
    ) throws -> [DisplacedContent] {
        guard content(of: paneID) != nil else { throw LayoutError.paneNotFound }
        guard leafCount < Self.maxLeaves else { throw LayoutError.tooManyLeaves }
        precondition(Self.ratioRange.contains(Self.clamped(ratio)))

        var displaced: [DisplacedContent] = []
        if case let .agent(newAgentID) = newContent {
            root = try evicting(agent: newAgentID, except: paneID, from: root, displaced: &displaced)
        }

        root = try splitting(in: root, paneID: paneID, axis: axis, ratio: Self.clamped(ratio), newContent: newContent)
        return displaced
    }

    private func splitting(
        in node: Node,
        paneID: PaneID,
        axis: SplitAxis,
        ratio: Double,
        newContent: PaneContent
    ) throws -> Node {
        switch node {
        case let .leaf(id, content):
            guard id == paneID else { return node }
            // Splitting a leaf with its own agent as the incoming content must
            // never show that agent twice (§3.3). The new half becomes empty.
            var inserted = newContent
            if case let .agent(existing) = content, case let .agent(newAgent) = newContent, existing == newAgent {
                inserted = .placeholder
            }
            return .split(axis, ratio, .leaf(id, content), .leaf(PaneID(), inserted))
        case let .split(splitAxis, splitRatio, first, second):
            return try .split(
                splitAxis,
                splitRatio,
                splitting(in: first, paneID: paneID, axis: axis, ratio: ratio, newContent: newContent),
                splitting(in: second, paneID: paneID, axis: axis, ratio: ratio, newContent: newContent)
            )
        }
    }

    /// Removes a leaf by collapsing its parent split into the sibling subtree.
    /// Refuses to remove the last remaining leaf.
    public mutating func removing(paneID: PaneID) throws {
        guard content(of: paneID) != nil else { throw LayoutError.paneNotFound }
        guard leafCount > 1 else { return }
        root = try removing(in: root, paneID: paneID)
    }

    private func removing(in node: Node, paneID: PaneID) throws -> Node {
        switch node {
        case .leaf:
            return node
        case let .split(axis, ratio, first, second):
            if case let .leaf(id, _) = first, id == paneID {
                return second
            }
            if case let .leaf(id, _) = second, id == paneID {
                return first
            }
            return try .split(
                axis,
                ratio,
                removing(in: first, paneID: paneID),
                removing(in: second, paneID: paneID)
            )
        }
    }
}

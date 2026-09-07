import AgentCore

// Pure Next Attention semantics (§3.4 priority/age ordering, §6.10 gate):
// ⌘⇧U cycles ONLY attention-flagged rows, ordered by
// inputRequired > failure > completionUnread, oldest attentionSince first
// within a group, wrapping after the last entry.
//
// Deliberately pure: no AppKit, no model — unit tests drive the §6.10
// eight-agent gate directly, and AppCommands.nextAttention only projects the
// live AppModel into `targets(attentionByItem:)` before calling `next`.

/// One attention-flagged row projected for navigation decisions.
struct AttentionTarget: Equatable {
    let item: SidebarItem
    let rank: Int
    let since: MonotonicInstant
}

enum AttentionNavigator {
    /// Builds the ordered attention queue from a typed attention map.
    /// Rows with `.none` attention never enter the queue.
    static func targets(attentionByItem: [SidebarItem: AttentionState]) -> [AttentionTarget] {
        attentionByItem.compactMap { item, state -> AttentionTarget? in
            guard state != .none, let since = state.since else { return nil }
            return AttentionTarget(item: item, rank: state.rank, since: since)
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank > rhs.rank
            } // priority beats age
            if lhs.since != rhs.since {
                return lhs.since < rhs.since
            } // oldest first
            return lhs.item.sortKey < rhs.item.sortKey // stable tiebreak
        }
    }

    /// The next target when cycling from `current` (the currently focused
    /// item, `nil` when nothing is focused or the focus is not flagged).
    /// Wraps: the entry after the last one is the first one again.
    static func next(after current: SidebarItem?, in targets: [AttentionTarget]) -> AttentionTarget? {
        guard !targets.isEmpty else { return nil }
        guard let current,
              let index = targets.firstIndex(where: { $0.item == current })
        else {
            return targets[0]
        }
        return targets[(index + 1) % targets.count]
    }
}

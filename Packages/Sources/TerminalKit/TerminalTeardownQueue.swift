import Foundation

// Two-phase safe free (architecture §3.8 teardown, ADR-0002 policy):
//
//   phase 1 (enqueue): mark closing → drop callbacks → reject commands
//   phase 2 (next main-runloop cycle): native free in a confirmed main-thread
//   context, then release the retained callback box, then run completion.
//
// One surface frees per runloop tick; the queue never frees off the main
// thread and never re-enters a target already closing.

@MainActor public protocol TerminalTeardownTarget: AnyObject {
    /// Phase-1 marker; must reject all new commands while true.
    var isClosing: Bool { get }
    func beginTeardown()
    /// Native free; main thread only, exactly once, strictly after
    /// `beginTeardown`.
    func performNativeFree()
}

@MainActor public final class TerminalTeardownQueue {
    struct Entry {
        let target: any TerminalTeardownTarget
        let completion: (@MainActor () -> Void)?
    }

    private var pending: [Entry] = []
    public private(set) var isDraining = false
    /// Number of targets whose native free completed through this queue.
    public private(set) var completedCount = 0

    public init() {}

    /// Enqueues a target for teardown. Idempotent: a target already closing is
    /// ignored. Phase 1 runs synchronously here; the caller may treat the
    /// target as dead immediately afterwards.
    public func enqueue(
        _ target: any TerminalTeardownTarget,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard !target.isClosing else { return } // rejected: already tearing down
        pending.append(Entry(target: target, completion: completion))
        // Phase 1: disable callbacks/commands before anything else can touch it.
        target.beginTeardown()
        pumpIfNeeded()
    }

    public var pendingCount: Int {
        pending.count
    }

    private func pumpIfNeeded() {
        guard !isDraining, !pending.isEmpty else { return }
        isDraining = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.freeNext()
            }
        }
    }

    private func freeNext() {
        guard let entry = pending.first else {
            isDraining = false
            return
        }
        pending.removeFirst()
        // Phase 2: confirmed main-thread context.
        entry.target.performNativeFree()
        completedCount += 1
        entry.completion?()
        if pending.isEmpty {
            isDraining = false
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.freeNext()
                }
            }
        }
    }

    /// Test hook: synchronously drains everything pending on the current main
    /// runloop iteration semantics without waiting for async hops.
    public func drainForTesting() {
        while !pending.isEmpty {
            if let entry = pending.first {
                pending.removeFirst()
                entry.target.performNativeFree()
                completedCount += 1
                entry.completion?()
            }
        }
        isDraining = false
    }
}

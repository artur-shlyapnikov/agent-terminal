import Foundation

// Domain-wide monotonic instant. Deliberately NOT MonotonicInstant:
// the domain needs a trivially constructible, deterministic value that tests
// can mint from a FakeClock without touching real system time.

public struct MonotonicInstant: Hashable, Comparable, Sendable {
    public var nanosecondsSinceEpoch: Int64

    public init(nanosecondsSinceEpoch: Int64) {
        self.nanosecondsSinceEpoch = nanosecondsSinceEpoch
    }

    public static let zero = MonotonicInstant(nanosecondsSinceEpoch: 0)

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanosecondsSinceEpoch < rhs.nanosecondsSinceEpoch
    }

    public static func + (lhs: MonotonicInstant, rhs: Duration) -> MonotonicInstant {
        MonotonicInstant(nanosecondsSinceEpoch: lhs.nanosecondsSinceEpoch + nanoseconds(of: rhs))
    }

    public static func - (lhs: MonotonicInstant, rhs: Duration) -> MonotonicInstant {
        MonotonicInstant(nanosecondsSinceEpoch: lhs.nanosecondsSinceEpoch - nanoseconds(of: rhs))
    }

    /// Interval between two instants (rhs earlier than lhs gives positive).
    public static func - (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Duration {
        .nanoseconds(lhs.nanosecondsSinceEpoch - rhs.nanosecondsSinceEpoch)
    }

    public func advanced(by duration: Duration) -> MonotonicInstant {
        self + duration
    }

    static func nanoseconds(of duration: Duration) -> Int64 {
        let components = duration.components
        return Int64(components.seconds) &* 1_000_000_000
            &+ Int64(components.attoseconds / 1_000_000_000)
    }
}

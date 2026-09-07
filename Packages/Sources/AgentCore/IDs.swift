import Foundation

// Typed identifiers (architecture §3.3).
//
// Every domain identifier is a distinct UUID-wrapper type so that a TerminalID
// can never be passed where an AgentID is expected. SurfaceGeneration is a
// monotonic UInt64 wrapper: restart/resume always mints a fresh generation and
// every late observation from an older generation is discarded.

public protocol TypedIdentifier: Hashable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension TypedIdentifier {
    init() {
        self.init(rawValue: UUID())
    }

    init(_ rawValue: UUID) {
        self.init(rawValue: rawValue)
    }

    static func random() -> Self {
        Self(rawValue: UUID())
    }

    var description: String {
        rawValue.uuidString
    }
}

public struct WorkspaceID: TypedIdentifier, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct AgentID: TypedIdentifier, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct TerminalID: TypedIdentifier, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct PaneID: TypedIdentifier, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct RuntimeEventID: TypedIdentifier, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct CommandID: TypedIdentifier, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Monotonic surface generation. Restart or resume creates a new generation;
/// observations carrying an older generation are stale by definition (§3.6).
public struct SurfaceGeneration: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let initial = SurfaceGeneration(rawValue: 0)

    public static func < (lhs: SurfaceGeneration, rhs: SurfaceGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func successor() -> SurfaceGeneration {
        SurfaceGeneration(rawValue: rawValue + 1)
    }

    public var description: String {
        "#\(rawValue)"
    }
}

/// Version marker consumed by the other package modules' smoke suites.
public enum AgentCoreInfo {
    public static let version = "0.1.0"
}

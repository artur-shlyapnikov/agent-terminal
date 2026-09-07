import Foundation

// Control protocol versioning (architecture §3.16).
//
// Policy:
// - every envelope carries `protocolVersion` and it is mandatory;
// - the server interprets a request ONLY when the version matches exactly;
// - mismatch → structured `unsupportedProtocolVersion` rejection listing the
//   supported versions; there is no fallback interpretation and no best-effort
//   decoding of unknown versions (docs/Protocols/control-v1.md §Versioning).
//
// Additive changes within v1 keep this constant at 1 and MUST be limited to
// optional result fields that old clients ignore. Any breaking change bumps
// to 2 and ships alongside a deprecation window for 1.

public enum ProtocolVersion {
    /// The current wire version.
    public static let current: Int = 1

    /// Every version this build can interpret without translation.
    public static let supported: [Int] = [1]

    public static func isSupported(_ version: Int) -> Bool {
        supported.contains(version)
    }

    /// Validates an inbound request's protocol version.
    /// - Throws: `ControlFailure.unsupportedProtocolVersion` on any mismatch.
    public static func validate(_ version: Int) throws {
        guard isSupported(version) else {
            throw ControlFailure(
                code: .unsupportedProtocolVersion,
                message: "unsupported protocolVersion \(version); supported: \(supported.map(String.init).joined(separator: ", "))"
            )
        }
    }
}

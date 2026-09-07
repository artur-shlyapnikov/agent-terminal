import Foundation

/// Canonical filesystem locations shared across modules (architecture §4.x).
///
/// Every module resolved Application Support independently, three of them by
/// force-unwrapping the lookup result. This is the single guarded definition.
public enum AppPaths {
    /// Application Support container for AgentTerminal.
    ///
    /// The API returns a one-element array on every Apple platform; the guard
    /// converts a hypothetical empty result into an explicit, named crash at
    /// startup instead of an uncontrolled unwrap deep in feature code.
    public static func applicationSupport() -> URL {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            preconditionFailure("Application Support directory is unavailable on this system")
        }
        return base
    }
}

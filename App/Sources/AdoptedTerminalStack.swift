import AgentCore
import Foundation
import TerminalKit

// Adopted-terminal-stack value (§3.18): a pre-built TerminalKit stack that
// an embedding entry point constructs BEFORE the full application shell and
// hands to AppCompositionRoot(adopting:). Production ships only this value
// type; the spawning half of the old bootstrap (spawnShells/pending) lives
// in the ACCEPTANCE target — scenario sources no longer compile into the
// shipping app.

@MainActor
struct AdoptedTerminalStack {
    let engine: GhosttyEngine
    let parkingHost: TerminalParkingHost
    let sessionManager: TerminalSessionManager
    let sessions: [TerminalSession]
}

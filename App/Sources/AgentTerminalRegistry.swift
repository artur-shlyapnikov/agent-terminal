import AgentCore
import Foundation

// App-side registry of the (agent → terminal, surface generation) binding.
// The composition root performs every launch and every restart, so it owns
// this mapping; it feeds the detection pipeline (which needs terminalID +
// generation for observation envelopes), the seam (foreground pid lookups)
// and the control plane's workspace mirror.

struct AgentBinding {
    var terminalID: TerminalID
    var surfaceGeneration: SurfaceGeneration
    var kind: AgentKind
    var displayName: String
    var cwd: String

    /// The runtime's own generation counter is authoritative; the app-side
    /// successor computation must match `AgentRuntime.restart` exactly.
    var nextGeneration: SurfaceGeneration {
        surfaceGeneration.successor()
    }
}

@MainActor
final class AgentTerminalRegistry: ObservableObject {
    private(set) var bindings: [AgentID: AgentBinding] = [:]
    private(set) var agentByTerminal: [TerminalID: AgentID] = [:]

    func bind(agentID: AgentID, to binding: AgentBinding) {
        // Sweep EVERY reverse mapping for this agent before installing the
        // new one: a bind-before-rebind race (observer installed the new
        // terminal while the old binding is still live) must retire the
        // stale terminal, mirroring rebind/remove.
        agentByTerminal = agentByTerminal.filter { $0.value != agentID }
        bindings[agentID] = binding
        agentByTerminal[binding.terminalID] = agentID
        objectWillChange.send()
    }

    /// Restart cutover: old terminal unbinds, new one takes over with the
    /// successor generation (§3.5 "Surface generation changed").
    /// The sweep removes every stale mapping for this agent, covering the
    /// bind-before-rebind race where an observer already installed the new
    /// terminal before this call runs.
    func rebind(agentID: AgentID, newTerminalID: TerminalID, generation: SurfaceGeneration) {
        guard var binding = bindings[agentID] else { return }
        agentByTerminal = agentByTerminal.filter { $0.value != agentID }
        binding.terminalID = newTerminalID
        binding.surfaceGeneration = generation
        bindings[agentID] = binding
        agentByTerminal[newTerminalID] = agentID
        objectWillChange.send()
    }

    func remove(agentID: AgentID) {
        // Sweep EVERY reverse mapping for this agent, not just the current
        // binding's terminal: the original bind installed the old terminal
        // and a spawn-time bindAndSpawn may already have installed a
        // successor before a failure path removes the binding — both
        // surfaces retire together, so both mappings must go.
        agentByTerminal = agentByTerminal.filter { $0.value != agentID }
        bindings[agentID] = nil
        objectWillChange.send()
    }

    func binding(for agentID: AgentID) -> AgentBinding? {
        bindings[agentID]
    }

    func agentID(for terminalID: TerminalID) -> AgentID? {
        agentByTerminal[terminalID]
    }

    var trackedTerminals: [TerminalID] {
        Array(agentByTerminal.keys)
    }
}

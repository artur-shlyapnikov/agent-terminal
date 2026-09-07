@testable import AgentCore
import Foundation
import XCTest

// Shared deterministic fixtures for the AgentCore suite.

func instant(_ milliseconds: Int64) -> MonotonicInstant {
    MonotonicInstant(nanosecondsSinceEpoch: milliseconds * 1_000_000)
}

func makeEnvelope(
    agent: AgentID,
    sourceKind: EvidenceSource,
    sourceID: String = "screen",
    sequence: UInt64? = nil,
    outputRevision: UInt64? = nil,
    generation: SurfaceGeneration = .initial,
    terminal: TerminalID? = nil,
    receivedAt: MonotonicInstant,
    observedAt: MonotonicInstant? = nil
) -> ObservationEnvelope {
    ObservationEnvelope(
        agentID: agent,
        terminalID: terminal,
        surfaceGeneration: generation,
        sourceID: sourceID,
        sourceKind: sourceKind,
        sequence: sequence,
        outputRevision: outputRevision,
        observedAt: observedAt ?? receivedAt,
        receivedAt: receivedAt
    )
}

func screenEvidence(
    agent: AgentID,
    lifecycle: LifecyclePhase,
    receivedAt: MonotonicInstant,
    outputRevision: UInt64? = nil,
    generation: SurfaceGeneration = .initial,
    matchedRuleID: String = "rule",
    conflicting: [String] = []
) -> Evidence {
    Evidence(
        envelope: makeEnvelope(
            agent: agent,
            sourceKind: .screen,
            outputRevision: outputRevision,
            generation: generation,
            receivedAt: receivedAt
        ),
        payload: .screen(ScreenEvidencePayload(
            matchedRuleID: conflicting.isEmpty ? matchedRuleID : nil,
            resultingLifecycle: lifecycle,
            supportingRules: [matchedRuleID],
            conflictingRules: conflicting
        ))
    )
}

func integrationEvidence(
    agent: AgentID,
    lifecycle: LifecyclePhase,
    sourceID: String = "hook:test",
    sequence: UInt64,
    receivedAt: MonotonicInstant,
    observedAt: MonotonicInstant? = nil,
    generation: SurfaceGeneration = .initial
) -> Evidence {
    Evidence(
        envelope: makeEnvelope(
            agent: agent,
            sourceKind: .integration,
            sourceID: sourceID,
            sequence: sequence,
            generation: generation,
            receivedAt: receivedAt,
            observedAt: observedAt
        ),
        payload: .integrationLifecycle(lifecycle)
    )
}

func processEvidence(agent: AgentID, receivedAt: MonotonicInstant) -> Evidence {
    Evidence(
        envelope: makeEnvelope(
            agent: agent,
            sourceKind: .process,
            sourceID: "process",
            receivedAt: receivedAt
        ),
        payload: .process(ProcessEvidencePayload(
            executablePath: "/usr/local/bin/claude",
            executableName: "claude",
            pid: 4242,
            matchesForegroundExecutables: true
        ))
    )
}

/// Records everything the runtime asks the terminal layer to do.
final class FakeTerminalPort: TerminalControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var deliveredTexts: [(TerminalID, String, Bool)] = []
    private(set) var sentSignals: [(TerminalID, SignalIntent)] = []
    private(set) var sentKeySequences: [(TerminalID, [String])] = []
    private(set) var snapshots: [TerminalSnapshot] = []

    var deliverInputCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return deliveredTexts.count
    }

    func deliverInput(_ terminalID: TerminalID, text: String, submit: Bool) async throws {
        lock.withLock { deliveredTexts.append((terminalID, text, submit)) }
    }

    func sendKeys(_ terminalID: TerminalID, keys: [String]) async throws {
        lock.withLock { sentKeySequences.append((terminalID, keys)) }
    }

    func sendSignal(_ intent: SignalIntent, to terminalID: TerminalID) async throws {
        lock.withLock { sentSignals.append((terminalID, intent)) }
    }

    func read(_: TerminalID, source _: TerminalReadSource) async throws -> TerminalSnapshot? {
        lock.withLock { snapshots.last }
    }

    func signalIntents() -> [SignalIntent] {
        lock.lock(); defer { lock.unlock() }
        return sentSignals.map(\.1)
    }
}

extension AgentRuntime {
    /// Creates a workspace + running agent with an attached surface.
    func makeRunningAgent(
        kind: AgentKind = .claudeCode,
        generation: SurfaceGeneration = .initial
    ) async throws -> (workspace: WorkspaceID, agent: AgentID, terminal: TerminalID) {
        let workspaceID = createWorkspace(name: "test", rootPath: "/tmp/test")
        let agentID = try await createAgent(
            AgentLaunchRequest(agentKind: kind, workingDirectory: "/tmp/test", displayName: "agent"),
            in: workspaceID
        )
        let terminalID = TerminalID()
        try await surfaceCreated(
            agentID: agentID,
            terminalID: terminalID,
            generation: generation,
            pid: 1000,
            processGroupID: 1000
        )
        return (workspaceID, agentID, terminalID)
    }
}

func waitingPhase(_ kind: InputRequestKind = .approval) -> LifecyclePhase {
    .waitingForInput(InputRequestDescriptor(
        kind: kind,
        summary: nil,
        safeReplyMode: .terminalOnly,
        source: .screen
    ))
}

/// Polls with 1 ms real sleeps until the condition holds — deterministic in
/// virtual time, generous to the cooperative pool.
func eventually(
    _ message: @autoclosure () -> String = "condition not reached",
    maxMilliseconds: Int = 5000,
    _ condition: () async -> Bool
) async {
    for _ in 0 ..< maxMilliseconds {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail(message())
}

import AgentCore
import Foundation
import GRDB

// DB record mappings for AgentCore domain types (architecture §4.4).
//
// Persistence rules (§3.14/§5.2):
// - launch_descriptor_json / session_ref_json hold adapter-owned NON-SECRET
//   data only; prompts, terminal output, raw environment and clipboard are
//   never persisted;
// - the layout JSON carries its own schemaVersion; unknown layout nodes
//   decode to placeholders while the original bytes are preserved;
// - timestamps are stored as REAL seconds. Domain instants (MonotonicInstant)
//   round-trip losslessly as seconds-with-fraction so restores stay exact.

enum PersistenceTime {
    static func real(_ instant: MonotonicInstant) -> Double {
        Double(instant.nanosecondsSinceEpoch) / 1_000_000_000
    }

    static func monotonic(_ real: Double) -> MonotonicInstant {
        // SQLite REAL columns can hold ±Inf, NaN or corrupt magnitudes;
        // initializing Int64 from such doubles traps and would kill the whole
        // timeline read. Degrade to .zero instead (per-row skip, §3.14).
        let ns = (real * 1_000_000_000).rounded()
        guard real.isFinite, real >= 0, ns.isFinite, ns <= Double(Int64.max)
        else { return MonotonicInstant(nanosecondsSinceEpoch: 0) }
        return MonotonicInstant(nanosecondsSinceEpoch: Int64(ns))
    }
}

// MARK: - Workspace

struct WorkspaceRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "workspaces"

    var id: String
    var name: String
    var rootPath: String
    var sortIndex: Int
    var createdAt: Double
    var updatedAt: Double
    var archivedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, name
        case rootPath = "root_path"
        case sortIndex = "sort_index"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }
}

extension Workspace {
    /// Row projection; `sortIndex` orders workspaces in the sidebar.
    func row(sortIndex: Int) -> WorkspaceRow {
        WorkspaceRow(
            id: id.rawValue.uuidString,
            name: name,
            rootPath: rootPath,
            sortIndex: sortIndex,
            createdAt: PersistenceTime.real(createdAt),
            updatedAt: PersistenceTime.real(updatedAt),
            archivedAt: nil
        )
    }

    /// Rebuilds the domain value. `agentOrder` is not a column of §3.14's
    /// workspaces table; the repository derives it from agent creation order.
    static func restoring(
        _ row: WorkspaceRow,
        agentOrder: [AgentID],
        layout: LayoutTree,
        selectedAgentID: AgentID?
    ) -> Workspace? {
        guard let id = UUID(uuidString: row.id) else { return nil }
        return Workspace(
            id: WorkspaceID(rawValue: id),
            name: row.name,
            rootPath: row.rootPath,
            agentOrder: agentOrder,
            layout: layout,
            selectedAgentID: selectedAgentID,
            createdAt: PersistenceTime.monotonic(row.createdAt),
            updatedAt: PersistenceTime.monotonic(row.updatedAt)
        )
    }
}

// MARK: - Terminal

struct TerminalRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "terminals"

    var id: String
    var workspaceID: String
    var agentID: String?
    var cwd: String
    var lastRuntimeStatus: String
    var lastExitCode: Int64?
    var lastExitAt: Double?
    var createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case agentID = "agent_id"
        case cwd
        case lastRuntimeStatus = "last_runtime_status"
        case lastExitCode = "last_exit_code"
        case lastExitAt = "last_exit_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Coarse runtime-status token for terminals.last_runtime_status.
enum RuntimeStatusToken: String {
    case notStarted = "not_started"
    case launching
    case running
    case exiting
    case exited
    case launchFailed = "launch_failed"

    init(phase: ProcessPhase) {
        switch phase {
        case .notStarted: self = .notStarted
        case .launching: self = .launching
        case .running: self = .running
        case .exiting: self = .exiting
        case .exited: self = .exited
        case .launchFailed: self = .launchFailed
        }
    }
}

extension TerminalSession {
    /// `exitAt` carries the wall-clock instant captured when the process phase
    /// became `.exited` (set by TerminalSessionManager); it must stay stable
    /// across re-saves, so a nil falls back to `now` only as a last resort.
    func row(now: Double, exitAt: Double? = nil) -> TerminalRow {
        let exit: (code: Int32?, at: Double?)? = if case let .exited(code, _, _) = processPhase {
            (code, exitAt ?? now)
        } else {
            nil
        }
        return TerminalRow(
            id: id.rawValue.uuidString,
            workspaceID: workspaceID.rawValue.uuidString,
            agentID: agentID?.rawValue.uuidString,
            cwd: cwd,
            lastRuntimeStatus: RuntimeStatusToken(phase: processPhase).rawValue,
            lastExitCode: exit.flatMap { $0.code.map(Int64.init) },
            lastExitAt: exit?.at,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Restores persisted metadata only: surface generation, presentation and
    /// output revision are ephemeral runtime state (§3.3) and come back as
    /// defaults — TerminalKit remints them.
    static func restoring(_ row: TerminalRow) -> TerminalSession? {
        guard let id = UUID(uuidString: row.id),
              let wsID = UUID(uuidString: row.workspaceID)
        else { return nil }
        let status = RuntimeStatusToken(rawValue: row.lastRuntimeStatus) ?? .notStarted
        let phase: ProcessPhase = switch status {
        case .notStarted: .notStarted
        case .launching: .launching
        case .running: .running(pid: nil, processGroupID: nil)
        case .exiting: .exiting
        case .exited:
            .exited(exitCode: row.lastExitCode.map(Int32.init), signal: nil, userInitiated: false)
        case .launchFailed: .launchFailed(errorDescriptor: "restored")
        }
        return TerminalSession(
            id: TerminalID(rawValue: id),
            workspaceID: WorkspaceID(rawValue: wsID),
            agentID: row.agentID.flatMap { UUID(uuidString: $0) }.map(AgentID.init(rawValue:)),
            cwd: row.cwd,
            processPhase: phase,
            exitAt: row.lastExitAt
        )
    }
}

// MARK: - Agent

struct AgentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "agents"

    var id: String
    var workspaceID: String
    var terminalID: String?
    var kind: String
    var displayName: String
    var taskSummary: String?
    var cwd: String
    var launchDescriptorJSON: Data
    var resumePolicy: String
    var sessionRefJSON: Data?
    var lastLifecycle: String
    var lastAttention: String
    var lastStateRevision: UInt64
    var lastActivityAt: Double?
    var resumeRequested: Bool
    var createdAt: Double
    var updatedAt: Double
    var archivedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case terminalID = "terminal_id"
        case kind
        case displayName = "display_name"
        case taskSummary = "task_summary"
        case cwd
        case launchDescriptorJSON = "launch_descriptor_json"
        case resumePolicy = "resume_policy"
        case sessionRefJSON = "session_ref_json"
        case lastLifecycle = "last_lifecycle"
        case lastAttention = "last_attention"
        case lastStateRevision = "last_state_revision"
        case lastActivityAt = "last_activity_at"
        case resumeRequested = "resume_requested"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }
}

/// Coarse lifecycle token stored in agents.last_lifecycle. Parameterized
/// phases keep only their identity; the full detail lives in the event
/// timeline, never in prompt/output form.
enum LifecycleToken: String {
    case unknown
    case starting
    case idle
    case working
    case waitingForInput = "waiting_for_input"
    case stopping
    case stoppedUserRequested = "stopped_user_requested"
    case stoppedCompleted = "stopped_completed"
    case failed

    init(phase: LifecyclePhase) {
        switch phase {
        case .unknown: self = .unknown
        case .starting: self = .starting
        case .idle: self = .idle
        case .working: self = .working
        case .waitingForInput: self = .waitingForInput
        case .stopping: self = .stopping
        case .stopped(.userRequested): self = .stoppedUserRequested
        case .stopped(.completed): self = .stoppedCompleted
        case .failed: self = .failed
        }
    }

    /// Unparameterized phases restore exactly; parameterized ones restore to
    /// `.unknown` because their payload is deliberately not persisted.
    var restored: LifecyclePhase {
        switch self {
        case .unknown: .unknown
        case .starting: .starting
        case .idle: .idle
        case .working: .working
        case .waitingForInput, .stopping, .failed: .unknown
        case .stoppedUserRequested: .stopped(.userRequested)
        case .stoppedCompleted: .stopped(.completed)
        }
    }
}

/// Coarse attention token stored in agents.last_attention. Attention detail
/// (since/event/request ids) is presentation state and not persisted.
enum AttentionToken: String {
    case none
    case completionUnread = "completion_unread"
    case inputRequired = "input_required"
    case failure

    init(state: AttentionState) {
        switch state {
        case .none: self = .none
        case .completionUnread: self = .completionUnread
        case .inputRequired: self = .inputRequired
        case .failure: self = .failure
        }
    }
}

private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()

extension AgentSession {
    func row(now: Double) throws -> AgentRow {
        try AgentRow(
            id: id.rawValue.uuidString,
            workspaceID: workspaceID.rawValue.uuidString,
            terminalID: terminalID?.rawValue.uuidString,
            kind: kind.rawValue,
            displayName: displayName,
            taskSummary: taskSummary,
            cwd: cwd,
            launchDescriptorJSON: jsonEncoder.encode(launchDescriptor),
            resumePolicy: resumePolicy.rawValue,
            sessionRefJSON: sessionReference.map { try jsonEncoder.encode($0) },
            lastLifecycle: LifecycleToken(phase: state.lifecycle).rawValue,
            lastAttention: AttentionToken(state: state.attention).rawValue,
            lastStateRevision: state.revision,
            lastActivityAt: PersistenceTime.real(lastActivityAt),
            resumeRequested: false,
            createdAt: PersistenceTime.real(createdAt),
            updatedAt: now,
            archivedAt: nil
        )
    }

    /// Restores what §3.14 persists. Queued prompts and active turns are
    /// never persisted (§3.11) and always come back nil; lifecycle phases
    /// whose payloads were dropped restore to `.unknown`.
    static func restoring(_ row: AgentRow) -> AgentSession? {
        guard let id = UUID(uuidString: row.id),
              let wsID = UUID(uuidString: row.workspaceID),
              let kind = AgentKind(rawValue: row.kind)
        else { return nil }
        guard let descriptor = try? jsonDecoder.decode(LaunchDescriptor.self, from: row.launchDescriptorJSON)
        else { return nil }

        let lifecycle = (LifecycleToken(rawValue: row.lastLifecycle) ?? .unknown).restored
        let state = AgentState(
            lifecycle: lifecycle,
            authority: .unknown,
            revision: row.lastStateRevision,
            observedAt: row.lastActivityAt.map(PersistenceTime.monotonic) ?? .zero
        )

        return AgentSession(
            id: AgentID(rawValue: id),
            workspaceID: WorkspaceID(rawValue: wsID),
            terminalID: row.terminalID.flatMap { UUID(uuidString: $0) }.map(TerminalID.init(rawValue:)),
            kind: kind,
            displayName: row.displayName,
            taskSummary: row.taskSummary,
            cwd: row.cwd,
            launchDescriptor: descriptor,
            resumePolicy: ResumePolicy(rawValue: row.resumePolicy) ?? .manual,
            sessionReference: row.sessionRefJSON.flatMap { try? jsonDecoder.decode(SessionReference.self, from: $0) },
            state: state,
            createdAt: PersistenceTime.monotonic(row.createdAt),
            lastActivityAt: row.lastActivityAt.map(PersistenceTime.monotonic) ?? .zero
        )
    }
}

// MARK: - Layout

struct LayoutRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "layouts"

    var workspaceID: String
    var schemaVersion: Int
    var treeJSON: Data
    var selectedAgentID: String?
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case schemaVersion = "schema_version"
        case treeJSON = "tree_json"
        case selectedAgentID = "selected_agent_id"
        case updatedAt = "updated_at"
    }
}

/// JSON codec for LayoutTree with its own schemaVersion (§5.2).
///
/// Unknown node or content tags decode to `.placeholder` leaves instead of
/// failing; the caller preserves the original bytes (backup rule, §5.2).
public enum LayoutCodec {
    public static let schemaVersion = 1

    enum CodingError: Error {
        case malformed
    }

    private final class NodeDTO: Codable {
        var type: String
        var pane: String?
        var content: ContentDTO?
        var axis: String?
        var ratio: Double?
        var first: NodeDTO?
        var second: NodeDTO?

        init(
            type: String,
            pane: String?,
            content: ContentDTO?,
            axis: String?,
            ratio: Double?,
            first: NodeDTO?,
            second: NodeDTO?
        ) {
            self.type = type
            self.pane = pane
            self.content = content
            self.axis = axis
            self.ratio = ratio
            self.first = first
            self.second = second
        }
    }

    private struct ContentDTO: Codable {
        var type: String
        var id: String?
    }

    private struct DocumentDTO: Codable {
        var schemaVersion: Int
        var root: NodeDTO
    }

    public struct DecodedLayout: Equatable {
        public var tree: LayoutTree
        /// Nodes replaced by placeholders during decode (§5.2 rule).
        public var unknownNodeCount: Int
        /// Original encoded bytes, preserved verbatim for backup.
        public var originalJSON: Data
    }

    /// Throwing on purpose (§5.2): an encoding failure must never persist
    /// empty bytes over a good layout row.
    public static func encode(_ tree: LayoutTree) throws -> Data {
        func nodeDTO(_ node: LayoutTree.Node) -> NodeDTO {
            switch node {
            case let .leaf(pane, content):
                let contentDTO = switch content {
                case let .agent(id): ContentDTO(type: "agent", id: id.rawValue.uuidString)
                case let .terminal(id): ContentDTO(type: "terminal", id: id.rawValue.uuidString)
                case .placeholder: ContentDTO(type: "placeholder", id: nil)
                }
                return NodeDTO(
                    type: "leaf",
                    pane: pane.rawValue.uuidString,
                    content: contentDTO,
                    axis: nil, ratio: nil, first: nil, second: nil
                )
            case let .split(axis, ratio, first, second):
                return NodeDTO(
                    type: "split",
                    pane: nil,
                    content: nil,
                    axis: axis == .horizontal ? "horizontal" : "vertical",
                    ratio: ratio,
                    first: nodeDTO(first),
                    second: nodeDTO(second)
                )
            }
        }
        let document = DocumentDTO(schemaVersion: schemaVersion, root: nodeDTO(tree.rootNode))
        return try JSONEncoder().encode(document)
    }

    public static func decode(_ data: Data) throws -> DecodedLayout {
        let document: DocumentDTO
        do {
            document = try JSONDecoder().decode(DocumentDTO.self, from: data)
        } catch {
            throw CodingError.malformed
        }

        var unknownCount = 0

        func content(from dto: ContentDTO?) -> PaneContent {
            switch dto?.type {
            case "agent":
                if let uuid = dto?.id.flatMap(UUID.init(uuidString:)) {
                    return .agent(AgentID(rawValue: uuid))
                }
            case "terminal":
                if let uuid = dto?.id.flatMap(UUID.init(uuidString:)) {
                    return .terminal(TerminalID(rawValue: uuid))
                }
            case "placeholder":
                return .placeholder
            default:
                break
            }
            unknownCount += 1
            return .placeholder
        }

        func node(from dto: NodeDTO) -> LayoutTree.Node {
            switch dto.type {
            case "leaf":
                let pane = dto.pane.flatMap(UUID.init(uuidString:)).map(PaneID.init(rawValue:)) ?? PaneID()
                return .leaf(pane, content(from: dto.content))
            case "split" where dto.axis == "vertical" || dto.axis == "horizontal":
                let axis = dto.axis == "vertical" ? SplitAxis.vertical : .horizontal
                let ratio = min(
                    max(dto.ratio ?? 0.5, LayoutTree.ratioRange.lowerBound),
                    LayoutTree.ratioRange.upperBound
                )
                return .split(axis, ratio, node(from: dto.first ?? fallback), node(from: dto.second ?? fallback))
            default:
                // §5.2: an unrecognized layout node becomes a placeholder.
                unknownCount += 1
                return .leaf(PaneID(), .placeholder)
            }
        }
        let fallback = NodeDTO(
            type: "__invalid__",
            pane: nil,
            content: nil,
            axis: nil,
            ratio: nil,
            first: nil,
            second: nil
        )

        return DecodedLayout(
            tree: LayoutTree(root: node(from: document.root)),
            unknownNodeCount: unknownCount,
            originalJSON: data
        )
    }
}

// MARK: - Events

struct EventRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "agent_events"

    var id: Int64?
    var agentID: String
    var revision: UInt64
    var kind: String
    var source: String
    var payloadJSON: Data
    var createdAt: Double
    var seenAt: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case agentID = "agent_id"
        case revision
        case kind
        case source
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
        case seenAt = "seen_at"
    }
}

/// One restored timeline entry with its commit revision.
public struct StoredTimelineEvent: Equatable, Sendable {
    public var rowID: Int64?
    public var event: TimelineEvent
    public var revision: UInt64
    public var seenAt: Date?

    public init(rowID: Int64?, event: TimelineEvent, revision: UInt64, seenAt: Date?) {
        self.rowID = rowID
        self.event = event
        self.revision = revision
        self.seenAt = seenAt
    }
}

/// Bidirectional mapping between `AgentEvent` and the §3.14 columns
/// (`kind`, `source`, `payload_json`). Payloads are structured scalar maps —
/// no free-form text, no prompts, no output ever reaches this column.
public enum EventPayloadCodec {
    /// Reporting source of record for MVP commits (integration reports also
    /// enter through the runtime).
    public static let runtimeSource = "runtime"

    public static func encode(_ event: AgentEvent) -> (kind: String, payload: Data) {
        var kind = ""
        var fields: [String: String] = [:]

        switch event {
        case let .stateChanged(from, to, authority):
            kind = "state_changed"
            fields["from"] = LifecycleToken(phase: from).rawValue
            fields["to"] = LifecycleToken(phase: to).rawValue
            fields["authority"] = encodeAuthority(authority)
        case let .turnStarted(reason):
            kind = "turn_started"
            switch reason {
            case let .promptDelivered(commandID): fields["reason"] = "prompt_delivered"; fields["command_id"] =
                commandID.rawValue.uuidString
            case .spontaneousWork: fields["reason"] = "spontaneous_work"
            case .integrationOperation: fields["reason"] = "integration_operation"
            }
        case let .turnCompleted(hadPrompt):
            kind = "turn_completed"
            fields["had_prompt"] = hadPrompt ? "true" : "false"
        case let .attentionRaised(attentionKind):
            kind = "attention_raised"
            fields["kind"] = encodeAttentionKind(attentionKind)
        case let .attentionCleared(attentionKind):
            kind = "attention_cleared"
            fields["kind"] = encodeAttentionKind(attentionKind)
        case let .promptDelivered(commandID):
            kind = "prompt_delivered"
            fields["command_id"] = commandID.rawValue.uuidString
        case let .promptDeliveryUnconfirmed(commandID):
            kind = "prompt_delivery_unconfirmed"
            fields["command_id"] = commandID.rawValue.uuidString
        case .queuedPromptCancelled:
            kind = "queued_prompt_cancelled"
        case let .queuedPromptDeliveryFailed(commandID):
            kind = "queued_prompt_delivery_failed"
            fields["command_id"] = commandID.rawValue.uuidString
        case let .processExited(exitCode, signal, userInitiated):
            kind = "process_exited"
            if let exitCode {
                fields["exit_code"] = String(exitCode)
            }
            if let signal {
                fields["signal"] = String(signal)
            }
            fields["user_initiated"] = userInitiated ? "true" : "false"
        case let .sessionIdentityCaptured(reference):
            kind = "session_identity_captured"
            merge(reference, into: &fields)
        case let .integrationSequenceGap(expected, received):
            kind = "integration_sequence_gap"
            fields["expected"] = String(expected)
            fields["received"] = String(received)
        case let .authorityLost(previous):
            kind = "authority_lost"
            fields["previous"] = encodeAuthority(previous)
        case let .stopCommanded(mode):
            kind = "stop_commanded"
            fields["mode"] = encodeStopMode(mode)
        case let .restartInitiated(generation):
            kind = "restart_initiated"
            fields["generation"] = String(generation.rawValue)
        case let .resumeAttempted(reference):
            kind = "resume_attempted"
            merge(reference, into: &fields)
        }

        let data = (try? jsonEncoder.encode(fields)) ?? Data("{}".utf8)
        return (kind, data)
    }

    public static func decode(kind: String, payload: Data) throws -> AgentEvent {
        let fields = (try? jsonDecoder.decode([String: String].self, from: payload)) ?? [:]

        switch kind {
        case "state_changed":
            return .stateChanged(
                from: lifecycle(from: fields["from"]),
                to: lifecycle(from: fields["to"]),
                authority: decodeAuthority(fields["authority"])
            )
        case "turn_started":
            switch fields["reason"] {
            case "prompt_delivered":
                return try .turnStarted(reason: .promptDelivered(decodeCommand(fields["command_id"])))
            case "spontaneous_work": return .turnStarted(reason: .spontaneousWork)
            case "integration_operation": return .turnStarted(reason: .integrationOperation)
            default: throw LayoutCodec.CodingError.malformed
            }
        case "turn_completed":
            return .turnCompleted(hadPrompt: fields["had_prompt"] == "true")
        case "attention_raised":
            return try .attentionRaised(kind: decodeAttentionKind(fields["kind"]))
        case "attention_cleared":
            return try .attentionCleared(kind: decodeAttentionKind(fields["kind"]))
        case "prompt_delivered":
            return try .promptDelivered(commandID: decodeCommand(fields["command_id"]))
        case "prompt_delivery_unconfirmed":
            return try .promptDeliveryUnconfirmed(commandID: decodeCommand(fields["command_id"]))
        case "queued_prompt_cancelled":
            return .queuedPromptCancelled
        case "queued_prompt_delivery_failed":
            return try .queuedPromptDeliveryFailed(commandID: decodeCommand(fields["command_id"]))
        case "process_exited":
            return .processExited(
                exitCode: fields["exit_code"].flatMap(Int32.init),
                signal: fields["signal"].flatMap(Int32.init),
                userInitiated: fields["user_initiated"] == "true"
            )
        case "session_identity_captured":
            return try .sessionIdentityCaptured(decodeReference(fields))
        case "integration_sequence_gap":
            guard let expectedToken = fields["expected"], let expected = UInt64(expectedToken),
                  let receivedToken = fields["received"], let received = UInt64(receivedToken)
            else {
                throw LayoutCodec.CodingError.malformed
            }
            return .integrationSequenceGap(expected: expected, received: received)
        case "authority_lost":
            return .authorityLost(previous: decodeAuthority(fields["previous"]))
        case "stop_commanded":
            return try .stopCommanded(mode: decodeStopMode(fields["mode"]))
        case "restart_initiated":
            guard let generationToken = fields["generation"], let generation = UInt64(generationToken) else {
                throw LayoutCodec.CodingError.malformed
            }
            return .restartInitiated(generation: SurfaceGeneration(rawValue: generation))
        case "resume_attempted":
            return try .resumeAttempted(decodeReference(fields))
        default:
            throw LayoutCodec.CodingError.malformed
        }
    }

    // Helpers

    private static func lifecycle(from token: String?) -> LifecyclePhase {
        (token.flatMap(LifecycleToken.init(rawValue:)) ?? .unknown).restored
    }

    private static func merge(_ reference: SessionReference, into fields: inout [String: String]) {
        fields["ref_kind"] = reference.agentKind.rawValue
        fields["ref_payload"] = reference.opaquePayload
        fields["ref_revision"] = String(reference.capturedAtRevision)
    }

    /// Corrupt stored tokens throw instead of fabricating a plausible
    /// identity — a malformed row must never invent timeline data.
    private static func decodeReference(_ fields: [String: String]) throws -> SessionReference {
        guard let kindToken = fields["ref_kind"],
              let agentKind = AgentKind(rawValue: kindToken),
              let opaquePayload = fields["ref_payload"],
              let capturedAtRevision = fields["ref_revision"].flatMap(UInt64.init)
        else {
            throw LayoutCodec.CodingError.malformed
        }
        return SessionReference(
            agentKind: agentKind,
            opaquePayload: opaquePayload,
            capturedAtRevision: capturedAtRevision
        )
    }

    private static func encodeAuthority(_ authority: StateAuthority) -> String {
        switch authority {
        case .unknown: "unknown"
        case .process: "process"
        case .screen: "screen"
        case .integration: "integration"
        }
    }

    private static func decodeAuthority(_ token: String?) -> StateAuthority {
        switch token {
        case "process": .process
        case "screen": .screen
        case "integration": .integration
        default: .unknown
        }
    }

    private static func encodeAttentionKind(_ kind: AgentEvent.AttentionKind) -> String {
        switch kind {
        case .completionUnread: "completion_unread"
        case .inputRequired: "input_required"
        case .failure: "failure"
        }
    }

    /// Corrupt stored tokens throw instead of fabricating a plausible kind —
    /// a malformed row must never invent timeline data.
    private static func decodeAttentionKind(_ token: String?) throws -> AgentEvent.AttentionKind {
        switch token {
        case "completion_unread": .completionUnread
        case "failure": .failure
        case "input_required": .inputRequired
        default: throw LayoutCodec.CodingError.malformed
        }
    }

    private static func encodeStopMode(_ mode: StopMode) -> String {
        switch mode {
        case .interrupt: "interrupt"
        case .gracefulStop: "graceful_stop"
        case .closeView: "close_view"
        }
    }

    /// Corrupt stored tokens throw instead of fabricating a plausible mode —
    /// a malformed row must never invent timeline data.
    private static func decodeStopMode(_ token: String?) throws -> StopMode {
        switch token {
        case "interrupt": .interrupt
        case "graceful_stop": .gracefulStop
        case "close_view": .closeView
        default: throw LayoutCodec.CodingError.malformed
        }
    }

    /// A missing or unparsable command token is corruption: throw rather
    /// than minting a fresh CommandID that was never delivered.
    private static func decodeCommand(_ token: String?) throws -> CommandID {
        guard let raw = token, let uuid = UUID(uuidString: raw) else {
            throw LayoutCodec.CodingError.malformed
        }
        return CommandID(rawValue: uuid)
    }
}

// MARK: - Integration installs / app runs / settings

struct IntegrationInstallRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "integration_installs"

    var agentKind: String
    var integrationVersion: String
    var status: String
    var managedFilesJSON: Data
    var managedFingerprint: String
    var installedAt: Double

    enum CodingKeys: String, CodingKey {
        case agentKind = "agent_kind"
        case integrationVersion = "integration_version"
        case status
        case managedFilesJSON = "managed_files_json"
        case managedFingerprint = "managed_fingerprint"
        case installedAt = "installed_at"
    }
}

struct AppRunRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "app_runs"

    var id: Int64?
    var startedAt: Double
    var endedAt: Double?
    var terminationKind: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case terminationKind = "termination_kind"
    }
}

struct SettingRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "settings"

    var key: String
    var valueJSON: Data
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case key
        case valueJSON = "value_json"
        case updatedAt = "updated_at"
    }
}

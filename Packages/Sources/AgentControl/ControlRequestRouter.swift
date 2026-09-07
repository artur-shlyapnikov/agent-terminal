import AgentCore
import Foundation

// Method → runtime command mapping (architecture §3.16, §4.5).
//
// The router never touches sockets beyond the injected connection handle and
// never leaks runtime internals: every failure is rendered through the stable
// error-code taxonomy (ControlErrors.swift). Runtime access goes through
// `ControlRuntime` so tests can substitute a double.

/// The slice of `AgentRuntime` the control plane needs. Conformed to by
/// `LiveControlRuntime` (wrapping the real actor) and by test doubles.
public protocol ControlRuntime: Sendable {
    func listWorkspaces() async -> [Workspace]
    func createAgent(_ request: AgentLaunchRequest, in workspaceID: WorkspaceID) async throws -> AgentID
    func summaries() async -> [AgentSummary]
    func summary(of agentID: AgentID) async -> AgentSummary?
    func prompt(_ agentID: AgentID, _ text: String, _ policy: PromptPolicy) async throws -> PromptReceipt
    func cancelQueuedPrompt(_ agentID: AgentID) async throws
    func focus(_ agentID: AgentID) async throws
    func interrupt(_ agentID: AgentID) async throws
    func stop(_ agentID: AgentID, mode: StopMode) async throws
    func resume(_ agentID: AgentID) async throws
    func read(_ agentID: AgentID, source: TerminalReadSource) async throws -> TerminalSnapshot
    func state(of agentID: AgentID) async throws -> AgentState
    func surfaceCreated(
        agentID: AgentID,
        terminalID: TerminalID,
        generation: SurfaceGeneration,
        pid: Int32?,
        processGroupID: Int32?
    ) async throws
    func ingest(_ evidence: Evidence) async
    /// Integration lease expiry fallback (§3.5 last row), used by release.
    func integrationExpired(sourceID: String, agentID: AgentID) async
}

/// Adapter over the real `AgentRuntime`. The composition root (stage 8)
/// wires the runtime; workspace listings come from the runtime itself —
/// the single authoritative registry since workspaces are opened under
/// their persisted identities.
public struct LiveControlRuntime: ControlRuntime {
    public let runtime: AgentRuntime
    private let launchAgent: (@Sendable (AgentLaunchRequest, WorkspaceID) async throws -> AgentID)?
    /// Optional full-stop port: the embedding app supplies its lifecycle
    /// coordinator so control-plane stops classify user intent and
    /// compensate detection suspensions — a bare runtime stop cannot.
    private let stopAgent: (@Sendable (AgentID, StopMode) async throws -> Void)?
    private let focusAgent: (@Sendable (AgentID) async throws -> Void)?

    public init(
        runtime: AgentRuntime,
        launchAgent: (@Sendable (AgentLaunchRequest, WorkspaceID) async throws -> AgentID)? = nil,
        stopAgent: (@Sendable (AgentID, StopMode) async throws -> Void)? = nil,
        focusAgent: (@Sendable (AgentID) async throws -> Void)? = nil
    ) {
        self.runtime = runtime
        self.launchAgent = launchAgent
        self.stopAgent = stopAgent
        self.focusAgent = focusAgent
    }

    public func listWorkspaces() async -> [Workspace] {
        await runtime.listWorkspaces()
    }

    public func createAgent(_ request: AgentLaunchRequest, in workspaceID: WorkspaceID) async throws -> AgentID {
        guard let launchAgent else { return try await runtime.createAgent(request, in: workspaceID) }
        return try await launchAgent(request, workspaceID)
    }

    public func summaries() async -> [AgentSummary] {
        await runtime.projection().agents
    }

    public func summary(of agentID: AgentID) async -> AgentSummary? {
        await summaries().first { $0.id == agentID }
    }

    public func prompt(_ agentID: AgentID, _ text: String, _ policy: PromptPolicy) async throws -> PromptReceipt {
        try await runtime.prompt(agentID, text, policy)
    }

    public func cancelQueuedPrompt(_ agentID: AgentID) async throws {
        try await runtime.cancelQueuedPrompt(agentID)
    }

    public func focus(_ agentID: AgentID) async throws {
        // The embedding app's port owns the full focus semantics (UI
        // selection + surface mount); without it, focus only marks runtime
        // visibility — nothing mounts a surfaceless agent's pane.
        if let focusAgent {
            try await focusAgent(agentID)
        } else {
            try await runtime.focus(agentID)
        }
    }

    public func interrupt(_ agentID: AgentID) async throws {
        try await runtime.interrupt(agentID)
    }

    public func stop(_ agentID: AgentID, mode: StopMode) async throws {
        // The embedding app's port owns the FULL semantic stop (user-intent
        // classification + detection-suspension compensation); the bare
        // runtime call remains for port-less embedders/tests.
        if let stopAgent {
            try await stopAgent(agentID, mode)
        } else {
            try await runtime.stop(agentID, mode: mode)
        }
    }

    public func resume(_ agentID: AgentID) async throws {
        try await runtime.resume(agentID)
    }

    public func read(_ agentID: AgentID, source: TerminalReadSource) async throws -> TerminalSnapshot {
        try await runtime.read(agentID, source: source)
    }

    public func state(of agentID: AgentID) async throws -> AgentState {
        try await runtime.state(of: agentID)
    }

    public func surfaceCreated(
        agentID: AgentID,
        terminalID: TerminalID,
        generation: SurfaceGeneration,
        pid: Int32?,
        processGroupID: Int32?
    ) async throws {
        try await runtime.surfaceCreated(
            agentID: agentID,
            terminalID: terminalID,
            generation: generation,
            pid: pid,
            processGroupID: processGroupID
        )
    }

    public func ingest(_ evidence: Evidence) async {
        await runtime.ingest(evidence)
    }

    public func integrationExpired(sourceID: String, agentID: AgentID) async {
        await runtime.integrationExpired(sourceID: sourceID, agentID: agentID)
    }
}

// MARK: - Typed params

/// Parameter decoding with precise `badRequest` messages.
struct ParamDecoder {
    let params: [String: JSONValue]

    func require(_ key: String) throws -> JSONValue {
        guard let value = params[key] else {
            throw ControlFailure.badRequest("missing param '\(key)'")
        }
        return value
    }

    func string(_ key: String) throws -> String {
        guard let value = try require(key).stringValue else {
            throw ControlFailure.badRequest("param '\(key)' must be a string")
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = params[key], value.isNotNull else { return nil }
        guard let string = value.stringValue else {
            throw ControlFailure.badRequest("param '\(key)' must be a string")
        }
        return string
    }

    func uint64(_ key: String) throws -> UInt64 {
        guard let raw = try require(key).intValue, raw >= 0 else {
            throw ControlFailure.badRequest("param '\(key)' must be a non-negative integer")
        }
        return UInt64(raw)
    }

    func optionalUInt64(_ key: String) throws -> UInt64? {
        guard let value = params[key], value.isNotNull else { return nil }
        guard let raw = value.intValue, raw >= 0 else {
            throw ControlFailure.badRequest("param '\(key)' must be a non-negative integer")
        }
        return UInt64(raw)
    }

    func int32(_ key: String) throws -> Int32 {
        guard let raw = try require(key).intValue, raw >= Int32.min, raw <= Int32.max else {
            throw ControlFailure.badRequest("param '\(key)' must be an int32")
        }
        return Int32(raw)
    }

    func uuid(_ key: String) throws -> UUID {
        let raw = try string(key)
        guard let uuid = UUID(uuidString: raw) else {
            throw ControlFailure.badRequest("param '\(key)' is not a valid UUID")
        }
        return uuid
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let value = params[key], value.isNotNull else { return nil }
        guard let raw = value.stringValue, let parsed = UUID(uuidString: raw) else {
            throw ControlFailure.badRequest("param '\(key)' is not a valid UUID")
        }
        return parsed
    }

    func stringArray(_ key: String) throws -> [String] {
        guard let array = try require(key).arrayValue else {
            throw ControlFailure.badRequest("param '\(key)' must be an array of strings")
        }
        return try array.map { element in
            guard let string = element.stringValue else {
                throw ControlFailure.badRequest("param '\(key)' must contain only strings")
            }
            return string
        }
    }

    func present(_ key: String) -> Bool {
        params[key]?.isNotNull == true
    }
}

extension JSONValue {
    var isNotNull: Bool {
        if case .null = self {
            return false
        }
        return true
    }
}

extension PromptPolicy {
    init(name: String) throws {
        switch name {
        case "sendNow": self = .sendNow
        case "queueWhenIdle": self = .queueWhenIdle
        case "rejectUnlessIdle": self = .rejectUnlessIdle
        default:
            throw ControlFailure.badRequest("unknown prompt policy '\(name)'")
        }
    }
}

extension StopMode {
    init(name: String) throws {
        switch name {
        case "gracefulStop": self = .gracefulStop
        case "closeView": self = .closeView
        default:
            throw ControlFailure.badRequest("unknown stop mode '\(name)' (interrupt has its own method)")
        }
    }
}

// MARK: - Router

public actor ControlRequestRouter {
    public let runtime: any ControlRuntime
    public let hooks: HookAuthenticator
    public let idempotency: IdempotencyCache
    public let broker: EventStreamBroker

    /// commandIDs currently executing. The idempotency cache only covers
    /// duplicates that arrive AFTER the first response was cached; this set
    /// closes the in-flight window so the same commandID racing across two
    /// connections cannot double-execute (§3.16 exactly-once for prompts).
    private var inFlightCommandIDs: Set<String> = []

    public init(
        runtime: any ControlRuntime,
        hooks: HookAuthenticator = HookAuthenticator(),
        idempotency: IdempotencyCache = IdempotencyCache(),
        broker: EventStreamBroker
    ) {
        self.runtime = runtime
        self.hooks = hooks
        self.idempotency = idempotency
        self.broker = broker
    }

    // MARK: Entry point

    /// Handles one parsed request. Writes exactly one response line for
    /// non-streaming methods; for streaming methods writes the ok-header then
    /// event frames until disconnect.
    public func handle(_ request: ControlRequest, connection: ControlConnection) async {
        // In-flight bookkeeping lives at FUNCTION scope so the claim survives
        // across dispatch and is released exactly once, on every exit path.
        var claimedCommandID: String?
        defer {
            if let claimed = claimedCommandID {
                endInFlight(claimed)
            }
        }

        do {
            try ProtocolVersion.validate(request.protocolVersion)

            guard let method = ControlMethod(rawValue: request.method) else {
                throw ControlFailure(code: .unknownMethod, message: "unknown method '\(request.method)'")
            }

            // Idempotency: any commandID-keyed request replays its cached
            // response instead of re-executing (prompt MUST NOT send twice).
            if let commandID = request.commandID,
               let cached = await idempotency.get(commandID)
            {
                guard var cachedResponse = Self.decodeCached(cached) else {
                    // An entry that no longer decodes must NOT fall through
                    // to execution: re-running a mutating command such as
                    // agent.prompt would break exactly-once (§3.16). Fail
                    // the request instead — do not re-execute and do not
                    // overwrite the stale cache entry.
                    throw ControlFailure(code: .internalError, message: "internal error")
                }
                cachedResponse.requestID = request.requestID
                try connection.send(cachedResponse)
                return
            }

            // In-flight guard: a duplicate commandID racing on ANOTHER
            // connection arrives before the first response is cached — the
            // replay above cannot see it yet. Reject it so the operation can
            // never double-execute; the client retries and then gets the
            // cached result.
            if let commandID = request.commandID {
                guard beginInFlight(commandID) else {
                    throw ControlFailure(
                        code: .commandInFlight,
                        message: "a request with this commandID is already executing; retry to obtain its result"
                    )
                }
                claimedCommandID = commandID
            }

            let response = try await dispatch(method, request: request, connection: connection)

            // Cache-then-send (§3.16 exactly-once): the encoded response is
            // committed to the idempotency cache BEFORE it is written to the
            // connection. If the connection dies between dispatch and send,
            // the catch path below never reaches a trailing cache write — the
            // in-flight claim releases and a client retry with the same
            // commandID would re-execute, double-delivering agent.prompt.
            // Caching first is strictly safer: a failed send leaves a cached
            // response the retry replays (exactly-once); a successful send
            // is unaffected.
            //
            // Only ok:true responses are cached: a failure did not mutate
            // anything (a rejected report, a wait whose outcome was
            // cancelled), so replaying it would make a transient error
            // sticky for the whole TTL instead of letting the client retry
            // with the same commandID re-execute. The disconnect path below
            // relies on the same property — its thrown cancellation never
            // reaches this cache write at all.
            //
            // events.subscribe's ok header is bound to the connection the
            // subscription forwarder lives on — caching it would make a
            // retry replay a dead subscriptionID. Let each retry create a
            // fresh subscription on its current connection.
            if let commandID = request.commandID, method != .eventsSubscribe, response.ok {
                await idempotency.put(commandID, ControlWire.encode(response))
            }

            // events.subscribe writes its own header inside dispatch (before
            // the forwarder task starts) and then streams event frames.
            if method != .eventsSubscribe {
                try connection.send(response)
            }
        } catch {
            let failure = mapRuntimeError(error)
            try? connection.send(.failure(failure, requestID: request.requestID))
        }
    }

    /// True when the commandID is already executing on another connection;
    /// otherwise marks it in-flight. The caller MUST release the claim via
    /// `endInFlight` when the dispatch completes (success or failure).
    private func beginInFlight(_ commandID: String) -> Bool {
        if inFlightCommandIDs.contains(commandID) {
            return false
        }
        inFlightCommandIDs.insert(commandID)
        return true
    }

    private func endInFlight(_ commandID: String) {
        inFlightCommandIDs.remove(commandID)
    }

    static func decodeCached(_ data: Data) -> ControlResponse? {
        guard let codable = try? ControlWire.jsonDecoder.decode(ResponseCodable.self, from: data) else { return nil }
        return codable.value
    }

    // MARK: Dispatch table

    private func dispatch(_ method: ControlMethod, request: ControlRequest,
                          connection: ControlConnection) async throws -> ControlResponse
    {
        let params = ParamDecoder(params: request.params)

        switch method {
        case .systemPing:
            return .success(request.requestID, [
                "protocolVersion": .int(Int64(ProtocolVersion.current)),
                "implementation": "agent-terminal-control",
            ])

        case .workspaceList:
            let workspaces = await runtime.listWorkspaces()
            return .success(request.requestID, [
                "workspaces": .array(workspaces.map { .object(WorkspaceDTO(workspace: $0).json) })
            ])

        case .agentCreate:
            let workspaceID = try WorkspaceID(rawValue: params.uuid("workspaceID"))
            let kindRaw = try params.string("kind")
            guard let kind = AgentKind(rawValue: kindRaw) else {
                throw ControlFailure.badRequest("unknown agent kind '\(kindRaw)'")
            }
            let launchRequest = try AgentLaunchRequest(
                agentKind: kind,
                workingDirectory: params.string("workingDirectory"),
                displayName: params.string("displayName"),
                taskSummary: params.optionalString("taskSummary")
            )
            let agentID = try await runtime.createAgent(launchRequest, in: workspaceID)
            return .success(request.requestID, ["agentID": .string(agentID.rawValue.uuidString)])

        case .agentList:
            let all = await runtime.summaries()
            let agents: [AgentSummary]
            if params.present("workspaceID") {
                let workspaceUUID = try params.uuid("workspaceID")
                agents = all.filter { $0.workspaceID.rawValue == workspaceUUID }
            } else {
                agents = all
            }
            return .success(request.requestID, [
                "agents": .array(agents.map { .object(AgentSummaryDTO(summary: $0).json) })
            ])

        case .agentGet:
            let agentID = try AgentID(rawValue: params.uuid("agentID"))
            guard let summary = await runtime.summary(of: agentID) else {
                throw ControlFailure(code: .agentNotFound, message: "agent not found")
            }
            return .success(request.requestID, [
                "agent": .object(AgentSummaryDTO(summary: summary).json)
            ], stateRevision: summary.state.revision)

        case .agentPrompt:
            let agentID = try AgentID(rawValue: params.uuid("agentID"))
            let text = try params.string("text")
            // optionalString: a present-but-non-string policy must be a
            // badRequest, not a silent fall back to the sendNow default.
            let policyName = try params.optionalString("policy") ?? "sendNow"
            let policy = try PromptPolicy(name: policyName)
            let receipt = try await runtime.prompt(agentID, text, policy)
            return .success(request.requestID, [
                "receipt": .object([
                    "commandID": .string(receipt.commandID.rawValue.uuidString),
                    "agentID": .string(receipt.agentID.rawValue.uuidString),
                    "outcome": .string(receipt.outcome == .delivered ? "delivered" : "queued"),
                ])
            ])

        case .agentCancelQueuedPrompt:
            let agentID = try AgentID(rawValue: params.uuid("agentID"))
            try await runtime.cancelQueuedPrompt(agentID)
            return .success(request.requestID)

        case .agentFocus:
            let agentID = try AgentID(rawValue: params.uuid("agentID"))
            try await runtime.focus(agentID)
            return .success(request.requestID)

        case .agentInterrupt:
            let agentID = try AgentID(rawValue: params.uuid("agentID"))
            try await runtime.interrupt(agentID)
            return .success(request.requestID)

        case .agentStop:
            let agentID = try AgentID(rawValue: params.uuid("agentID"))
            // optionalString: a present-but-non-string mode must be a
            // badRequest, not a silent fall back to the gracefulStop default.
            let modeName = try params.optionalString("mode") ?? "gracefulStop"
            try await runtime.stop(agentID, mode: StopMode(name: modeName))
            return .success(request.requestID)

        case .agentResume:
            let agentID = try AgentID(rawValue: params.uuid("agentID"))
            try await runtime.resume(agentID)
            return .success(request.requestID)

        case .agentRead:
            let agentID = try AgentID(rawValue: params.uuid("agentID"))
            let sourceName = try params.optionalString("source") ?? "visible"
            guard let source = TerminalReadSource(rawValue: sourceName) else {
                throw ControlFailure.badRequest("unknown read source '\(sourceName)'")
            }
            let snapshot = try await runtime.read(agentID, source: source)
            // §3.6: the top-level `stateRevision` lives in the state revision
            // space; `outputRevision` is a separate terminal-output counter.
            // Conflating them would let wait(minStateRevision:) clients
            // compare across incompatible domains.
            guard let summary = await runtime.summary(of: agentID) else {
                throw ControlFailure(code: .agentNotFound, message: "agent not found")
            }
            return .success(request.requestID, [
                "text": .string(snapshot.text),
                "outputRevision": .uint64(snapshot.outputRevision),
                "generation": .uint64(snapshot.generation.rawValue),
            ], stateRevision: summary.state.revision)

        case .agentWait:
            return try await handleWait(request: request, params: params, connection: connection)

        case .eventsSubscribe:
            return try await handleSubscribe(request: request, params: params, connection: connection)

        case .integrationReport:
            return try await handleIntegrationReport(request: request, params: params)

        case .integrationRelease:
            return try await handleIntegrationRelease(request: request, params: params)

        case .launcherStarted:
            return try await handleLauncherStarted(request: request, params: params)

        case .launcherFailed:
            return try await handleLauncherFailed(request: request, params: params)
        }
    }

    // MARK: agent.wait

    private func handleWait(
        request: ControlRequest,
        params: ParamDecoder,
        connection: ControlConnection
    ) async throws -> ControlResponse {
        let agentID = try AgentID(rawValue: params.uuid("agentID"))
        let targetNames = try params.stringArray("targetLifecycle")
        // Empty predicate would trip waitForLifecycle's precondition and
        // crash the host — reject it as a client error instead.
        guard !targetNames.isEmpty else {
            throw ControlFailure.badRequest("targetLifecycle must name at least one lifecycle")
        }
        let targets = try Set(targetNames.map { name -> LifecycleTag in
            guard let tag = LifecycleTag(rawValue: name) else {
                throw ControlFailure.badRequest("unknown lifecycle tag '\(name)'")
            }
            return tag
        })
        let minRevision = try params.optionalUInt64("minStateRevision")
        let timeoutMs = try params.optionalUInt64("timeoutMs") ?? 60000

        // Duration.milliseconds takes Int64; a crafted UInt64 above
        // Int64.max traps at the conversion and crashes the host. Cap at
        // 24 h — far above any legitimate wait, far below the trap point —
        // and reject larger values as a client error.
        let maxTimeoutMs: UInt64 = 24 * 60 * 60 * 1000
        guard timeoutMs <= maxTimeoutMs else {
            throw ControlFailure.badRequest("timeoutMs exceeds maximum of \(maxTimeoutMs)")
        }

        let runtime = runtime
        let broker = broker

        enum RaceOutcome {
            case wait(Result<WaitOutcome, WaitError>)
            case disconnected
        }

        // Step 6: race the wait against client disconnection so a dead peer
        // never leaves the operation hanging until its timeout.
        let race = await withTaskGroup(of: RaceOutcome.self) { group in
            group.addTask {
                let outcome = await waitForLifecycle(
                    targets: targets,
                    minStateRevision: minRevision,
                    timeout: .milliseconds(timeoutMs),
                    reader: { () -> LifecycleSnapshot? in
                        guard let summary = await runtime.summary(of: agentID) else { return nil }
                        return summary.lifecycleSnapshot
                    },
                    events: { await broker.subscribe(agentID: agentID) }
                )
                return .wait(outcome)
            }
            group.addTask {
                await connection.awaitClosed()
                return .disconnected
            }
            let first = await group.next() ?? .disconnected
            group.cancelAll()
            return first
        }

        switch race {
        case .disconnected:
            // Structured cancellation (§3.16 step 6): the peer is gone; there
            // is nobody left to answer, the subscription was torn down above.
            // Throwing (not returning) keeps this failure out of the
            // idempotency cache, so a client retry with the same commandID
            // re-waits instead of replaying the cancellation.
            throw ControlFailure(code: .cancelled, message: "wait cancelled: client disconnected")
        case let .wait(outcome):
            switch outcome {
            case .failure(.agentNotFound):
                throw ControlFailure(code: .agentNotFound, message: "agent not found")
            case let .failure(.readerFailed(reason)):
                throw ControlFailure(code: .internalError, message: "wait state reader failed: \(reason)")
            case let .success(.matched(revision, lifecycle)):
                return .success(request.requestID, [
                    "matched": true,
                    "stateRevision": .uint64(revision),
                    "lifecycle": .string(lifecycle.rawValue),
                ])
            case let .success(.timedOut(lastKnown)):
                var result: [String: JSONValue] = ["matched": false, "reason": "timeout"]
                if let lastKnown {
                    result["lastKnownRevision"] = .uint64(lastKnown)
                }
                return .success(request.requestID, result)
            case .success(.cancelled):
                return .failure(
                    ControlFailure(code: .cancelled, message: "wait cancelled"),
                    requestID: request.requestID
                )
            }
        }
    }

    // MARK: events.subscribe

    private func handleSubscribe(
        request: ControlRequest,
        params: ParamDecoder,
        connection: ControlConnection
    ) async throws -> ControlResponse {
        var filter: AgentID?
        if params.present("agentID") {
            filter = try AgentID(rawValue: params.uuid("agentID"))
        }
        let subscriptionID = UUID().uuidString
        let header = ControlResponse.success(
            request.requestID,
            ["subscriptionID": .string(subscriptionID)]
        )

        // Forward frames until disconnect/cancel; clean teardown via the
        // broker's onTermination when this loop ends. The header is written
        // BEFORE the forwarder starts so no frame can precede it.
        let broker = broker
        let subscription = await broker.subscribe(agentID: filter)
        try connection.send(header)
        let forwarder = Task {
            do {
                for try await summary in subscription {
                    let frame: [String: JSONValue] = [
                        "subscriptionID": .string(subscriptionID),
                        "event": "agentChanged",
                        "agent": .object(AgentSummaryDTO(summary: summary).json),
                    ]
                    try connection.send(frame: frame)
                }
            } catch {
                // Disconnected or cancelled; the stream's onTermination
                // detaches the subscriber when this loop ends.
                return
            }
        }
        // Watchdog: a silent client (no frames flowing) must also be
        // detached when its socket dies. Races closure against forwarder
        // completion so a subscription that ends normally does not leave
        // this task parked on awaitClosed() until the client disconnects.
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await connection.awaitClosed() }
                group.addTask { _ = await forwarder.value }
                group.cancelAll()
            }
            forwarder.cancel()
        }

        return header
    }

    // MARK: Hook-authenticated reports

    private func handleIntegrationReport(
        request: ControlRequest,
        params: ParamDecoder
    ) async throws -> ControlResponse {
        let report = try decodeIntegrationReport(params)
        // Decode before validateReport: a malformed payload must not consume the
        // sequence (a corrected retry with the same seq would classify as duplicate).
        let payload = try report.payload()
        let verdict = await hooks.validateReport(
            agentID: report.agentID,
            surfaceGeneration: SurfaceGeneration(rawValue: report.surfaceGeneration),
            sourceID: report.source,
            sequence: report.seq,
            token: report.token
        )

        switch verdict {
        case let .reject(failure):
            return .failure(failure, requestID: request.requestID)
        case let .duplicate(lastAccepted):
            // §3.6: duplicate acknowledged without creating an event.
            return .success(request.requestID, [
                "accepted": false,
                "duplicate": true,
                "lastAcceptedSequence": .uint64(lastAccepted),
            ])
        case let .accept(sequence):
            let now = ContinuousRuntimeClock().currentInstant()
            let envelope = ObservationEnvelope(
                agentID: report.agentID,
                terminalID: report.terminalID.map { TerminalID(rawValue: $0) },
                surfaceGeneration: SurfaceGeneration(rawValue: report.surfaceGeneration),
                sourceID: report.source,
                sourceKind: .integration,
                sequence: sequence,
                outputRevision: nil,
                observedAt: MonotonicInstant.zero, // external clocks untrusted (§3.6)
                receivedAt: now
            )
            await runtime.ingest(Evidence(envelope: envelope, payload: payload))
            return .success(request.requestID, ["accepted": true])
        }
    }

    private func handleIntegrationRelease(
        request: ControlRequest,
        params: ParamDecoder
    ) async throws -> ControlResponse {
        let agentID = try AgentID(rawValue: params.uuid("agentID"))
        let token = try params.string("token")
        let source = try params.string("source")
        let generation = try params.uint64("surfaceGeneration")

        let verdict = await hooks.validateReport(
            agentID: agentID,
            surfaceGeneration: SurfaceGeneration(rawValue: generation),
            sourceID: source,
            sequence: nil,
            token: token
        )
        switch verdict {
        case let .reject(failure):
            return .failure(failure, requestID: request.requestID)
        case let .duplicate(lastAccepted):
            // §3.6: duplicate acknowledged without releasing again.
            return .success(request.requestID, [
                "accepted": false,
                "duplicate": true,
                "lastAcceptedSequence": .uint64(lastAccepted),
            ])
        case .accept:
            break
        }
        await hooks.release(sourceID: source, agentID: agentID)
        await runtime.integrationExpired(sourceID: source, agentID: agentID)
        return .success(request.requestID, ["released": true])
    }

    private func handleLauncherStarted(
        request: ControlRequest,
        params: ParamDecoder
    ) async throws -> ControlResponse {
        let agentID = try AgentID(rawValue: params.uuid("agentID"))
        let generation = try params.uint64("surfaceGeneration")

        let verdict = try await hooks.validateReport(
            agentID: agentID,
            surfaceGeneration: SurfaceGeneration(rawValue: generation),
            sourceID: "launcher",
            sequence: params.optionalUInt64("seq"),
            token: params.string("token")
        )
        if case let .reject(failure) = verdict {
            return .failure(failure, requestID: request.requestID)
        }
        if case let .duplicate(lastAccepted) = verdict {
            // §3.6: duplicate acknowledged without re-running surfaceCreated
            // below.
            return .success(request.requestID, [
                "accepted": false,
                "duplicate": true,
                "lastAcceptedSequence": .uint64(lastAccepted),
            ])
        }
        try await runtime.surfaceCreated(
            agentID: agentID,
            terminalID: TerminalID(rawValue: params.uuid("terminalID")),
            generation: SurfaceGeneration(rawValue: generation),
            pid: params.present("pid") ? params.int32("pid") : nil,
            processGroupID: params.present("processGroupID") ? params.int32("processGroupID") : nil
        )
        return .success(request.requestID, ["acknowledged": true])
    }

    private func handleLauncherFailed(
        request: ControlRequest,
        params: ParamDecoder
    ) async throws -> ControlResponse {
        let agentID = try AgentID(rawValue: params.uuid("agentID"))
        let generation = try params.uint64("surfaceGeneration")
        let reason = try params.string("reason")

        let verdict = try await hooks.validateReport(
            agentID: agentID,
            surfaceGeneration: SurfaceGeneration(rawValue: generation),
            sourceID: "launcher",
            sequence: params.optionalUInt64("seq"),
            token: params.string("token")
        )
        if case let .reject(failure) = verdict {
            return .failure(failure, requestID: request.requestID)
        }

        if case let .duplicate(lastAccepted) = verdict {
            // §3.6: duplicate acknowledged without ingesting a second
            // failure event below.
            return .success(request.requestID, [
                "accepted": false,
                "duplicate": true,
                "lastAcceptedSequence": .uint64(lastAccepted),
            ])
        }
        let now = ContinuousRuntimeClock().currentInstant()
        let envelope = ObservationEnvelope(
            agentID: agentID,
            terminalID: nil,
            surfaceGeneration: SurfaceGeneration(rawValue: generation),
            sourceID: "launcher",
            sourceKind: .process,
            sequence: nil,
            outputRevision: nil,
            observedAt: now,
            receivedAt: now
        )
        let payload = EvidencePayload.integrationLifecycle(.failed(FailureDescriptor(reason: reason)))
        await runtime.ingest(Evidence(envelope: envelope, payload: payload))
        return .success(request.requestID, ["acknowledged": true])
    }
}

// MARK: - Report payload decoding

struct IntegrationReportFields {
    var agentID: AgentID
    var terminalID: UUID?
    var surfaceGeneration: UInt64
    var source: String
    var seq: UInt64?
    var lifecycleName: String?
    var sessionReferenceJSON: [String: JSONValue]?
    var inputRequestJSON: [String: JSONValue]?
    var token: String

    /// Builds the EvidencePayload from the optional report sections.
    func payload() throws -> EvidencePayload {
        if let lifecycleName {
            guard let tag = LifecycleTag(rawValue: lifecycleName) else {
                throw ControlFailure.badRequest("unknown lifecycle '\(lifecycleName)'")
            }
            var phase = tag.asLifecyclePhase()
            // §3.16: an explicit `inputRequest` refines the waitingForInput
            // descriptor beyond the coarse freeText fallback.
            if case .waitingForInput = phase, let reported = inputRequestJSON {
                phase = try .waitingForInput(Self.inputRequest(from: reported))
            }
            return .integrationLifecycle(phase)
        }
        if let reference = sessionReferenceJSON {
            let data = try JSONSerialization.data(withJSONObject: reference)
            let decoded = try ControlWire.jsonDecoder.decode(SessionReference.self, from: data)
            return .sessionIdentity(decoded)
        }
        throw ControlFailure.badRequest("report requires 'lifecycle' or 'sessionReference'")
    }

    /// Builds an InputRequestDescriptor from a reported `inputRequest` object.
    ///
    /// §5.1 critical law: the reply surface is forced server-side. A report
    /// can never widen it past `terminalOnly`, no matter what its payload
    /// claims — the descriptor's safeReplyMode is not read from the wire.
    private static func inputRequest(from reported: [String: JSONValue]) throws -> InputRequestDescriptor {
        let kind: InputRequestKind
        switch reported["kind"]?.stringValue {
        case "freeText": kind = .freeText
        case "approval": kind = .approval
        case "selection": kind = .selection
        case "unknown", nil: kind = .unknown
        case let .some(other):
            throw ControlFailure.badRequest("unknown inputRequest kind '\(other)'")
        }
        return InputRequestDescriptor(
            kind: kind,
            summary: reported["summary"]?.stringValue,
            safeReplyMode: .terminalOnly,
            source: .integration
        )
    }
}

private func decodeIntegrationReport(_ params: ParamDecoder) throws -> IntegrationReportFields {
    try IntegrationReportFields(
        agentID: AgentID(rawValue: params.uuid("agentID")),
        terminalID: params.optionalUUID("terminalID"),
        surfaceGeneration: params.uint64("surfaceGeneration"),
        source: params.string("source"),
        seq: params.optionalUInt64("seq"),
        lifecycleName: params.optionalString("lifecycle"),
        sessionReferenceJSON: params.params["sessionReference"]?.objectValue,
        inputRequestJSON: params.params["inputRequest"]?.objectValue,
        token: params.string("token")
    )
}

extension LifecycleTag {
    /// Rebuilds a minimal lifecycle phase from a coarse tag. Descriptors that
    /// cannot round-trip degrade to their safest form (§3.4 safety rules).
    func asLifecyclePhase() -> LifecyclePhase {
        switch self {
        case .unknown: .unknown
        case .starting: .starting
        case .idle: .idle
        case .working: .working
        case .waitingForInput:
            .waitingForInput(InputRequestDescriptor(
                kind: .freeText,
                summary: nil,
                safeReplyMode: .terminalOnly,
                source: .integration
            ))
        case .stopping: .stopping
        case .stopped: .stopped(.completed)
        case .failed: .failed(FailureDescriptor())
        }
    }
}

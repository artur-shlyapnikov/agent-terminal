import AgentCore
import Foundation

// Wire envelopes and typed params/results (architecture §3.16).
//
// Request (NDJSON, one object per line):
//   {"protocolVersion":1,"requestID":"<uuid>","commandID":"<uuid>","method":"agent.prompt","params":{…}}
//   commandID is OPTIONAL and present on idempotency-keyed requests.
//
// Response:
//   {"requestID":"<uuid>","ok":true,"result":{…},"stateRevision":N}
//   {"requestID":"<uuid>","ok":false,"error":{"code":"…","message":"…"}}
//   stateRevision is OPTIONAL and present when the request observed a
//   specific agent state revision.
//
// Field names are part of the v1 contract (§3.16) and never renamed.

// MARK: - JSONValue

/// Minimal JSON tree used for `params`, `result`, and event frames. Keeps the
/// wire format exact without pulling in a dependency.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value):
            if value.isFinite {
                try container.encode(value)
            } else {
                // Non-finite doubles are not representable in JSON.
                try container.encodeNil()
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int64) {
        self = .int(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(floatLiteral value: Double) {
        self = .double(value)
    }

    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self {
            return object[key]
        }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    /// Accepts both `int` and `double` payloads that represent whole numbers.
    var intValue: Int64? {
        switch self {
        case let .int(value): value
        case let .double(value) where value == value.rounded(.towardZero) && abs(value) < 9.2e18:
            Int64(value)
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    static func uint64(_ value: UInt64) -> JSONValue {
        value <= UInt64(Int64.max) ? .int(Int64(value)) : .double(Double(value))
    }
}

// MARK: - Request envelope

public struct ControlRequest: Equatable, Sendable {
    public var protocolVersion: Int
    public var requestID: String
    public var commandID: String?
    public var method: String
    public var params: [String: JSONValue]

    public init(
        protocolVersion: Int = ProtocolVersion.current,
        requestID: String,
        commandID: String? = nil,
        method: String,
        params: [String: JSONValue] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.commandID = commandID
        self.method = method
        self.params = params
    }
}

// MARK: - Response envelope

public struct ControlResponse: Equatable, Sendable {
    public var requestID: String
    public var ok: Bool
    public var result: [String: JSONValue]
    public var error: ControlErrorBody?
    /// Present when the request observed a specific agent state revision.
    public var stateRevision: UInt64?

    public init(
        requestID: String,
        ok: Bool,
        result: [String: JSONValue] = [:],
        error: ControlErrorBody? = nil,
        stateRevision: UInt64? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.result = result
        self.error = error
        self.stateRevision = stateRevision
    }

    public static func success(_ requestID: String, _ result: [String: JSONValue] = [:],
                               stateRevision: UInt64? = nil) -> ControlResponse
    {
        ControlResponse(requestID: requestID, ok: true, result: result, stateRevision: stateRevision)
    }

    public static func failure(_ failure: ControlFailure, requestID: String) -> ControlResponse {
        ControlResponse(
            requestID: requestID,
            ok: false,
            error: ControlErrorBody(code: failure.code, message: failure.message)
        )
    }
}

public struct ControlErrorBody: Equatable, Sendable, Codable {
    public var code: ControlErrorCode
    public var message: String

    public init(code: ControlErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - NDJSON codec

public enum ControlWire {
    public static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Compact output: one line per message is the framing contract.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let jsonDecoder = JSONDecoder()

    public static func encode(_ request: ControlRequest) -> Data {
        encodeLine(RequestCodable(from: request))
    }

    public static func encode(_ response: ControlResponse) -> Data {
        encodeLine(ResponseCodable(from: response))
    }

    /// Encodes a mid-subscription event notification frame.
    public static func encode(eventFrame: [String: JSONValue]) -> Data {
        encodeLine(JSONValue.object(eventFrame))
    }

    /// Parses one line into either a request or a response.
    /// - Throws: an unspecified decoding error; callers map to `badRequest`.
    public static func parse(line: Substring) throws -> ParsedFrame {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ControlFailure.badRequest("empty frame") }
        let data = Data(trimmed.utf8)
        if let request = try? jsonDecoder.decode(RequestCodable.self, from: data) {
            return .request(request.value)
        }
        if let response = try? jsonDecoder.decode(ResponseCodable.self, from: data) {
            return .response(response.value)
        }
        throw ControlFailure.badRequest("malformed JSON frame")
    }

    public enum ParsedFrame: Equatable, Sendable {
        case request(ControlRequest)
        case response(ControlResponse)
    }

    private static func encodeLine(_ value: some Encodable) -> Data {
        var data = (try? jsonEncoder.encode(value)) ?? Data("{}".utf8)
        data.append(0x0A) // "\n" — NDJSON framing
        return data
    }
}

// MARK: - Flat wire codecs

/// Hand-rolled flat codecs keep the §3.16 field names byte-exact on the wire
/// (`protocolVersion`, `requestID`, `commandID`, `method`, `params`;
/// `requestID`, `ok`, `result`/`error`, `stateRevision`) while the in-memory
/// model stays strongly typed.
public struct RequestCodable: Codable {
    public var protocolVersion: Int
    public var requestID: String
    public var commandID: String?
    public var method: String
    public var params: JSONValue

    public init(from request: ControlRequest) {
        protocolVersion = request.protocolVersion
        requestID = request.requestID
        commandID = request.commandID
        method = request.method
        params = .object(request.params)
    }

    public var value: ControlRequest {
        ControlRequest(
            protocolVersion: protocolVersion,
            requestID: requestID,
            commandID: commandID,
            method: method,
            params: {
                if case let .object(object) = params {
                    return object
                }
                return [:]
            }()
        )
    }
}

public struct ResponseCodable: Codable {
    public var requestID: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: ControlErrorBody?
    public var stateRevision: UInt64?

    public init(from response: ControlResponse) {
        requestID = response.requestID
        ok = response.ok
        result = response.ok ? .object(response.result) : nil
        error = response.error
        stateRevision = response.stateRevision
    }

    public var value: ControlResponse {
        ControlResponse(
            requestID: requestID,
            ok: ok,
            result: {
                if case let .object(object)? = result {
                    return object
                }
                return [:]
            }(),
            error: error,
            stateRevision: stateRevision
        )
    }
}

// MARK: - DTOs

/// Coarse lifecycle tag — the closed predicate vocabulary for `agent.wait`
/// and lifecycle encoding in summaries. Deliberately NOT arbitrary code.
public enum LifecycleTag: String, CaseIterable, Sendable, Codable {
    case unknown
    case starting
    case idle
    case working
    case waitingForInput
    case stopping
    case stopped
    case failed

    public init(_ phase: LifecyclePhase) {
        switch phase {
        case .unknown: self = .unknown
        case .starting: self = .starting
        case .idle: self = .idle
        case .working: self = .working
        case .waitingForInput: self = .waitingForInput
        case .stopping: self = .stopping
        case .stopped: self = .stopped
        case .failed: self = .failed
        }
    }
}

public struct AgentSummaryDTO: Equatable, Sendable {
    public var id: String
    public var workspaceID: String
    public var kind: String
    public var displayName: String
    public var taskSummary: String?
    public var lifecycle: LifecycleTag
    public var processPhase: String
    public var authority: String
    public var attention: String
    public var stateRevision: UInt64
    public var hasQueuedPrompt: Bool
    public var turnActive: Bool
    public var hasSessionReference: Bool

    public init(summary: AgentSummary) {
        id = summary.id.rawValue.uuidString
        workspaceID = summary.workspaceID.rawValue.uuidString
        kind = summary.kind.rawValue
        displayName = summary.displayName
        taskSummary = summary.taskSummary
        lifecycle = LifecycleTag(summary.state.lifecycle)
        processPhase = Self.processName(summary.state.process)
        authority = Self.authorityName(summary.state.authority)
        attention = Self.attentionName(summary.state.attention)
        stateRevision = summary.state.revision
        hasQueuedPrompt = summary.hasQueuedPrompt
        turnActive = summary.turnActive
        hasSessionReference = summary.hasSessionReference
    }

    static func processName(_ phase: ProcessPhase) -> String {
        switch phase {
        case .notStarted: "notStarted"
        case .launching: "launching"
        case .running: "running"
        case .exiting: "exiting"
        case .exited: "exited"
        case .launchFailed: "launchFailed"
        }
    }

    static func authorityName(_ authority: StateAuthority) -> String {
        switch authority {
        case .unknown: "unknown"
        case .process: "process"
        case .screen: "screen"
        case .integration: "integration"
        }
    }

    static func attentionName(_ attention: AttentionState) -> String {
        switch attention {
        case .none: "none"
        case .completionUnread: "completionUnread"
        case .inputRequired: "inputRequired"
        case .failure: "failure"
        }
    }

    public var json: [String: JSONValue] {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "workspaceID": .string(workspaceID),
            "kind": .string(kind),
            "displayName": .string(displayName),
            "lifecycle": .string(lifecycle.rawValue),
            "processPhase": .string(processPhase),
            "authority": .string(authority),
            "attention": .string(attention),
            "stateRevision": .uint64(stateRevision),
            "hasQueuedPrompt": .bool(hasQueuedPrompt),
            "turnActive": .bool(turnActive),
            "hasSessionReference": .bool(hasSessionReference),
        ]
        if let taskSummary {
            object["taskSummary"] = .string(taskSummary)
        }
        return object
    }
}

public struct WorkspaceDTO: Equatable, Sendable {
    public var id: WorkspaceID
    public var name: String
    public var rootPath: String
    public var agents: [AgentID]

    public init(workspace: Workspace) {
        id = workspace.id
        name = workspace.name
        rootPath = workspace.rootPath
        agents = workspace.agentOrder
    }

    public var json: [String: JSONValue] {
        [
            "id": .string(id.rawValue.uuidString),
            "name": .string(name),
            "rootPath": .string(rootPath),
            "agents": .array(agents.map { .string($0.rawValue.uuidString) }),
        ]
    }
}

// agentctl — command-line client for the AgentTerminal control protocol v1
// (architecture §3.16).
//
// Dependency law (§3.2): helpers depend on AgentControl protocol models only
// — no AppKit, no UI.
//
// Usage:
//   agentctl [--socket PATH] <subcommand> [options]
//
// Subcommands:
//   system ping
//   workspace list
//   agent create --workspace ID --kind K --dir PATH --name NAME [--task-summary S]
//   agent list [--workspace ID]
//   agent get AGENT_ID
//   agent prompt AGENT_ID TEXT... [--policy sendNow|queueWhenIdle|rejectUnlessIdle]
//                                  [--command-id UUID]
//   agent wait AGENT_ID --lifecycle idle,working,... [--min-revision N] [--timeout-ms N]
//        EVENT-DRIVEN via events.subscribe — never polls.
//   agent read AGENT_ID [--source visible|detection]
//   agent focus AGENT_ID | agent interrupt AGENT_ID | agent resume AGENT_ID
//   agent cancel-queued-prompt AGENT_ID
//   agent stop AGENT_ID [--mode gracefulStop|closeView]
//   events subscribe [--agent AGENT_ID]      (streams NDJSON until Ctrl-C)
//   integration report --agent-id ID --terminal-id ID --surface-generation N
//                      --source S --token T [--seq N] [--lifecycle L]
//                      [--session-reference JSON]
//   integration release --agent-id ID --surface-generation N --source S --token T
//   launcher started --agent-id ID --terminal-id ID --surface-generation N
//                    --token T [--pid N] [--process-group-id N] [--seq N]
//   launcher failed  --agent-id ID --surface-generation N --reason R --token T
// Output is JSON (the raw response envelope) on stdout; exit code 0 on ok,
// 1 on any error, 2 on `agent wait` timeout (envelope reports ok:true with
// reason "timeout").
// A bare `--` ends option parsing: everything after it is command text.
import AgentControl
import Foundation

let version = "agentctl, control protocol v\(ProtocolVersion.current)"

// MARK: - Argument plumbing

struct Options {
    private var storage: [String: String] = [:]

    static func parse(_ arguments: [String], flagsWithValues: Set<String>) -> (positional: [String], options: Options) {
        var positional: [String] = []
        var storage: [String: String] = [:]
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            if argument == "--" {
                // End-of-options: everything after is positional text,
                // even when it looks like a flag (e.g. prompt text
                // containing a literal --socket).
                positional.append(contentsOf: iterator)
                break
            }
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                continue
            }
            let name = String(argument.dropFirst(2))
            if let equalsIndex = name.firstIndex(of: "=") {
                let flag = String(name[name.startIndex ..< equalsIndex])
                guard flagsWithValues.contains(flag) else {
                    // Every valid agentctl flag takes a value, so anything
                    // else is a typo; failing loudly beats silent ignoring.
                    fail("unknown option '--\(flag)'")
                }
                guard storage[flag] == nil else {
                    fail("option --\(flag) given more than once")
                }
                guard let value = iterator.next(), !value.hasPrefix("--") else {
                    fail("option --\(flag) requires a value")
                }
                storage[flag] = value
                continue
            }
            guard flagsWithValues.contains(name) else {
                fail("unknown option '--\(name)'")
            }
            guard let value = iterator.next(), !value.hasPrefix("--") else {
                fail("option --\(name) requires a value")
            }
            guard storage[name] == nil else {
                fail("option --\(name) given more than once")
            }
            storage[name] = value
        }
        return (positional, Options(storage: storage))
    }

    func value(_ name: String) -> String? {
        storage[name]
    }

    func require(_ name: String) throws -> String {
        guard let value = storage[name] else {
            throw ControlFailure.badRequest("missing required option --\(name)")
        }
        return value
    }

    func int(_ name: String) throws -> Int64 {
        guard let raw = value(name), let parsed = Int64(raw) else {
            throw ControlFailure.badRequest("option --\(name) must be an integer")
        }
        return parsed
    }
}

/// Parses an explicitly-provided numeric option strictly: malformed input is
/// a usage error, never a silent fallback to a default or omitted parameter.
func strictNonNegativeInteger(_ raw: String?, name: String) throws -> UInt64? {
    guard let raw else { return nil }
    guard let parsed = UInt64(raw) else {
        throw ControlFailure.badRequest("option --\(name) must be a non-negative integer")
    }
    return parsed
}

func defaultSocketPath() -> String {
    if let fromEnvironment = ProcessInfo.processInfo.environment["AGENT_TERMINAL_CONTROL_SOCKET"] {
        return fromEnvironment
    }
    return UnixSocketServer.defaultPath()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[agentctl] \(message)\n".utf8))
    exit(1)
}

/// Encodes a §3.16 wire envelope for stdout. Envelopes we construct are always
/// valid JSON objects; an encoding throw is a programmer error, so it exits
/// through the standard CLI failure path instead of crashing on a force try.
func jsonEncoded(_ object: Any) -> Data {
    do {
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    } catch {
        fail("internal error: envelope re-encoding failed: \(error)")
    }
}

func printResponse(_ response: ControlResponse) {
    let encoded = jsonEncoded(envelopeJSONObject(response))
    print(String(decoding: encoded, as: UTF8.self))
    if !response.ok {
        exit(1)
    }
}

/// Renders the typed envelope back into its §3.16 wire shape.
func envelopeJSONObject(_ response: ControlResponse) -> [String: Any] {
    var object: [String: Any] = ["requestID": response.requestID, "ok": response.ok]
    if response.ok {
        object["result"] = jsonValueToFoundation(.object(response.result))
    } else if let error = response.error {
        object["error"] = ["code": error.code.rawValue, "message": error.message]
    }
    if let stateRevision = response.stateRevision {
        object["stateRevision"] = stateRevision
    }
    return object
}

func jsonValueToFoundation(_ value: JSONValue) -> Any {
    switch value {
    case .null: return NSNull()
    case let .bool(bool): return bool
    case let .int(int): return int
    case let .double(double): return double
    case let .string(string): return string
    case let .array(array): return array.map(jsonValueToFoundation)
    case let .object(object):
        var result: [String: Any] = [:]
        for (key, element) in object {
            result[key] = jsonValueToFoundation(element)
        }
        return result
    }
}

// MARK: - Command implementations

func runPing(client: ControlClient) throws {
    try printResponse(client.roundtrip(method: ControlMethod.systemPing.rawValue))
}

func runWorkspaceList(client: ControlClient) throws {
    try printResponse(client.roundtrip(method: ControlMethod.workspaceList.rawValue))
}

func runAgentCreate(client: ControlClient, options: Options) throws {
    let params: [String: JSONValue] = try [
        "workspaceID": .string(options.require("workspace")),
        "kind": .string(options.require("kind")),
        "workingDirectory": .string(options.require("dir")),
        "displayName": .string(options.require("name")),
        "taskSummary": options.value("task-summary").map { .string($0) } ?? .null,
    ]
    try printResponse(client.roundtrip(method: ControlMethod.agentCreate.rawValue, params: params))
}

func runAgentList(client: ControlClient, options: Options) throws {
    var params: [String: JSONValue] = [:]
    if let workspace = options.value("workspace") {
        params["workspaceID"] = .string(workspace)
    }
    try printResponse(client.roundtrip(method: ControlMethod.agentList.rawValue, params: params))
}

func agentIDParams(options: Options, positional: [String], key: String = "agentID") throws -> [String: JSONValue] {
    let identifier = try positional.count > 1 ? positional[1] : (options.require(key == "agentID" ? "agent" : key))
    return [key: .string(identifier)]
}

func runAgentGet(client: ControlClient, options: Options, positional: [String]) throws {
    try printResponse(client.roundtrip(
        method: ControlMethod.agentGet.rawValue,
        params: agentIDParams(options: options, positional: positional)
    ))
}

func simpleAgentAction(client: ControlClient, method: ControlMethod, options: Options, positional: [String]) throws {
    let extra: [String: JSONValue] = switch method {
    case .agentStop:
        ["mode": .string(options.value("mode") ?? "gracefulStop")]
    case .agentRead:
        ["source": .string(options.value("source") ?? "visible")]
    default:
        [:]
    }
    var params = try agentIDParams(options: options, positional: positional)
    params.merge(extra) { current, _ in current }
    try printResponse(client.roundtrip(method: method.rawValue, params: params))
}

func runAgentPrompt(client: ControlClient, options: Options, positional: [String]) throws {
    guard positional.count >= 3 else {
        throw ControlFailure.badRequest("usage: agent prompt AGENT_ID TEXT...")
    }
    let text = positional[2...].joined(separator: " ")
    var params: [String: JSONValue] = [
        "agentID": .string(positional[1]),
        "text": .string(text),
        "policy": .string(options.value("policy") ?? "sendNow"),
    ]
    if let commandID = options.value("command-id") ?? ProcessInfo.processInfo.environment["AGENT_TERMINAL_COMMAND_ID"] {
        params["__commandID"] = .string(commandID) // consumed below
    }
    let commandID = params.removeValue(forKey: "__commandID")?.stringValue
    try printResponse(client.roundtrip(
        method: ControlMethod.agentPrompt.rawValue,
        params: params,
        commandID: commandID
    ))
}

/// Event-driven wait (§3.16 algorithm, client side): initial read → check →
/// subscribe → re-check → await matching frames or timeout. No polling loop.
func runAgentWait(client: ControlClient, options: Options, positional: [String]) throws {
    guard positional.count >= 2 else {
        throw ControlFailure.badRequest("usage: agent wait AGENT_ID --lifecycle idle[,working,...]")
    }
    let agentID = positional[1]
    let lifecycleArgument = try options.require("lifecycle")
    let targets = try Set(lifecycleArgument.split(separator: ",").map { token in
        guard let tag = LifecycleTag(rawValue: token.trimmingCharacters(in: .whitespaces)) else {
            throw ControlFailure
                .badRequest(
                    "--lifecycle must list valid tags: \(LifecycleTag.allCases.map(\.rawValue).joined(separator: ","))"
                )
        }
        return tag.rawValue
    })
    let minRevision = try strictNonNegativeInteger(options.value("min-revision"), name: "min-revision")
    // Clamp to 24 h so a UInt64 beyond Int64.max cannot trap the conversion;
    // the deadline math below operates in milliseconds anyway.
    let timeoutMs = try Int64(min(
        strictNonNegativeInteger(options.value("timeout-ms"), name: "timeout-ms") ?? 60000,
        86_400_000
    ))

    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)

    func snapshot() throws -> (revision: UInt64, lifecycle: String)? {
        let response = try client.roundtrip(
            method: ControlMethod.agentGet.rawValue,
            params: ["agentID": .string(agentID)]
        )
        guard response.ok else {
            let error = response.error
            if error?.code == .agentNotFound {
                fail("agent not found: \(agentID)")
            }
            fail("agent lookup failed: \(error?.code.rawValue ?? "unknown") \(error?.message ?? "no error details")")
        }
        guard case let .object(agentObject)? = response.result["agent"] else { return nil }
        let revision = agentObject["stateRevision"]?.intValue ?? 0
        let lifecycle = agentObject["lifecycle"]?.stringValue ?? "unknown"
        return (UInt64(revision), lifecycle)
    }

    func matches(_ state: (revision: UInt64, lifecycle: String)) -> Bool {
        targets.contains(state.lifecycle) && (minRevision == nil || state.revision >= minRevision!)
    }

    // Steps 1–2.
    guard let initial = try snapshot() else { fail("agent not found: \(agentID)") }
    if matches(initial) {
        emitWaitResult(matched: true, revision: initial.revision, lifecycle: initial.lifecycle)
        return
    }

    setSignalHandler()
    let streamClient = try ControlClient(socketPath: client.socketPath)
    _ = try streamClient.openSubscription(agentID: agentID)
    streamClient.setReceiveTimeout(milliseconds: 200) // wake for deadline checks

    // Step 4 — re-read after subscribing (closes the subscribe race).
    guard let baseline = try snapshot() else { fail("agent not found: \(agentID)") }
    if matches(baseline) {
        emitWaitResult(matched: true, revision: baseline.revision, lifecycle: baseline.lifecycle)
        return
    }

    // Step 5 — await matching event frames until deadline. The receive
    // timeout only wakes the deadline check; EAGAIN is not an error here.
    while Date() < deadline {
        let frame: [String: JSONValue]?
        do {
            frame = try streamClient.nextEventFrame()
        } catch is ControlReadTimeout {
            continue
        }
        guard let frame else { fail("connection closed while waiting for agent") }
        guard frame["event"]?.stringValue == "agentChanged" else { continue }
        guard case let .object(agent)? = frame["agent"],
              agent["id"]?.stringValue == agentID else { continue }
        let revision = agent["stateRevision"]?.intValue ?? 0
        let lifecycle = agent["lifecycle"]?.stringValue ?? ""
        let state = (UInt64(revision), lifecycle)
        if matches(state) {
            emitWaitResult(matched: true, revision: UInt64(revision), lifecycle: lifecycle)
            return
        }
    }
    emitWaitResult(matched: false, revision: nil, lifecycle: nil, timedOut: true)
}

private func emitWaitResult(matched: Bool, revision: UInt64?, lifecycle: String?, timedOut: Bool = false) {
    var result: [String: Any] = ["matched": matched]
    if let revision {
        result["stateRevision"] = revision
    }
    if let lifecycle {
        result["lifecycle"] = lifecycle
    }
    if timedOut {
        result["reason"] = "timeout"
    }
    let data = jsonEncoded(["requestID": "", "ok": true, "result": result])
    print(String(decoding: data, as: UTF8.self))
    exit(matched ? 0 : 2)
}

private func setSignalHandler() {
    // Ctrl-C terminates the process; default disposition already does that.
    // Installed explicitly so the subscription socket closes via process exit.
    signal(SIGINT, SIG_DFL)
}

func runEventsSubscribe(client: ControlClient, options: Options) throws {
    setSignalHandler()
    _ = try client.openSubscription(agentID: options.value("agent"))
    while true {
        guard let frame = try client.nextEventFrame() else {
            // Normal termination is SIGINT (default disposition); a nil frame
            // is an unexpected server disconnect and must not exit 0.
            fail("connection closed by server")
        }
        let data = jsonEncoded(jsonValueToFoundation(.object(frame)))
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout) // flush stdio so piped readers observe frames line-by-line
    }
}

func tokenFromOptionsOrEnvironment(_ options: Options) throws -> String {
    if let explicit = options.value("token") {
        return explicit
    }
    if let fromEnvironment = ProcessInfo.processInfo.environment["AGENT_TERMINAL_TOKEN"] {
        return fromEnvironment
    }
    throw ControlFailure.badRequest("hook token required (--token or AGENT_TERMINAL_TOKEN)")
}

func runIntegrationReport(client: ControlClient, options: Options) throws {
    var params: [String: JSONValue] = try [
        "agentID": .string(options.require("agent-id")),
        "surfaceGeneration": .int(options.int("surface-generation")),
        "source": .string(options.require("source")),
        "token": .string(tokenFromOptionsOrEnvironment(options)),
    ]
    if let terminalID = options.value("terminal-id") {
        params["terminalID"] = .string(terminalID)
    }
    if let seq = try strictNonNegativeInteger(options.value("seq"), name: "seq") {
        params["seq"] = .uint64(seq)
    }
    if let reference = options.value("session-reference") {
        guard let jsonData = reference.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: jsonData)
        else {
            throw ControlFailure.badRequest("option --session-reference must be valid JSON")
        }
        params["sessionReference"] = foundationToJSONValue(decoded)
    }
    try printResponse(client.roundtrip(method: ControlMethod.integrationReport.rawValue, params: params))
}

func foundationToJSONValue(_ any: Any) -> JSONValue {
    switch any {
    case is NSNull: return .null
    case let number as NSNumber:
        if number.isBoolean {
            return .bool(number.boolValue)
        }
        // Route by objCType so integers keep their exact value on the wire
        // (a .double round-trip corrupts magnitudes beyond 2^53).
        switch String(cString: number.objCType) {
        case "C", "I", "S", "L", "Q":
            // Magnitudes beyond Int64.max would wrap to a negative value
            // through Int64(bitPattern:); degrade to double instead of
            // corrupting them on the wire.
            if number.uint64Value > UInt64(Int64.max) {
                return .double(number.doubleValue)
            }
            return .int(Int64(bitPattern: number.uint64Value))
        case "c", "i", "s", "l", "q": return .int(number.int64Value)
        default: return .double(number.doubleValue)
        }
    case let string as String: return .string(string)
    case let array as [Any]: return .array(array.map(foundationToJSONValue))
    case let dictionary as [String: Any]:
        var result: [String: JSONValue] = [:]
        for (key, value) in dictionary {
            result[key] = foundationToJSONValue(value)
        }
        return .object(result)
    default: return .null
    }
}

extension NSNumber {
    var isBoolean: Bool {
        String(cString: objCType) == "c" || CFGetTypeID(self) == CFBooleanGetTypeID()
    }
}

func runIntegrationRelease(client: ControlClient, options: Options) throws {
    let params: [String: JSONValue] = try [
        "agentID": .string(options.require("agent-id")),
        "surfaceGeneration": .int(options.int("surface-generation")),
        "source": .string(options.require("source")),
        "token": .string(tokenFromOptionsOrEnvironment(options)),
    ]
    try printResponse(client.roundtrip(method: ControlMethod.integrationRelease.rawValue, params: params))
}

func runLauncher(kind: String, client: ControlClient, options: Options) throws {
    var params: [String: JSONValue] = try [
        "agentID": .string(options.require("agent-id")),
        "surfaceGeneration": .int(options.int("surface-generation")),
        "token": .string(tokenFromOptionsOrEnvironment(options)),
    ]
    if kind == "started" {
        params["terminalID"] = try .string(options.require("terminal-id"))
        if let pid = options.value("pid") {
            guard let pidValue = Int32(pid) else {
                throw ControlFailure.badRequest("option --pid must be a 32-bit integer")
            }
            params["pid"] = .int(Int64(pidValue))
        }
        if let pgid = options.value("process-group-id") {
            guard let pgidValue = Int32(pgid) else {
                throw ControlFailure.badRequest("option --process-group-id must be a 32-bit integer")
            }
            params["processGroupID"] = .int(Int64(pgidValue))
        }
    } else {
        params["reason"] = try .string(options.require("reason"))
    }
    let method: ControlMethod = kind == "started" ? .launcherStarted : .launcherFailed
    try printResponse(client.roundtrip(method: method.rawValue, params: params))
}

// MARK: - Entry point

// Belt-and-braces next to the server's UnixSocketServer.start: if the server
// dies mid-write, ControlClient writes must report EPIPE through the normal
// error path instead of killing this process with SIGPIPE.
_ = signal(SIGPIPE, SIG_IGN)

let allArguments = Array(CommandLine.arguments.dropFirst())

var socketPath = defaultSocketPath()
var rest = allArguments
// The global --socket may appear anywhere in argv (the CLI's own harness
// appends it last), so the pre-scan walks the whole line — but a bare `--`
// ends option scanning: tokens after it are command text, never options.
let optionsEnd = rest.firstIndex(of: "--") ?? rest.endIndex
let globalRegion = rest[..<optionsEnd]
let assignedIndex = globalRegion.firstIndex(where: { $0.hasPrefix("--socket=") })
let flagIndex = assignedIndex == nil ? globalRegion.firstIndex(of: "--socket") : nil
if let flagIndex, rest.indices.contains(flagIndex + 1),
   flagIndex + 1 < optionsEnd, !rest[flagIndex + 1].hasPrefix("--")
{
    socketPath = rest[flagIndex + 1]
    rest.removeSubrange(flagIndex ... flagIndex + 1)
} else if let assignedIndex {
    socketPath = String(rest[assignedIndex].dropFirst("--socket=".count))
    rest.remove(at: assignedIndex)
} else if globalRegion.contains("--socket") {
    fail("option --socket requires a value")
}

guard let command = rest.first else {
    fail("usage: agentctl [--socket PATH] <ping | workspace list | agent ...> \n\(version)")
}

let subcommandArguments = Array(rest.dropFirst())

do {
    let (positional, options) = Options.parse(subcommandArguments, flagsWithValues: [
        "workspace", "kind", "dir", "name", "task-summary",
        "policy", "command-id", "lifecycle", "min-revision", "timeout-ms",
        "source", "mode", "agent", "agent-id", "terminal-id",
        "surface-generation", "seq", "token", "session-reference",
        "pid", "process-group-id", "reason",
    ])

    let client = try ControlClient(socketPath: socketPath)
    defer { client.close() }
    try client.handshake()

    switch command {
    case "system":
        guard positional.first == "ping" else { fail("unknown system subcommand") }
        try runPing(client: client)
    case "ping":
        try runPing(client: client)
    case "workspace":
        guard positional.first == "list" else { fail("unknown workspace subcommand") }
        try runWorkspaceList(client: client)
    case "agent":
        guard let action = positional.first else { fail("missing agent action") }
        switch action {
        case "create": try runAgentCreate(client: client, options: options)
        case "list": try runAgentList(client: client, options: options)
        case "get": try runAgentGet(client: client, options: options, positional: positional)
        case "prompt": try runAgentPrompt(client: client, options: options, positional: positional)
        case "wait": try runAgentWait(client: client, options: options, positional: positional)
        case "read": try simpleAgentAction(client: client, method: .agentRead, options: options, positional: positional)
        case "focus": try simpleAgentAction(
                client: client,
                method: .agentFocus,
                options: options,
                positional: positional
            )
        case "interrupt": try simpleAgentAction(
                client: client,
                method: .agentInterrupt,
                options: options,
                positional: positional
            )
        case "stop": try simpleAgentAction(client: client, method: .agentStop, options: options, positional: positional)
        case "resume": try simpleAgentAction(
                client: client,
                method: .agentResume,
                options: options,
                positional: positional
            )
        case "cancel-queued-prompt": try simpleAgentAction(
                client: client,
                method: .agentCancelQueuedPrompt,
                options: options,
                positional: positional
            )
        default: fail("unknown agent action '\(action)'")
        }
    case "events":
        guard positional.first == "subscribe" else { fail("unknown events subcommand") }
        try runEventsSubscribe(client: client, options: options)
    case "integration":
        guard let action = positional.first else { fail("missing integration action") }
        switch action {
        case "report": try runIntegrationReport(client: client, options: options)
        case "release": try runIntegrationRelease(client: client, options: options)
        default: fail("unknown integration action '\(action)'")
        }
    case "launcher":
        guard let action = positional.first else { fail("missing launcher action") }
        try runLauncher(kind: action, client: client, options: options)
    default:
        fail("unknown command '\(command)'")
    }
} catch let failure as ControlFailure {
    fail("\(failure.code.rawValue): \(failure.message)")
} catch let socketError as SocketError {
    fail("\(socketError)")
} catch {
    fail("internal error")
}

import Foundation

// Integration validator (architecture §3.17 steps 6 & 9).
//
// Syntax validation per target format plus integration self-test execution:
// run the hook shim in dry-run mode and assert it emits a well-formed
// NDJSON report WITHOUT touching any socket. Foundation-only (§3.2);
// `node --check` is used opportunistically when available.

public struct SyntaxValidationResult: Equatable, Sendable {
    public let isValid: Bool
    public let diagnostics: [String]

    public init(isValid: Bool, diagnostics: [String] = []) {
        self.isValid = isValid
        self.diagnostics = diagnostics
    }

    public static let valid = SyntaxValidationResult(isValid: true)
}

/// One parsed NDJSON report line emitted by a shim in dry-run mode.
public struct NDJSONReport: @unchecked Sendable {
    public let object: [String: Any]

    public init(object: [String: Any]) {
        self.object = object
    }

    var canonical: String {
        IntegrationSelfTestResult.canonical(object)
    }
}

public struct IntegrationSelfTestResult: Equatable, Sendable {
    public let succeeded: Bool
    /// Parsed NDJSON report objects emitted by the shim in dry-run mode.
    public let reports: [NDJSONReport]
    public let diagnostics: [String]

    public static func == (lhs: IntegrationSelfTestResult, rhs: IntegrationSelfTestResult) -> Bool {
        lhs.succeeded == rhs.succeeded && lhs.diagnostics == rhs.diagnostics
            && lhs.reports.map(\.canonical) == rhs.reports.map(\.canonical)
    }

    static func canonical(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return String(describing: object)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Bounded child-process execution

/// Runs a child process with event-driven output collection and a hard
/// deadline.
///
/// `readDataToEndOfFile()` never returns when a child spawns a grandchild
/// that inherits the pipe and outlives it, and `Process.terminate()` signals
/// only the direct child — so EOF may never arrive even after the parent is
/// dead. This runner therefore accumulates output through readability
/// handlers, escalates an unmet deadline to SIGKILL, reaps the child through
/// its termination handler (no zombies), and waits at most `eofGrace` for
/// EOF after the child is observed exiting before giving up. It returns
/// exactly once.
/// Consumed by TerminalKit's `ShellEnvironmentResolver` for its bounded
/// login-shell environment probe.
public enum ManagedChildProcess {
    public struct Outcome {
        public let stdout: Data
        let stderr: Data
        /// Exit status of the direct child once observed; nil when it never
        /// exited within the bounded window.
        public let terminationStatus: Int32?
        /// True when the deadline fired and SIGKILL was sent.
        public let deadlineFired: Bool

        init(stdout: Data, stderr: Data, terminationStatus: Int32?, deadlineFired: Bool) {
            self.stdout = stdout
            self.stderr = stderr
            self.terminationStatus = terminationStatus
            self.deadlineFired = deadlineFired
        }
    }

    /// Per-run state shared between the readability/termination handlers and
    /// the waiting caller. All access is lock-guarded so each flag flips and
    /// buffers append exactly once from any queue.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()
        private var exited = false
        private var deadlineFired = false

        func appendStdout(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }; stdoutData.append(chunk)
        }

        func appendStderr(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }; stderrData.append(chunk)
        }

        func markExited() {
            lock.lock(); defer { lock.unlock() }; exited = true
        }

        func markDeadlineFired() {
            lock.lock(); defer { lock.unlock() }; deadlineFired = true
        }

        var hasExited: Bool {
            lock.lock(); defer { lock.unlock() }
            return exited
        }

        var hasFiredDeadline: Bool {
            lock.lock(); defer { lock.unlock() }
            return deadlineFired
        }

        var output: (stdout: Data, stderr: Data) {
            lock.lock(); defer { lock.unlock() }
            return (stdoutData, stderrData)
        }
    }

    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        deadline: TimeInterval,
        eofGrace: TimeInterval = 0.5
    ) throws -> Outcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = RunState()
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            state.markExited()
            exitSignal.signal()
        }

        func watch(
            _ handle: FileHandle,
            append: @escaping @Sendable (Data) -> Void,
            onEOF: @escaping @Sendable () -> Void
        ) {
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    onEOF()
                } else {
                    append(chunk)
                }
            }
        }
        let stdoutEOF = DispatchSemaphore(value: 0)
        let stderrEOF = DispatchSemaphore(value: 0)
        watch(stdoutPipe.fileHandleForReading, append: state.appendStdout, onEOF: { stdoutEOF.signal() })
        watch(stderrPipe.fileHandleForReading, append: state.appendStderr, onEOF: { stderrEOF.signal() })

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        // Hard deadline: escalate straight to SIGKILL. Only the direct child
        // dies, but the termination handler still reaps it and every wait
        // below is bounded, so a surviving descendant cannot wedge us.
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
            if !state.hasExited, process.isRunning {
                state.markDeadlineFired()
                kill(process.processIdentifier, SIGKILL)
            }
        }

        _ = exitSignal.wait(timeout: .now() + deadline + eofGrace)

        if state.hasExited {
            // Bounded grace for EOF so output flushed around exit is captured
            // even when a lingering descendant keeps the pipe open.
            _ = stdoutEOF.wait(timeout: .now() + eofGrace)
            _ = stderrEOF.wait(timeout: .now() + eofGrace)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let collected = state.output
        return Outcome(
            stdout: collected.stdout,
            stderr: collected.stderr,
            terminationStatus: state.hasExited ? process.terminationStatus : nil,
            deadlineFired: state.hasFiredDeadline
        )
    }
}

public enum IntegrationValidator {
    // MARK: Syntax validation (§3.17 step 6)

    public static func validateSyntax(_ content: String, format: ConfigFileFormat) -> SyntaxValidationResult {
        switch format {
        case .json:
            validateJSON(content)
        case .toml:
            validateTOML(content)
        case .javaScript:
            validateJavaScript(content)
        }
    }

    public static func validateFile(at path: String, format: ConfigFileFormat) -> SyntaxValidationResult {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return SyntaxValidationResult(isValid: false, diagnostics: ["cannot read \(path)"])
        }
        return validateSyntax(String(decoding: data, as: UTF8.self), format: format)
    }

    private static func validateJSON(_ content: String) -> SyntaxValidationResult {
        guard let data = content.data(using: .utf8) else {
            return SyntaxValidationResult(isValid: false, diagnostics: ["content is not UTF-8"])
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return .valid
        } catch {
            return SyntaxValidationResult(isValid: false, diagnostics: ["invalid JSON: \(error.localizedDescription)"])
        }
    }

    private static func validateTOML(_ content: String) -> SyntaxValidationResult {
        do {
            _ = try TOMLParser.parse(content)
            return .valid
        } catch let error as TOMLParseError {
            return SyntaxValidationResult(isValid: false, diagnostics: ["invalid TOML: \(error)"])
        } catch {
            return SyntaxValidationResult(isValid: false, diagnostics: ["invalid TOML: \(error)"])
        }
    }

    private static func validateJavaScript(_ content: String) -> SyntaxValidationResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return SyntaxValidationResult(isValid: false, diagnostics: ["empty plugin source"])
        }

        // Structural check: balanced brackets outside strings/comments. The
        // scanner has no regex-literal state, so a literal like /[({]/ reads
        // as a mismatched closer; that verdict is only a gate — when node is
        // present, `node --check` arbitrates it. Findings at end of input
        // (unclosed construct, unterminated string) are different: no regex
        // literal can produce them in otherwise-valid code, and node's
        // module auto-detection can let them slip through, so they stand.
        var diagnostics: [String] = []

        var depthStack: [Character] = []
        var mismatchedClose = false
        var inString: Character? = nil
        var escaped = false
        var inLineComment = false
        var inBlockComment = false
        var previous: Character = "\0"
        scanning: for character in content {
            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                }
                previous = character
                continue
            }
            if inBlockComment {
                if previous == "*", character == "/" {
                    inBlockComment = false
                }
                previous = character
                continue
            }
            if let quote = inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == quote {
                    inString = nil
                }
                previous = character
                continue
            }
            switch character {
            case "/":
                if previous == "/" {
                    inLineComment = true
                }
            case "*":
                if previous == "/" {
                    inBlockComment = true
                }
            case "\"", "'", "`":
                inString = character
            case "(", "[", "{":
                depthStack.append(character)
            case ")", "]", "}":
                let expected: Character = character == ")" ? "(" : character == "]" ? "[" : "{"
                guard depthStack.last == expected else {
                    diagnostics.append("unbalanced '\(character)'")
                    mismatchedClose = true
                    break scanning
                }
                depthStack.removeLast()
            default:
                break
            }
            previous = character
        }
        // An aborted scan leaves the stack mid-flight; leftover depth there
        // is expected, not evidence of an unclosed construct.
        let structuralFailure = !mismatchedClose && (inString != nil || !depthStack.isEmpty)
        if inString != nil {
            diagnostics.append("unterminated string literal")
        }
        if !depthStack.isEmpty {
            diagnostics.append("unclosed \(String(depthStack))")
        }

        if let nodePath = locateNode() {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".js")
            do {
                try content.data(using: .utf8)?.write(to: temporary)
                defer { try? FileManager.default.removeItem(at: temporary) }

                let outcome = try ManagedChildProcess.run(
                    executableURL: URL(fileURLWithPath: nodePath),
                    arguments: ["--check", temporary.path],
                    deadline: 10
                )
                // `node --check` arbitrates a mismatched-close suspicion:
                // acceptance clears it (regex-literal false positive), a
                // rejection stands. End-of-input findings keep their own
                // verdict even when node's ESM auto-detection accepts.
                guard !outcome.deadlineFired else {
                    diagnostics.append("node --check timed out")
                    return SyntaxValidationResult(isValid: false, diagnostics: diagnostics)
                }
                if outcome.terminationStatus != 0 {
                    diagnostics
                        .append(
                            "node --check rejected source: \(String(decoding: outcome.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))"
                        )
                    return SyntaxValidationResult(isValid: false, diagnostics: diagnostics)
                }
                // Node accepted: any remaining diagnostics were scanner
                // suspicion, so report a clean pass.
                return structuralFailure ? SyntaxValidationResult(isValid: false, diagnostics: diagnostics) : .valid
            } catch {
                diagnostics.append("node --check failed to run: \(error.localizedDescription)")
                return SyntaxValidationResult(isValid: false, diagnostics: diagnostics)
            }
        }

        // No node binary: the scanner verdict is all we have. A clean scan
        // passes (structural checks only); a rejection reports as invalid.
        return SyntaxValidationResult(isValid: diagnostics.isEmpty, diagnostics: diagnostics)
    }

    private static func locateNode() -> String? {
        for candidate in ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
            where FileManager.default.isExecutableFile(atPath: candidate)
        {
            return candidate
        }
        // Fall back to PATH lookup.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for directory in path.split(separator: ":") {
            let candidate = directory + "/node"
            if FileManager.default.isExecutableFile(atPath: String(candidate)) {
                return String(candidate)
            }
        }
        return nil
    }

    // MARK: Self-test execution (§3.17 step 9)

    /// Runs a hook shim in dry-run mode (`AGENT_TERMINAL_DRY_RUN=1`) and asserts
    /// it emits well-formed NDJSON reports without touching any socket.
    ///
    /// - Parameters:
    ///   - scriptPath: absolute path of the shim or plugin runner.
    ///   - interpreter: interpreter argv prefix; empty for executable shims.
    ///   - environment: launch environment (AGENT_TERMINAL_* values); token is
    ///     required so the dry-run output proves the token rule is honored.
    ///   - requiredFields: fields every emitted report line must carry.
    public static func runSelfTest(
        scriptPath: String,
        interpreter: [String] = ["/bin/sh"],
        environment: [String: String],
        requiredFields: Set<String> = ["agentID", "surfaceGeneration", "source", "seq", "tokenPresent"]
    ) -> IntegrationSelfTestResult {
        var env = environment
        env["AGENT_TERMINAL_DRY_RUN"] = "1"

        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            processEnvironment[key] = value
        }

        let outcome: ManagedChildProcess.Outcome
        do {
            outcome = try ManagedChildProcess.run(
                executableURL: URL(fileURLWithPath: interpreter.first ?? "/bin/sh"),
                arguments: Array(interpreter.dropFirst()) + [scriptPath],
                environment: processEnvironment,
                deadline: 15
            )
        } catch {
            return IntegrationSelfTestResult(
                succeeded: false,
                reports: [],
                diagnostics: ["failed to launch: \(error.localizedDescription)"]
            )
        }

        if outcome.deadlineFired {
            return IntegrationSelfTestResult(succeeded: false, reports: [], diagnostics: ["self-test timed out"])
        }

        let outputData = outcome.stdout
        var diagnostics: [String] = []
        var reports: [NDJSONReport] = []

        for line in String(decoding: outputData, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let report = object as? [String: Any]
            else {
                diagnostics.append("non-JSON output line: \(trimmed.prefix(80))")
                continue
            }
            let missing = requiredFields.subtracting(report.keys)
            if !missing.isEmpty {
                diagnostics.append("report missing fields: \(missing.sorted().joined(separator: ","))")
            }
            if report["token"] != nil {
                diagnostics.append("dry-run leaked raw token")
            }
            reports.append(NDJSONReport(object: report))
        }
        if reports.isEmpty, diagnostics.isEmpty {
            diagnostics.append("no NDJSON report produced")
        }

        return IntegrationSelfTestResult(
            succeeded: diagnostics.isEmpty && !reports.isEmpty,
            reports: reports,
            diagnostics: diagnostics
        )
    }
}

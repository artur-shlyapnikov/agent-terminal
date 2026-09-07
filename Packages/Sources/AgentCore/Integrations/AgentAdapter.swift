import Foundation

// AgentAdapter contract (architecture §3.10).
//
// Adapters are stateless value services: they translate between generic
// domain requests and agent-specific launch/resume/integration material.

/// What an integration can report. A session-identity hook never becomes
/// lifecycle authority — only `complete` lifecycles do (§3.6).
public enum LifecycleCapability: Equatable, Sendable {
    case none
    case partial
    case complete(LeasePolicy)
}

public enum LeasePolicy: Equatable, Sendable {
    /// Authority holds until the plugin explicitly releases it.
    case explicitRelease
    /// Authority holds while heartbeats arrive within the timeout.
    case heartbeat(timeout: Duration)
    /// Authority holds until the process generation ends.
    case processGeneration
}

public struct AgentIntegrationCapability: Equatable, Sendable {
    public let sessionIdentity: Bool
    public let lifecycle: LifecycleCapability
    public let screenFallback: Bool

    public init(sessionIdentity: Bool, lifecycle: LifecycleCapability, screenFallback: Bool) {
        self.sessionIdentity = sessionIdentity
        self.lifecycle = lifecycle
        self.screenFallback = screenFallback
    }

    public var isProcessOnly: Bool {
        !sessionIdentity && lifecycle == .none && !screenFallback
    }
}

public enum InstallationStatus: Equatable, Sendable {
    case installed(executablePath: String, version: String?)
    case notInstalled
}

/// Raw integration report as delivered by a hook/plugin through agentctl,
/// before adapter-specific normalization.
public struct IntegrationReport: Equatable, Sendable {
    public let seq: UInt64
    public let lifecycleText: String?
    public let sessionReferencePayload: String?
    public let inputRequestKindText: String?
    public let inputRequestSummary: String?
    public let operationStartedID: String?
    public let operationCompletedID: String?

    public init(
        seq: UInt64,
        lifecycleText: String? = nil,
        sessionReferencePayload: String? = nil,
        inputRequestKindText: String? = nil,
        inputRequestSummary: String? = nil,
        operationStartedID: String? = nil,
        operationCompletedID: String? = nil
    ) {
        self.seq = seq
        self.lifecycleText = lifecycleText
        self.sessionReferencePayload = sessionReferencePayload
        self.inputRequestKindText = inputRequestKindText
        self.inputRequestSummary = inputRequestSummary
        self.operationStartedID = operationStartedID
        self.operationCompletedID = operationCompletedID
    }
}

public protocol AgentAdapter: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: AgentIntegrationCapability { get }
    var executableCandidates: [String] { get }

    func detectInstallation() async -> InstallationStatus
    func detectVersion(executablePath: String) async -> String?

    /// Builds the persistable, non-secret launch profile (§3.3).
    func makeLaunchDescriptor(request: AgentLaunchRequest) throws -> LaunchDescriptor

    /// Fully resolved argv/env/cwd handed to the terminal layer's ticket writer.
    func buildLaunchSpec(descriptor: LaunchDescriptor) -> LaunchSpec

    /// Adapter-generated resume command, or nil when unsupported (§3.10).
    func buildResumeSpec(sessionReference: SessionReference) -> ResumeSpec?

    /// Resource name of the bundled screen manifest, if any (§3.7).
    var bundledManifestName: String? { get }

    /// The AgentKind this adapter serves; nil when unregistered by kind.
    var bundledAgentKind: AgentKind? { get }

    /// Declarative edits the integration installer would apply (§3.17).
    func integrationInstallPlan() -> IntegrationInstallPlan

    /// Normalizes a raw hook/plugin report into typed evidence payloads.
    func normalizeIntegrationReport(_ report: IntegrationReport) throws -> NormalizedIntegrationReport
}

public struct NormalizedIntegrationReport: Equatable, Sendable {
    public var lifecycle: LifecyclePhase?
    public var sessionReference: SessionReference?
    public var inputRequest: InputRequestDescriptor?
    public var operation: IntegrationOperation?

    public init(
        lifecycle: LifecyclePhase? = nil,
        sessionReference: SessionReference? = nil,
        inputRequest: InputRequestDescriptor? = nil,
        operation: IntegrationOperation? = nil
    ) {
        self.lifecycle = lifecycle
        self.sessionReference = sessionReference
        self.inputRequest = inputRequest
        self.operation = operation
    }
}

// MARK: Default implementations shared by all adapters

public extension AgentAdapter {
    /// Scans PATH for the first executable candidate (Foundation-only).
    func detectInstallation() async -> InstallationStatus {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        let fileManager = FileManager.default
        for candidate in executableCandidates where candidate.hasPrefix("/") {
            if fileManager.isExecutableFile(atPath: candidate) {
                return .installed(executablePath: candidate, version: nil)
            }
        }
        for directory in path.split(separator: ":").map(String.init) {
            for candidate in executableCandidates {
                let full = (directory as NSString).appendingPathComponent(candidate)
                if fileManager.isExecutableFile(atPath: full) {
                    return .installed(executablePath: full, version: nil)
                }
            }
        }
        return .notInstalled
    }

    /// Runs `<executable> --version` under a 3 s hard deadline via
    /// `ManagedChildProcess`: event-driven output collection, SIGKILL
    /// escalation, guaranteed reaping, and bounded EOF grace — so a child
    /// that spawns an output-inheriting grandchild can never wedge the read.
    func detectVersion(executablePath: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let outcome: ManagedChildProcess.Outcome
                do {
                    outcome = try ManagedChildProcess.run(
                        executableURL: URL(fileURLWithPath: executablePath),
                        arguments: ["--version"],
                        deadline: 3
                    )
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                guard !outcome.deadlineFired else {
                    continuation.resume(returning: nil)
                    return
                }

                let text = String(decoding: outcome.stdout, as: UTF8.self)
                continuation.resume(returning: text.split(separator: "\n").first.map(String.init))
            }
        }
    }
}

extension AgentAdapter {
    /// Common normalization: lifecycle vocabulary matches the manifest strings;
    /// screen-sourced safety defaults never apply here (integration source).
    public func normalizeIntegrationReport(_ report: IntegrationReport) throws -> NormalizedIntegrationReport {
        var normalized = NormalizedIntegrationReport()

        if let lifecycleText = report.lifecycleText {
            let requestKind: InputRequestKind? =
                report.inputRequestKindText.flatMap { try? ScreenManifestLoader.decodeRequestKind($0) }
            normalized.lifecycle = try ScreenManifestLoader.decodeLifecycle(
                lifecycleText,
                requestKind: requestKind,
                ruleID: "\(id)-hook"
            )
        }
        if let kindText = report.inputRequestKindText {
            let kind = try ScreenManifestLoader.decodeRequestKind(kindText)
            // Hook-reported requests may allow the composer only for freeText.
            let mode: SafeReplyMode = kind == .freeText ? .composerAllowed : .terminalOnly
            normalized.inputRequest = InputRequestDescriptor(
                kind: kind,
                summary: report.inputRequestSummary,
                safeReplyMode: mode,
                source: .integration
            )
        }
        if let payload = report.sessionReferencePayload {
            normalized.sessionReference = SessionReference(agentKind: kindForReports(), opaquePayload: payload)
        }
        if let started = report.operationStartedID {
            normalized.operation = .started(operationID: started)
        } else if let completed = report.operationCompletedID {
            normalized.operation = .completed(operationID: completed)
        }
        return normalized
    }

    private func kindForReports() -> AgentKind {
        switch id {
        case ClaudeCodeAdapter.staticID: .claudeCode
        case CodexAdapter.staticID: .codex
        case OpenCodeAdapter.staticID: .openCode
        default: .genericShell
        }
    }
}

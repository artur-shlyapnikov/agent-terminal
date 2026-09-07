import Foundation

/// One-shot launch ticket handed from the app to the `AgentLauncher` helper
/// process (architecture §3.9).
///
/// Shared contract between `TerminalKit/LaunchTicketWriter` (producer) and the
/// `AgentLauncher` executable (consumer). Lives in AgentCore so both sides
/// cannot drift; it is pure Foundation data — no I/O, no secrets handling
/// beyond "never log me" (fields are excluded from all descriptions).
///
/// Security invariants enforced by the WRITER and re-verified by the CONSUMER:
/// file mode 0600, TTL 60 s, single use (atomic rename to `consuming` before
/// read), owner UID must match, symlinks rejected, deleted after read.
public struct LaunchTicket: Codable, Equatable, Sendable {
    /// Bump on any wire-incompatible change; launcher rejects mismatches.
    public static let currentProtocolVersion = 1

    /// Ticket time-to-live in seconds (architecture §3.9).
    public static let defaultTTL: Double = 60

    public var protocolVersion: Int
    public var ticketID: UUID
    public var agentID: UUID
    public var terminalID: UUID
    public var surfaceGeneration: UInt64
    public var expectedUID: UInt32
    /// Epoch seconds.
    public var createdAt: Double
    /// Epoch seconds; `createdAt + ttl`.
    public var expiresAt: Double
    public var cwd: String
    /// Exact argv, exec'd without any shell interpolation.
    public var argv: [String]
    /// Full environment for the child; never persisted anywhere.
    public var environment: [String: String]
    /// Scoped per-process-generation hook token (§3.16); never persisted.
    public var integrationToken: String
    public var controlSocketPath: String

    public init(
        protocolVersion: Int = LaunchTicket.currentProtocolVersion,
        ticketID: UUID,
        agentID: UUID,
        terminalID: UUID,
        surfaceGeneration: UInt64,
        expectedUID: UInt32,
        createdAt: Double,
        expiresAt: Double,
        cwd: String,
        argv: [String],
        environment: [String: String],
        integrationToken: String,
        controlSocketPath: String
    ) {
        self.protocolVersion = protocolVersion
        self.ticketID = ticketID
        self.agentID = agentID
        self.terminalID = terminalID
        self.surfaceGeneration = surfaceGeneration
        self.expectedUID = expectedUID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.cwd = cwd
        self.argv = argv
        self.environment = environment
        self.integrationToken = integrationToken
        self.controlSocketPath = controlSocketPath
    }

    /// Factory using wall-clock `now` and the current UID by default.
    public static func make(
        agentID: UUID,
        terminalID: UUID,
        surfaceGeneration: UInt64,
        cwd: String,
        argv: [String],
        environment: [String: String],
        integrationToken: String,
        controlSocketPath: String,
        now: Double,
        ttl: Double = LaunchTicket.defaultTTL,
        expectedUID: UInt32 = UInt32(getuid())
    ) -> LaunchTicket {
        LaunchTicket(
            ticketID: UUID(),
            agentID: agentID,
            terminalID: terminalID,
            surfaceGeneration: surfaceGeneration,
            expectedUID: expectedUID,
            createdAt: now,
            expiresAt: now + ttl,
            cwd: cwd,
            argv: argv,
            environment: environment,
            integrationToken: integrationToken,
            controlSocketPath: controlSocketPath
        )
    }

    public func isExpired(atEpochSeconds now: Double) -> Bool {
        now >= expiresAt
    }

    public func isProtocolSupported() -> Bool {
        protocolVersion == LaunchTicket.currentProtocolVersion
    }

    public func matchesCurrentUID(_ uid: UInt32) -> Bool {
        uid == expectedUID
    }
}

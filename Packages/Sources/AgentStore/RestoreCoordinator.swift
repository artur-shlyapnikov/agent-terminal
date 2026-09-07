import AgentCore
import Foundation
import GRDB

// Restore coordination (architecture §3.15). Called ONCE at startup, after
// DB open + migrations and BEFORE any surface exists:
//
//   1. runs left open by a previous process are marked `.unclean`;
//   2. a fresh app_runs row opens for THIS process;
//   3a. clean quit path: `resume_requested` rows are validated against their
//       adapter's resume capability (§3.10 table) and become resume actions;
//   3b. crash path: NO agent auto-starts — every previously-running agent
//       becomes a Recovery Center candidate instead;
//   4. unsupported sessions (generic shells, missing/invalid references) are
//       reported explicitly, never silently dropped.
//
// The returned plan is consumed by the App composition root; this module
// never touches surfaces or processes.

/// One validated resume: launch the adapter-generated command through the
/// app's launch pipeline, then clear the persisted flag (§3.15 step 9).
public struct RestoreResumeAction: Equatable, Sendable {
    /// Persisted agents row that carries `resume_requested` — the flag is
    /// cleared against THIS id after confirmed launch.
    public let persistedAgentID: AgentID
    public let workspaceID: WorkspaceID
    public let kind: AgentKind
    public let displayName: String
    public let cwd: String
    public let sessionReference: SessionReference
    public let resumeSpec: ResumeSpec

    public init(
        persistedAgentID: AgentID,
        workspaceID: WorkspaceID,
        kind: AgentKind,
        displayName: String,
        cwd: String,
        sessionReference: SessionReference,
        resumeSpec: ResumeSpec
    ) {
        self.persistedAgentID = persistedAgentID
        self.workspaceID = workspaceID
        self.kind = kind
        self.displayName = displayName
        self.cwd = cwd
        self.sessionReference = sessionReference
        self.resumeSpec = resumeSpec
    }
}

/// A session that cannot resume; surfaced to the operator in both the quit
/// sheet (before quitting) and the Recovery Center (start-fresh-only).
public struct UnsupportedSession: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Adapter has no resume semantics (e.g. generic shell, §3.10).
        case adapterUnsupported
        /// No session reference was captured for this agent.
        case missingSessionReference
    }

    public let agentID: AgentID
    public let displayName: String
    public let kind: AgentKind
    public let reason: Reason

    public var reasonText: String {
        switch reason {
        case .adapterUnsupported: "adapter cannot resume sessions"
        case .missingSessionReference: "no session reference was captured"
        }
    }
}

/// A previously-running agent after an unclean termination. Its session
/// reference is preserved until a successful new launch (§3.15).
public struct RecoveryCandidate: Equatable, Sendable {
    public let agentID: AgentID
    public let workspaceID: WorkspaceID
    public let kind: AgentKind
    public let displayName: String
    public let cwd: String
    public let sessionReference: SessionReference?
    public let canResume: Bool
    public let unsupportedReason: UnsupportedSession.Reason?

    /// Start-Fresh-only candidates appear in both the quit-sheet listing and
    /// the Recovery Center as unsupported sessions (§3.15).
    public var unsupportedReasonText: String? {
        guard let reason = unsupportedReason else { return nil }
        return UnsupportedSession(
            agentID: agentID, displayName: displayName, kind: kind,
            reason: reason
        ).reasonText
    }
}

public struct CleanRestorePlan: Equatable, Sendable {
    public let currentRunID: Int64
    public let resumes: [RestoreResumeAction]
    /// Rows whose persisted reference blob is corrupt (present but
    /// undecodable): data corruption is crash-recovery territory (§3.15),
    /// NOT an adapter-capability report.
    public var crashCandidates: [RecoveryCandidate] = []
    public let unsupported: [UnsupportedSession]
}

public struct CrashRecoveryPlan: Equatable, Sendable {
    public let currentRunID: Int64
    /// Previous run rows this startup closed as `.unclean`.
    public let unclosedRuns: [AppRun]
    public let candidates: [RecoveryCandidate]
}

public enum RestorePlan: Equatable, Sendable {
    case clean(CleanRestorePlan)
    case crashRecovery(CrashRecoveryPlan)

    public var currentRunID: Int64 {
        switch self {
        case let .clean(plan): plan.currentRunID
        case let .crashRecovery(plan): plan.currentRunID
        }
    }
}

public final class RestoreCoordinator: Sendable {
    private let transactor: any StoreTransacting
    private let catalog: AgentCatalog

    public init(transactor: any StoreTransacting, catalog: AgentCatalog = .standard()) {
        self.transactor = transactor
        self.catalog = catalog
    }

    public convenience init(database: AgentDatabase, catalog: AgentCatalog = .standard()) {
        self.init(transactor: PoolTransactor(pool: database.pool), catalog: catalog)
    }

    // MARK: - Startup plan

    /// MUST run before any agent surface exists (§3.15 clean-restore order).
    public func prepareStartup(now: Date = Date()) async throws -> RestorePlan {
        let runs = AppRunRepository(transactor: transactor)
        let unclosed = try await runs.detectUnclosedRuns()
        // Closing the unclean runs AND opening this process's run row MUST
        // be one transaction (§3.15): otherwise a crash between them leaves
        // zero unclosed rows and the next launch misreads the crash as clean.
        let currentRunID = try await runs.beginRun(closing: unclosed, endedAt: now)
        let rows = try await liveAgentRows()

        if !unclosed.isEmpty {
            // Crash recovery: nothing starts automatically (§3.15).
            let candidates = rows.compactMap { row -> RecoveryCandidate? in
                guard Self.isPreviouslyRunning(row) else { return nil }
                return recoveryCandidate(from: row)
            }
            // A crash that left nothing recoverable degrades to a clean
            // plan. Recovery-pending with zero candidates wedges startup:
            // the app skips the (empty) Recovery Center, but the pending
            // flag also defers keying the main window with no UI path out
            // — every launch after an unclean kill starts as an unkeyed,
            // empty zombie. The unclean terminations stay recorded on the
            // run rows this startup just closed, so the §3.15 audit trail
            // keeps them. Resumes stay suppressed: §3.15 forbids
            // restarting agents after a crash without user action.
            if candidates.isEmpty {
                return .clean(CleanRestorePlan(
                    currentRunID: currentRunID,
                    resumes: [],
                    crashCandidates: [],
                    unsupported: []
                ))
            }
            return .crashRecovery(CrashRecoveryPlan(
                currentRunID: currentRunID,
                unclosedRuns: unclosed,
                candidates: candidates
            ))
        }
        var resumes: [RestoreResumeAction] = []
        var unsupported: [UnsupportedSession] = []
        var crashCandidates: [RecoveryCandidate] = []
        for row in rows where row.resumeRequested {
            if let action = resumeAction(from: row) {
                resumes.append(action)
            } else if row.sessionRefJSON != nil, decodedReference(from: row) == nil {
                // Corrupt reference blob: data corruption, not an adapter
                // capability limit — a crash-recovery candidate (§3.15).
                crashCandidates.append(recoveryCandidate(from: row))
            } else if let failure = unsupportedFailure(from: row) {
                unsupported.append(failure)
            }
        }
        return .clean(CleanRestorePlan(
            currentRunID: currentRunID,
            resumes: resumes,
            crashCandidates: crashCandidates,
            unsupported: unsupported
        ))
    }

    // MARK: - Classification

    /// Adapter + reference validation per the §3.10 capability table:
    /// claude/codex/opencode resume when a valid session reference exists;
    /// generic shell never does.
    func resumeAction(from row: AgentRow) -> RestoreResumeAction? {
        guard let session = AgentSession.restoring(row),
              let reference = decodedReference(from: row),
              let spec = catalog.adapter(for: session.kind)?
              .buildResumeSpec(sessionReference: reference),
              !spec.argv.isEmpty
        else { return nil }
        return RestoreResumeAction(
            persistedAgentID: session.id,
            workspaceID: session.workspaceID,
            kind: session.kind,
            displayName: session.displayName,
            cwd: session.cwd,
            sessionReference: reference,
            resumeSpec: spec
        )
    }

    /// Why a flagged row cannot resume — nil when it actually CAN.
    func unsupportedFailure(from row: AgentRow) -> UnsupportedSession? {
        let failureReason: UnsupportedSession.Reason? = if decodedReference(from: row) == nil {
            .missingSessionReference
        } else {
            // A reference exists but no adapter accepts it (kind mismatch or
            // generic shell).
            .adapterUnsupported
        }
        guard let reason = failureReason else { return nil }
        // Defensive fallbacks mirror recoveryCandidate: every flagged row must
        // surface, even when kind/id are unparseable.
        return UnsupportedSession(
            agentID: UUID(uuidString: row.id).map(AgentID.init(rawValue:)) ?? AgentID(),
            displayName: row.displayName,
            kind: AgentKind(rawValue: row.kind) ?? .genericShell,
            reason: reason
        )
    }

    private func recoveryCandidate(from row: AgentRow) -> RecoveryCandidate {
        let reference = decodedReference(from: row)
        let kind = AgentKind(rawValue: row.kind) ?? .genericShell
        let canResume: Bool = if let reference,
                                 let spec = catalog.adapter(for: kind)?.buildResumeSpec(sessionReference: reference)
        {
            !spec.argv.isEmpty
        } else {
            false
        }
        return RecoveryCandidate(
            agentID: UUID(uuidString: row.id).map(AgentID.init(rawValue:)) ?? AgentID(),
            workspaceID: UUID(uuidString: row.workspaceID).map(WorkspaceID.init(rawValue:)) ?? WorkspaceID(),
            kind: kind,
            displayName: row.displayName,
            cwd: row.cwd,
            sessionReference: reference,
            canResume: canResume,
            unsupportedReason: canResume ? nil : (reference == nil ? .missingSessionReference : .adapterUnsupported)
        )
    }

    private func decodedReference(from row: AgentRow) -> SessionReference? {
        guard let data = row.sessionRefJSON else { return nil }
        return try? JSONDecoder().decode(SessionReference.self, from: data)
    }

    // MARK: - Row access

    private func liveAgentRows() async throws -> [AgentRow] {
        try await transactor.write { db in
            try AgentRow
                .filter(Column("archived_at") == nil)
                .order(Column("created_at").asc)
                .fetchAll(db)
        }
    }

    /// A persisted terminal whose lifecycle token still reads as live counts
    /// as interrupted-until-a-new-process-exists (§3.15 clean restore step 4).
    static func isPreviouslyRunning(_ row: AgentRow) -> Bool {
        guard row.terminalID != nil else { return false }
        switch LifecycleToken(rawValue: row.lastLifecycle) {
        case .starting, .idle, .working, .waitingForInput, .stopping:
            return true
        case .unknown, .stoppedUserRequested, .stoppedCompleted, .failed, .none:
            return false
        }
    }
}

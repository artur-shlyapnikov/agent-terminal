import Foundation

// Integration installer (architecture §3.17, §5.3).
//
// Safety law: the installer NEVER overwrites a user config wholesale.
// Flow per §3.17: read existing config → diff plan vs reality → backup →
// temp write → syntax validate → atomic rename → record managed
// fingerprints → self-test → restore backup on any error.
//
// Ownership: every managed entry carries the AgentTerminal namespace
// marker (`IntegrationInstallPlan.namespaceMarker`). Uninstall removes ONLY
// entries whose recorded fingerprint still matches — plus orphaned entries
// that carry our marker but lost their fingerprint in a crash between
// atomic rename and recording. A user-modified managed section is a
// conflict and is never overwritten (§5.3 steps 1–2).
//
// Fingerprint persistence goes through the injectable
// `IntegrationInstallRecording` port; wiring to AgentStore happens at the
// composition root (stage 8+). Foundation-only by law (§3.2).

// MARK: - Fingerprints & recording port

/// Proof of what AgentTerminal last wrote at a managed location. Fingerprint
/// equality is exact-content equality — stronger than hashing and boring.
public struct ManagedEntryFingerprint: Equatable, Sendable, Codable {
    public let adapterID: String
    /// Absolute target path as installed.
    public let targetPath: String
    /// Key path of the managed entry inside the document; empty for
    /// whole-content formats (TOML managed block, plugin script).
    public let entryKeyPath: [String]
    public let marker: String
    /// Exact managed content recorded at install time.
    public let managedContent: String

    public init(adapterID: String, targetPath: String, entryKeyPath: [String], marker: String, managedContent: String) {
        self.adapterID = adapterID
        self.targetPath = targetPath
        self.entryKeyPath = entryKeyPath
        self.marker = marker
        self.managedContent = managedContent
    }
}

/// Injectable persistence port for install fingerprints. The installer never
/// touches GRDB directly; the composition root bridges this to
/// AgentStore.IntegrationRepository.
public protocol IntegrationInstallRecording: Sendable {
    func record(_ fingerprints: [ManagedEntryFingerprint]) throws
    func fingerprints(adapterID: String) -> [ManagedEntryFingerprint]
    func removeAll(adapterID: String)
}

/// In-memory recording — used by tests and as a standalone default.
public final class InMemoryInstallRecording: IntegrationInstallRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ManagedEntryFingerprint] = []

    public init() {}

    public func record(_ fingerprints: [ManagedEntryFingerprint]) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll { stored in
            fingerprints
                .contains {
                    $0.adapterID == stored.adapterID && $0.targetPath == stored.targetPath && $0.entryKeyPath == stored
                        .entryKeyPath
                }
        }
        storage.append(contentsOf: fingerprints)
    }

    public func fingerprints(adapterID: String) -> [ManagedEntryFingerprint] {
        lock.lock(); defer { lock.unlock() }
        return storage.filter { $0.adapterID == adapterID }
    }

    public func removeAll(adapterID: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll { $0.adapterID == adapterID }
    }
}

// MARK: - Diff model (§3.17 step 3)

public enum ManagedEntryAction: Equatable, Sendable {
    case add
    /// Our fingerprint matches exactly — safe upgrade in place.
    case replaceManaged
    case unchanged
    /// User edited our managed section — never overwrite (§5.3 step 2).
    case conflictUserModified
    /// User-owned value without our marker — never clobber.
    case conflictUserOwned
    /// Marker present but no fingerprint recorded — crashed install of ours;
    /// adopted on reinstall.
    case adoptOrphaned

    var isApplied: Bool {
        switch self {
        case .add, .replaceManaged, .adoptOrphaned: true
        default: false
        }
    }

    var isConflict: Bool {
        switch self {
        case .conflictUserModified, .conflictUserOwned: true
        default: false
        }
    }
}

public struct FilePlanDiff: Equatable, Sendable {
    public let targetPath: String
    public let format: ConfigFileFormat
    public let actions: [(keyPath: [String], action: ManagedEntryAction)]

    public static func == (lhs: FilePlanDiff, rhs: FilePlanDiff) -> Bool {
        lhs.targetPath == rhs.targetPath
            && lhs.format == rhs.format
            && lhs.actions.map { "\($0.keyPath):\($0.action)" } == rhs.actions.map { "\($0.keyPath):\($0.action)" }
    }

    var hasConflicts: Bool {
        actions.contains(where: \.action.isConflict)
    }
}

public struct PlanDiff: Equatable, Sendable {
    public let files: [FilePlanDiff]

    public var hasConflicts: Bool {
        files.contains(where: \.hasConflicts)
    }
}

// MARK: - Outcomes & diagnostics

public enum InstallOutcome: Equatable, Sendable {
    case installed
    case upgraded
    case noChanges
    /// Nothing was modified; paths list the blocking key locations.
    case conflict(paths: [String])
}

public struct InstallReport: Equatable, Sendable {
    public let outcome: InstallOutcome
    public let planDiff: PlanDiff
    /// Backup files created during this install (one per modified target).
    public let backups: [String]
    public let fingerprintsRecorded: Int
    public let selfTestRan: Bool
}

public struct UninstallReport: Equatable, Sendable {
    /// Locations actually removed (fingerprint-matched or orphaned-ours).
    public let removed: [String]
    /// Locations left untouched because the user had modified them.
    public let skippedUserModified: [String]
}

/// Repair/diagnostic status for the UI Repair flow (§3.17 degraded mode).
public enum IntegrationHealth: Equatable, Sendable {
    case healthy
    case notInstalled
    /// Locations where the managed section no longer matches its fingerprint.
    case userModified(paths: [String])
    /// Target exists but no longer parses / lost its marker.
    case corrupted(reason: String)
}

public enum IntegrationInstallError: Error, Equatable, CustomStringConvertible {
    case validationFailed(path: String, diagnostic: String)
    case selfTestFailed(reason: String)

    public var description: String {
        switch self {
        case let .validationFailed(path, diagnostic): "validation failed for \(path): \(diagnostic)"
        case let .selfTestFailed(reason): "self-test failed: \(reason)"
        }
    }
}

// MARK: - Installer

public final class IntegrationInstaller: @unchecked Sendable {
    public typealias SyntaxValidator = @Sendable (_ content: String, _ format: ConfigFileFormat)
        -> SyntaxValidationResult

    private let recording: any IntegrationInstallRecording
    private let homeDirectory: String
    private let syntaxValidator: SyntaxValidator
    private let fileManager: FileManager
    private let recovery = InstallerFileRecovery(
        tempPrefix: IntegrationInstaller.tempPrefix,
        backupSuffix: IntegrationInstaller.backupSuffix
    )

    static let tempPrefix = ".agentterminal-tmp-"
    static let backupSuffix = ".agentterminal-backup"

    public init(
        recording: any IntegrationInstallRecording,
        homeDirectory: String,
        fileManager: FileManager = .default,
        syntaxValidator: SyntaxValidator? = nil
    ) {
        self.recording = recording
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        if let syntaxValidator {
            self.syntaxValidator = syntaxValidator
        } else {
            self.syntaxValidator = { content, format in
                let result = IntegrationValidator.validateSyntax(content, format: format)
                return SyntaxValidationResult(isValid: result.isValid, diagnostics: result.diagnostics)
            }
        }
    }

    // MARK: Path expansion

    public func expandPath(_ template: String) -> String {
        if template.hasPrefix("~") {
            let remainder = template.dropFirst()
            if remainder.isEmpty {
                return homeDirectory
            }
            if remainder.hasPrefix("/") {
                return homeDirectory + remainder
            }
            // `~user/…` forms are NOT expanded: NSString-style expansion only
            // covers the current user, and this Foundation-only module (§3.2)
            // performs no C-level passwd lookups. Pass such templates through
            // verbatim rather than silently rewriting them into the current
            // user's home.
            return template
        }
        // Relative templates are resolved against the managed home so every
        // later operation works on one unambiguous absolute path.
        guard !template.hasPrefix("/") else { return template }
        return homeDirectory + "/" + template
    }

    // MARK: §3.17 steps 1–3: read + diff (never writes)

    public func diff(plan: IntegrationInstallPlan) throws -> PlanDiff {
        let fileDiffs = plan.files.map { edit -> FilePlanDiff in
            let target = expandPath(edit.targetPathTemplate)
            let existing = readIfExists(target)
            return FilePlanDiff(
                targetPath: target,
                format: edit.format,
                actions: planActions(for: edit, target: target, existing: existing, adapterID: plan.adapterID)
                    .map { (keyPath: $0.0, action: $0.1) }
            )
        }
        return PlanDiff(files: fileDiffs)
    }

    // MARK: §3.17 steps 4–10: backup → temp write → validate → rename → record → self-test → rollback

    @discardableResult
    public func install(plan: IntegrationInstallPlan, selfTest: (() throws -> Void)? = nil) throws -> InstallReport {
        cleanupStaleTempFiles(plan: plan)

        let planDiff = try diff(plan: plan)

        // Bail out BEFORE touching anything when the user owns a conflict.
        let conflictPaths = planDiff.files.flatMap { file in
            file.actions.compactMap { pair -> String? in
                pair.action.isConflict ? "\(file.targetPath)#\(pair.keyPath.joined(separator: "/"))" : nil
            }
        }
        if planDiff.hasConflicts {
            return InstallReport(
                outcome: .conflict(paths: conflictPaths),
                planDiff: planDiff,
                backups: [],
                fingerprintsRecorded: 0,
                selfTestRan: false
            )
        }

        let changingPaths = Set(planDiff.files.flatMap { file in
            file.actions.filter(\.action.isApplied).map { _ in file.targetPath }
        })
        guard !changingPaths.isEmpty else {
            // Idempotent reinstall: nothing to write, but re-record whatever
            // the plan's entries now look like — this is how an orphaned
            // crashed-install entry (marker present, fingerprint lost) gets
            // adopted into managed ownership.
            let current = fingerprintsAfterInstall(plan: plan)
            if !current.isEmpty {
                try recording.record(current)
            }
            // §5.3 step 5 applies even when nothing changed.
            try selfTest?()
            return InstallReport(
                outcome: .noChanges,
                planDiff: planDiff,
                backups: [],
                fingerprintsRecorded: current.count,
                selfTestRan: selfTest != nil
            )
        }
        // Snapshot pre-install fingerprints BEFORE anything is modified:
        // rollback must restore exactly these entries. Wiping all recorded
        // fingerprints for the adapter would leave a previous successful
        // install unidentifiable to uninstall (§5.3).
        let previousFingerprints = recording.fingerprints(adapterID: plan.adapterID)

        var modifiedTargets: [String] = []
        var backup = InstallerFileRecovery.Backup(backupPaths: [], previousState: [], backupSuffix: Self.backupSuffix)

        do {
            backup = try recovery.backup(Array(changingPaths), using: fileManager)

            for edit in plan.files {
                let target = expandPath(edit.targetPathTemplate)
                guard changingPaths.contains(target) else { continue }
                // A brand-new managed file may live in a not-yet-existing directory.
                try fileManager.createDirectory(
                    atPath: (target as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                let existing = readIfExists(target)
                let merged = try mergedContent(for: edit, target: target, existing: existing, adapterID: plan.adapterID)

                guard let data = merged.data(using: .utf8) else {
                    throw IntegrationInstallError.validationFailed(
                        path: target,
                        diagnostic: "content is not valid UTF-8"
                    )
                }
                let validation = syntaxValidator(merged, edit.format)
                guard validation.isValid else {
                    throw IntegrationInstallError.validationFailed(
                        path: target,
                        diagnostic: validation.diagnostics.joined(separator: "; ")
                    )
                }

                try recovery.commit(data, to: target, permissions: backup.permissions(for: target), using: fileManager)
                modifiedTargets.append(target)
            }

            // Step 8: record fingerprints. A throwing recorder here simulates a
            // crash between rename and recording; rollback restores pre-state.
            let fingerprints = fingerprintsAfterInstall(plan: plan)
            try recording.record(fingerprints)

            // Step 9: integration self-test hook.
            try selfTest?()

            let upgraded = planDiff.files.contains { file in
                file.actions.contains { $0.action == .replaceManaged || $0.action == .adoptOrphaned }
            }
            return InstallReport(
                outcome: upgraded ? .upgraded : .installed,
                planDiff: planDiff,
                backups: backup.backupPaths,
                fingerprintsRecorded: fingerprints.count,
                selfTestRan: selfTest != nil
            )
        } catch {
            // Restore backups, then restore exactly the pre-install
            // fingerprints so uninstall keeps identifying managed entries.
            rollback(
                backup: backup,
                adapterID: plan.adapterID,
                previousFingerprints: previousFingerprints
            )
            throw error
        }
    }

    private func rollback(
        backup: InstallerFileRecovery.Backup,
        adapterID: String,
        previousFingerprints: [ManagedEntryFingerprint]
    ) {
        backup.restore(using: fileManager)
        recording.removeAll(adapterID: adapterID)
        // Exact restore of the pre-install snapshot via the existing port —
        // never a wholesale wipe of the adapter's recorded entries. Best-
        // effort: a failure here must never mask the original install error
        // that triggered rollback, but is surfaced rather than swallowed.
        do {
            try recording.record(previousFingerprints)
        } catch {
            NSLog("IntegrationInstaller: rollback fingerprint restore failed: \(error)")
        }
    }

    /// Recovery for a crash between temp write and atomic rename: removes our
    /// stale temp siblings next to every planned target. Every entry with the
    /// temp prefix is deleted — a concurrent install of a different plan into
    /// the same directory may lose its in-flight temp, but that only fails its
    /// atomic rename, which is retriable.
    public func cleanupStaleTempFiles(plan: IntegrationInstallPlan) {
        let directories = Set(plan.files
            .map { (expandPath($0.targetPathTemplate) as NSString).deletingLastPathComponent })
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasPrefix(Self.tempPrefix) {
                try? fileManager.removeItem(atPath: directory + "/" + entry)
            }
        }
    }

    // MARK: Uninstall — remove ONLY fingerprint-matched (or orphaned-ours) entries

    public func uninstall(plan: IntegrationInstallPlan) throws -> UninstallReport {
        var removed: [String] = []
        var skipped: [String] = []

        for edit in plan.files {
            let target = expandPath(edit.targetPathTemplate)
            guard let existing = readIfExists(target) else { continue }
            let recorded = recording.fingerprints(adapterID: plan.adapterID).filter { $0.targetPath == target }

            switch edit.format {
            case .json:
                guard var document = try? JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]
                else { continue }
                var changed = false
                for entry in edit.entries {
                    let location = "\(target)#\(entry.keyPath.joined(separator: "/"))"
                    if Self.removeManagedEntry(
                        &document,
                        keyPath: entry.keyPath,
                        recorded: recorded,
                        marker: entry.marker
                    ) != nil {
                        removed.append(location)
                        changed = true
                    } else {
                        skipped.append(location)
                    }
                }
                if changed {
                    let data = try JSONSerialization.data(
                        withJSONObject: document,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    try writeAtomically(data, to: target)
                }
            case .toml:
                let location = target + "#" + edit.entries.map { $0.keyPath.joined(separator: "/") }
                    .joined(separator: ",")
                guard let block = Self.extractManagedBlock(in: existing, adapterID: plan.adapterID) else { continue }
                let matched = recorded.first { $0.entryKeyPath.isEmpty && $0.managedContent == block.text }
                // Orphan adoption (no fingerprint at all) requires PROOF the
                // block is EXACTLY what our plan generates: a crashed install
                // wrote it verbatim, so an exact match proves ownership. A
                // user-modified orphan never matches and survives as a
                // conflict (§3.17).
                if matched != nil
                    || (recorded.isEmpty && block.text == Self.renderTOMLManagedBlock(
                        entries: edit.entries,
                        adapterID: plan.adapterID
                    ))
                {
                    let stripped = existing.replacingOccurrences(of: block.text, with: "")
                    try writeAtomically(Data(stripped.utf8), to: target)
                    removed.append(location)
                } else {
                    skipped.append(location)
                }
            case .javaScript:
                let matched = recorded.first { $0.entryKeyPath.isEmpty && $0.managedContent == existing }
                // Orphan deletion requires PROOF of ownership: the file must
                // START with the exact generated banner, and with no recorded
                // fingerprint it must ALSO match the plan's generated content
                // byte-for-byte — a crashed install wrote exactly that, while
                // a user-modified orphan never does and survives (§3.17).
                if Self.startsWithGeneratedJavaScriptBanner(existing),
                   matched != nil || (recorded.isEmpty && existing == edit.entries.first?.valueJSON)
                {
                    try fileManager.removeItem(atPath: target)
                    removed.append(target)
                } else {
                    skipped.append(target)
                }
            }
        }
        if skipped.isEmpty {
            recording.removeAll(adapterID: plan.adapterID)
        } else {
            // Some entries were left untouched as user-modified (§3.17). The
            // recording is the orphan-adoption ledger: wiping it while a
            // user-modified binary remains would let a later install adopt-
            // and-overwrite it. Keep exactly the surviving entries' finger-
            // prints — record(_:) filters out same-adapter entries before
            // appending (PersistentInstallRecording), so removeAll followed by
            // record(survivors) persists precisely the kept set.
            let survivors = recording.fingerprints(adapterID: plan.adapterID)
                .filter { fingerprint in
                    skipped.contains { location in
                        location == fingerprint.targetPath
                            || location.hasPrefix(fingerprint.targetPath + "#")
                    }
                }
            recording.removeAll(adapterID: plan.adapterID)
            try recording.record(survivors)
        }
        return UninstallReport(removed: removed, skippedUserModified: skipped)
    }

    // MARK: Repair diagnostics (§3.17 degraded mode)

    public func diagnose(plan: IntegrationInstallPlan) -> IntegrationHealth {
        let recorded = recording.fingerprints(adapterID: plan.adapterID)
        guard !recorded.isEmpty else { return .notInstalled }

        var modifiedPaths: [String] = []

        for edit in plan.files {
            let target = expandPath(edit.targetPathTemplate)
            guard let existing = readIfExists(target) else { return .notInstalled }

            switch edit.format {
            case .json:
                guard let document = try? JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]
                else {
                    return .corrupted(reason: target + " does not parse as JSON")
                }
                for entry in edit.entries {
                    guard let match = recorded
                        .first(where: { $0.targetPath == target && $0.entryKeyPath == entry.keyPath }) else { continue }
                    guard let leaf = Self.jsonValue(at: entry.keyPath, in: document) else {
                        return .corrupted(reason: target + "#\(entry.keyPath.joined(separator: "/")) disappeared")
                    }
                    let drifted: Bool = if let liveDict = leaf as? [String: Any],
                                           let recordedDict = try? JSONSerialization
                                           .jsonObject(with: Data(match.managedContent.utf8)) as? [String: Any]
                    {
                        recordedDict.contains { key, recordedValue in
                            guard let live = liveDict[key] else { return true }
                            return Self.canonicalJSON(live) != Self.canonicalJSON(recordedValue)
                                && !Self.containsMarker(live, marker: match.marker)
                        }
                    } else {
                        Self.canonicalJSON(leaf) != match.managedContent
                    }
                    if drifted {
                        modifiedPaths.append(target + "#" + entry.keyPath.joined(separator: "/"))
                    }
                }
            case .toml:
                guard (try? TOMLParser.parse(existing)) != nil else {
                    return .corrupted(reason: target + " does not parse as TOML")
                }
                if let block = Self.extractManagedBlock(in: existing, adapterID: plan.adapterID),
                   let match = recorded.first(where: { $0.targetPath == target && $0.entryKeyPath.isEmpty }),
                   match.managedContent != block.text
                {
                    modifiedPaths.append(target)
                }
            case .javaScript:
                if let match = recorded.first(where: { $0.targetPath == target && $0.entryKeyPath.isEmpty }),
                   match.managedContent != existing
                {
                    modifiedPaths.append(target)
                }
            }
        }
        if !modifiedPaths.isEmpty {
            return .userModified(paths: modifiedPaths)
        }
        return .healthy
    }

    // MARK: - Planning & merging per format

    /// Returns (keyPath, action) pairs for one planned file.
    private func planActions(for edit: IntegrationFileEdit, target: String, existing: String?, adapterID: String) -> [(
        [String],
        ManagedEntryAction
    )] {
        let recorded = recording.fingerprints(adapterID: adapterID).filter { $0.targetPath == target }

        switch edit.format {
        case .json:
            guard let existing,
                  let document = try? JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]
            else {
                return edit.entries.map { ($0.keyPath, .add) }
            }
            return edit.entries.map { (
                $0.keyPath,
                jsonAction(
                    keyPath: $0.keyPath,
                    newValueJSON: $0.valueJSON,
                    document: document,
                    recorded: recorded,
                    marker: $0.marker
                )
            ) }
        case .toml:
            let desired = Self.renderTOMLManagedBlock(entries: edit.entries, adapterID: adapterID)
            guard let currentBlock = existing.flatMap({ Self.extractManagedBlock(in: $0, adapterID: adapterID) }) else {
                return [([], .add)]
            }
            if currentBlock.text == desired {
                return [([], .unchanged)]
            }
            if let match = recorded.first(where: { $0.entryKeyPath.isEmpty }) {
                return match.managedContent == currentBlock.text ? [([], .replaceManaged)] : [(
                    [],
                    .conflictUserModified
                )]
            }
            return [([], .adoptOrphaned)]
        case .javaScript:
            guard let existing, !existing.isEmpty else { return [([], .add)] }
            // Adoption/replace requires the file to START with OUR generated
            // banner — matching the uninstall path's orphan-deletion rule
            // below. A substring hit anywhere else is not ownership evidence.
            guard Self.startsWithGeneratedJavaScriptBanner(existing) else {
                return [([], .conflictUserOwned)]
            }
            if let match = recorded.first(where: { $0.entryKeyPath.isEmpty }) {
                return match.managedContent == existing ? [([], .unchanged)] : [([], .conflictUserModified)]
            }
            return [([], .adoptOrphaned)]
        }
    }

    private func jsonAction(
        keyPath: [String],
        newValueJSON: String,
        document: [String: Any],
        recorded: [ManagedEntryFingerprint],
        marker: String
    ) -> ManagedEntryAction {
        guard let newLeaf = try? JSONSerialization.jsonObject(with: Data(newValueJSON.utf8))
        else { return .conflictUserOwned }
        guard let current = Self.jsonValue(at: keyPath, in: document) else { return .add }

        let match = recorded.first { $0.entryKeyPath == keyPath }

        // Both sides are objects → deep merge, never destructive.
        if let currentDict = current as? [String: Any], let newDict = newLeaf as? [String: Any] {
            for (key, incoming) in newDict {
                if let existingSub = currentDict[key],
                   Self.canonicalJSON(existingSub) != Self.canonicalJSON(incoming),
                   !Self.containsMarker(existingSub, marker: marker),
                   !(existingSub is [String: Any] && incoming is [String: Any])
                {
                    return .conflictUserOwned
                }
            }
            if let match,
               let recordedDict = try? JSONSerialization
               .jsonObject(with: Data(match.managedContent.utf8)) as? [String: Any]
            {
                // §5.3 step 1: every previously-contributed key must still be
                // intact; any drift means the user edited our section.
                for (key, recordedValue) in recordedDict {
                    guard let live = currentDict[key],
                          Self.canonicalJSON(live) == Self.canonicalJSON(recordedValue) || Self.containsMarker(
                              live,
                              marker: marker
                          )
                    else {
                        return .conflictUserModified
                    }
                }
            } else if match == nil && Self.containsMarker(currentDict, marker: marker) {
                // Orphan adoption (crash between atomic rename and
                // recording): safe ONLY while the entry holds nothing but
                // keys we would contribute ourselves. Any additional key is
                // user content → conflict, never a silent adopt.
                let userKeys = currentDict.keys.filter { newDict[$0] == nil }
                if !userKeys.isEmpty {
                    return .conflictUserOwned
                }
            }
            let mergeChangesNothing = Self.mergeIsNoOp(from: currentDict, to: newDict)
            if mergeChangesNothing {
                return .unchanged
            }
            if match != nil {
                return .replaceManaged
            }
            return Self.containsMarker(currentDict, marker: marker) ? .adoptOrphaned : .add
        }

        // Scalar/array replacement requires our ownership proof.
        if Self.containsMarker(current, marker: marker) {
            if let match {
                return match.managedContent == Self.canonicalJSON(current) ? .replaceManaged : .conflictUserModified
            }
            return .adoptOrphaned
        }
        return .conflictUserOwned
    }

    private func mergedContent(for edit: IntegrationFileEdit, target: String, existing: String?,
                               adapterID: String) throws -> String
    {
        switch edit.format {
        case .json:
            var document: [String: Any]
            if let existing {
                // §3.17 law: an existing file that fails to parse as a JSON
                // object is a CONFLICT, never a silent reset to an empty
                // document (which would wholesale-replace the user's config).
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]
                else {
                    throw IntegrationInstallError.validationFailed(
                        path: target,
                        diagnostic: "existing file does not parse as a JSON object"
                    )
                }
                document = parsed
            } else {
                document = [:]
            }
            for entry in edit.entries {
                guard let newLeaf = try? JSONSerialization.jsonObject(with: Data(entry.valueJSON.utf8)) else {
                    throw IntegrationInstallError.validationFailed(
                        path: target,
                        diagnostic: "entry \(entry.keyPath.joined(separator: "/")) value is not valid JSON"
                    )
                }
                Self.setValue(newLeaf, at: entry.keyPath, in: &document)
            }
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self) + "\n"
        case .toml:
            let base = existing ?? ""
            let desired = Self.renderTOMLManagedBlock(entries: edit.entries, adapterID: adapterID)
            if let block = existing.flatMap({ Self.extractManagedBlock(in: $0, adapterID: adapterID) }) {
                return base.replacingOccurrences(of: block.text, with: desired)
            }
            var result = base
            if !result.isEmpty, !result.hasSuffix("\n") {
                result += "\n"
            }
            return result + "\n" + desired
        case .javaScript:
            // Whole-file format: the entry's valueJSON IS the file content.
            return edit.entries.first?.valueJSON ?? existing ?? ""
        }
    }

    // MARK: Fingerprints after apply

    private func fingerprintsAfterInstall(plan: IntegrationInstallPlan) -> [ManagedEntryFingerprint] {
        var result: [ManagedEntryFingerprint] = []
        for edit in plan.files {
            let target = expandPath(edit.targetPathTemplate)
            guard let content = readIfExists(target) else { continue }
            switch edit.format {
            case .json:
                guard let document = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
                else { continue }
                for entry in edit.entries {
                    guard Self.jsonValue(at: entry.keyPath, in: document) != nil else { continue }
                    // For deep-merged dictionary entries we own only what WE
                    // contributed — fingerprint exactly that contribution.
                    guard let contributed = try? JSONSerialization.jsonObject(with: Data(entry.valueJSON.utf8))
                    else { continue }
                    result.append(ManagedEntryFingerprint(
                        adapterID: plan.adapterID,
                        targetPath: target,
                        entryKeyPath: entry.keyPath,
                        marker: entry.marker,
                        managedContent: Self.canonicalJSON(contributed)
                    ))
                }
            case .toml:
                if let block = Self.extractManagedBlock(in: content, adapterID: plan.adapterID) {
                    result.append(ManagedEntryFingerprint(
                        adapterID: plan.adapterID,
                        targetPath: target,
                        entryKeyPath: [],
                        marker: IntegrationInstallPlan.namespaceMarker,
                        managedContent: block.text
                    ))
                }
            case .javaScript:
                result.append(ManagedEntryFingerprint(
                    adapterID: plan.adapterID,
                    targetPath: target,
                    entryKeyPath: [],
                    marker: IntegrationInstallPlan.namespaceMarker,
                    managedContent: content
                ))
            }
        }
        return result
    }

    // MARK: - Shared helpers

    private func readIfExists(_ path: String) -> String? {
        guard fileManager.fileExists(atPath: path), let data = fileManager.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeAtomically(_ data: Data, to path: String) throws {
        try recovery.commit(data, to: path, permissions: nil, using: fileManager)
    }

    static func jsonValue(at keyPath: [String], in object: [String: Any]) -> Any? {
        var current: Any = object
        for key in keyPath {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    /// Sets a value at a key path, deep-merging dictionaries along the way so
    /// sibling user content survives (e.g. their own hooks under "hooks").
    static func setValue(_ value: Any, at keyPath: [String], in document: inout [String: Any]) {
        precondition(!keyPath.isEmpty)
        if keyPath.count == 1 {
            let key = keyPath[0]
            if let existing = document[key] as? [String: Any], let incoming = value as? [String: Any] {
                var merged = existing
                for (k, v) in incoming {
                    // Both sides objects → deep merge (jsonAction contract):
                    // never destroy nested user content we don't contribute.
                    if existing[k] is [String: Any], let child = v as? [String: Any] {
                        setValue(child, at: [k], in: &merged)
                    } else {
                        merged[k] = v
                    }
                }
                document[key] = merged
            } else {
                document[key] = value
            }
            return
        }
        var child = document[keyPath[0]] as? [String: Any] ?? [:]
        setValue(value, at: Array(keyPath.dropFirst()), in: &child)
        document[keyPath[0]] = child
    }

    /// True when merging `incoming` into `current` would change nothing.
    static func mergeIsNoOp(from current: [String: Any], to incoming: [String: Any]) -> Bool {
        for (key, value) in incoming {
            guard let existing = current[key],
                  canonicalJSON(existing) == canonicalJSON(value) else { return false }
        }
        return true
    }

    static func containsMarker(_ value: Any, marker: String) -> Bool {
        switch value {
        case let string as String: string == marker
        case let dict as [String: Any]: dict.values.contains { containsMarker($0, marker: marker) }
        case let array as [Any]: array.contains { containsMarker($0, marker: marker) }
        default: false
        }
    }

    /// Ownership proof for whole-file JavaScript installs: the content must
    /// BEGIN with the exact generated banner line (`// AgentTerminal …`).
    /// A user file that merely QUOTES the namespace marker deeper in its
    /// body is never treated as ours.
    static func startsWithGeneratedJavaScriptBanner(_ content: String) -> Bool {
        let firstLine = content.prefix { !$0.isNewline }
        return firstLine.hasPrefix("// AgentTerminal")
    }

    static func canonicalJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes a managed entry. Returns the removed canonical content when
    /// something was removed; nil means user-modified/user-owned — leave it.
    static func removeManagedEntry(
        _ document: inout [String: Any],
        keyPath: [String],
        recorded: [ManagedEntryFingerprint],
        marker: String
    ) -> String? {
        guard !keyPath.isEmpty else { return nil }
        guard let leaf = jsonValue(at: keyPath, in: document) else { return nil }

        let match = recorded.first { $0.entryKeyPath == keyPath }

        // Exact fingerprint match → remove the whole leaf.
        if let match, canonicalJSON(leaf) == match.managedContent {
            removeAtRoot(&document, keyPath: keyPath)
            return match.managedContent
        }
        // Orphaned ours (marker present, no fingerprint). Whole-leaf removal
        // only for non-dictionary leaves; dictionaries lose exactly the keys
        // that carry our marker so sibling user content survives even here.
        if match == nil, containsMarker(leaf, marker: marker) {
            if var leafDict = leaf as? [String: Any] {
                var didRemove = false
                for (key, value) in leafDict where containsMarker(value, marker: marker) {
                    leafDict.removeValue(forKey: key)
                    didRemove = true
                }
                if didRemove {
                    // Replace (not merge): the cleaned dict must not resurrect
                    // removed keys via setValue's merge behavior.
                    replaceAtRoot(&document, keyPath: keyPath, value: leafDict)
                    return canonicalJSON(leafDict)
                }
                return nil
            }
            let canonical = canonicalJSON(leaf)
            removeAtRoot(&document, keyPath: keyPath)
            return canonical
        }
        // Deep-merged contribution: remove exactly the recorded subkeys whose
        // values still equal what we wrote.
        if let match,
           let recordedDict = try? JSONSerialization
           .jsonObject(with: Data(match.managedContent.utf8)) as? [String: Any],
           var leafDict = leaf as? [String: Any]
        {
            var didRemove = false
            for (key, value) in recordedDict
                where leafDict[key] != nil && canonicalJSON(leafDict[key]!) == canonicalJSON(value)
            {
                leafDict.removeValue(forKey: key)
                didRemove = true
            }
            if didRemove {
                // Replace (not merge) so removed keys cannot resurrect.
                replaceAtRoot(&document, keyPath: keyPath, value: leafDict)
                return match.managedContent
            }
        }
        return nil
    }

    private static func replaceAtRoot(_ document: inout [String: Any], keyPath: [String], value: Any) {
        if keyPath.count == 1 {
            document[keyPath[0]] = value
            return
        }
        var child = document[keyPath[0]] as? [String: Any] ?? [:]
        replaceAtRoot(&child, keyPath: Array(keyPath.dropFirst()), value: value)
        document[keyPath[0]] = child
    }

    private static func removeAtRoot(_ document: inout [String: Any], keyPath: [String]) {
        if keyPath.count == 1 {
            document.removeValue(forKey: keyPath[0])
            return
        }
        var child = document[keyPath[0]] as? [String: Any] ?? [:]
        removeAtRoot(&child, keyPath: Array(keyPath.dropFirst()))
        document[keyPath[0]] = child
    }

    // MARK: - TOML managed block

    public struct InstallerManagedBlock: Equatable, Sendable {
        public let text: String
        public let startLine: Int
        public let endLine: Int
    }

    public static func extractManagedBlock(in source: String, adapterID: String) -> InstallerManagedBlock? {
        let lines = source.components(separatedBy: "\n")
        let beginTag = "# BEGIN " + IntegrationInstallPlan.namespaceMarker + " " + adapterID
        let endTag = "# END " + IntegrationInstallPlan.namespaceMarker + " " + adapterID
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == beginTag })
        else { return nil }
        guard let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endTag })
        else { return nil }
        let text = lines[start ... end].joined(separator: "\n") + "\n"
        return InstallerManagedBlock(text: text, startLine: start, endLine: end)
    }

    public static func renderTOMLManagedBlock(entries: [ManagedConfigEntry], adapterID: String) -> String {
        var lines = ["# BEGIN " + IntegrationInstallPlan.namespaceMarker + " " + adapterID]
        for entry in entries {
            guard let value = try? JSONSerialization.jsonObject(with: Data(entry.valueJSON.utf8)) else { continue }
            lines.append("[" + entry.keyPath.joined(separator: ".") + "]")
            if let table = value as? [String: Any] {
                for (key, item) in table.sorted(by: { $0.key < $1.key }) {
                    lines.append("\(key) = \(renderTOMLValue(item))")
                }
            } else {
                lines.append("value = \(renderTOMLValue(value))")
            }
        }
        lines.append("# END " + IntegrationInstallPlan.namespaceMarker + " " + adapterID)
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderTOMLValue(_ value: Any) -> String {
        // JSONSerialization yields every JSON number as NSNumber, and a
        // conditional cast to Bool succeeds for ANY NSNumber (nonzero → true),
        // so Bool must be distinguished via objCType (see agentctl
        // foundationToJSONValue for the established pattern) — otherwise
        // `timeout = 30` renders as `timeout = true` in the managed block.
        switch value {
        case let number as NSNumber:
            if String(cString: number.objCType) == "c" {
                number.boolValue ? "true" : "false"
            } else {
                number.stringValue
            }
        case let string as String:
            "\"" + string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case let array as [Any]:
            "[ " + array.map(renderTOMLValue).joined(separator: ", ") + " ]"
        case let dict as [String: Any]:
            "{ " + dict.sorted(by: { $0.key < $1.key }).map { "\($0.key) = \(renderTOMLValue($0.value))" }
                .joined(separator: ", ") + " }"
        default:
            "\"\(value)\""
        }
    }
}

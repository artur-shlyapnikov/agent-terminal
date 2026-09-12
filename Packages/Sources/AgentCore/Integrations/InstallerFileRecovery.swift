import Foundation

/// Crash-consistent file swap behind the installer's recovery phase
/// (architecture §3.17: backup → temp write → atomic rename → restore).
/// Files here, fingerprint ledger rollback stays in IntegrationInstaller.
struct InstallerFileRecovery: Sendable {
    let tempPrefix: String
    let backupSuffix: String

    /// Snapshot plus backup copies for every path. A mid-copy failure removes
    /// the partial backup before rethrowing, so restore never mistakes it for
    /// a complete snapshot.
    func backup(_ paths: [String], using fileManager: FileManager) throws -> Backup {
        var previousState: [(path: String, existed: Bool, permissions: Int)] = []
        var backups: [String] = []
        for path in paths.sorted() {
            let existed = fileManager.fileExists(atPath: path)
            let permissions = try existed
                ? (fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0o644)
                : 0o644
            previousState.append((path, existed, permissions))
            if existed {
                let backupPath = path + backupSuffix
                try? fileManager.removeItem(atPath: backupPath)
                do {
                    try fileManager.copyItem(atPath: path, toPath: backupPath)
                } catch {
                    try? fileManager.removeItem(atPath: backupPath)
                    throw error
                }
                backups.append(backupPath)
            }
        }
        return Backup(backupPaths: backups, previousState: previousState, backupSuffix: backupSuffix)
    }

    /// Temp-stage data, carry permissions, POSIX-rename over the target.
    /// A nil permission preserves the target's own attributes best-effort.
    func commit(_ data: Data, to target: String, permissions: Int?, using fileManager: FileManager) throws {
        let tempPath = (target as NSString).deletingLastPathComponent + "/" + tempPrefix + UUID().uuidString
        try data.write(to: URL(fileURLWithPath: tempPath))
        if let permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempPath)
        } else if let attributes = try? fileManager.attributesOfItem(atPath: target) {
            try? fileManager.setAttributes(attributes, ofItemAtPath: tempPath)
        }
        try Self.rename(tempPath, over: target)
    }

    /// POSIX rename(2) silently replaces any existing destination;
    /// FileManager.moveItem refuses to.
    static func rename(_ sourcePath: String, over targetPath: String) throws {
        guard Darwin.rename(sourcePath, targetPath) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "rename \(sourcePath) → \(targetPath) failed"
            ])
        }
    }

    struct Backup: Sendable {
        let backupPaths: [String]
        let previousState: [(path: String, existed: Bool, permissions: Int)]
        let backupSuffix: String

        func permissions(for path: String) -> Int {
            previousState.first { $0.path == path }?.permissions ?? 0o644
        }

        func restore(using fileManager: FileManager) {
            for state in previousState {
                if state.existed {
                    let backupPath = state.path + backupSuffix
                    if fileManager.fileExists(atPath: backupPath) {
                        try? fileManager.removeItem(atPath: state.path)
                        try? fileManager.moveItem(atPath: backupPath, toPath: state.path)
                    }
                } else {
                    try? fileManager.removeItem(atPath: state.path)
                }
            }
        }
    }
}

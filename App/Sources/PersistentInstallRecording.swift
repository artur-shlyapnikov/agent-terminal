import AgentCore
import AgentStore
import CryptoKit
import Foundation

// Stage-16 deferred item A: AgentStore-backed `IntegrationInstallRecording`.
//
// The installer port is synchronous (Foundation-only law, §3.2); the
// repository is async. Bridge = in-memory mirror + write-through:
//   - startup loads persisted fingerprints once (semaphore join — one row
//     read at launch, so `diagnose()` reflects installs from PREVIOUS runs);
//   - record/removeAll update the mirror synchronously (installer rollback
//     semantics stay exact) and persist asynchronously.
// Persistence failure degrades to mirror-only recording with a diagnostics
// log line; it never fails an install that already renamed files into place.

final class PersistentInstallRecording: IntegrationInstallRecording, @unchecked Sendable {
    /// Hook-shim bundle generation recorded alongside the fingerprints
    /// (integration_installs is keyed by agent_kind + integration_version).
    static let integrationVersion = "1"

    private let lock = NSLock()
    private var mirror: [ManagedEntryFingerprint] = []
    /// Adapter ids touched by this run (record/removeAll); the deferred
    /// loader must never overwrite these from persisted previous-run rows.
    private var mutatedAdapters: Set<String> = []
    private let repository: IntegrationRepository?

    init(repository: IntegrationRepository?) {
        self.repository = repository
        guard let repository else { return }
        // One-shot synchronous load: diagnose() must see previous-run state
        // on the very first inspector render.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [weak self] in
            guard let self else { semaphore.signal(); return }
            var loaded: [ManagedEntryFingerprint] = []
            if let installs = try? await repository.installs() {
                for install in installs where install.status == "installed" {
                    if let entries = try? JSONDecoder().decode(
                        [ManagedEntryFingerprint].self, from: install.managedFilesJSON
                    ) {
                        loaded.append(contentsOf: entries)
                    }
                }
            }
            lock.withLock {
                // Keep this run's recordings/removals; fill remaining
                // adapters from the persisted previous-run state.
                self.mirror.append(
                    contentsOf: loaded.filter { !self.mutatedAdapters.contains($0.adapterID) }
                )
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func record(_ fingerprints: [ManagedEntryFingerprint]) throws {
        lock.lock()
        var updated = mirror.filter { stored in
            !fingerprints.contains { $0.adapterID == stored.adapterID }
        }
        updated.append(contentsOf: fingerprints)
        mirror = updated
        let byAdapter = Dictionary(grouping: fingerprints, by: \.adapterID)
        mutatedAdapters.formUnion(byAdapter.keys)
        lock.unlock()

        for (adapterID, entries) in byAdapter {
            persist(adapterID: adapterID, entries: entries, status: "installed")
        }
    }

    func fingerprints(adapterID: String) -> [ManagedEntryFingerprint] {
        lock.lock(); defer { lock.unlock() }
        return mirror.filter { $0.adapterID == adapterID }
    }

    func removeAll(adapterID: String) {
        lock.lock()
        mirror.removeAll { $0.adapterID == adapterID }
        mutatedAdapters.insert(adapterID)
        lock.unlock()
        persist(adapterID: adapterID, entries: [], status: "uninstalled")
    }

    // MARK: - Persistence

    private func persist(adapterID: String, entries: [ManagedEntryFingerprint], status: String) {
        guard let repository,
              let kind = AgentKind(rawValue: adapterID) ?? Self.fallbackKind(adapterID) else { return }
        let data = (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
        let digest = SHA256.hash(data: data)
        let fingerprintHex = digest.map { String(format: "%02x", $0) }.joined()
        let install = IntegrationInstall(
            agentKind: kind,
            integrationVersion: Self.integrationVersion,
            status: status,
            managedFilesJSON: data,
            managedFingerprint: fingerprintHex,
            installedAt: Date()
        )
        Task.detached { [repository] in
            do {
                try await repository.upsert(install)
            } catch {
                Task { @MainActor in
                    DiagnosticsLogRing.shared.record(
                        "install-recording persist failed for \(adapterID): \(error)"
                    )
                }
            }
        }
    }

    /// Adapter ids and AgentKind raw values coincide today; an id with no
    /// AgentKind match is only logged here. Persisting it under a shared
    /// .genericShell row would let two distinct unknown adapters (or an
    /// unknown one plus a real genericShell adapter) collide on the same
    /// (agent_kind, integration_version) key — last writer wins and corrupts
    /// the recording. Unknown ids therefore degrade to mirror-only recording,
    /// like any other persistence failure.
    private static func fallbackKind(_ adapterID: String) -> AgentKind? {
        Task { @MainActor in
            DiagnosticsLogRing.shared.record(
                "unknown adapter id '\(adapterID)' in install recording"
            )
        }
        return nil
    }
}

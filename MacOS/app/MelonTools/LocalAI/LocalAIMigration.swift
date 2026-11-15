import Foundation
import CryptoKit

/// One-time migration from 5.5.5 to 6.0.0 plus startup housekeeping.
///
/// The specification (§19) requires that upgrading never loses user data and
/// that a rollback is possible. Two properties make that true here:
/// * the snapshot happens **before** any shared service is created, so it
///   captures the registry as it was, not a version a service already rewrote;
/// * the marker is written only after every file was copied and verified, so a
///   failed backup is retried on the next launch instead of being forgotten.
@MainActor
enum LocalAIMigration {
    private static let markerName = "migrated-6.0.0.json"
    private static let manifestName = "backup-manifest.json"

    struct BackupFile: Codable, Equatable {
        var name: String
        var sha256: String
        var size: UInt64
    }

    struct BackupManifest: Codable, Equatable {
        var from: String
        var to: String
        var at: String
        var files: [BackupFile]
    }

    struct Report {
        var performed: Bool
        var backupDirectory: URL?
        var backedUp: [String]
        var failure: String?

        var summary: String {
            if let failure { return failure }
            guard performed else { return "Already migrated." }
            guard let backupDirectory else { return "Nothing to back up." }
            return "Backup: \(backupDirectory.path)"
        }
    }

    @discardableResult
    static func runIfNeeded() -> Report {
        let metadata = LocalPaths.metadata
        let marker = metadata.appendingPathComponent(markerName)

        // `LocalPaths` only, deliberately: touching `LocalModelStore.shared` here
        // would run its initializer and rewrite `models.json` before the copy.
        if FileManager.default.fileExists(atPath: marker.path) {
            return Report(performed: false, backupDirectory: nil, backedUp: [], failure: nil)
        }

        try? FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupRoot = metadata
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("6.0.0-\(stamp)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        } catch {
            return Report(
                performed: false, backupDirectory: nil, backedUp: [],
                failure: String(format: L("Could not create the backup folder: %@"), error.localizedDescription)
            )
        }

        var backedUp: [BackupFile] = []
        var failures: [String] = []

        func backup(_ source: URL, as name: String) {
            guard FileManager.default.fileExists(atPath: source.path) else { return }
            let target = backupRoot.appendingPathComponent(name)
            do {
                try AtomicFileOps.copyVerifying(source: source, destination: target)
                let size = AtomicFileOps.fileSize(target)
                let digest = AtomicFileOps.sha256Hex(of: target) ?? ""
                if size != AtomicFileOps.fileSize(source) {
                    throw LocalStorageError.verificationFailed(name)
                }
                backedUp.append(BackupFile(name: name, sha256: digest, size: size))
            } catch {
                failures.append(name)
            }
        }

        // Gateway configuration: the file that carries every provider route.
        backup(LocalPaths.gatewayConfig, as: "config.yaml")
        // Local model registry and its storage settings.
        backup(LocalPaths.registry, as: "models.json")
        backup(LocalPaths.storageSettings, as: "storage_settings.json")

        // Preferences: accounts, aliases and UI settings live here.
        if let domain = Bundle.main.bundleIdentifier,
           let prefs = UserDefaults.standard.persistentDomain(forName: domain),
           let data = try? PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0) {
            let target = backupRoot.appendingPathComponent("preferences.plist")
            do {
                try data.write(to: target, options: .atomic)
                backedUp.append(BackupFile(
                    name: "preferences.plist",
                    sha256: AtomicFileOps.sha256Hex(of: target) ?? "",
                    size: AtomicFileOps.fileSize(target)
                ))
            } catch {
                failures.append("preferences.plist")
            }
        }

        guard failures.isEmpty else {
            // No marker: the next launch retries instead of silently shipping a
            // migration without a rollback path.
            return Report(
                performed: false, backupDirectory: backupRoot,
                backedUp: backedUp.map { $0.name },
                failure: String(format: L("Backup incomplete (%@). Will retry on next launch."),
                                failures.joined(separator: ", "))
            )
        }

        let manifest = BackupManifest(from: "5.5.5", to: "6.0.0", at: stamp, files: backedUp)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: backupRoot.appendingPathComponent(manifestName), options: .atomic)
        }
        let markerPayload: [String: Any] = [
            "from": "5.5.5",
            "to": "6.0.0",
            "at": stamp,
            "backup": backupRoot.lastPathComponent,
            "backedUp": backedUp.map { $0.name },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: markerPayload, options: [.prettyPrinted]) {
            do {
                try data.write(to: marker, options: .atomic)
            } catch {
                return Report(
                    performed: false, backupDirectory: backupRoot,
                    backedUp: backedUp.map { $0.name },
                    failure: String(format: L("Could not record the migration marker: %@"), error.localizedDescription)
                )
            }
        }

        return Report(
            performed: true,
            backupDirectory: backupRoot,
            backedUp: backedUp.map { $0.name },
            failure: nil
        )
    }

    /// Path of the most recent backup, if any — shown in Settings.
    static var latestBackup: URL? {
        let root = LocalPaths.metadata.appendingPathComponent("backups", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("6.0.0-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    /// Copies a backup back over the live files. Used by the restore test and by
    /// support when a migration produced an unusable registry.
    static func restore(from backup: URL) throws {
        let manifestURL = backup.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            throw LocalStorageError.verificationFailed("backup-manifest.json")
        }
        for file in manifest.files {
            let source = backup.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if !file.sha256.isEmpty,
               let actual = AtomicFileOps.sha256Hex(of: source),
               actual != file.sha256 {
                throw LocalStorageError.verificationFailed(file.name)
            }
            let destination: URL
            switch file.name {
            case "config.yaml": destination = LocalPaths.gatewayConfig
            case "models.json": destination = LocalPaths.registry
            case "storage_settings.json": destination = LocalPaths.storageSettings
            case "preferences.plist":
                if let domain = Bundle.main.bundleIdentifier,
                   let dict = NSDictionary(contentsOf: source) as? [String: Any] {
                    UserDefaults.standard.setPersistentDomain(dict, forName: domain)
                }
                continue
            default: continue
            }
            AtomicFileOps.removeIfExists(destination)
            try AtomicFileOps.copyVerifying(source: source, destination: destination)
        }
    }

    /// Removes work-in-progress leftovers from a crash or a force-quit.
    ///
    /// Age and ownership are both required: a temporary folder younger than the
    /// threshold may belong to a live operation, and a download job listed as
    /// active is never touched.
    @discardableResult
    static func runMaintenance(
        now: Date = Date(),
        olderThan hours: Double = 24,
        activeDownloadJobs: Set<UUID> = []
    ) -> [String] {
        var removed: [String] = []
        let manager = FileManager.default

        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }

        func sweep(
            _ root: URL,
            prefixes: [String],
            olderThan age: Double = 24,
            also: ((URL) -> Bool)? = nil
        ) {
            let cutoff = now.addingTimeInterval(-age * 3600)
            let entries = (try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            )) ?? []
            for entry in entries {
                let name = entry.lastPathComponent
                let matchesPrefix = prefixes.contains { name.hasPrefix($0) }
                let matchesExtra = also?(entry) ?? false
                guard matchesPrefix || matchesExtra else { continue }
                guard let date = modified(entry), date < cutoff else { continue }
                if (try? manager.removeItem(at: entry)) != nil {
                    removed.append(entry.path)
                }
            }
        }

        sweep(LocalPaths.models, prefixes: [".staging-", ".publish-"])
        sweep(LocalPaths.downloads, prefixes: [".staging-"])
        sweep(LocalPaths.runtime, prefixes: [".download-", ".extract-", ".install-", ".catalog-"])

        // Download jobs are kept while they can still be resumed: a job with a
        // sidecar (and therefore an identifiable revision) survives a week, an
        // empty husk without one only a day.
        sweep(LocalPaths.downloads, prefixes: [], olderThan: hours, also: { entry in
            guard let job = UUID(uuidString: entry.lastPathComponent) else { return false }
            guard !activeDownloadJobs.contains(job) else { return false }
            let contents = (try? manager.contentsOfDirectory(atPath: entry.path)) ?? []
            return !contents.contains { $0.hasSuffix(".part.json") }
        })
        sweep(LocalPaths.downloads, prefixes: [], olderThan: max(hours, 24 * 7), also: { entry in
            guard let job = UUID(uuidString: entry.lastPathComponent) else { return false }
            return !activeDownloadJobs.contains(job)
        })

        // Orphan `.part` files directly in the downloads root (pre-6.0.0 layout).
        sweep(LocalPaths.downloads, prefixes: [], also: { entry in
            entry.pathExtension == "part"
        })
        return removed
    }
}

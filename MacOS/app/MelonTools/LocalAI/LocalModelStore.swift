import Foundation
import Combine
import CryptoKit
import Security

/// Where the models live and how to recognise the volume that holds them.
///
/// The previous code silently fell back to the internal folder when an external
/// drive was not mounted, which made every model look missing and put new
/// downloads somewhere the registry was not pointing at. The volume identity is
/// stored so an unmounted drive is reported as unavailable instead.
struct StorageLocation: Codable, Equatable {
    var path: String
    var volumeID: String?
}

enum StorageStatus: Equatable {
    case internalStorage
    case available
    /// The configured folder does not exist (drive detached or folder removed).
    case unavailable
    /// The folder exists but belongs to a different volume than the one we
    /// recorded, so the files in it are not necessarily ours.
    case differentVolume
    case readOnly

    var isUsable: Bool { self == .internalStorage || self == .available }
}

/// How a new storage location is adopted.
enum StorageChangeMode {
    /// Point the registry at the folder as it is. Nothing is copied and nothing
    /// is deleted; models that are not there become `not_installed`.
    case connect
    /// Copy every model to the new folder, verify it, then switch and (optionally)
    /// remove the old copies.
    case migrate(deleteSource: Bool)
}

/// The models were copied to a new folder, but the choice could not be saved.
/// The current session keeps using the new folder; the old copies are kept so a
/// launch that still reads the old root is not left without files.
private struct StorageLocationSaveFailure: LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        String(
            format: L("The models were moved, but the new folder could not be remembered. Choose it again. (%@)"),
            underlying.localizedDescription
        )
    }
}

/// Manages local models registry, directories, filesystem operations, and gateway config integration.
@MainActor
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()

    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var customModelsDirectory: URL?
    @Published private(set) var storageStatus: StorageStatus = .internalStorage
    @Published var activeModelId: String? = nil
    @Published private(set) var hfTokenConfigured: Bool = false
    /// Set when the Keychain could not be read, so a denial or a locked Keychain
    /// is not presented as "no token configured". `nil` when the last probe
    /// succeeded.
    @Published private(set) var hfTokenError: String?
    /// The most recent failure a caller could not be handed directly. Storage
    /// and registry writes used to fail silently; this keeps the reason
    /// available for logging or a user-visible banner.
    @Published private(set) var lastError: String?
    /// Progress of a storage migration, 0...1, `nil` when idle.
    @Published private(set) var relocationProgress: Double?
    @Published private(set) var relocationMessage: String?
    /// A failed load is not an empty catalog. Keep the original file and block
    /// every writer until it can be read successfully (after restore/update).
    @Published private(set) var registryError: String?
    @Published private(set) var registryBackupURL: URL?
    var canWriteRegistry: Bool { registryError == nil }

    var totalDiskBytes: UInt64 {
        models.reduce(0) { $0 + $1.fileSize }
    }

    private let fileManager = FileManager.default
    private var metadataRepairTask: Task<Void, Never>?
    private let directoryOverride: URL?
    /// Registry bytes are written on this serial queue. Encoding stays on the
    /// main actor because the array is main-actor state; every writer, sync or
    /// async, uses the same queue, so a queued status write can never land
    /// after a newer user-triggered save.
    private let registryIOQueue = DispatchQueue(
        label: "dev.melontools.localai.registry",
        qos: .utility
    )
    /// Monotonic id of the newest registry write, used to drop a late failure
    /// from an older background write after a newer save succeeded.
    private var registryWriteGeneration: UInt64 = 0

    /// An isolated directory is used by regression tests, never the real vault.
    init(directory: URL? = nil) {
        directoryOverride = directory
        if directory == nil {
            // The real app remembers whether a Hugging Face token exists. The
            // test host must not trigger a Keychain prompt for a UI flag it
            // never uses. The probe runs off the main thread: a Keychain that
            // is locked or waiting on a prompt must not delay the first frame.
            if !AppRuntime.isTesting {
                probeHuggingFaceToken()
            }
            loadCustomPath()
            ensureDirectoriesExist()
        } else if let directory {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Reading the registry stays synchronous: the models root, the
        // availability flag and the first UI render all depend on it, and it is
        // one small file read at launch. Writes are serialized separately.
        loadRegistry()
        // A llama-server process never survives an app restart. A `ready` row
        // left by the previous run used to make the cards report a running
        // model and the publisher wait for an alias nothing served. Test
        // stores are isolated and keep whatever their fixture encoded.
        if directory == nil, !AppRuntime.isTesting {
            normalizeRuntimeStates()
        }
    }

    /// Reads the Keychain flag without blocking the main actor and keeps a
    /// denial apart from "no token stored".
    private func probeHuggingFaceToken() {
        Task.detached(priority: .utility) { [weak self] in
            let result = LocalKeychainHelper.loadHuggingFaceTokenResult()
            guard let self else { return }
            await MainActor.run {
                switch result {
                case .success(let token):
                    self.hfTokenConfigured = token != nil
                    self.hfTokenError = nil
                case .failure(let error):
                    self.hfTokenConfigured = false
                    self.hfTokenError = error.localizedDescription
                    self.lastError = error.localizedDescription
                    NSLog("LocalModelStore: Keychain read failed: %@", String(describing: error))
                }
            }
        }
    }

    // MARK: - Paths

    var baseStorageDirectory: URL { LocalPaths.base }

    /// The configured models folder, whether or not it is reachable. Never
    /// silently replaced by the internal folder, so the UI can report the truth.
    var modelsDirectory: URL {
        customModelsDirectory ?? directoryOverride?.appendingPathComponent("models", isDirectory: true) ?? LocalPaths.models
    }

    var downloadsDirectory: URL { LocalPaths.downloads }

    /// Engine shipped inside the app bundle (§5.3).
    var bundledRuntimeDirectory: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/runtime", isDirectory: true)
    }

    var runtimeDirectory: URL { LocalPaths.runtime }
    var metadataDirectory: URL { LocalPaths.metadata }
    var logsDirectory: URL { LocalPaths.logs }
    var registryFileURL: URL { directoryOverride?.appendingPathComponent("registry.json") ?? LocalPaths.registry }

    var isStorageUsable: Bool { storageStatus.isUsable }

    func ensureDirectoriesExist() {
        guard isStorageUsable else { return }
        if let directoryOverride {
            try? fileManager.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            return
        }
        var dirs = [downloadsDirectory, runtimeDirectory, metadataDirectory, logsDirectory]
        if customModelsDirectory == nil { dirs.append(LocalPaths.models) }
        for dir in dirs {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // A connected external folder must exist already; creating it would hide
        // a detached volume behind an empty local-looking directory.
        if customModelsDirectory != nil, fileManager.fileExists(atPath: modelsDirectory.path) {
            try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Custom Storage Path

    private func loadCustomPath() {
        let settingsURL = LocalPaths.storageSettings
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            // First launch: no saved choice is not an error.
            customModelsDirectory = nil
            storageStatus = .internalStorage
            return
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            let location = try JSONDecoder().decode(StorageLocation.self, from: data)
            guard !location.path.isEmpty else {
                // An empty path is how "use the internal folder" is stored.
                customModelsDirectory = nil
                storageStatus = .internalStorage
                return
            }

            let url = URL(fileURLWithPath: location.path)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                // Keep the path: the drive may simply be unplugged, and silently
                // switching roots would make every registered file look foreign.
                customModelsDirectory = url
                storageStatus = .unavailable
                return
            }

            customModelsDirectory = url
            if let expected = location.volumeID,
               let actual = Self.volumeIdentifier(for: url),
               actual != expected {
                storageStatus = .differentVolume
            } else if !fileManager.isWritableFile(atPath: url.path) {
                storageStatus = .readOnly
            } else {
                storageStatus = .available
            }
        } catch {
            resetCustomPath(reason: error.localizedDescription)
        }
    }

    /// Drops an unreadable or malformed saved location and falls back to the
    /// internal folder. The settings file is left on disk for diagnosis; the
    /// next saved choice overwrites it.
    private func resetCustomPath(reason: String) {
        customModelsDirectory = nil
        storageStatus = .internalStorage
        let message = String(
            format: L("The saved models folder could not be read (%@). Using the internal folder."),
            reason
        )
        lastError = message
        NSLog("LocalModelStore: %@", message)
    }

    /// Persists the chosen models folder.
    ///
    /// Throws when the choice could not be written, so a caller cannot report
    /// success while the next launch silently uses a different root.
    private func saveStorageLocation() throws {
        let location = StorageLocation(
            path: customModelsDirectory?.path ?? "",
            volumeID: customModelsDirectory.flatMap { Self.volumeIdentifier(for: $0) }
        )
        do {
            let data = try JSONEncoder().encode(location)
            try Self.writeAtomically(data, to: LocalPaths.storageSettings)
        } catch {
            let message = String(
                format: L("The models folder could not be saved: %@"),
                error.localizedDescription
            )
            lastError = message
            NSLog("LocalModelStore: %@", message)
            throw error
        }
    }

    /// Writes `data` atomically and flushes it to the volume.
    ///
    /// `.atomic` swaps the file into place but does not force its bytes out, so
    /// a power loss could leave an empty or stale file under a valid name. The
    /// explicit synchronize closes that window.
    nonisolated static func writeAtomically(_ data: Data, to url: URL) throws {
        // The parent can be missing after a launch that could not reach the
        // storage volume; creating it here keeps a valid choice savable.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// `2026-11-07T15-47-34.123Z`: ISO 8601 that is also a safe file name.
    nonisolated static func backupTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// Stable identity of the volume a folder lives on. `volumeUUIDString` is not
    /// available on every filesystem, so the volume mount path is the fallback.
    nonisolated static func volumeIdentifier(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        if let uuid = values?.volumeUUIDString, !uuid.isEmpty { return uuid }
        if let volume = values?.volume, !volume.path.isEmpty { return volume.path }
        return nil
    }

    /// Adopts a folder as the models root. Deliberately refuses folders that are
    /// not writable and reports volume changes instead of adopting them silently.
    func connectModelsDirectory(_ newURL: URL?) throws {
        guard canWriteRegistry else { throw LocalStorageError.registryUnavailable }
        let previousDirectory = customModelsDirectory
        let previousStatus = storageStatus
        guard let newURL else {
            customModelsDirectory = nil
            storageStatus = .internalStorage
            do {
                try saveStorageLocation()
            } catch {
                customModelsDirectory = previousDirectory
                storageStatus = previousStatus
                throw error
            }
            ensureDirectoriesExist()
            loadRegistry()
            LocalHardwareService.shared.refresh(modelsDirectory: modelsDirectory)
            return
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: newURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LocalStorageError.notADirectory
        }
        guard fileManager.isWritableFile(atPath: newURL.path) else {
            throw LocalStorageError.notWritable
        }

        customModelsDirectory = newURL
        storageStatus = .available
        do {
            try saveStorageLocation()
        } catch {
            customModelsDirectory = previousDirectory
            storageStatus = previousStatus
            throw error
        }
        ensureDirectoriesExist()
        loadRegistry()
        LocalHardwareService.shared.refresh(modelsDirectory: modelsDirectory)
    }

    /// Moves every registered model into `newURL`, verifies the copies, then
    /// switches the registry over. Nothing is deleted until the new location is
    /// complete, so a failure leaves the old storage untouched.
    func migrateModelsDirectory(to newURL: URL, deleteSource: Bool) async throws {
        guard canWriteRegistry else { throw LocalStorageError.registryUnavailable }
        guard relocationProgress == nil else { throw LocalStorageError.busy }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: newURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LocalStorageError.notADirectory
        }
        guard fileManager.isWritableFile(atPath: newURL.path) else {
            throw LocalStorageError.notWritable
        }

        let snapshot = models
        let sourceRoot = modelsDirectory
        let required = snapshot.reduce(UInt64(0)) { $0 + $1.fileSize }
        let (free, _) = LocalHardwareService.getDiskSpace(for: newURL)
        guard free >= required + required / 20 else {
            throw LocalStorageError.notEnoughSpace(required: required, free: free)
        }

        relocationProgress = 0
        relocationMessage = L("Copying models...")
        let staging = newURL.appendingPathComponent(
            ".staging-relocate-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try await Self.copyModels(snapshot, from: sourceRoot, into: staging) { [weak self] done, total in
                Task { @MainActor in
                    self?.relocationProgress = total > 0 ? Double(done) / Double(total) : 1
                }
            }

            // Publish: move the staged trees into the destination root. Each
            // entry already carries its own namespace directory.
            let entries = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            for entry in entries {
                let destination = newURL.appendingPathComponent(entry.lastPathComponent)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw LocalStorageError.destinationConflict(entry.lastPathComponent)
                }
                try fileManager.moveItem(at: entry, to: destination)
            }
            try fileManager.removeItem(at: staging)

            let previousRoot = customModelsDirectory
            customModelsDirectory = newURL
            storageStatus = .available
            let locationError: Error?
            do {
                try saveStorageLocation()
                locationError = nil
            } catch {
                locationError = error
            }
            ensureDirectoriesExist()
            loadRegistry()
            relocationProgress = nil
            relocationMessage = nil
            LocalHardwareService.shared.refresh(modelsDirectory: modelsDirectory)

            if let locationError {
                // The files are in the new folder and this session uses it, but
                // the choice was not remembered. Keep the old copies as the
                // fallback for a launch that still reads the old root, and tell
                // the caller instead of reporting a clean migration.
                throw StorageLocationSaveFailure(underlying: locationError)
            }

            if deleteSource, let previousRoot, previousRoot != newURL {
                Self.removeOwnedCopies(of: snapshot, in: previousRoot)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            relocationProgress = nil
            relocationMessage = nil
            throw error
        }
    }

    /// Copies each registered file, preserving the relative path, and checks the
    /// copy before it is allowed into the destination.
    nonisolated private static func copyModels(
        _ models: [LocalModel],
        from sourceRoot: URL,
        into staging: URL,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) async throws {
        let total = models.reduce(UInt64(0)) { $0 + $1.fileSize }
        var done: UInt64 = 0
        for model in models {
            for relative in model.files where !relative.hasPrefix("/") {
                let source = sourceRoot.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = staging.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let copied = try AtomicFileOps.copyVerifying(source: source, destination: destination)
                if model.fileSize > 0, model.files.count == 1, copied != model.fileSize {
                    throw LocalStorageError.verificationFailed(relative)
                }
                done += copied
                progress(done, total)
                try Task.checkCancellation()
            }
        }
        progress(total, total)
    }

    /// Deletes the copies the migration itself made under `root`.
    ///
    /// A linked model points at a file the user owns elsewhere; its entry is an
    /// absolute path, and `fileURLs(in:)` would hand that absolute path back and
    /// delete it. Only relative entries that stay inside `root` are ours.
    nonisolated private static func removeOwnedCopies(of models: [LocalModel], in root: URL) {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for model in models {
            for relative in model.files where !relative.hasPrefix("/") {
                let url = root.appendingPathComponent(relative).standardizedFileURL
                guard url.path.hasPrefix(prefix) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
            if let namespace = model.ownedNamespaceDirectory(in: root) {
                try? FileManager.default.removeItem(at: namespace)
            }
        }
    }

    // MARK: - Hugging Face Token

    func getHuggingFaceToken() -> String? {
        switch LocalKeychainHelper.loadHuggingFaceTokenResult() {
        case .success(let token):
            return token
        case .failure(let error):
            // A locked or denied Keychain must not look like an empty token:
            // callers would silently send an unauthenticated request.
            hfTokenError = error.localizedDescription
            lastError = error.localizedDescription
            NSLog("LocalModelStore: Keychain read failed: %@", String(describing: error))
            return nil
        }
    }

    /// Saves or removes the token. Throws when the Keychain refused the write so
    /// the UI stops claiming "Saved" over a token that was never stored.
    func setHuggingFaceToken(_ token: String?) throws {
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            let status = LocalKeychainHelper.saveHuggingFaceToken(token)
            guard status == errSecSuccess else {
                hfTokenError = LocalStorageError.keychain(status).localizedDescription
                throw LocalStorageError.keychain(status)
            }
            hfTokenConfigured = true
            hfTokenError = nil
        } else {
            let status = LocalKeychainHelper.deleteHuggingFaceToken()
            guard status == errSecSuccess else {
                hfTokenError = LocalStorageError.keychain(status).localizedDescription
                throw LocalStorageError.keychain(status)
            }
            hfTokenConfigured = false
            hfTokenError = nil
        }
    }

    // MARK: - Import

    /// Result of the expensive part of an import, produced off the main actor.
    struct PreparedImport: Sendable {
        /// Path the file will occupy relative to the models root, e.g.
        /// `local-model-3f2a9c11/model.gguf`.
        var storedPath: String
        /// Where the bytes are right now: a staging file, or the source itself
        /// when the user chose to link instead of copy.
        var stagedURL: URL
        var fileSize: UInt64
        var fileName: String
        var sha256: String?
        var metadata: GgufInfo?
        var isLinked: Bool
    }

    /// Copies the file into a staging folder on the models volume and reads its
    /// header. Nothing in the models root is touched yet, so a failed copy cannot
    /// destroy an installed model the way `removeItem` + `copyItem` did.
    nonisolated static func prepareImport(
        source: URL,
        modelsDirectory: URL,
        copyToStorage: Bool
    ) throws -> PreparedImport {
        let fileName = source.lastPathComponent
        guard fileName.lowercased().hasSuffix(".gguf") else {
            throw LocalStorageError.notGGUF
        }
        guard AtomicFileOps.isSafeFileName(fileName) else {
            throw LocalStorageError.unsafeName(fileName)
        }

        let metadata: GgufInfo?
        do {
            metadata = try GgufMetadataReader.read(from: source)
        } catch {
            throw LocalStorageError.invalidGGUF(fileName)
        }

        if !copyToStorage {
            let size = AtomicFileOps.fileSize(source)
            return PreparedImport(
                storedPath: source.path,
                stagedURL: source,
                fileSize: size,
                fileName: fileName,
                sha256: nil,
                metadata: metadata,
                isLinked: true
            )
        }

        let stagingDirectory = modelsDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let staged = stagingDirectory.appendingPathComponent(fileName)
        do {
            let copied = try AtomicFileOps.copyVerifying(source: source, destination: staged)
            return PreparedImport(
                storedPath: fileName,
                stagedURL: staged,
                fileSize: copied,
                fileName: fileName,
                sha256: AtomicFileOps.sha256Hex(of: staged),
                metadata: metadata,
                isLinked: false
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    /// Async single-file import used by the UI.
    func importGGUFFileAsync(from sourceURL: URL, copyToStorage: Bool = true) async throws -> LocalModel {
        let directory = modelsDirectory
        guard canWriteRegistry else { throw LocalStorageError.registryUnavailable }
        guard isStorageUsable else { throw LocalStorageError.storageUnavailable }
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareImport(source: sourceURL, modelsDirectory: directory, copyToStorage: copyToStorage)
        }.value
        do {
            return try publish([prepared])
        } catch {
            discardStaged([prepared])
            throw error
        }
    }

    /// Async folder import: split models are grouped and only complete sets are
    /// registered, a folder with two shards of three is refused instead of
    /// producing a model the engine can never load.
    func importGGUFFolderAsync(from folder: URL, copyToStorage: Bool = true) async throws -> [LocalModel] {
        let directory = modelsDirectory
        guard canWriteRegistry else { throw LocalStorageError.registryUnavailable }
        guard isStorageUsable else { throw LocalStorageError.storageUnavailable }
        let prepared = try await Task.detached(priority: .userInitiated) { () -> [PreparedImport] in
            let contents = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let ggufs = contents.filter { $0.pathExtension.lowercased() == "gguf" }
            guard !ggufs.isEmpty else { throw LocalStorageError.noGGUFFiles }
            var result: [PreparedImport] = []
            for url in ggufs {
                result.append(
                    try Self.prepareImport(source: url, modelsDirectory: directory, copyToStorage: copyToStorage)
                )
            }
            return result
        }.value

        do {
            return try await publishGrouped(prepared)
        } catch {
            discardStaged(prepared)
            throw error
        }
    }

    /// Validates split sets and publishes every complete group.
    @discardableResult
    func publishGrouped(_ prepared: [PreparedImport]) throws -> [LocalModel] {
        var groups: [String: [PreparedImport]] = [:]
        var singles: [PreparedImport] = []

        for item in prepared {
            if let shard = Self.shardInfo(for: item.fileName) {
                groups[shard.base, default: []].append(item)
            } else {
                singles.append(item)
            }
        }

        var result: [LocalModel] = []
        for item in singles {
            result.append(try publish([item]))
        }

        for base in groups.keys.sorted() {
            let items = groups[base] ?? []
            let set = try Self.validateSplitSet(items)
            result.append(try publish(set, displayName: base))
        }
        return result
    }

    /// Ensures `index` covers `1...total` exactly once for every shard.
    nonisolated static func validateSplitSet(_ items: [PreparedImport]) throws -> [PreparedImport] {
        guard !items.isEmpty else { throw LocalStorageError.incompleteSplit(missing: []) }
        let shards = items.compactMap { item -> (PreparedImport, ShardInfo)? in
            guard let info = shardInfo(for: item.fileName) else { return nil }
            return (item, info)
        }
        guard shards.count == items.count else { throw LocalStorageError.incompleteSplit(missing: []) }

        let totals = Set(shards.map { $0.1.total })
        guard totals.count == 1, let total = totals.first, total > 0 else {
            throw LocalStorageError.inconsistentSplit
        }
        let indices = Set(shards.map { $0.1.index })
        let missing = (1...total).filter { !indices.contains($0) }
        guard missing.isEmpty, indices.count == total else {
            throw LocalStorageError.incompleteSplit(missing: missing)
        }
        return shards
            .sorted { $0.1.index < $1.1.index }
            .map { $0.0 }
    }

    /// Moves the prepared files into a fresh namespace directory and registers
    /// one model. The namespace makes two `model.gguf` files from different
    /// repositories impossible to confuse, on case-insensitive APFS too.
    @discardableResult
    func publish(_ items: [PreparedImport], displayName: String? = nil) throws -> LocalModel {
        guard !items.isEmpty else { throw LocalStorageError.noGGUFFiles }
        guard canWriteRegistry else { throw LocalStorageError.registryUnavailable }
        guard isStorageUsable else { throw LocalStorageError.storageUnavailable }

        let first = items[0]
        let name = displayName ?? items[0].fileName
            .replacingOccurrences(of: ".gguf", with: "", options: [.caseInsensitive])
        let metadata = first.metadata
        let workingContext = Self.workingContext(for: metadata)
        let identifier = uniqueModelID(
            base: name,
            quantization: metadata?.quantization,
            repoId: nil
        )
        let namespaceName = Self.namespaceName(for: identifier)
        let namespace = modelsDirectory.appendingPathComponent(namespaceName, isDirectory: true)
        guard !fileManager.fileExists(atPath: namespace.path) else {
            throw LocalStorageError.destinationConflict(namespaceName)
        }

        // A linked import keeps its file where the user put it; creating a
        // namespace for it would leave an empty directory behind.
        let needsNamespace = items.contains { !$0.isLinked }
        var publishedFiles: [String] = []
        do {
            if needsNamespace {
                try fileManager.createDirectory(at: namespace, withIntermediateDirectories: true)
            }
            for item in items {
                let destination = namespace.appendingPathComponent(item.fileName)
                if item.isLinked {
                    publishedFiles.append(item.stagedURL.path)
                } else {
                    try AtomicFileOps.publish(item.stagedURL, to: destination)
                    publishedFiles.append("\(namespaceName)/\(item.fileName)")
                    removeStagingDirectoryIfEmpty(item.stagedURL)
                }
            }
        } catch {
            try? fileManager.removeItem(at: namespace)
            throw error
        }

        let totalSize = items.reduce(UInt64(0)) { $0 + $1.fileSize }
        var settings = LocalModelSettings.defaultSettings(forContext: workingContext)
        settings.contextLength = workingContext

        let model = LocalModel(
            id: identifier,
            displayName: name,
            provider: "Local AI",
            source: first.isLinked ? "custom" : "import",
            repoId: nil,
            revision: nil,
            files: publishedFiles,
            fileSize: totalSize,
            quantization: metadata?.quantization ?? extractQuantization(from: first.fileName),
            format: "GGUF",
            contextLength: metadata?.contextLength ?? workingContext,
            configuredContext: workingContext,
            blockCount: metadata?.blockCount,
            architecture: metadata?.architecture,
            memoryProfile: metadata.flatMap { GgufMemoryProfile(info: $0) },
            backend: LocalHardwareService.shared.hardwareInfo.recommendedBackend,
            gpuOffload: nil,
            threads: nil,
            runtimeStatus: .installed,
            capabilities: [.text],
            installedAt: Date(),
            updatedAt: Date(),
            lastUsedAt: nil,
            license: metadata?.license,
            checksum: items.count == 1 ? first.sha256 : nil,
            userSettings: settings
        )
        addOrUpdateModel(model)
        return model
    }

    /// Publishes verified download results into a fresh model namespace and
    /// registers one model for the whole set.
    ///
    /// The staged bytes are copied, not moved, and the staged copy is only
    /// removed once the registry write is verified on disk. That ordering is what
    /// makes an interrupted publication recoverable: a failure at any step leaves
    /// the caller's files intact, and a half-copied namespace carries a marker
    /// naming the job that created it, so a retry can replace it instead of
    /// colliding with it.
    @discardableResult
    func publishDownloaded(
        files: [(stagedURL: URL, fileName: String)],
        displayName: String,
        repoId: String,
        revision: String?,
        metadata: GgufInfo?,
        checksum: String?,
        downloadJobID: UUID?
    ) throws -> LocalModel {
        guard !files.isEmpty else { throw LocalStorageError.noGGUFFiles }
        guard canWriteRegistry else { throw LocalStorageError.registryUnavailable }
        guard isStorageUsable else { throw LocalStorageError.storageUnavailable }

        let markerName = ".download-job.json"

        func markerURL(_ directory: URL) -> URL {
            directory.appendingPathComponent(markerName)
        }

        func readMarker(_ directory: URL) -> UUID? {
            guard let data = try? Data(contentsOf: markerURL(directory)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["jobID"] as? String else { return nil }
            return UUID(uuidString: raw)
        }

        func writeMarker(_ directory: URL, jobID: UUID) throws {
            let payload: [String: Any] = ["version": 1, "jobID": jobID.uuidString]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: markerURL(directory), options: .atomic)
        }

        /// The registry file is the source of truth: `addOrUpdateModel` cannot
        /// report a failed write, and a full disk must not delete the only copy
        /// of the model while the entry stayed unregistered.
        func registryHolds(_ model: LocalModel) -> Bool {
            guard let data = try? Data(contentsOf: registryFileURL) else { return false }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let stored = try? decoder.decode([LocalModel].self, from: data) else { return false }
            return stored.contains {
                $0.id == model.id
                    && $0.downloadJobID == model.downloadJobID
                    && $0.files == model.files
            }
        }

        let identifier = uniqueModelID(
            base: displayName,
            quantization: metadata?.quantization,
            repoId: repoId
        )
        let namespaceName = Self.namespaceName(for: identifier)
        let namespace = modelsDirectory.appendingPathComponent(namespaceName, isDirectory: true)

        // A crash during an earlier attempt can leave a partial namespace. Only
        // a marker naming this same job proves the bytes are ours to replace.
        if fileManager.fileExists(atPath: namespace.path) {
            if downloadJobID != nil, readMarker(namespace) == downloadJobID {
                try fileManager.removeItem(at: namespace)
            } else {
                throw LocalStorageError.destinationConflict(namespaceName)
            }
        }

        var published: [String] = []
        var totalSize: UInt64 = 0
        do {
            try fileManager.createDirectory(at: namespace, withIntermediateDirectories: true)
            if let downloadJobID {
                try writeMarker(namespace, jobID: downloadJobID)
            }
            for file in files {
                let destination = namespace.appendingPathComponent(file.fileName)
                let size = AtomicFileOps.fileSize(file.stagedURL)
                totalSize += size
                // Copy, so a failure below cannot destroy the only copy.
                try AtomicFileOps.copyVerifying(source: file.stagedURL, destination: destination)
                guard AtomicFileOps.fileSize(destination) == size else {
                    throw LocalStorageError.verificationFailed(file.fileName)
                }
                published.append("\(namespaceName)/\(file.fileName)")
            }
        } catch {
            try? fileManager.removeItem(at: namespace)
            throw error
        }

        let workingContext = Self.workingContext(for: metadata)
        var settings = LocalModelSettings.defaultSettings(forContext: workingContext)
        settings.contextLength = workingContext

        let model = LocalModel(
            id: identifier,
            displayName: displayName,
            provider: "Hugging Face",
            source: "huggingface",
            repoId: repoId,
            revision: revision,
            files: published,
            fileSize: totalSize,
            quantization: metadata?.quantization ?? extractQuantization(from: displayName),
            format: "GGUF",
            contextLength: metadata?.contextLength ?? workingContext,
            configuredContext: workingContext,
            blockCount: metadata?.blockCount,
            architecture: metadata?.architecture,
            memoryProfile: metadata.flatMap { GgufMemoryProfile(info: $0) },
            backend: LocalHardwareService.shared.hardwareInfo.recommendedBackend,
            gpuOffload: nil,
            threads: nil,
            runtimeStatus: .installed,
            capabilities: [.text],
            installedAt: Date(),
            updatedAt: Date(),
            lastUsedAt: nil,
            license: metadata?.license,
            checksum: checksum,
            userSettings: settings,
            downloadJobID: downloadJobID
        )

        let previousModels = models
        addOrUpdateModel(model)
        guard registryHolds(model) else {
            // Roll back in memory and on disk: the staged bytes are untouched, so
            // the caller can retry once the registry is writable again.
            models = previousModels
            try? fileManager.removeItem(at: namespace)
            throw LocalStorageError.registryUnavailable
        }

        // Registered and verified: the staged copies are now redundant.
        for file in files {
            try? fileManager.removeItem(at: file.stagedURL)
        }
        return model
    }

    /// Drops the per-import staging folder once its file has been published.
    private func removeStagingDirectoryIfEmpty(_ stagedURL: URL) {
        let directory = stagedURL.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix(".staging-") else { return }
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        if contents.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
    }

    /// Removes staged copies of an import that failed before publication, so a
    /// rejected split set cannot leave gigabytes behind until the next GC.
    private func discardStaged(_ items: [PreparedImport]) {
        for item in items where !item.isLinked {
            try? fileManager.removeItem(at: item.stagedURL)
            removeStagingDirectoryIfEmpty(item.stagedURL)
        }
    }

    /// Context the engine will actually serve by default: never the model's
    /// advertised maximum, never more than the 8k documented starting point.
    nonisolated static func workingContext(for metadata: GgufInfo?) -> Int {
        min(8192, max(512, metadata?.contextLength ?? 8192))
    }

    // MARK: - Namespaces

    /// Filesystem name for one model. The hash keeps two identifiers that
    /// sanitise to the same slug apart and survives case-insensitive volumes.
    nonisolated static func namespaceName(for identifier: String) -> String {
        let slug = identifier
            .lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let digest = SHA256.hash(data: Data(identifier.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        let base = trimmed.isEmpty ? "model" : String(trimmed.prefix(48))
        return "\(base)-\(digest)"
    }

    // MARK: - Multi-file GGUF

    /// Parsed name of a split GGUF, e.g. `model-Q4_K_M-00002-of-00003.gguf`.
    struct ShardInfo: Equatable {
        let base: String
        let index: Int
        let total: Int
    }

    /// Recognises llama.cpp's split-file naming. A single-file model returns
    /// `nil`, so callers can treat both shapes uniformly.
    nonisolated static func shardInfo(for fileName: String) -> ShardInfo? {
        let name = (fileName as NSString).lastPathComponent
        guard name.lowercased().hasSuffix(".gguf") else { return nil }
        let stem = String(name.dropLast(5))
        // `-00001-of-00003` at the end, zero-padded to five digits by convention.
        let parts = stem.split(separator: "-")
        guard parts.count >= 4 else { return nil }
        let totalPart = parts[parts.count - 1]
        let ofPart = parts[parts.count - 2]
        let indexPart = parts[parts.count - 3]
        guard ofPart.lowercased() == "of",
              let total = Int(totalPart), total > 0, total <= 99_999,
              let index = Int(indexPart), index > 0, index <= total else { return nil }
        let base = parts.dropLast(3).joined(separator: "-")
        guard !base.isEmpty else { return nil }
        return ShardInfo(base: base, index: index, total: total)
    }

    /// `local/<slug>` that does not collide with an existing entry (§10.1).
    func uniqueModelID(base: String, quantization: String?, repoId: String?) -> String {
        var slug = base.lowercased()
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        if let repoId, !repoId.isEmpty {
            let owner = repoId.split(separator: "/").first.map(String.init) ?? ""
            if !owner.isEmpty, !slug.hasPrefix(owner.lowercased()) {
                slug = owner.lowercased() + "-" + slug
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let candidate = "local/" + (slug.isEmpty ? "model" : slug)
        if !models.contains(where: { $0.id == candidate }) {
            return candidate
        }
        if let quantization, !quantization.isEmpty {
            let withQuant = candidate + "-" + quantization.lowercased()
            if !models.contains(where: { $0.id == withQuant }) {
                return withQuant
            }
        }
        var counter = 2
        while models.contains(where: { $0.id == "\(candidate)-\(counter)" }) {
            counter += 1
        }
        return "\(candidate)-\(counter)"
    }

    // MARK: - Registry Operations

    /// Reads the registry, drops runtime states that cannot outlive a process,
    /// and repairs metadata in the background. The header of every registered
    /// file used to be parsed synchronously on the main thread at launch.
    func loadRegistry() {
        metadataRepairTask?.cancel()
        guard fileManager.fileExists(atPath: registryFileURL.path) else {
            // A previously failed file disappearing is not consent to reset it.
            guard registryError == nil else { return }
            self.models = []
            return
        }

        do {
            let data = try Data(contentsOf: registryFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([LocalModel].self, from: data)
            guard loaded.allSatisfy({ ($0.schemaVersion ?? 1) <= PersistenceSchema.current }) else {
                throw LocalStorageError.registryUnavailable
            }

            var repaired = false
            let storageReachable = storageStatus.isUsable
            for index in loaded.indices {
                let wasTransient = loaded[index].runtimeStatus.isTransient
                let exists = loaded[index].fileExists(in: modelsDirectory)
                if !exists {
                    // A detached drive must not be recorded as "model deleted":
                    // the entry keeps its state until the volume is back.
                    if storageReachable, loaded[index].runtimeStatus != .notInstalled {
                        loaded[index].runtimeStatus = .notInstalled
                        repaired = true
                    }
                } else if wasTransient || loaded[index].runtimeStatus == .notInstalled {
                    // Runtime states are not durable: after a crash or a clean
                    // quit the engine is gone, so "ready" must not survive. A
                    // file that is back on disk is installed again.
                    loaded[index].runtimeStatus = .installed
                    repaired = true
                }
            }
            registryError = nil
            // A readable registry ends the previous recovery event, so the next
            // corruption backs up its own bytes instead of reusing the old URL.
            registryBackupURL = nil
            self.models = loaded
            if repaired { saveRegistry() }
            if directoryOverride == nil { scheduleMetadataRepair() }
        } catch {
            if registryBackupURL == nil {
                let stamp = Self.backupTimestamp()
                let backup = registryFileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("registry.corrupt-\(stamp).json")
                do {
                    let corrupt = try Data(contentsOf: registryFileURL)
                    try Self.writeAtomically(corrupt, to: backup)
                } catch {
                    NSLog(
                        "LocalModelStore: could not back up the corrupt registry: %@",
                        String(describing: error)
                    )
                    try? fileManager.copyItem(at: registryFileURL, to: backup)
                }
                if fileManager.fileExists(atPath: backup.path) {
                    registryBackupURL = backup
                    NSLog(
                        "LocalModelStore: corrupt registry backed up to %@",
                        backup.lastPathComponent
                    )
                }
            }
            // Retain a last-known-good catalog in memory; first launch has none.
            // In both cases neither an import nor a status update may overwrite
            // corrupt or newer-schema data with an apparently empty catalog.
            registryError = L("The Local AI registry could not be read. Changes are disabled. Restore the registry or update the app, then retry.")
        }
    }

    /// Re-reads GGUF headers off the main thread for entries that never got real
    /// metadata, then applies only the fields that are still missing.
    private func scheduleMetadataRepair() {
        metadataRepairTask?.cancel()
        let candidates = models.filter {
            $0.memoryProfile == nil || $0.memoryProfile?.headCountKVByLayer == nil
                || $0.blockCount == nil || $0.architecture == nil
                || $0.quantization == "GGUF" || $0.quantization == "Unknown"
        }
        guard !candidates.isEmpty else { return }
        let directory = modelsDirectory
        metadataRepairTask = Task { [weak self] in
            let repaired = await Task.detached(priority: .utility) { () -> [String: GgufInfo] in
                var result: [String: GgufInfo] = [:]
                for model in candidates {
                    guard let url = model.fileURLs(in: directory).first,
                          FileManager.default.fileExists(atPath: url.path) else { continue }
                    if let info = try? GgufMetadataReader.read(from: url) {
                        result[model.id] = info
                    }
                }
                return result
            }.value
            guard let self, !Task.isCancelled else { return }
            self.applyMetadataRepair(repaired)
        }
    }

    private func applyMetadataRepair(_ repaired: [String: GgufInfo]) {
        guard canWriteRegistry else { return }
        var changed = false
        for index in models.indices {
            guard let info = repaired[models[index].id] else { continue }
            if let context = info.contextLength, context > 0, context != models[index].contextLength {
                models[index].contextLength = context
                changed = true
            }
            if let blocks = info.blockCount, blocks > 0, blocks != models[index].blockCount {
                models[index].blockCount = blocks
                changed = true
            }
            if info.architecture != models[index].architecture {
                models[index].architecture = info.architecture
                changed = true
            }
            if info.quantization != "GGUF", info.quantization != models[index].quantization {
                models[index].quantization = info.quantization
                changed = true
            }
            if let profile = GgufMemoryProfile(info: info), profile != models[index].memoryProfile {
                models[index].memoryProfile = profile
                changed = true
            }
        }
        if changed { saveRegistry() }
    }

    @discardableResult
    func saveRegistry() -> Bool {
        guard canWriteRegistry, isStorageUsable else { return false }
        ensureDirectoriesExist()
        registryWriteGeneration &+= 1
        do {
            let data = try Self.encodeRegistry(models)
            let url = registryFileURL
            // The same serial queue serves background status writes, so a
            // queued one always lands before this save.
            try registryIOQueue.sync {
                try Self.writeAtomically(data, to: url)
            }
            return true
        } catch {
            reportRegistrySaveFailure(error)
            return false
        }
    }

    /// Writes the registry without blocking the caller.
    ///
    /// Status changes are frequent and a catalogue write with fsync must not
    /// stall a frame. The shared serial queue keeps these bytes ordered with
    /// later synchronous saves, and the snapshot is taken before the hop so the
    /// main-actor array is never touched from the queue.
    private func saveRegistryInBackground(for modelID: String, status: ModelRuntimeStatus) {
        guard canWriteRegistry, isStorageUsable else { return }
        ensureDirectoriesExist()
        let data: Data
        do {
            data = try Self.encodeRegistry(models)
        } catch {
            reportRegistrySaveFailure(error)
            return
        }
        registryWriteGeneration &+= 1
        let generation = registryWriteGeneration
        let url = registryFileURL
        registryIOQueue.async { [weak self] in
            do {
                try Self.writeAtomically(data, to: url)
            } catch {
                NSLog(
                    "LocalModelStore: registry write failed for model %@ (status %@): %@",
                    modelID, String(describing: status), String(describing: error)
                )
                Task { @MainActor [weak self] in
                    guard let self, generation == self.registryWriteGeneration else { return }
                    self.lastError = String(
                        format: L("The Local AI registry could not be saved: %@"),
                        error.localizedDescription
                    )
                }
            }
        }
    }

    nonisolated private static func encodeRegistry(_ models: [LocalModel]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(models)
    }

    private func reportRegistrySaveFailure(_ error: Error) {
        let message = String(
            format: L("The Local AI registry could not be saved: %@"),
            error.localizedDescription
        )
        lastError = message
        NSLog("LocalModelStore: registry save failed: %@", String(describing: error))
    }

    @discardableResult
    func addOrUpdateModel(_ model: LocalModel) -> Bool {
        guard canWriteRegistry else { return false }
        // A malformed settings row would be clamped by the engine or stop it
        // from starting, so it is rejected before it reaches the registry.
        if let reason = model.userSettings.validate() {
            lastError = reason
            NSLog("LocalModelStore: refused settings for %@: %@", model.id, reason)
            return false
        }
        let previous = models
        if let idx = models.firstIndex(where: { $0.id == model.id }) {
            models[idx] = model
        } else {
            models.append(model)
        }
        guard saveRegistry() else {
            models = previous
            return false
        }
        return true
    }

    func updateModelStatus(id: String, status: ModelRuntimeStatus) {
        guard canWriteRegistry else { return }
        guard let idx = models.firstIndex(where: { $0.id == id }) else { return }
        guard models[idx].runtimeStatus != status else { return }
        models[idx].runtimeStatus = status
        if status == .ready {
            models[idx].lastUsedAt = Date()
            activeModelId = id
        } else if status == .unloading || status == .installed || status == .error || status == .notInstalled {
            if activeModelId == id {
                activeModelId = nil
            }
        }
        // The row is visible immediately; persistence happens behind the UI and
        // logs its own failure with the model id and status.
        saveRegistryInBackground(for: id, status: status)
    }

    /// Resets every live-engine state to `installed`. Called when the router is
    /// stopped or found dead so the catalog cannot advertise a model that no
    /// process is serving.
#if DEBUG
    /// Test seam: reload the registry from the current `LocalPaths.baseOverride`
    /// instead of keeping rows loaded from the real vault at app startup.
    func reloadFromDiskForTesting() {
        metadataRepairTask?.cancel()
        models = []
        registryError = nil
        activeModelId = nil
        loadRegistry()
    }

    /// Replaces the in-memory rows without reading or writing any registry.
    /// Cancels a pending metadata repair so it cannot outlive the test vault.
    func replaceModelsForTesting(_ models: [LocalModel]) {
        metadataRepairTask?.cancel()
        self.models = models
    }
#endif

    func normalizeRuntimeStates() {
        guard canWriteRegistry else { return }
        var changed = false
        for index in models.indices where models[index].runtimeStatus.isTransient {
            models[index].runtimeStatus = .installed
            changed = true
        }
        if changed {
            activeModelId = nil
            saveRegistry()
        }
    }

    // MARK: - Delete

    /// Removes the model from the registry and, when asked, its files.
    ///
    /// The files are renamed into a trash folder first and only then is the
    /// registry rewritten; a failed registry write restores them. A failed file
    /// removal must not look like a clean deletion: the caller gets the paths
    /// that are still on disk.
    @discardableResult
    func removeModel(id: String, deleteFiles: Bool) -> [String] {
        guard let idx = models.firstIndex(where: { $0.id == id }) else { return [] }
        let model = models[idx]
        guard canWriteRegistry else { return model.files }

        guard deleteFiles else {
            models.remove(at: idx)
            if activeModelId == id { activeModelId = nil }
            saveRegistry()
            return []
        }

        guard isStorageUsable else { return model.files }

        // Trash lives on the models volume: a cross-volume move during delete
        // would copy gigabytes instead of renaming.
        let trash = modelsDirectory.appendingPathComponent(
            ".staging-delete-\(UUID().uuidString)", isDirectory: true
        )
        try? fileManager.createDirectory(at: trash, withIntermediateDirectories: true)

        var moved: [(URL, URL)] = []
        var failedPaths: [String] = []
        let urls = model.fileURLs(in: modelsDirectory)

        // Only files inside the managed root are deleted; a model linked from
        // the user's own folder keeps its file.
        let rootPrefix = modelsDirectory.standardizedFileURL.path.hasSuffix("/")
            ? modelsDirectory.standardizedFileURL.path
            : modelsDirectory.standardizedFileURL.path + "/"
        for url in urls where url.standardizedFileURL.path.hasPrefix(rootPrefix) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let target = trash.appendingPathComponent(UUID().uuidString)
            do {
                try fileManager.moveItem(at: url, to: target)
                moved.append((url, target))
            } catch {
                failedPaths.append(url.lastPathComponent)
            }
        }

        models.remove(at: idx)
        if activeModelId == id { activeModelId = nil }
        let saved = saveRegistry()
        if !saved {
            // Restore: the registry still described these files a moment ago.
            for (original, target) in moved.reversed() {
                try? fileManager.moveItem(at: target, to: original)
            }
            models.insert(model, at: min(idx, models.count))
            if activeModelId == nil { activeModelId = model.id }
            try? fileManager.removeItem(at: trash)
            return model.files
        }

        if let namespace = model.ownedNamespaceDirectory(in: modelsDirectory) {
            try? fileManager.removeItem(at: namespace)
        }
        try? fileManager.removeItem(at: trash)
        return failedPaths
    }

    private func extractQuantization(from name: String) -> String {
        GgufMetadataReader.extractQuantization(from: name)
    }
}

import Foundation
import CryptoKit

/// Descriptor of one installed inference runtime.
///
/// A runtime is a self-contained folder: `llama-server`, its dylibs and a
/// `runtime.json` manifest. The bundled engine uses the same shape, so the
/// switcher does not need a special case for it.
struct RuntimeManifest: Codable, Identifiable, Equatable, Sendable {
    /// `<backend>-<platform>-<build>`, also the folder name.
    var id: String
    var backend: String        // metal | cpu | cuda | vulkan | rocm
    var platform: String       // macos-arm64 | win-x64 | …
    var build: String          // llama.cpp build tag, e.g. b12099
    var version: String        // human string from `--version`
    /// SHA-256 of `llama-server`, used to detect tampering.
    var sha256: String?
    /// CPU instruction set the binary was compiled for (Windows/Linux).
    var cpuExtensions: [String]
    var sizeBytes: UInt64
    /// True when the runtime ships inside the app bundle and cannot be deleted.
    var isBundled: Bool

    enum CodingKeys: String, CodingKey {
        case id, backend, platform, build, version, sha256
        case cpuExtensions = "cpu_extensions"
        case sizeBytes = "size_bytes"
        case isBundled = "bundled"
    }
}

/// Installed runtimes plus the active selection.
@MainActor
final class RuntimeStore: ObservableObject {
    static let shared = RuntimeStore()

    @Published private(set) var runtimes: [RuntimeManifest] = []
    @Published private(set) var activeID: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var installStage = ""
    @Published private(set) var installBytes: Int64 = 0
    @Published private(set) var installTotal: Int64 = 0
    @Published private(set) var installError: String?
    /// Tag of the catalog release currently being installed, for the catalog UI.
    @Published private(set) var installingReleaseTag: String?
    /// Cached manifest digest status per runtime id. Hashing runs off the main
    /// thread because the universal engine is ~146 MB.
    @Published private(set) var integrityByID: [String: String] = [:]
    private var installTask: Task<Void, Never>?
    private var integrityTask: Task<Void, Never>?
    /// Tests install into a temporary directory instead of the user's data.
    private let directoryOverride: URL?

    init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    func cancelInstall() { installTask?.cancel() }

    func install(from url: URL, sha256: String) {
        guard !isInstalling else { return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              RuntimePackageInstaller.validDigest(sha256) else {
            installError = L("Enter an HTTP(S) URL without credentials and a 64-character SHA-256.")
            return
        }
        beginInstall(stage: L("Downloading runtime..."))
        let root = runtimesDirectory
        installTask = Task {
            let progress = RuntimeDownloadProgress { [weak self] bytes, total in
                Task { @MainActor in
                    self?.installBytes = bytes
                    self?.installTotal = total
                }
            }
            do {
                let configuration = NetworkProxy.externalConfiguration()
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (temporary, response) = try await session.download(for: request, delegate: progress)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw RuntimePackageInstaller.failure(L("Runtime download failed: expected HTTP 200."))
                }
                try Task.checkCancellation()
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                let archive = root.appendingPathComponent(".download-\(UUID().uuidString).tar.gz")
                try fileManager.moveItem(at: temporary, to: archive)
                defer { try? fileManager.removeItem(at: archive) }
                installStage = L("Verifying and installing...")
                let worker = Task.detached(priority: .utility) {
                    try RuntimePackageInstaller.installArchive(archive, expectedSHA256: sha256, into: root)
                }
                _ = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                reload()
                installStage = L("Runtime installed. Select it to use it.")
            } catch {
                if progress.exceededLimit {
                    installError = L("Runtime archive is larger than the 2 GiB limit.")
                } else {
                    installError = Task.isCancelled ? L("Installation cancelled.") : error.localizedDescription
                }
                installStage = ""
            }
            isInstalling = false
            installTask = nil
        }
    }

    func importFolder(_ folder: URL) {
        guard !isInstalling else { return }
        beginInstall(stage: L("Verifying and installing..."))
        let root = runtimesDirectory
        installTask = Task {
            do {
                let worker = Task.detached(priority: .utility) {
                    try RuntimePackageInstaller.installFolder(folder, into: root)
                }
                _ = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                reload()
                installStage = L("Runtime installed. Select it to use it.")
            } catch {
                installError = Task.isCancelled ? L("Installation cancelled.") : error.localizedDescription
                installStage = ""
            }
            isInstalling = false
            installTask = nil
        }
    }

    /// Downloads both official macOS slices, merges them into a universal
    /// engine with the bundled helper and installs it through the same
    /// validated package path as a manual archive.
    func install(catalog release: RuntimeCatalogRelease) {
        guard !isInstalling else { return }
        guard release.arm64.size > 0, release.x64.size > 0,
              RuntimePackageInstaller.validDigest(release.arm64.sha256),
              RuntimePackageInstaller.validDigest(release.x64.sha256) else {
            installError = L("The selected release has no valid SHA-256 metadata.")
            return
        }
        beginInstall(stage: L("Downloading macOS arm64 engine..."))
        installingReleaseTag = release.tag
        installTotal = release.totalBytes
        let root = runtimesDirectory
        installTask = Task {
            let scratch = root.appendingPathComponent(".catalog-\(UUID().uuidString)", isDirectory: true)
            defer {
                installingReleaseTag = nil
                try? fileManager.removeItem(at: scratch)
            }
            do {
                try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
                let arm = try await downloadCatalogAsset(
                    release.arm64,
                    to: scratch.appendingPathComponent(release.arm64.name),
                    byteOffset: 0
                )
                installStage = L("Downloading macOS x86_64 engine...")
                let x64 = try await downloadCatalogAsset(
                    release.x64,
                    to: scratch.appendingPathComponent(release.x64.name),
                    byteOffset: release.arm64.size
                )
                try Task.checkCancellation()
                installStage = L("Merging universal runtime...")
                let merged = scratch.appendingPathComponent("runtime", isDirectory: true)
                try await mergeCatalogRelease(
                    release, arm64: arm, x64: x64, into: merged, scratch: scratch
                )
                try Task.checkCancellation()
                installStage = L("Verifying runtime...")
                let worker = Task.detached(priority: .utility) {
                    try RuntimePackageInstaller.installFolder(merged, into: root)
                }
                _ = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
                reload()
                installStage = L("Runtime installed. Select it to use it.")
            } catch {
                installError = Task.isCancelled
                    ? L("Installation cancelled.")
                    : error.localizedDescription
                installStage = ""
            }
            isInstalling = false
            installTask = nil
        }
    }

    private func downloadCatalogAsset(
        _ asset: RuntimeCatalogAsset,
        to destination: URL,
        byteOffset: Int64
    ) async throws -> URL {
        guard RuntimePackageInstaller.validDigest(asset.sha256) else {
            throw RuntimePackageInstaller.failure(L("Invalid runtime archive digest."))
        }
        let progress = RuntimeDownloadProgress { [weak self] bytes, _ in
            Task { @MainActor in
                self?.installBytes = byteOffset + bytes
            }
        }
        let configuration = NetworkProxy.externalConfiguration()
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: asset.downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporary, response) = try await session.download(for: request, delegate: progress)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimePackageInstaller.failure(L("Runtime download failed: expected HTTP 200."))
        }
        if progress.exceededLimit {
            throw RuntimePackageInstaller.failure(L("Runtime archive is larger than the 2 GiB limit."))
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: temporary, to: destination)
        guard let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == asset.size else {
            try? fileManager.removeItem(at: destination)
            throw RuntimePackageInstaller.failure(L("Downloaded runtime has an unexpected size."))
        }
        guard Self.sha256Hex(of: destination) == asset.sha256.lowercased() else {
            try? fileManager.removeItem(at: destination)
            throw RuntimePackageInstaller.failure(
                L("Downloaded runtime SHA-256 does not match the release metadata.")
            )
        }
        return destination
    }

    /// Runs the bundled merge helper on already verified archives. The helper
    /// is the same script used for release builds, so lipo/signing/manifest
    /// behaviour cannot drift between the two paths.
    private func mergeCatalogRelease(
        _ release: RuntimeCatalogRelease,
        arm64: URL,
        x64: URL,
        into destination: URL,
        scratch: URL
    ) async throws {
        guard let script = Bundle.main.url(forResource: "fetch-runtime", withExtension: "sh") else {
            throw RuntimePackageInstaller.failure(L("Bundled runtime merge script is missing."))
        }
        let log = scratch.appendingPathComponent("merge.log")
        fileManager.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["LLAMA_TAG"] = release.tag
        environment["RUNTIME_DEST"] = destination.path
        environment["RUNTIME_CACHE"] = scratch.appendingPathComponent("cache", isDirectory: true).path
        environment["RUNTIME_LOCAL_ARM64"] = arm64.path
        environment["RUNTIME_LOCAL_X64"] = x64.path
        environment["RUNTIME_SHA_ARM64"] = release.arm64.sha256
        environment["RUNTIME_SHA_X64"] = release.x64.sha256
        environment["RUNTIME_SKIP_VERSION"] = "1"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? handle.close()
        }
        try process.run()
        while process.isRunning {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = (try? String(contentsOf: log, encoding: .utf8))?
                .split(separator: "\n").suffix(6).joined(separator: "\n") ?? ""
            throw RuntimePackageInstaller.failure(
                tail.isEmpty ? L("Runtime merge failed.") : L("Runtime merge failed.") + " " + tail
            )
        }
        guard fileManager.fileExists(
            atPath: destination.appendingPathComponent("runtime.json").path
        ) else {
            throw RuntimePackageInstaller.failure(L("Runtime merge produced no manifest."))
        }
    }

    private func beginInstall(stage: String) {
        isInstalling = true
        installStage = stage
        installBytes = 0
        installTotal = 0
        installError = nil
    }

    private let defaultsKey = "activeLocalRuntimeID"
    private let fileManager = FileManager.default

    var runtimesDirectory: URL {
        directoryOverride ?? LocalModelStore.shared.runtimeDirectory
    }

    /// The runtime currently used by the engine.
    var active: RuntimeManifest? {
        if let activeID, let match = runtimes.first(where: { $0.id == activeID }) {
            return match
        }
        return runtimes.first
    }

    var activeBinaryURL: URL? {
        guard let active else { return nil }
        let url = directory(for: active).appendingPathComponent("llama-server")
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    func directory(for manifest: RuntimeManifest) -> URL {
        manifest.isBundled
            ? LocalModelStore.shared.bundledRuntimeDirectory
            : runtimesDirectory.appendingPathComponent(manifest.id, isDirectory: true)
    }

    /// Rescans bundled and downloaded runtimes. Called at launch and after an
    /// install or a delete.
    func reload() {
        var found: [RuntimeManifest] = []

        if let bundled = Self.readManifest(in: LocalModelStore.shared.bundledRuntimeDirectory) {
            found.append(bundled)
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: runtimesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for folder in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Skip only our own work-in-progress folders. Skipping every hidden
            // directory hid a successfully installed `.<id>` package forever.
            guard !LocalPaths.isTemporaryArtifact(folder.lastPathComponent),
                  var manifest = Self.readManifest(in: folder) else { continue }
            manifest.isBundled = false
            found.append(manifest)
        }

        runtimes = found
        verifyIntegrity()
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        if let stored, found.contains(where: { $0.id == stored }) {
            activeID = stored
        } else {
            activeID = found.first?.id
        }
    }

    /// Selecting a runtime used by the engine; the caller restarts the engine.
    func select(_ manifest: RuntimeManifest) {
        activeID = manifest.id
        UserDefaults.standard.set(manifest.id, forKey: defaultsKey)
    }

    /// Removes a downloaded runtime. The bundled one is never deletable.
    func delete(_ manifest: RuntimeManifest) throws {
        guard !manifest.isBundled else {
            throw NSError(domain: "MelonTools.Runtime", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The bundled runtime cannot be removed."
            ])
        }
        try fileManager.removeItem(at: directory(for: manifest))
        if activeID == manifest.id {
            activeID = nil
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        reload()
    }

    /// Digest status cached by `verifyIntegrity`; the body never hashes.
    func integrity(of manifest: RuntimeManifest) -> String {
        integrityByID[manifest.id] ?? "Checking…"
    }

    /// Re-hashes installed engines off the main thread. Runs after a reload,
    /// so the settings list never blocks on a 146 MB read.
    private func verifyIntegrity() {
        integrityTask?.cancel()
        let manifests = runtimes
        var results: [String: String] = [:]
        for manifest in manifests where manifest.sha256?.isEmpty != false {
            results[manifest.id] = "Unverified"
        }
        integrityByID = results
        guard manifests.contains(where: { $0.sha256?.isEmpty == false }) else { return }
        integrityTask = Task { [weak self] in
            for manifest in manifests {
                guard !Task.isCancelled else { return }
                guard let expected = manifest.sha256?.lowercased(), !expected.isEmpty else { continue }
                let directory = self?.directory(for: manifest)
                guard let binary = directory?.appendingPathComponent("llama-server") else { return }
                let actual = await Task.detached(priority: .utility) {
                    Self.sha256Hex(of: binary)
                }.value
                guard !Task.isCancelled else { return }
                let status = actual == nil ? "Unverified" : (actual == expected ? "Verified" : "Modified")
                self?.integrityByID[manifest.id] = status
            }
        }
    }

    // MARK: - Manifest I/O

    static func readManifest(in directory: URL) -> RuntimeManifest? {
        let url = directory.appendingPathComponent("runtime.json")
        guard let data = try? Data(contentsOf: url),
              var manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data)
        else { return nil }
        // The folder name is authoritative, and a bundled runtime is never
        // deletable even if the manifest claims otherwise.
        manifest.id = directory.lastPathComponent == "runtime"
            ? manifest.id
            : directory.lastPathComponent
        if directory.path.contains("/Resources/runtime") {
            manifest.isBundled = true
        }
        guard FileManager.default.isExecutableFile(
            atPath: directory.appendingPathComponent("llama-server").path
        ) else { return nil }
        return manifest
    }

    nonisolated static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                guard !Task.isCancelled else { return nil }
                hasher.update(data: chunk)
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

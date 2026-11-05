import Foundation

/// Untrusted packages stay in staging until validated. Existing installs are
/// never removed or overwritten; validation never executes downloaded code.
enum RuntimePackageInstaller {
    static let maximumArchiveBytes: Int64 = 2 * 1024 * 1024 * 1024

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MelonTools.Runtime", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Reserved folder prefixes used for staging, extraction and downloads.
    /// A package must not be able to publish itself into one of them, and a
    /// leading dot used to make a successfully installed runtime invisible:
    /// `reload()` skipped every hidden directory.
    static let reservedPrefixes = ["", ".", "install-", "extract-", "download-", "catalog-", "staging-", "publish-"]

    static func validID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 120, id != ".", id != ".." else { return false }
        guard !id.hasPrefix(".") else { return false }
        guard !reservedPrefixes.contains(where: { !$0.isEmpty && id.lowercased().hasPrefix($0) }) else {
            return false
        }
        return id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    static func validDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }
    }

    /// Reject links, including internal ones: packages must be self-contained.
    static func inspectTree(_ root: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
            throw failure(L("Runtime package must be a real directory."))
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw failure(L("Cannot inspect runtime package."))
        }
        var count = 0
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw failure(L("Runtime packages cannot contain links or special files."))
            }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
            guard count <= 4096, bytes <= 8 * maximumArchiveBytes else {
                throw failure(L("Runtime package exceeds installation limits."))
            }
        }
        if let enumerationError { throw enumerationError }
    }

    static func validate(_ folder: URL) throws -> RuntimeManifest {
        try inspectTree(folder)
        var manifest = try JSONDecoder().decode(RuntimeManifest.self,
            from: Data(contentsOf: folder.appendingPathComponent("runtime.json")))
        guard validID(manifest.id), ["metal", "cpu"].contains(manifest.backend) else {
            throw failure(L("Invalid runtime id or unsupported macOS backend."))
        }
        #if arch(arm64)
        let architecture = "arm64"
        let platforms = ["macos-arm64", "macos-universal"]
        #else
        let architecture = "x86_64"
        let platforms = ["macos-x64", "macos-x86_64", "macos-universal"]
        #endif
        guard platforms.contains(manifest.platform) else {
            throw failure(L("Runtime platform is incompatible with this Mac."))
        }
        let binary = folder.appendingPathComponent("llama-server")
        guard let digest = manifest.sha256, validDigest(digest),
              RuntimeStore.sha256Hex(of: binary) == digest.lowercased() else {
            throw failure(L("Runtime binary SHA-256 does not match runtime.json."))
        }
        guard try supportsArchitecture(binary, architecture) else {
            throw failure(String(format: L("Runtime binary does not contain a native %@ slice."), architecture))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        manifest.isBundled = false
        return manifest
    }

    static func installFolder(_ source: URL, into root: URL) throws -> RuntimeManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try inspectTree(source)
        try fm.copyItem(at: source, to: stage)
        let manifest = try validate(stage)
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else {
            throw failure(L("This runtime id is already installed. Remove it explicitly before installing a replacement."))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("runtime.json"), options: .atomic)
        try Task.checkCancellation()
        try fm.moveItem(at: stage, to: destination)
        return manifest
    }

    static func installArchive(_ archive: URL, expectedSHA256: String, into root: URL) throws -> RuntimeManifest {
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard archiveSize > 0, Int64(archiveSize) <= maximumArchiveBytes else {
            throw failure(L("Runtime archive is empty or larger than the 2 GiB limit."))
        }
        guard validDigest(expectedSHA256),
              RuntimeStore.sha256Hex(of: archive) == expectedSHA256.lowercased() else {
            throw failure(L("Downloaded archive SHA-256 does not match. Nothing was installed."))
        }
        let names = try run("/usr/bin/tar", ["-tzf", archive.path]).split(separator: "\n")
        guard !names.isEmpty, names.count <= 4096 else { throw failure(L("Invalid runtime archive.")) }
        for name in names {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
                throw failure(L("Unsafe path in runtime archive."))
            }
        }
        let listing = try run("/usr/bin/tar", ["-tvzf", archive.path])
        var unpackedBytes: Int64 = 0
        for line in listing.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard line.first == "-" || line.first == "d", columns.count >= 5,
                  let size = Int64(columns[4]), size >= 0 else {
                throw failure(L("Archive links and special files are not allowed."))
            }
            unpackedBytes += size
            guard unpackedBytes <= 8 * maximumArchiveBytes else {
                throw failure(L("Expanded runtime archive is too large."))
            }
        }
        let scratch = root.appendingPathComponent(".extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try run("/usr/bin/tar", ["-xzf", archive.path, "--no-same-owner", "--no-same-permissions", "-C", scratch.path])
        try inspectTree(scratch)
        let candidates = [scratch] + (try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil))
        let folders = candidates.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("runtime.json").path) }
        guard folders.count == 1, let folder = folders.first else {
            throw failure(L("Archive must contain one folder with runtime.json and llama-server."))
        }
        return try installFolder(folder, into: root)
    }

    /// `lipo -verify_arch` rejects arm64e when asked for arm64, so the arch
    /// list is checked instead. A binary that is not Mach-O is rejected by lipo.
    static func supportsArchitecture(_ binary: URL, _ architecture: String) throws -> Bool {
        let archs = try run("/usr/bin/lipo", ["-archs", binary.path])
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
        if archs.contains(architecture) { return true }
        return architecture == "arm64" && archs.contains { $0 == "arm64e" || $0.hasPrefix("arm64e.") }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if Task.isCancelled || data.count + chunk.count > 4 * 1024 * 1024 {
                process.terminate()
                process.waitUntilExit()
                throw failure(L("Package inspection cancelled or output limit exceeded."))
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw failure(L("Runtime inspection or extraction failed.")) }
        return String(decoding: data, as: UTF8.self)
    }
}

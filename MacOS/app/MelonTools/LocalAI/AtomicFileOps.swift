import Foundation
import CryptoKit
import Security

/// Failures of the local storage layer, with messages a user can act on.
enum LocalStorageError: LocalizedError {
    case notADirectory
    case notWritable
    case storageUnavailable
    case registryUnavailable
    case journalUnavailable
    case busy
    case notEnoughSpace(required: UInt64, free: UInt64)
    case destinationConflict(String)
    case verificationFailed(String)
    case unsafeName(String)
    case notGGUF
    case invalidGGUF(String)
    case noGGUFFiles
    case incompleteSplit(missing: [Int])
    case inconsistentSplit
    case keychain(OSStatus)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .notADirectory:
            return L("The selected location is not a folder.")
        case .notWritable:
            return L("The selected folder is not writable.")
        case .storageUnavailable:
            return L("The models folder is not available. Reconnect the drive or choose another folder.")
        case .registryUnavailable:
            return L("The Local AI registry could not be read. Changes are disabled. Restore the registry or update the app, then retry.")
        case .journalUnavailable:
            return L("The download queue could not be saved. Nothing was started; free some space or fix file permissions and retry.")
        case .busy:
            return L("Another storage operation is already running.")
        case .notEnoughSpace(let required, let free):
            return String(
                format: L("Not enough free space: %@ required, %@ available."),
                LocalHardwareService.formatBytes(required),
                LocalHardwareService.formatBytes(free)
            )
        case .destinationConflict(let name):
            return String(format: L("A file named %@ already exists in the models folder."), name)
        case .verificationFailed(let name):
            return String(format: L("Copied file %@ does not match the source."), name)
        case .unsafeName(let name):
            return String(format: L("Unsafe file name: %@"), name)
        case .notGGUF:
            return L("Selected file is not a GGUF model.")
        case .invalidGGUF(let name):
            return String(format: L("Not a valid GGUF file: %@"), name)
        case .noGGUFFiles:
            return L("No .gguf files in the selected folder.")
        case .incompleteSplit(let missing):
            let list = missing.map(String.init).joined(separator: ", ")
            return missing.isEmpty
                ? L("The selected files are not a complete split model.")
                : String(format: L("Split model is incomplete. Missing part(s): %@"), list)
        case .inconsistentSplit:
            return L("Split model parts disagree about the total number of files.")
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            return String(format: L("Could not save the token in the Keychain: %@"), detail)
        case .copyFailed(let name):
            return String(format: L("Could not copy %@."), name)
        }
    }
}

/// File operations that never destroy the previous state before the new one is
/// verified. The download/import paths used `removeItem` followed by `copyItem`,
/// so a full disk or a detached drive took the installed model with it.
enum AtomicFileOps {
    /// 4 MiB: big enough to keep syscalls cheap, small enough to cancel quickly.
    private static let chunkSize = 4 * 1024 * 1024

    static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Rejects names that could escape the managed folder or break lookups.
    /// Hugging Face reports real repository paths, so only the last component is
    /// kept and separators are refused even there.
    static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        guard !name.hasPrefix(".") else { return false }
        guard name.count <= 200 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    /// Sanitised last path component of a repository file path, e.g.
    /// `subdir/model.gguf` → `model.gguf`.
    static func safeFileName(_ path: String, fallback: String = "model.gguf") -> String {
        let candidate = (path as NSString).lastPathComponent
        return isSafeFileName(candidate) ? candidate : fallback
    }

    static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                if Task.isCancelled { return nil }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies `source` to `destination`, hashing while writing, and refuses to
    /// leave a partial file behind on failure.
    @discardableResult
    static func copyVerifying(source: URL, destination: URL) throws -> UInt64 {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            throw LocalStorageError.destinationConflict(destination.lastPathComponent)
        }
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw LocalStorageError.copyFailed(source.lastPathComponent)
        }
        defer { try? input.close() }
        guard manager.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else {
            throw LocalStorageError.copyFailed(destination.lastPathComponent)
        }

        var written: UInt64 = 0
        do {
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                if Task.isCancelled { throw CancellationError() }
                try output.write(contentsOf: chunk)
                written += UInt64(chunk.count)
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? manager.removeItem(at: destination)
            throw error
        }

        let sourceSize = fileSize(source)
        guard sourceSize == 0 || written == sourceSize else {
            try? manager.removeItem(at: destination)
            throw LocalStorageError.verificationFailed(destination.lastPathComponent)
        }
        return written
    }

    /// Publishes a staged file at its final path. Same-volume moves are a single
    /// rename; cross-volume moves copy to a hidden sibling first, verify, rename
    /// into place and only then delete the source.
    static func publish(_ staged: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            throw LocalStorageError.destinationConflict(destination.lastPathComponent)
        }
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if sameVolume(staged, destination) {
            try manager.moveItem(at: staged, to: destination)
            return
        }

        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".publish-\(UUID().uuidString)")
        try copyVerifying(source: staged, destination: temporary)
        do {
            try manager.moveItem(at: temporary, to: destination)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        try? manager.removeItem(at: staged)
    }

    static func sameVolume(_ first: URL, _ second: URL) -> Bool {
        guard let left = LocalModelStore.volumeIdentifier(for: first.deletingLastPathComponent()),
              let right = LocalModelStore.volumeIdentifier(for: second.deletingLastPathComponent()) else {
            return false
        }
        return left == right
    }

    /// Removes `url` when it exists; never throws at the caller.
    static func removeIfExists(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

import Foundation
import Combine
import CryptoKit

/// State of an active or finished download task.
enum DownloadTaskState: String, Codable {
    case queued
    case downloading
    case paused
    case verifying
    case completed
    case failed
    case cancelled
}

/// One file of a download job.
struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    /// Files that belong to one model (a split set) share a job id.
    let jobID: UUID
    let repoId: String
    /// Path inside the repository, e.g. `subdir/model-00001-of-00002.gguf`.
    let rfilename: String
    /// Sanitised base name used on disk.
    let fileName: String
    let downloadURL: URL
    var totalBytes: UInt64
    var downloadedBytes: UInt64
    var speedBytesPerSec: UInt64
    var state: DownloadTaskState
    var errorMessage: String?
    let startedAt: Date
    /// LFS digest from Hugging Face, when published. Absent means "no
    /// authoritative checksum", and the UI must not claim verification.
    var expectedSHA256: String?
    /// `ETag`/`Last-Modified` of the first response, used as `If-Range` so a
    /// resumed download cannot splice two different revisions together.
    var validator: String?
    /// 1-based part number when this file is a shard of a split model.
    var shardIndex: Int?
    var shardTotal: Int?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    var formattedProgress: String { "\(Int(progress * 100))%" }

    /// True until the server (or the catalog) reports a usable total. The UI
    /// then shows an indeterminate bar instead of a frozen 0%.
    var hasKnownSize: Bool { totalBytes > 0 }

    var formattedSpeed: String {
        guard state == .downloading, speedBytesPerSec > 0 else { return "" }
        return "\(LocalHardwareService.formatBytes(speedBytesPerSec))/s"
    }

    var isTerminal: Bool {
        state == .completed || state == .cancelled || state == .failed
    }
}

/// A file requested from Hugging Face, resolved by the catalog.
struct HFDownloadRequest: Equatable {
    var rfilename: String
    var downloadURL: URL
    var size: UInt64
    var sha256: String?
}

/// Filesystem layout one manager instance works on.
///
/// The app uses `live`; tests pass a fixed temporary root so a regression case
/// never touches the real models folder or the user's journal.
struct DownloadRoots {
    /// Parts and the journal live under the app's support folder, which never
    /// moves while the app runs.
    var downloads: URL
    var journal: URL
    /// Set by tests only. Production leaves both nil so a models folder that is
    /// connected or migrated after launch is honoured instead of a stale copy.
    private var fixedModels: URL? = nil
    private var fixedStorageUsable: Bool? = nil
    /// Injected resolvers, used by regression tests to model a storage switch
    /// without touching the shared store or any real profile.
    private var modelsProvider: (@MainActor () -> URL)? = nil
    private var storageProvider: (@MainActor () -> Bool)? = nil

    /// The models folder as it is *now*: the user can attach another volume or
    /// migrate storage at any time.
    @MainActor var models: URL {
        fixedModels ?? modelsProvider?() ?? LocalModelStore.shared.modelsDirectory
    }

    @MainActor var storageUsable: Bool {
        fixedStorageUsable ?? storageProvider?() ?? LocalModelStore.shared.isStorageUsable
    }

    /// Fixed layout for tests, so no case reads or writes a real profile.
    init(downloads: URL, models: URL, storageUsable: Bool, journal: URL? = nil) {
        self.downloads = downloads
        self.journal = journal ?? downloads.appendingPathComponent("downloads.json")
        self.fixedModels = models
        self.fixedStorageUsable = storageUsable
    }

    /// Dynamic layout for tests: every read goes through the resolver, which is
    /// what the production `live` layout does against the shared store.
    init(
        downloads: URL,
        journal: URL? = nil,
        models: @escaping @MainActor () -> URL,
        storageUsable: @escaping @MainActor () -> Bool
    ) {
        self.downloads = downloads
        self.journal = journal ?? downloads.appendingPathComponent("downloads.json")
        self.modelsProvider = models
        self.storageProvider = storageUsable
    }

    private init(downloads: URL, journal: URL) {
        self.downloads = downloads
        self.journal = journal
        self.fixedModels = nil
        self.fixedStorageUsable = nil
    }

    /// Layout the app uses: parts under Local AI downloads, models on whatever
    /// volume is configured when the check runs.
    @MainActor
    static var live: DownloadRoots {
        DownloadRoots(downloads: LocalPaths.downloads, journal: LocalPaths.downloadJournal)
    }
}

/// Everything the model registry needs to adopt one finished job.
struct DownloadPublishRequest {
    var jobID: UUID
    var files: [(stagedURL: URL, fileName: String)]
    var displayName: String
    var repoId: String
    var revision: String?
    var metadata: GgufInfo?
    var checksum: String?
    /// SHA-256 published by the source, per file name, when there is one.
    var digests: [String: String]
}

/// Registry seam: the manager never writes the registry directly, so a crash
/// between "bytes are ready" and "model is registered" can be retried, and
/// tests can observe publication without a real model store.
@MainActor
protocol DownloadPublishSink {
    /// True only when the registry already holds *these bytes* for this job.
    ///
    /// Called after a crash, so the answer decides whether downloaded gigabytes
    /// may be deleted. Matching file names alone is not enough: another
    /// revision of the same repository can be registered under the same names.
    func hasPublished(_ request: DownloadPublishRequest) -> Bool
    func publish(_ request: DownloadPublishRequest) throws
}

/// Default sink: publishes into `LocalModelStore`.
@MainActor
struct LocalModelPublishSink: DownloadPublishSink {
    let store: LocalModelStore

    init(store: LocalModelStore = .shared) {
        self.store = store
    }

    func hasPublished(_ request: DownloadPublishRequest) -> Bool {
        guard !request.files.isEmpty else { return false }
        // A detached models volume proves nothing: keep the bytes and retry.
        guard store.isStorageUsable else { return false }
        let root = store.modelsDirectory
        // Exact: this job wrote this registry entry. Only its availability is
        // re-checked, because the bytes were ours by construction.
        if let model = store.models.first(where: { $0.downloadJobID == request.jobID }) {
            return Self.holdsSameBytes(request, model: model, root: root, requireByteProof: false)
        }
        // A re-download of the same revision is already registered under another
        // job. Adopting it is safe only when the bytes are identical.
        let names = Set(request.files.map { $0.fileName })
        return store.models.contains { model in
            guard model.repoId == request.repoId else { return false }
            let registered = Set(model.files.map { ($0 as NSString).lastPathComponent })
            guard names.isSubset(of: registered) else { return false }
            return Self.holdsSameBytes(request, model: model, root: root, requireByteProof: true)
        }
    }

    func publish(_ request: DownloadPublishRequest) throws {
        _ = try store.publishDownloaded(
            files: request.files,
            displayName: request.displayName,
            repoId: request.repoId,
            revision: request.revision,
            metadata: request.metadata,
            checksum: request.checksum,
            downloadJobID: request.jobID
        )
    }

    /// Compares the staged bytes with the files the registry points at. Size is
    /// cheap and catches most revisions; a published SHA-256 makes it exact.
    private static func holdsSameBytes(
        _ request: DownloadPublishRequest,
        model: LocalModel,
        root: URL,
        requireByteProof: Bool
    ) -> Bool {
        var files: [String: URL] = [:]
        for url in model.fileURLs(in: root) {
            files[url.lastPathComponent] = url
        }
        for staged in request.files {
            guard let registered = files[staged.fileName],
                  FileManager.default.fileExists(atPath: registered.path) else { return false }
            let storedSize = AtomicFileOps.fileSize(registered)
            if !FileManager.default.fileExists(atPath: staged.stagedURL.path) {
                // The durable registry already names this exact job; successful
                // publication removes its staged files before the final journal
                // write. That crash window must not trigger a fresh download.
                guard !requireByteProof, storedSize > 0 else { return false }
                continue
            }
            guard storedSize == AtomicFileOps.fileSize(staged.stagedURL) else { return false }
            guard requireByteProof else { continue }
            if let digest = request.digests[staged.fileName] {
                guard AtomicFileOps.sha256Hex(of: registered)?
                    .caseInsensitiveCompare(digest) == .orderedSame else { return false }
            } else {
                // Without an upstream digest, compare the bytes themselves: the
                // size alone cannot tell two revisions apart.
                guard let expected = AtomicFileOps.sha256Hex(of: staged.stagedURL),
                      let actual = AtomicFileOps.sha256Hex(of: registered),
                      expected.caseInsensitiveCompare(actual) == .orderedSame else { return false }
            }
        }
        return true
    }
}

/// One download job: one model, one or more files.
private struct DownloadJob {
    let id: UUID
    let repoId: String
    var revision: String?
    /// True once publishing started. A crash here is finished on the next
    /// launch from the staged files instead of downloading them again.
    var publishing = false
}

/// Durable sidecar written next to a `.part` file, so a resume cannot splice
/// two revisions together and a completed-but-crashed download is recoverable.
private struct PartSidecar: Codable {
    var repoId: String
    var rfilename: String
    var downloadURL: String
    var validator: String?
    var expectedSHA256: String?
    var expectedSize: UInt64
    var updatedAt: Date
}

/// What survives a quit or a crash: jobs, items and the bytes they already own.
///
/// Deliberately no credentials: the Hugging Face token is passed in per start
/// and resume call and never reaches the disk.
private struct DownloadJournal: Codable {
    var version: Int
    var jobs: [DownloadJournalJob]
}

private struct DownloadJournalJob: Codable {
    var id: UUID
    var repoId: String
    var revision: String?
    var publishing: Bool
    var updatedAt: Date
    var files: [DownloadJournalFile]
}

private struct DownloadJournalFile: Codable {
    var id: UUID
    var rfilename: String
    var fileName: String
    var downloadURL: String
    var size: UInt64
    var sha256: String?
    var validator: String?
    var state: DownloadTaskState
    var downloadedBytes: UInt64
    var startedAt: Date
    var shardIndex: Int?
    var shardTotal: Int?
}

/// Background download manager with durable pause/resume, GGUF verification,
/// and disk space pre-checks.
@MainActor
final class LocalDownloadManager: NSObject, ObservableObject {
    static let shared = LocalDownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// Last durable-queue failure. Identity and state changes are refused
    /// rather than reported as saved while this is non-nil.
    @Published private(set) var journalError: String?

    private let roots: DownloadRoots
    private let publisher: DownloadPublishSink
    private let configuration: URLSessionConfiguration?

    private var jobs: [UUID: DownloadJob] = [:]
    /// Live credentials only. Never written to the journal or the sidecar.
    private var tokens: [UUID: String] = [:]
    private var activeTasks: [UUID: URLSessionDataTask] = [:]
    private var fileHandles: [UUID: FileHandle] = [:]
    /// Bumped whenever a task is abandoned, so a late delegate callback of the
    /// old task can neither write bytes nor change the state of the new one.
    private var epochs: [UUID: Int] = [:]
    private var restartAttempts: [UUID: Int] = [:]
    private var lastBytesSample: [UUID: (bytes: UInt64, time: Date)] = [:]
    private var lastJournalWrite = Date.distantPast
    private var session: URLSession?
    private var sessionDelegate: DownloadSessionDelegate?
    private var didRecover = false
    private var isShutDown = false

    // MARK: - Init

    /// `roots`, `publisher` and `configuration` exist for tests: production
    /// always uses the defaults, which read the live profile and the app proxy.
    init(
        roots: DownloadRoots? = nil,
        publisher: DownloadPublishSink? = nil,
        configuration: URLSessionConfiguration? = nil
    ) {
        self.roots = roots ?? DownloadRoots.live
        self.publisher = publisher ?? LocalModelPublishSink()
        self.configuration = configuration
        super.init()
        recoverPendingJobs()
    }

    // MARK: - Public API

    /// Downloads one file. Kept for callers that have a single GGUF; split sets
    /// go through `startDownload(repoId:files:)` so the whole model arrives.
    func startDownload(
        repoId: String,
        fileName: String,
        downloadURL: URL,
        expectedSize: UInt64,
        expectedSHA256: String? = nil,
        validator: String? = nil,
        token: String? = nil
    ) throws {
        let request = HFDownloadRequest(
            rfilename: fileName,
            downloadURL: downloadURL,
            size: expectedSize,
            sha256: expectedSHA256
        )
        try beginJob(
            repoId: repoId,
            files: [request],
            token: token,
            validatorHints: validator.map { [fileName: $0] } ?? [:]
        )
    }

    /// Starts one job for one model. A split model must be requested as a whole:
    /// the job verifies that parts `1...N` all arrived before anything is
    /// registered, so a single shard can never look like an installed model.
    func startDownload(repoId: String, files: [HFDownloadRequest], token: String? = nil) throws {
        try beginJob(repoId: repoId, files: files, token: token, validatorHints: [:])
    }

    func pauseDownload(id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              item.state == .downloading || item.state == .queued else { return }
        _ = bumpEpoch(id)
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        try? fileHandles[id]?.close()
        fileHandles.removeValue(forKey: id)
        lastBytesSample.removeValue(forKey: id)
        updateItem(id: id) {
            $0.state = .paused
            $0.speedBytesPerSec = 0
        }
        if !writeJournal() {
            // The task is already cancelled; do not claim a durable pause.
            updateItem(id: id) {
                $0.state = .failed
                $0.errorMessage = journalError
            }
        }
    }

    /// Resumes the paused/failed row in place: same job id, item ids, part files
    /// and sidecars, so the server is asked only for the missing bytes.
    func resumeDownload(id: UUID, token: String? = nil) {
        guard let item = items.first(where: { $0.id == id }),
              item.state == .paused || item.state == .failed || item.state == .queued else { return }
        guard let job = jobs[item.jobID] ?? rebuildJob(jobID: item.jobID) else { return }
        if let token, !token.isEmpty { tokens[job.id] = token }
        let jobItems = items.filter { $0.jobID == job.id }
        guard !jobItems.isEmpty else { return }

        if jobItems.allSatisfy({ $0.state == .completed }) {
            // Bytes are done; only publication can still be owed.
            publishIfReady(jobID: job.id)
            return
        }
        if jobItems.allSatisfy({ isCompleteOnDisk($0) }) {
            // Verification or publication was interrupted: re-verify the bytes
            // we have instead of asking for gigabytes again.
            for pending in jobItems where pending.state != .completed {
                finish(id: pending.id)
            }
            return
        }
        do {
            try resumeJob(jobID: job.id, token: token)
        } catch {
            // The row already carries the failure; resume is non-throwing for
            // the SwiftUI call site.
            journalError = error.localizedDescription
        }
    }

    /// Removes finished cards and any `.part` they still own.
    func clearFinished() {
        for item in items where item.isTerminal {
            removeStagedFiles(for: item, includeFinal: true)
        }
        items.removeAll { $0.isTerminal }
        for jobID in Array(jobs.keys) {
            discardJobIfUnused(jobID)
        }
        writeJournal()
        pruneEmptyJobDirectories()
    }

    func removeCompleted(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll(where: { $0.id == id })
        discardJobIfUnused(item.jobID)
        writeJournal()
        pruneEmptyJobDirectories()
    }

    func cancelDownload(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        _ = bumpEpoch(id)
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        try? fileHandles[id]?.close()
        fileHandles.removeValue(forKey: id)
        lastBytesSample.removeValue(forKey: id)
        removeStagedFiles(for: item, includeFinal: true)
        updateItem(id: id) {
            $0.state = .cancelled
            $0.speedBytesPerSec = 0
            $0.downloadedBytes = 0
        }
        // Other parts of the same job keep running; the directory goes once
        // nothing in it is live.
        if !items.contains(where: { $0.jobID == item.jobID && !$0.isTerminal }) {
            jobs.removeValue(forKey: item.jobID)
            tokens.removeValue(forKey: item.jobID)
            try? FileManager.default.removeItem(at: jobDirectory(item.jobID))
        }
        writeJournal()
        pruneEmptyJobDirectories()
    }

    /// Cancels every task and drops the session. Tests call this instead of
    /// relying on deallocation, because `URLSession` keeps its delegate alive.
    func shutdown() {
        writeJournal()
        isShutDown = true
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        for (_, handle) in fileHandles { try? handle.close() }
        fileHandles.removeAll()
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
    }

    // MARK: - Journal recovery

    /// Restores rows from the journal so a quit, a crash or a force-quit leaves
    /// the queue visible instead of silently dropping multi-gigabyte parts.
    ///
    /// A job whose bytes all arrived before the crash is verified and published
    /// here: that is the only step a crash can still be owed.
    func recoverPendingJobs() {
        guard !didRecover else { return }
        didRecover = true
        guard items.isEmpty, let journal = readJournal(), !journal.jobs.isEmpty else { return }

        var restored: [(jobID: UUID, items: [DownloadItem])] = []
        for entry in journal.jobs {
            var jobItems: [DownloadItem] = []
            for file in entry.files {
                guard AtomicFileOps.isSafeFileName(file.fileName),
                      let url = URL(string: file.downloadURL),
                      url.scheme != nil else { continue }

                var item = DownloadItem(
                    id: file.id,
                    jobID: entry.id,
                    repoId: entry.repoId,
                    rfilename: file.rfilename,
                    fileName: file.fileName,
                    downloadURL: url,
                    totalBytes: file.size,
                    downloadedBytes: 0,
                    speedBytesPerSec: 0,
                    state: .paused,
                    errorMessage: nil,
                    startedAt: file.startedAt,
                    expectedSHA256: file.sha256,
                    validator: file.validator,
                    shardIndex: file.shardIndex,
                    shardTotal: file.shardTotal
                )
                let staged = stagedURL(item)
                let size = AtomicFileOps.fileSize(staged)
                // A known total proves completeness. Without one the part may be
                // a prefix, so only the journal's own progress markers may claim
                // the model is whole.
                let completeBySize = size > 0 && file.size > 0 && size == file.size
                let completeWithoutSize = size > 0 && file.size == 0
                    && (file.state == .completed || file.state == .verifying || entry.publishing)
                    && Self.hasGGUFMagic(staged)
                let complete = completeBySize || completeWithoutSize
                item.downloadedBytes = size
                item.totalBytes = complete ? max(file.size, size) : file.size
                // A part that was verified before the crash stays completed even
                // if another shard of the set is still missing.
                item.state = (file.state == .completed && complete) ? .completed : .paused
                jobItems.append(item)
            }
            guard !jobItems.isEmpty else { continue }
            jobs[entry.id] = DownloadJob(
                id: entry.id,
                repoId: entry.repoId,
                revision: entry.revision,
                publishing: entry.publishing
            )
            items.append(contentsOf: jobItems)
            restored.append((entry.id, jobItems))
        }

        writeJournal()
        // A job whose bytes all arrived before the crash only owes verification
        // and publication. Nothing is downloaded here.
        for (jobID, jobItems) in restored {
            guard jobItems.allSatisfy({ hasWholeFile($0) || $0.state == .completed }) else { continue }
            let pending = jobItems.filter { $0.state != .completed }
            if pending.isEmpty {
                publishIfReady(jobID: jobID)
            } else {
                for item in pending { finish(id: item.id) }
            }
        }
    }

    /// True when the staged file holds the whole expected payload.
    private func hasWholeFile(_ item: DownloadItem) -> Bool {
        let size = AtomicFileOps.fileSize(stagedURL(item))
        guard size > 0 else { return false }
        return item.totalBytes > 0 && size == item.totalBytes
    }

    private func readJournal() -> DownloadJournal? {
        guard let data = try? Data(contentsOf: roots.journal) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DownloadJournal.self, from: data)
    }

    /// Writes the queue, throttled while bytes stream in. Never contains a token.
    /// Persists the queue. Returns `false` when the durable record is missing,
    /// so identity and state transitions can fail closed. Per-chunk progress is
    /// the only caller allowed to ignore the result.
    @discardableResult
    private func writeJournal(force: Bool = true) -> Bool {
        guard !isShutDown else { return false }
        if !force, Date().timeIntervalSince(lastJournalWrite) < 2 { return true }
        let journal = DownloadJournal(version: 1, jobs: snapshotJobs())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(journal) else {
            journalError = L("The download queue could not be saved. Nothing was started; free some space or fix file permissions and retry.")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: roots.downloads, withIntermediateDirectories: true)
            try data.write(to: roots.journal, options: .atomic)
            lastJournalWrite = Date()
            journalError = nil
            return true
        } catch {
            journalError = String(
                format: L("Could not save the download queue: %@"),
                error.localizedDescription
            )
            return false
        }
    }

    private func snapshotJobs() -> [DownloadJournalJob] {
        jobs.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { jobID in
            guard let job = jobs[jobID] else { return nil }
            let jobItems = items.filter { $0.jobID == jobID }
            guard !jobItems.isEmpty else { return nil }
            return DownloadJournalJob(
                id: job.id,
                repoId: job.repoId,
                revision: job.revision,
                publishing: job.publishing,
                updatedAt: Date(),
                files: jobItems.map { item in
                    DownloadJournalFile(
                        id: item.id,
                        rfilename: item.rfilename,
                        fileName: item.fileName,
                        downloadURL: item.downloadURL.absoluteString,
                        size: item.totalBytes,
                        sha256: item.expectedSHA256,
                        validator: item.validator,
                        state: item.state,
                        downloadedBytes: item.downloadedBytes,
                        startedAt: item.startedAt,
                        shardIndex: item.shardIndex,
                        shardTotal: item.shardTotal
                    )
                }
            )
        }
    }

    // MARK: - Setup

    private func beginJob(
        repoId: String,
        files: [HFDownloadRequest],
        token: String?,
        validatorHints: [String: String]
    ) throws {
        guard !files.isEmpty else { throw LocalStorageError.noGGUFFiles }
        let requests = try validate(files)

        if let running = jobs.values.first(where: { $0.repoId == repoId && matchesJob($0.id, requests) }) {
            let jobItems = items.filter { $0.jobID == running.id }
            if jobItems.contains(where: {
                $0.state == .downloading || $0.state == .queued || $0.state == .verifying
            }) {
                throw NSError(
                    domain: "MelonTools.LocalAI",
                    code: 103,
                    userInfo: [NSLocalizedDescriptionKey: L("This file is already downloading.")]
                )
            }
            if !jobItems.isEmpty {
                // The same set is paused or failed: reuse its job, item ids,
                // part files and sidecars instead of writing a second copy.
                if let token, !token.isEmpty { tokens[running.id] = token }
                try resumeJob(jobID: running.id, token: token)
                return
            }
        }

        // Drop finished cards for the same files so a retry does not stack.
        items.removeAll { item in
            item.repoId == repoId
            && requests.contains(where: { $0.rfilename == item.rfilename })
            && item.isTerminal
        }

        let jobID = UUID()
        let directory = jobDirectory(jobID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var prepared: [(item: DownloadItem, handle: FileHandle)] = []
        do {
            for request in requests {
                prepared.append(try prepareItem(
                    jobID: jobID,
                    repoId: repoId,
                    request: request,
                    validatorHint: validatorHints[request.rfilename],
                    reuse: nil
                ))
            }
        } catch {
            // Nothing is registered and nothing is left behind when any member
            // of the set cannot be opened.
            for entry in prepared {
                try? entry.handle.close()
                removeStagedFiles(for: entry.item, includeFinal: true)
            }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        jobs[jobID] = DownloadJob(id: jobID, repoId: repoId, revision: nil)
        if let token, !token.isEmpty { tokens[jobID] = token }
        items.append(contentsOf: prepared.map(\.item))

        // No request may start before this job has a durable identity. Otherwise
        // a crash loses the id and the bytes become an unrecoverable orphan.
        guard writeJournal() else {
            for entry in prepared {
                try? entry.handle.close()
                removeStagedFiles(for: entry.item, includeFinal: true)
            }
            try? FileManager.default.removeItem(at: directory)
            jobs.removeValue(forKey: jobID)
            tokens.removeValue(forKey: jobID)
            items.removeAll { $0.jobID == jobID }
            throw LocalStorageError.journalUnavailable
        }

        for entry in prepared {
            fileHandles[entry.item.id] = entry.handle
            startTransfer(for: entry.item, token: tokens[jobID], from: entry.item.downloadedBytes)
        }
    }

    private func validate(_ files: [HFDownloadRequest]) throws -> [HFDownloadRequest] {
        var sanitized: [HFDownloadRequest] = []
        var seen = Set<String>()
        for file in files {
            let name = AtomicFileOps.safeFileName(file.rfilename, fallback: "")
            guard AtomicFileOps.isSafeFileName(name) else {
                throw LocalStorageError.unsafeName(file.rfilename)
            }
            guard !seen.contains(name) else {
                throw LocalStorageError.destinationConflict(name)
            }
            seen.insert(name)
            sanitized.append(file)
        }

        let shards = sanitized.compactMap { LocalModelStore.shardInfo(for: $0.rfilename) }
        if !shards.isEmpty {
            guard shards.count == sanitized.count else {
                throw LocalStorageError.incompleteSplit(missing: [])
            }
            let totals = Set(shards.map { $0.total })
            guard totals.count == 1, let total = totals.first else {
                throw LocalStorageError.inconsistentSplit
            }
            let indices = Set(shards.map { $0.index })
            let missing = (1...total).filter { !indices.contains($0) }
            guard missing.isEmpty else { throw LocalStorageError.incompleteSplit(missing: missing) }
        }
        return sanitized.sorted {
            (LocalModelStore.shardInfo(for: $0.rfilename)?.index ?? 0)
                < (LocalModelStore.shardInfo(for: $1.rfilename)?.index ?? 0)
        }
    }

    /// Opens (or reopens) the part file of one item and records the resume
    /// decision in the sidecar. `reuse` keeps the item identity on a resume.
    private func prepareItem(
        jobID: UUID,
        repoId: String,
        request: HFDownloadRequest,
        validatorHint: String?,
        reuse: DownloadItem?
    ) throws -> (item: DownloadItem, handle: FileHandle) {
        let fileName = AtomicFileOps.safeFileName(request.rfilename)
        guard AtomicFileOps.isSafeFileName(fileName) else {
            throw LocalStorageError.unsafeName(request.rfilename)
        }
        let shard = LocalModelStore.shardInfo(for: request.rfilename)
        var item = DownloadItem(
            id: reuse?.id ?? UUID(),
            jobID: jobID,
            repoId: repoId,
            rfilename: request.rfilename,
            fileName: fileName,
            downloadURL: request.downloadURL,
            totalBytes: request.size,
            downloadedBytes: 0,
            speedBytesPerSec: 0,
            state: .downloading,
            errorMessage: nil,
            startedAt: reuse?.startedAt ?? Date(),
            expectedSHA256: request.sha256,
            validator: reuse?.validator ?? validatorHint,
            shardIndex: shard?.index,
            shardTotal: shard?.total
        )

        let part = partURL(item)
        let sidecar = loadSidecar(sidecarURL(item))
        var validator = Self.strongValidator(sidecar?.validator) ?? Self.strongValidator(item.validator)

        // Resume only when the recorded identity matches this request exactly:
        // same URL, same digest expectation, same size. Otherwise the bytes on
        // disk may belong to a revision we cannot prove.
        let identityMatches = sidecar.map { recorded in
            recorded.downloadURL == request.downloadURL.absoluteString
                && recorded.rfilename == request.rfilename
                && recorded.expectedSHA256 == request.sha256
                && (recorded.expectedSize == 0 || request.size == 0 || recorded.expectedSize == request.size)
        } ?? (reuse != nil)

        var existingBytes: UInt64 = 0
        if identityMatches, validator != nil, FileManager.default.fileExists(atPath: part.path) {
            existingBytes = AtomicFileOps.fileSize(part)
            if request.size > 0, existingBytes > request.size { existingBytes = 0 }
        }
        if existingBytes == 0 {
            // Without matching durable metadata the partial file cannot be
            // trusted: it may belong to another revision with the same size.
            AtomicFileOps.removeIfExists(part)
            AtomicFileOps.removeIfExists(sidecarURL(item))
            validator = nil
        }

        item.validator = validator
        item.downloadedBytes = existingBytes
        item.totalBytes = request.size > 0 ? max(request.size, existingBytes) : 0

        // Only a growing file needs room. An unknown total has nothing to
        // reserve against, and a complete part needs no extra space at all.
        if item.totalBytes > existingBytes {
            try ensureSpace(remaining: item.totalBytes - existingBytes)
        }

        let handle: FileHandle
        do {
            if !FileManager.default.fileExists(atPath: part.path) {
                guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                    throw LocalStorageError.copyFailed(fileName)
                }
            }
            guard let opened = try? FileHandle(forWritingTo: part) else {
                throw LocalStorageError.copyFailed(fileName)
            }
            try opened.truncate(atOffset: existingBytes)
            _ = opened.seekToEndOfFile()
            handle = opened
        } catch {
            AtomicFileOps.removeIfExists(part)
            throw error
        }

        saveSidecar(
            PartSidecar(
                repoId: repoId,
                rfilename: request.rfilename,
                downloadURL: request.downloadURL.absoluteString,
                validator: validator,
                expectedSHA256: request.sha256,
                expectedSize: request.size,
                updatedAt: Date()
            ),
            to: sidecarURL(item)
        )
        return (item, handle)
    }

    /// Disk check that looks at the remaining bytes, not the whole file: a
    /// 7.5 GB part of an 8 GB model needs 0.5 GB, not 10 GB.
    private func ensureSpace(remaining: UInt64) throws {
        guard remaining > 0 else { return }
        let reserve = max(512 * 1024 * 1024, remaining / 20)
        let (freeDownloads, _) = LocalHardwareService.getDiskSpace(for: roots.downloads)
        guard freeDownloads >= remaining + reserve else {
            throw LocalStorageError.notEnoughSpace(
                required: remaining + reserve,
                free: freeDownloads
            )
        }
        if roots.storageUsable, !AtomicFileOps.sameVolume(roots.downloads, roots.models) {
            let (freeModels, _) = LocalHardwareService.getDiskSpace(for: roots.models)
            guard freeModels >= remaining else {
                throw LocalStorageError.notEnoughSpace(required: remaining, free: freeModels)
            }
        }
    }

    // MARK: - Paths

    private func jobDirectory(_ jobID: UUID) -> URL {
        roots.downloads.appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    private func partURL(_ item: DownloadItem) -> URL {
        jobDirectory(item.jobID)
            .appendingPathComponent(item.fileName)
            .appendingPathExtension("part")
    }

    private func finalURL(_ item: DownloadItem) -> URL {
        jobDirectory(item.jobID).appendingPathComponent(item.fileName)
    }

    private func sidecarURL(_ item: DownloadItem) -> URL {
        jobDirectory(item.jobID).appendingPathComponent(item.fileName + ".part.json")
    }

    /// The staged file a finished item currently lives in. Publishing promotes
    /// `.part` to the final name; a retry after a crash may find either.
    private func stagedURL(_ item: DownloadItem) -> URL {
        let final = finalURL(item)
        if FileManager.default.fileExists(atPath: final.path) { return final }
        return partURL(item)
    }

    private func isCompleteOnDisk(_ item: DownloadItem) -> Bool {
        let size = AtomicFileOps.fileSize(stagedURL(item))
        guard size > 0 else { return false }
        if item.state == .completed { return true }
        return item.totalBytes > 0 && size == item.totalBytes
    }

    private func loadSidecar(_ url: URL) -> PartSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PartSidecar.self, from: data)
    }

    private func saveSidecar(_ sidecar: PartSidecar, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sidecar) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func updateItem(id: UUID, mutate: (inout DownloadItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
    }

    private func replaceItem(_ item: DownloadItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.append(item)
        }
    }

    private func removeStagedFiles(for item: DownloadItem, includeFinal: Bool) {
        AtomicFileOps.removeIfExists(partURL(item))
        AtomicFileOps.removeIfExists(sidecarURL(item))
        if includeFinal { AtomicFileOps.removeIfExists(finalURL(item)) }
    }

    private func matchesJob(_ jobID: UUID, _ requests: [HFDownloadRequest]) -> Bool {
        let names = items.filter { $0.jobID == jobID }.map(\.rfilename).sorted()
        guard !names.isEmpty else { return false }
        return names == requests.map(\.rfilename).sorted()
    }

    private func rebuildJob(jobID: UUID) -> DownloadJob? {
        guard let first = items.first(where: { $0.jobID == jobID }) else { return nil }
        let job = DownloadJob(id: jobID, repoId: first.repoId, revision: nil)
        jobs[jobID] = job
        return job
    }

    /// Removes a job record and its directory once no row of it is left.
    private func discardJobIfUnused(_ jobID: UUID) {
        guard !items.contains(where: { $0.jobID == jobID }) else { return }
        jobs.removeValue(forKey: jobID)
        tokens.removeValue(forKey: jobID)
        try? FileManager.default.removeItem(at: jobDirectory(jobID))
        for id in Array(epochs.keys) where !items.contains(where: { $0.id == id }) {
            epochs.removeValue(forKey: id)
            restartAttempts.removeValue(forKey: id)
        }
    }

    private func pruneEmptyJobDirectories() {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: roots.downloads, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: entry.path)) ?? []
            let hasRow = items.contains { $0.jobID.uuidString == entry.lastPathComponent }
            let hasPendingPublish = jobs.values.contains { $0.id.uuidString == entry.lastPathComponent }
            if contents.isEmpty, !hasRow, !hasPendingPublish {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    // MARK: - Transfer

    private func activeSession() -> URLSession {
        if let session { return session }
        let config = configuration ?? NetworkProxy.externalConfiguration()
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600 * 12
        let delegate = DownloadSessionDelegate()
        delegate.owner = self
        sessionDelegate = delegate
        let created = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session = created
        return created
    }

    private func resumeJob(jobID: UUID, token: String?) throws {
        guard let job = jobs[jobID] ?? rebuildJob(jobID: jobID) else { return }
        if let token, !token.isEmpty { tokens[jobID] = token }
        let jobToken = tokens[jobID]

        // Prepare every member first, but start no request until the resumed
        // state (ids, offsets and validators) is durable.
        var preparedItems: [DownloadItem] = []
        for item in items.filter({ $0.jobID == jobID }) {
            guard item.state != .completed, item.state != .cancelled else { continue }
            do {
                let prepared = try prepareItem(
                    jobID: jobID,
                    repoId: job.repoId,
                    request: HFDownloadRequest(
                        rfilename: item.rfilename,
                        downloadURL: item.downloadURL,
                        size: item.totalBytes,
                        sha256: item.expectedSHA256
                    ),
                    validatorHint: item.validator,
                    reuse: item
                )
                fileHandles[prepared.item.id] = prepared.handle
                replaceItem(prepared.item)
                restartAttempts[item.id] = 0
                preparedItems.append(prepared.item)
            } catch {
                closeHandles(jobID: jobID)
                failJob(jobID: jobID, message: error.localizedDescription)
                writeJournal()
                throw error
            }
        }

        guard writeJournal() else {
            closeHandles(jobID: jobID)
            let message = journalError ?? L("The download queue could not be saved. Nothing was started; free some space or fix file permissions and retry.")
            for index in items.indices where items[index].jobID == jobID {
                items[index].state = .failed
                items[index].errorMessage = message
                items[index].speedBytesPerSec = 0
            }
            throw LocalStorageError.journalUnavailable
        }

        for item in preparedItems {
            startTransfer(for: item, token: jobToken, from: item.downloadedBytes)
        }
    }

    private func closeHandles(jobID: UUID) {
        for item in items where item.jobID == jobID {
            try? fileHandles[item.id]?.close()
            fileHandles.removeValue(forKey: item.id)
            activeTasks[item.id]?.cancel()
            activeTasks.removeValue(forKey: item.id)
        }
    }

    private func startTransfer(for item: DownloadItem, token: String?, from offset: UInt64) {
        let epoch = bumpEpoch(item.id)
        var request = URLRequest(url: item.downloadURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // A byte range only joins when the body is not content-encoded.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if offset > 0, let validator = Self.strongValidator(item.validator) {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            // `If-Range` makes the server send the whole body when the resource
            // changed, instead of a slice of a different revision.
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        let task = activeSession().dataTask(with: request)
        task.taskDescription = "\(item.id.uuidString)#\(epoch)"
        activeTasks[item.id] = task
        lastBytesSample[item.id] = (offset, Date())
        task.resume()
    }

    @discardableResult
    private func bumpEpoch(_ id: UUID) -> Int {
        let next = (epochs[id] ?? 0) + 1
        epochs[id] = next
        return next
    }

    private func isCurrentTask(id: UUID, epoch: Int) -> Bool {
        epochs[id] == epoch && activeTasks[id] != nil
    }

    // MARK: - Delegate handling

    /// Applies the HTTP response metadata to the item and decides whether the
    /// body may be written.
    ///
    /// - `200 OK` means the server ignored our `Range` header, so the body
    ///   starts at byte zero. The partial file is truncated first.
    /// - `206 Partial Content` reports the real total in `Content-Range` and its
    ///   start must equal what we already have, otherwise the parts do not join.
    /// - `416` with a total equal to our offset means the part is already whole.
    fileprivate func handleResponse(
        id: UUID,
        epoch: Int,
        status: Int?,
        contentRange: String?,
        expectedLength: Int64,
        validator: String?
    ) -> URLSession.ResponseDisposition {
        guard !isShutDown, isCurrentTask(id: id, epoch: epoch) else { return .cancel }
        guard let item = items.first(where: { $0.id == id }), item.state == .downloading else {
            return .cancel
        }
        let strong = Self.strongValidator(validator)

        if status == 416 {
            // The server says the range is unsatisfiable: the part is usually
            // already complete (crash between the last byte and finalisation).
            if let total = Self.totalBytes(fromContentRange: contentRange),
               total > 0, total == item.downloadedBytes {
                updateItem(id: id) { $0.totalBytes = total }
                finish(id: id)
            } else {
                restartFromZero(id: id)
            }
            return .cancel
        }

        if status == 206, let contentRange,
           let start = Self.startByte(fromContentRange: contentRange),
           start != item.downloadedBytes {
            // Server resumed from a different offset than ours: the halves do
            // not join, so the response is dropped and the file restarts.
            restartFromZero(id: id)
            return .cancel
        }

        if status == 206, let recorded = Self.strongValidator(item.validator),
           let strong, recorded != strong {
            // The server ignored `If-Range` and answered from another revision.
            restartFromZero(id: id)
            return .cancel
        }

        if status == 200 {
            if item.downloadedBytes > 0 { truncate(id: id, to: 0) }
            if let strong { recordValidator(id: id, strong) }
        } else if status == 206, item.validator == nil, let strong {
            recordValidator(id: id, strong)
        }

        let fromRange = Self.totalBytes(fromContentRange: contentRange)
        let fromLength: UInt64? = status == 206
            ? nil
            : (expectedLength > 0 ? UInt64(expectedLength) : nil)
        if let total = fromRange ?? fromLength, total > 0 {
            updateItem(id: id) { item in
                if item.totalBytes != total { item.totalBytes = total }
            }
        }
        writeJournal(force: false)
        return .allow
    }

    fileprivate func handleDataReceived(id: UUID, epoch: Int, data: Data) {
        guard !isShutDown, isCurrentTask(id: id, epoch: epoch) else { return }
        guard let item = items.first(where: { $0.id == id }), item.state == .downloading else { return }
        guard let handle = fileHandles[id] else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failItem(id: id, message: L("Could not write the downloaded data to disk."))
            return
        }

        let now = Date()
        updateItem(id: id) { item in
            item.downloadedBytes += UInt64(data.count)
            guard let sample = lastBytesSample[id] else { return }
            let interval = now.timeIntervalSince(sample.time)
            guard interval >= 0.5 else { return }
            let diff = item.downloadedBytes > sample.bytes ? item.downloadedBytes - sample.bytes : 0
            item.speedBytesPerSec = UInt64(Double(diff) / interval)
            lastBytesSample[id] = (item.downloadedBytes, now)
        }
        writeJournal(force: false)
    }

    fileprivate func handleTaskCompleted(id: UUID, epoch: Int, error: Error?) {
        guard !isShutDown, isCurrentTask(id: id, epoch: epoch) else { return }
        try? fileHandles[id]?.close()
        fileHandles.removeValue(forKey: id)
        activeTasks.removeValue(forKey: id)
        lastBytesSample.removeValue(forKey: id)

        guard let item = items.first(where: { $0.id == id }) else { return }

        if let error {
            // A cancelled task is a pause/cancel/restart we already handled.
            if (error as NSError).code == NSURLErrorCancelled { return }
            // Never overwrite a deliberate pause/cancel with a network failure.
            guard item.state == .downloading || item.state == .verifying else { return }
            failItem(id: id, message: error.localizedDescription)
            return
        }

        // An unsatisfiable-range response already started verification; a
        // successful completion of that same task must not verify twice.
        guard item.state == .downloading else { return }
        finish(id: id)
    }

    private func truncate(id: UUID, to offset: UInt64) {
        try? fileHandles[id]?.truncate(atOffset: offset)
        try? fileHandles[id]?.seek(toOffset: offset)
        lastBytesSample[id] = (offset, Date())
        updateItem(id: id) { $0.downloadedBytes = offset }
    }

    private func recordValidator(id: UUID, _ value: String) {
        guard let item = items.first(where: { $0.id == id }), item.validator != value else { return }
        updateItem(id: id) { $0.validator = value }
        if var sidecar = loadSidecar(sidecarURL(item)) {
            sidecar.validator = value
            sidecar.updatedAt = Date()
            saveSidecar(sidecar, to: sidecarURL(item))
        }
        writeJournal()
    }

    /// Drops the response we are rejecting and asks for the file from byte zero.
    private func restartFromZero(id: UUID, message: String? = nil) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let attempts = (restartAttempts[id] ?? 0) + 1
        restartAttempts[id] = attempts

        // Bump the epoch first: the cancelled task's data and completion
        // callbacks must not touch the fresh file.
        _ = bumpEpoch(id)
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        try? fileHandles[id]?.close()
        fileHandles.removeValue(forKey: id)

        if attempts > 2 {
            failItem(id: id, message: message ?? L("The server sent a different range. Restarting the download."))
            return
        }

        AtomicFileOps.removeIfExists(partURL(item))
        guard FileManager.default.createFile(atPath: partURL(item).path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partURL(item)) else {
            failItem(id: id, message: L("Could not write the downloaded data to disk."))
            return
        }
        fileHandles[id] = handle
        if var sidecar = loadSidecar(sidecarURL(item)) {
            sidecar.validator = nil
            sidecar.updatedAt = Date()
            saveSidecar(sidecar, to: sidecarURL(item))
        }
        updateItem(id: id) {
            $0.downloadedBytes = 0
            $0.validator = nil
            $0.errorMessage = message ?? L("The server sent a different range. Restarting the download.")
        }
        writeJournal()
        guard let fresh = items.first(where: { $0.id == id }) else { return }
        startTransfer(for: fresh, token: tokens[fresh.jobID], from: 0)
    }

    // MARK: - Verification & Finalization

    /// Outcome of the off-main verification pass.
    private enum VerificationOutcome {
        case ok(UInt64)
        /// The bytes are structurally wrong (not GGUF, digest mismatch): the
        /// part must not be resumed, or every retry would fail identically.
        case corrupt(Error)
        /// A transient failure (I/O, size not yet consistent): keep the part so
        /// the user can resume instead of downloading gigabytes again.
        case failed(Error)
    }

    /// Verifies the finished file off the main thread, then hands the set to the
    /// registry once every file of the job is complete.
    private func finish(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? fileHandles[id]?.close()
        fileHandles.removeValue(forKey: id)
        updateItem(id: id) {
            $0.state = .verifying
            $0.speedBytesPerSec = 0
        }
        let url = stagedURL(item)
        let expectedSHA = item.expectedSHA256
        let expectedSize = item.totalBytes
        let jobID = item.jobID
        let epoch = epochs[id] ?? 0

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> VerificationOutcome in
                do {
                    let size = AtomicFileOps.fileSize(url)
                    guard size > 0 else {
                        throw NSError(
                            domain: "MelonTools.LocalAI", code: 107,
                            userInfo: [NSLocalizedDescriptionKey: L("Downloaded file is empty.")]
                        )
                    }
                    if expectedSize > 0, size != expectedSize {
                        throw NSError(
                            domain: "MelonTools.LocalAI", code: 104,
                            userInfo: [NSLocalizedDescriptionKey: String(
                                format: L("Incomplete download: %lld of %lld bytes."),
                                Int64(size), Int64(expectedSize)
                            )]
                        )
                    }
                    guard LocalDownloadManager.hasGGUFMagic(url) else {
                        return .corrupt(NSError(
                            domain: "MelonTools.LocalAI", code: 103,
                            userInfo: [NSLocalizedDescriptionKey: L("Invalid file: GGUF magic header mismatch.")]
                        ))
                    }
                    if let expectedSHA {
                        guard let actual = AtomicFileOps.sha256Hex(of: url) else {
                            throw NSError(
                                domain: "MelonTools.LocalAI", code: 105,
                                userInfo: [NSLocalizedDescriptionKey: L("Could not hash the downloaded file.")]
                            )
                        }
                        guard actual.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
                            return .corrupt(NSError(
                                domain: "MelonTools.LocalAI", code: 106,
                                userInfo: [NSLocalizedDescriptionKey: L("SHA-256 mismatch: the file is corrupted or was replaced upstream.")]
                            ))
                        }
                    }
                    return .ok(size)
                } catch {
                    return .failed(error)
                }
            }.value

            await MainActor.run {
                guard let self, !self.isShutDown else { return }
                // A cancel or pause during verification makes this pass stale.
                guard (self.epochs[id] ?? 0) == epoch,
                      self.items.first(where: { $0.id == id })?.state == .verifying else { return }
                switch result {
                case .ok:
                    self.markFileComplete(id: id, jobID: jobID)
                case .corrupt(let error):
                    // A corrupt file would poison every retry through the
                    // sidecar, so it is discarded on purpose.
                    if let item = self.items.first(where: { $0.id == id }) {
                        self.removeStagedFiles(for: item, includeFinal: true)
                    }
                    self.failJob(id: id, message: error.localizedDescription)
                case .failed(let error):
                    self.failJob(id: id, message: error.localizedDescription)
                }
            }
        }
    }

    private func markFileComplete(id: UUID, jobID: UUID) {
        guard jobs[jobID] != nil, items.contains(where: { $0.id == id }) else { return }
        updateItem(id: id) {
            $0.state = .completed
            $0.speedBytesPerSec = 0
            $0.errorMessage = nil
        }
        guard writeJournal() else {
            // Verified bytes alone are not a durable completion. Leave the row
            // retryable and visible instead of publishing from an unrecorded
            // state.
            updateItem(id: id) {
                $0.state = .failed
                $0.errorMessage = journalError
            }
            return
        }
        publishIfReady(jobID: jobID)
    }

    /// Publishes a job once every file verified. The journal records the intent
    /// before the registry call, so a crash here is retried on the next launch
    /// from the files that are already on disk.
    private func publishIfReady(jobID: UUID) {
        guard var job = jobs[jobID] else { return }
        let jobItems = items.filter { $0.jobID == jobID }
        guard !jobItems.isEmpty, jobItems.allSatisfy({ $0.state == .completed }) else { return }

        // `publishing` marks the journal before the registry call; a crash in
        // that window is retried on the next launch.
        job.publishing = true
        jobs[jobID] = job
        guard writeJournal() else {
            // Moving parts or calling the registry without a durable publishing
            // intent would create a model a crash cannot reconcile.
            failJob(
                jobID: jobID,
                message: journalError ?? L("The download queue could not be saved."),
                includeCompleted: true
            )
            return
        }

        var staged: [(stagedURL: URL, fileName: String)] = []
        for item in jobItems {
            let final = finalURL(item)
            let part = partURL(item)
            if !FileManager.default.fileExists(atPath: final.path),
               FileManager.default.fileExists(atPath: part.path) {
                try? FileManager.default.moveItem(at: part, to: final)
            }
            if FileManager.default.fileExists(atPath: final.path) {
                staged.append((final, item.fileName))
            }
        }
        guard staged.count == jobItems.count else {
            failJob(jobID: jobID, message: L("Could not collect the downloaded parts."))
            return
        }

        let first = jobItems[0]
        let isSplit = LocalModelStore.shardInfo(for: first.rfilename) != nil
        let displayName = isSplit
            ? (LocalModelStore.shardInfo(for: first.rfilename)?.base ?? first.rfilename)
            : first.rfilename.replacingOccurrences(of: ".gguf", with: "", options: [.caseInsensitive])
        let metadata = try? GgufMetadataReader.read(from: staged[0].stagedURL)
        let checksum = jobItems.count == 1 ? first.expectedSHA256 : nil
        var digests: [String: String] = [:]
        for item in jobItems {
            if let digest = item.expectedSHA256 { digests[item.fileName] = digest }
        }
        let request = DownloadPublishRequest(
            jobID: jobID,
            files: staged,
            displayName: displayName,
            repoId: job.repoId,
            revision: job.revision,
            metadata: metadata,
            checksum: checksum,
            digests: digests
        )

        // Only *this* job's bytes may be adopted: the registry entry carries the
        // job id, and the fallback compares registered bytes with staged ones.
        if publisher.hasPublished(request) {
            finishPublished(jobID: jobID)
            return
        }

        do {
            try publisher.publish(request)
            finishPublished(jobID: jobID)
        } catch {
            // The bytes stay staged and the journal keeps `publishing`, so the
            // next launch retries publication instead of downloading again.
            failJob(jobID: jobID, message: error.localizedDescription, includeCompleted: true)
            writeJournal()
        }
    }

    private func finishPublished(jobID: UUID) {
        jobs.removeValue(forKey: jobID)
        tokens.removeValue(forKey: jobID)
        try? FileManager.default.removeItem(at: jobDirectory(jobID))
        for index in items.indices where items[index].jobID == jobID {
            items[index].state = .completed
            items[index].speedBytesPerSec = 0
            items[index].errorMessage = nil
        }
        writeJournal()
        pruneEmptyJobDirectories()
    }

    private func failItem(id: UUID, message: String) {
        _ = bumpEpoch(id)
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        try? fileHandles[id]?.close()
        fileHandles.removeValue(forKey: id)
        updateItem(id: id) {
            $0.state = .failed
            $0.errorMessage = message
            $0.speedBytesPerSec = 0
        }
        writeJournal()
    }

    private func failJob(id: UUID, message: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        failJob(jobID: item.jobID, message: message)
    }

    private func failJob(jobID: UUID, message: String, includeCompleted: Bool = false) {
        for index in items.indices where items[index].jobID == jobID {
            if items[index].state == .completed, !includeCompleted { continue }
            items[index].state = .failed
            items[index].errorMessage = message
            items[index].speedBytesPerSec = 0
        }
        writeJournal()
    }

    // MARK: - Formatting helpers

    /// Streaming SHA-256 of a file, so a multi-gigabyte model never has to be
    /// loaded into memory at once.
    nonisolated static func sha256Hex(of url: URL) -> String? {
        AtomicFileOps.sha256Hex(of: url)
    }

    /// `If-Range` only accepts a strong validator. A weak ETag (`W/"..."`)
    /// cannot prove that the bytes on disk belong to the same revision, so it
    /// is treated as "unknown" and the download starts clean.
    nonisolated static func strongValidator(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("W/") else { return nil }
        return trimmed
    }

    nonisolated static func hasGGUFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 4)
        return header.count == 4
            && header[0] == 0x47 && header[1] == 0x47
            && header[2] == 0x55 && header[3] == 0x46
    }

    /// Reads the total size out of a `Content-Range` header, e.g.
    /// `bytes 0-1023/4096` or `bytes */4096`. Returns nil when the total is `*`.
    nonisolated static func totalBytes(fromContentRange header: String?) -> UInt64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let tail = header[header.index(after: slash)...]
            .trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty, tail != "*" else { return nil }
        return UInt64(tail)
    }

    /// Start offset of a `bytes <start>-<end>/<total>` range.
    nonisolated static func startByte(fromContentRange header: String?) -> UInt64? {
        guard let header else { return nil }
        let pattern = #"bytes\s+(\d+)-"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: header, range: NSRange(header.startIndex..., in: header)
              ),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return UInt64(header[range])
    }
}

/// Routes `URLSession` callbacks to the owning manager. The manager is held
/// weakly: a session keeps its delegate alive until it is invalidated, and a
/// strong back-reference would leak every test instance.
private final class DownloadSessionDelegate: NSObject, URLSessionDataDelegate {
    weak var owner: LocalDownloadManager?

    private static func route(_ task: URLSessionTask) -> (id: UUID, epoch: Int)? {
        guard let text = task.taskDescription else { return nil }
        let parts = text.split(separator: "#", maxSplits: 1)
        guard parts.count == 2,
              let id = UUID(uuidString: String(parts[0])),
              let epoch = Int(parts[1]) else { return nil }
        return (id, epoch)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let route = Self.route(dataTask) else {
            completionHandler(.allow)
            return
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode
        let contentRange = http?.value(forHTTPHeaderField: "Content-Range")
        let length = response.expectedContentLength
        let validator = http?.value(forHTTPHeaderField: "ETag")
            ?? http?.value(forHTTPHeaderField: "Last-Modified")
        // The body is only released after the item absorbed the headers, so the
        // first chunk cannot outrun a pending truncate.
        Task { @MainActor [weak self] in
            var disposition = URLSession.ResponseDisposition.cancel
            if let owner = self?.owner {
                disposition = owner.handleResponse(
                    id: route.id,
                    epoch: route.epoch,
                    status: status,
                    contentRange: contentRange,
                    expectedLength: length,
                    validator: validator
                )
            }
            completionHandler(disposition)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let route = Self.route(dataTask) else { return }
        Task { @MainActor [weak self] in
            self?.owner?.handleDataReceived(id: route.id, epoch: route.epoch, data: data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let route = Self.route(task) else { return }
        Task { @MainActor [weak self] in
            self?.owner?.handleTaskCompleted(id: route.id, epoch: route.epoch, error: error)
        }
    }
}

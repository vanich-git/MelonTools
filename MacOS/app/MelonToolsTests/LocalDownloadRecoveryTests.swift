import XCTest
@testable import MelonTools

/// Regression coverage for CORE-09: durable queue, real `Range`/`ETag` resume,
/// stale-cancellation guards and crash recovery.
///
/// Everything runs on an injected temporary root and an in-process
/// `URLProtocol` transport: no network, no real models folder, no real journal.
@MainActor
final class LocalDownloadRecoveryTests: XCTestCase {
    private var root: URL!
    private var downloads: URL!
    private var models: URL!
    private var managers: [LocalDownloadManager] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-download-\(UUID().uuidString)", isDirectory: true)
        downloads = root.appendingPathComponent("downloads", isDirectory: true)
        models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        StubDownloadProtocol.server = nil
    }

    override func tearDown() async throws {
        for manager in managers { manager.shutdown() }
        managers.removeAll()
        StubDownloadProtocol.server = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Durable job identity

    func testRestartReusesJobItemPartAndSidecar() async throws {
        let body = payload(bytes: 16_384)
        let publisher = RecordingPublisher()
        let server = StubDownloadServer(StubConfig(payload: body, stall: [0: 4_096]))
        StubDownloadProtocol.server = server

        let first = makeManager(publisher: publisher)
        try first.startDownload(
            repoId: "org/model",
            files: [request(payload: body)],
            token: "hf_secret_token"
        )
        let started = try XCTUnwrap(first.items.first)
        try await waitUntil("first chunk") { first.items.first?.downloadedBytes == 4_096 }

        // The journal must describe the job without ever storing the token.
        let journalText = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertFalse(journalText.contains("hf_secret_token"))
        XCTAssertFalse(journalText.lowercased().contains("bearer"))
        XCTAssertFalse(journalText.lowercased().contains("authorization"))
        XCTAssertTrue(journalText.contains(started.id.uuidString))
        XCTAssertTrue(journalText.contains(started.jobID.uuidString))

        XCTAssertEqual(AtomicFileOps.fileSize(partURL(for: started)), 4_096)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL(for: started).path))

        // Quit or crash: the in-memory queue dies, the files stay.
        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        let recovered = try XCTUnwrap(second.items.first)
        XCTAssertEqual(recovered.id, started.id)
        XCTAssertEqual(recovered.jobID, started.jobID)
        XCTAssertEqual(recovered.state, .paused)
        XCTAssertEqual(recovered.downloadedBytes, 4_096)
        XCTAssertEqual(recovered.totalBytes, UInt64(body.count))

        second.resumeDownload(id: recovered.id, token: "hf_secret_token")
        try await waitUntil("completion") { second.items.first?.state == .completed }

        let requests = server.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].rangeStart, 4_096)
        XCTAssertEqual(requests[1].ifRange, "\"rev-1\"")
        XCTAssertEqual(requests[1].authorization, "Bearer hf_secret_token")

        XCTAssertEqual(publisher.publications.count, 1)
        XCTAssertEqual(publisher.publications.first?.names, [started.fileName])
        XCTAssertEqual(publisher.publications.first?.contents[started.fileName], body)
        XCTAssertEqual(second.items.first?.downloadedBytes, UInt64(body.count))
        XCTAssertNil(second.items.first?.errorMessage)
    }

    func testSecondDownloadTapResumesThePausedJobInsteadOfStartingOver() async throws {
        let body = payload(bytes: 12_288)
        let publisher = RecordingPublisher()
        let server = StubDownloadServer(StubConfig(payload: body, stall: [0: 4_096]))
        StubDownloadProtocol.server = server

        let first = makeManager(publisher: publisher)
        try first.startDownload(repoId: "org/model", files: [request(payload: body)])
        let started = try XCTUnwrap(first.items.first)
        try await waitUntil("first chunk") { first.items.first?.downloadedBytes == 4_096 }

        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        XCTAssertEqual(second.items.count, 1)
        // A second "Download" click on the same set must resume the paused job,
        // not create a second job with its own part file.
        try second.startDownload(repoId: "org/model", files: [request(payload: body)])
        try await waitUntil("completion") { second.items.first?.state == .completed }

        XCTAssertEqual(second.items.count, 1)
        XCTAssertEqual(second.items.first?.id, started.id)
        XCTAssertEqual(second.items.first?.jobID, started.jobID)
        let requests = server.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].rangeStart, 4_096)
        XCTAssertEqual(publisher.publications.count, 1)
        XCTAssertEqual(publisher.publications.first?.contents[started.fileName], body)
        XCTAssertEqual(jobDirectories().count, 0, "the staged job folder is removed after publishing")
    }

    // MARK: - Range / ETag

    func testServerIgnoringRangeTruncatesInsteadOfSplicing() async throws {
        let body = payload(bytes: 12_288)
        let publisher = RecordingPublisher()
        let server = StubDownloadServer(
            StubConfig(payload: body, honorsRange: false, stall: [0: 4_096])
        )
        StubDownloadProtocol.server = server

        let first = makeManager(publisher: publisher)
        try first.startDownload(repoId: "org/model", files: [request(payload: body)])
        try await waitUntil("first chunk") { first.items.first?.downloadedBytes == 4_096 }

        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        let recovered = try XCTUnwrap(second.items.first)
        XCTAssertEqual(recovered.downloadedBytes, 4_096)

        second.resumeDownload(id: recovered.id)
        try await waitUntil("completion") { second.items.first?.state == .completed }

        XCTAssertEqual(second.items.first?.downloadedBytes, UInt64(body.count))
        XCTAssertEqual(
            publisher.publications.first?.contents[recovered.fileName],
            body,
            "a 200 after a ranged request must restart the file, not append the whole body"
        )
        XCTAssertEqual(server.recordedRequests().count, 2)
    }

    func testChangedETagRestartsFromZero() async throws {
        let original = payload(bytes: 12_288)
        let replacement = payload(bytes: 12_288, seed: 77)
        let publisher = RecordingPublisher()
        let server = StubDownloadServer(StubConfig(
            payload: original,
            stall: [0: 4_096],
            changedETag: "\"rev-2\"",
            changedPayload: replacement
        ))
        StubDownloadProtocol.server = server

        let first = makeManager(publisher: publisher)
        try first.startDownload(repoId: "org/model", files: [request(payload: original)])
        try await waitUntil("first chunk") { first.items.first?.downloadedBytes == 4_096 }

        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        let recovered = try XCTUnwrap(second.items.first)
        second.resumeDownload(id: recovered.id)
        try await waitUntil("completion") { second.items.first?.state == .completed }

        let requests = server.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].rangeStart, 4_096)
        XCTAssertEqual(requests[1].ifRange, "\"rev-1\"")
        // The second response carried another revision, so the bytes on disk
        // were dropped and the file restarted from byte zero.
        XCTAssertNil(requests[2].rangeStart)
        XCTAssertEqual(second.items.first?.validator, "\"rev-2\"")
        XCTAssertEqual(publisher.publications.first?.contents[recovered.fileName], replacement)
    }

    func testUnsatisfiableRangeFinishesAnUnknownSizeDownload() async throws {
        let body = payload(bytes: 8_192)
        let publisher = RecordingPublisher()
        StubDownloadProtocol.server = StubDownloadServer(
            StubConfig(payload: body, stall: [0: body.count], omitContentLength: true)
        )

        let first = makeManager(publisher: publisher)
        // The catalog did not report a size: only the server can say how big the
        // file is, so the client cannot know the part is already complete.
        try first.startDownload(
            repoId: "org/model",
            files: [HFDownloadRequest(
                rfilename: "model.gguf",
                downloadURL: url("model.gguf"),
                size: 0,
                sha256: nil
            )]
        )
        try await waitUntil("all bytes") {
            first.items.first?.downloadedBytes == UInt64(body.count)
        }
        XCTAssertEqual(first.items.first?.totalBytes, 0, "no size was ever reported")

        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        let recovered = try XCTUnwrap(second.items.first)
        XCTAssertEqual(recovered.downloadedBytes, UInt64(body.count))
        XCTAssertEqual(recovered.state, .paused)

        let secondServer = StubDownloadServer(StubConfig(
            payload: body,
            notSatisfiableAt: 0
        ))
        StubDownloadProtocol.server = secondServer

        second.resumeDownload(id: recovered.id)
        try await waitUntil("completion") { second.items.first?.state == .completed }

        let requests = secondServer.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let resumed = try XCTUnwrap(requests.first)
        XCTAssertEqual(resumed.rangeStart, UInt64(body.count))
        XCTAssertEqual(publisher.publications.count, 1)
        XCTAssertEqual(publisher.publications.first?.contents[recovered.fileName], body)
    }

    // MARK: - Stale cancellation

    func testPauseThenImmediateResumeIgnoresCancelledTaskCallbacks() async throws {
        let body = payload(bytes: 16_384)
        let publisher = RecordingPublisher()
        let server = StubDownloadServer(StubConfig(payload: body, stall: [0: 4_096]))
        StubDownloadProtocol.server = server

        let manager = makeManager(publisher: publisher)
        try manager.startDownload(repoId: "org/model", files: [request(payload: body)])
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("first chunk") { manager.items.first?.downloadedBytes == 4_096 }

        // The cancelled task's delegate callbacks race with the fresh task.
        manager.pauseDownload(id: item.id)
        manager.resumeDownload(id: item.id, token: "hf_secret_token")
        XCTAssertEqual(manager.items.first?.state, .downloading)

        try await waitUntil("completion") { manager.items.first?.state == .completed }

        XCTAssertEqual(manager.items.first?.downloadedBytes, UInt64(body.count))
        XCTAssertNil(manager.items.first?.errorMessage)
        XCTAssertEqual(
            publisher.publications.first?.contents[item.fileName],
            body,
            "bytes of the cancelled task must not be written into the new file"
        )
        XCTAssertEqual(server.recordedRequests().count, 2)
    }

    // MARK: - Crash recovery

    func testCrashAfterLastBytePublishesOnNextLaunch() async throws {
        let body = payload(bytes: 8_192)
        let publisher = RecordingPublisher()
        // Every byte arrives, but the process dies before `didComplete`.
        StubDownloadProtocol.server = StubDownloadServer(
            StubConfig(payload: body, stall: [0: body.count])
        )

        let first = makeManager(publisher: publisher)
        try first.startDownload(repoId: "org/model", files: [request(payload: body)])
        let started = try XCTUnwrap(first.items.first)
        try await waitUntil("all bytes") {
            first.items.first?.downloadedBytes == UInt64(body.count)
        }
        XCTAssertEqual(first.items.first?.state, .downloading)
        XCTAssertEqual(AtomicFileOps.fileSize(partURL(for: started)), UInt64(body.count))

        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        try await waitUntil("published after restart") {
            second.items.first?.state == .completed
        }
        XCTAssertEqual(publisher.publications.count, 1)
        XCTAssertEqual(publisher.publications.first?.names, [started.fileName])
        XCTAssertEqual(publisher.publications.first?.contents[started.fileName], body)
        XCTAssertEqual(journalJobs().count, 0)
        XCTAssertEqual(jobDirectories().count, 0)
    }

    func testFailedPublishIsRetriedFromStagedFilesWithoutDownloadingAgain() async throws {
        let body = payload(bytes: 8_192)
        let publisher = RecordingPublisher()
        publisher.failuresRemaining = 1
        let server = StubDownloadServer(StubConfig(payload: body))
        StubDownloadProtocol.server = server

        let first = makeManager(publisher: publisher)
        try first.startDownload(repoId: "org/model", files: [request(payload: body)])
        let started = try XCTUnwrap(first.items.first)
        try await waitUntil("publish failure") { first.items.first?.state == .failed }
        XCTAssertEqual(AtomicFileOps.fileSize(finalURL(for: started)), UInt64(body.count))

        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        try await waitUntil("retried publish") { second.items.first?.state == .completed }

        XCTAssertEqual(publisher.publications.count, 1)
        XCTAssertEqual(publisher.publishCalls, 2)
        XCTAssertEqual(server.recordedRequests().count, 1, "the bytes were already on disk")
        XCTAssertEqual(second.items.first?.downloadedBytes, UInt64(body.count))
    }

    func testAlreadyPublishedJobIsCleanedUpWithoutRepublishing() async throws {
        let body = payload(bytes: 4_096)
        let firstPublisher = RecordingPublisher()
        firstPublisher.failuresRemaining = 1
        StubDownloadProtocol.server = StubDownloadServer(StubConfig(payload: body))

        let first = makeManager(publisher: firstPublisher)
        try first.startDownload(repoId: "org/model", files: [request(payload: body)])
        let started = try XCTUnwrap(first.items.first)
        try await waitUntil("publish failure") { first.items.first?.state == .failed }

        first.shutdown()
        forget(first)

        // The registry write did land before the crash; only the journal lagged.
        let secondPublisher = RecordingPublisher()
        secondPublisher.prefill(repoId: "org/model", names: [started.fileName])
        let second = makeManager(publisher: secondPublisher)
        try await waitUntil("recovered") { second.items.first?.state == .completed }

        XCTAssertEqual(secondPublisher.publishCalls, 0)
        XCTAssertEqual(journalJobs().count, 0)
        XCTAssertEqual(jobDirectories().count, 0)
    }

    func testSplitJobKeepsCompletedPartAndResumesOnlyTheMissingOne() async throws {
        let firstShard = payload(bytes: 8_192, seed: 3)
        let secondShard = payload(bytes: 12_288, seed: 9)
        let names = ["model-00001-of-00002.gguf", "model-00002-of-00002.gguf"]
        let publisher = RecordingPublisher()
        let server = StubDownloadServer(StubConfig(
            payload: secondShard,
            stallByPath: [names[1]: 4_096],
            payloadByPath: [names[0]: firstShard, names[1]: secondShard]
        ))
        StubDownloadProtocol.server = server

        let first = makeManager(publisher: publisher)
        try first.startDownload(repoId: "org/model", files: [
            HFDownloadRequest(
                rfilename: names[0],
                downloadURL: url(names[0]),
                size: UInt64(firstShard.count),
                sha256: nil
            ),
            HFDownloadRequest(
                rfilename: names[1],
                downloadURL: url(names[1]),
                size: UInt64(secondShard.count),
                sha256: nil
            ),
        ])
        try await waitUntil("first shard done and second started") {
            first.items.count == 2
                && first.items[0].state == .completed
                && first.items[1].downloadedBytes == 4_096
        }
        let shardOne = first.items[0]
        let shardTwo = first.items[1]
        first.pauseDownload(id: shardTwo.id)

        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        XCTAssertEqual(second.items.count, 2)
        guard second.items.count == 2 else { return }
        XCTAssertEqual(second.items[0].id, shardOne.id)
        XCTAssertEqual(second.items[0].state, .completed)
        XCTAssertEqual(second.items[1].id, shardTwo.id)
        XCTAssertEqual(second.items[1].state, .paused)
        XCTAssertEqual(second.items[1].downloadedBytes, 4_096)

        // Resuming one row resumes the whole set: the finished shard is not
        // requested again.
        second.resumeDownload(id: shardTwo.id)
        try await waitUntil("both shards") {
            second.items.allSatisfy { $0.state == .completed }
        }

        XCTAssertEqual(publisher.publications.count, 1)
        let publication = try XCTUnwrap(publisher.publications.first)
        XCTAssertEqual(Set(publication.names), Set(names))
        XCTAssertEqual(publication.contents[names[0]], firstShard)
        XCTAssertEqual(publication.contents[names[1]], secondShard)
        let ranges = server.recordedRequests().compactMap(\.rangeStart)
        XCTAssertEqual(ranges, [4_096], "only the missing shard is resumed")
    }

    // MARK: - Cancel and maintenance

    func testCancelRemovesPartSidecarAndJournalEntry() async throws {
        let body = payload(bytes: 8_192)
        let publisher = RecordingPublisher()
        StubDownloadProtocol.server = StubDownloadServer(
            StubConfig(payload: body, stall: [0: 4_096])
        )

        let manager = makeManager(publisher: publisher)
        try manager.startDownload(repoId: "org/model", files: [request(payload: body)])
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("first chunk") { manager.items.first?.downloadedBytes == 4_096 }

        manager.cancelDownload(id: item.id)

        XCTAssertEqual(manager.items.first?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL(for: item).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL(for: item).path))
        XCTAssertEqual(journalJobs().count, 0)
        XCTAssertEqual(jobDirectories().count, 0)
        XCTAssertEqual(publisher.publications.count, 0)
    }

    func testRecoveryIsIdempotentAndClearFinishedDropsTheJournal() async throws {
        let body = payload(bytes: 8_192)
        let publisher = RecordingPublisher()
        StubDownloadProtocol.server = StubDownloadServer(
            StubConfig(payload: body, stall: [0: 4_096])
        )

        let first = makeManager(publisher: publisher)
        try first.startDownload(repoId: "org/model", files: [request(payload: body)])
        try await waitUntil("first chunk") { first.items.first?.downloadedBytes == 4_096 }
        first.shutdown()
        forget(first)

        let second = makeManager(publisher: publisher)
        XCTAssertEqual(second.items.count, 1)
        second.recoverPendingJobs()
        XCTAssertEqual(second.items.count, 1, "recovery must not duplicate rows")

        let item = try XCTUnwrap(second.items.first)
        second.cancelDownload(id: item.id)
        second.clearFinished()

        XCTAssertTrue(second.items.isEmpty)
        XCTAssertEqual(journalJobs().count, 0)
        XCTAssertEqual(jobDirectories().count, 0)
    }

    func testWeakValidatorIsNotUsedForIfRange() {
        XCTAssertNil(LocalDownloadManager.strongValidator("W/\"weak\""))
        XCTAssertNil(LocalDownloadManager.strongValidator("   "))
        XCTAssertNil(LocalDownloadManager.strongValidator(nil))
        XCTAssertEqual(LocalDownloadManager.strongValidator(" \"strong\" "), "\"strong\"")
        XCTAssertEqual(
            LocalDownloadManager.strongValidator("Wed, 21 Oct 2015 07:28:00 GMT"),
            "Wed, 21 Oct 2015 07:28:00 GMT"
        )
    }

    /// A same-named model of another revision must not be mistaken for this
    /// job's publication: adopting it would delete freshly downloaded bytes.
    func testPublisherComparesRegisteredBytesNotJustNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-publish-\(UUID().uuidString)", isDirectory: true)
        let store = LocalModelStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let registeredBytes = payload(bytes: 4_096, seed: 1)
        let otherRevision = payload(bytes: 4_096, seed: 9)
        let stagedA = staging.appendingPathComponent("registered.gguf")
        try registeredBytes.write(to: stagedA)
        _ = try store.publishDownloaded(
            files: [(stagedURL: stagedA, fileName: "model.gguf")],
            displayName: "Model",
            repoId: "org/model",
            revision: nil,
            metadata: nil,
            checksum: nil,
            downloadJobID: UUID()
        )

        let stagedB = staging.appendingPathComponent("other.gguf")
        try otherRevision.write(to: stagedB)
        let otherRequest = DownloadPublishRequest(
            jobID: UUID(),
            files: [(stagedB, "model.gguf")],
            displayName: "Model",
            repoId: "org/model",
            revision: nil,
            metadata: nil,
            checksum: nil,
            digests: [:]
        )
        let sink = LocalModelPublishSink(store: store)
        XCTAssertFalse(
            sink.hasPublished(otherRequest),
            "same file name and size but different bytes is another revision"
        )

        let stagedC = staging.appendingPathComponent("same.gguf")
        try registeredBytes.write(to: stagedC)
        let sameRequest = DownloadPublishRequest(
            jobID: UUID(),
            files: [(stagedC, "model.gguf")],
            displayName: "Model",
            repoId: "org/model",
            revision: nil,
            metadata: nil,
            checksum: nil,
            digests: [:]
        )
        XCTAssertTrue(sink.hasPublished(sameRequest))

        // A registered file that is not on the volume proves nothing.
        let registered = try XCTUnwrap(
            store.models.first { $0.repoId == "org/model" }?
                .fileURLs(in: store.modelsDirectory).first
        )
        try FileManager.default.removeItem(at: registered)
        XCTAssertFalse(sink.hasPublished(sameRequest))
    }

    /// The registry entry carries the job identity, so a crash after the write
    /// is recognised exactly; a missing file still invalidates it.
    func testPublishRecordsJobIdentityAndChecksRealFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-publish-id-\(UUID().uuidString)", isDirectory: true)
        // Injected directory: no shared store, UserDefaults or real profile.
        let store = LocalModelStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bytes = payload(bytes: 4_096, seed: 5)
        let staged = staging.appendingPathComponent("model.gguf")
        try bytes.write(to: staged)
        let jobID = UUID()

        let model = try store.publishDownloaded(
            files: [(stagedURL: staged, fileName: "model.gguf")],
            displayName: "Identified",
            repoId: "org/identified",
            revision: nil,
            metadata: nil,
            checksum: nil,
            downloadJobID: jobID
        )
        XCTAssertEqual(model.downloadJobID, jobID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.path),
            "the staged copy goes away only after the registry commit"
        )

        let copy = staging.appendingPathComponent("again.gguf")
        try bytes.write(to: copy)
        let sameJob = DownloadPublishRequest(
            jobID: jobID,
            files: [(copy, "model.gguf")],
            displayName: "Identified",
            repoId: "org/identified",
            revision: nil,
            metadata: nil,
            checksum: nil,
            digests: [:]
        )
        let sink = LocalModelPublishSink(store: store)
        XCTAssertTrue(sink.hasPublished(sameJob))

        let otherJob = DownloadPublishRequest(
            jobID: UUID(),
            files: [(copy, "model.gguf")],
            displayName: "Identified",
            repoId: "org/identified",
            revision: nil,
            metadata: nil,
            checksum: nil,
            digests: [:]
        )
        XCTAssertTrue(sink.hasPublished(otherJob), "identical bytes under another job are the same model")

        // A registered entry that points at a missing file proves nothing.
        let registered = try XCTUnwrap(
            store.models.first { $0.downloadJobID == jobID }?
                .fileURLs(in: store.modelsDirectory).first
        )
        try FileManager.default.removeItem(at: registered)
        XCTAssertFalse(sink.hasPublished(sameJob))
    }

    /// A half-copied namespace is replaced when it names the same job, and a
    /// foreign namespace still refuses to be overwritten.
    func testPublishReplacesItsOwnOrphanNamespaceOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-publish-orphan-\(UUID().uuidString)", isDirectory: true)
        let store = LocalModelStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bytes = payload(bytes: 2_048, seed: 11)
        let staged = staging.appendingPathComponent("model.gguf")
        try bytes.write(to: staged)

        let jobID = UUID()
        let identifier = store.uniqueModelID(base: "Orphan", quantization: nil, repoId: "org/orphan")
        let namespace = store.modelsDirectory.appendingPathComponent(
            LocalModelStore.namespaceName(for: identifier),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        try Data("half copied".utf8).write(to: namespace.appendingPathComponent("model.gguf"))
        try Data(#"{"version":1,"jobID":"\#(jobID.uuidString)"}"#.utf8)
            .write(to: namespace.appendingPathComponent(".download-job.json"))

        let model = try store.publishDownloaded(
            files: [(stagedURL: staged, fileName: "model.gguf")],
            displayName: "Orphan",
            repoId: "org/orphan",
            revision: nil,
            metadata: nil,
            checksum: nil,
            downloadJobID: jobID
        )
        XCTAssertEqual(model.downloadJobID, jobID)
        XCTAssertEqual(
            try Data(contentsOf: namespace.appendingPathComponent("model.gguf")),
            bytes,
            "the orphan copy was replaced by the real bytes"
        )

        // Another namespace without our marker is not ours to delete.
        let foreign = store.modelsDirectory.appendingPathComponent(
            LocalModelStore.namespaceName(for: store.uniqueModelID(base: "Foreign", quantization: nil, repoId: "org/foreign")),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("someone else".utf8).write(to: foreign.appendingPathComponent("model.gguf"))
        let staged2 = staging.appendingPathComponent("model2.gguf")
        try bytes.write(to: staged2)
        XCTAssertThrowsError(try store.publishDownloaded(
            files: [(stagedURL: staged2, fileName: "model.gguf")],
            displayName: "Foreign",
            repoId: "org/foreign",
            revision: nil,
            metadata: nil,
            checksum: nil,
            downloadJobID: UUID()
        )) { error in
            guard case LocalStorageError.destinationConflict = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged2.path))
    }

    func testPublishSinkUsesItsInjectedStoreForTheCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("melon-sink-\(UUID())")
        let store = LocalModelStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("model.part")
        try payload(bytes: 2_048, seed: 7).write(to: staged)
        let jobID = UUID()
        let request = DownloadPublishRequest(
            jobID: jobID, files: [(stagedURL: staged, fileName: "model.gguf")],
            displayName: "Injected", repoId: "test/injected", revision: nil,
            metadata: nil, checksum: nil, digests: [:]
        )
        let sink = LocalModelPublishSink(store: store)
        try sink.publish(request)
        XCTAssertEqual(store.models.count, 1)
        XCTAssertEqual(store.models.first?.downloadJobID, jobID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.registryFileURL.path))
        XCTAssertTrue(sink.hasPublished(request))
    }

    /// A registry that cannot be written must not consume the staged bytes.
    func testPublishRollsBackWhenRegistryCannotBeWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-publish-rollback-\(UUID().uuidString)", isDirectory: true)
        let store = LocalModelStore(directory: root)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bytes = payload(bytes: 2_048, seed: 13)
        let staged = staging.appendingPathComponent("model.gguf")
        try bytes.write(to: staged)
        // The namespace must be creatable; only the registry write at the root
        // is denied below.
        try FileManager.default.createDirectory(
            at: store.modelsDirectory,
            withIntermediateDirectories: true
        )

        // The registry write is the commit point: without it nothing may be
        // deleted, and the models folder must not keep a half-published copy.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: root.path
        )

        XCTAssertThrowsError(try store.publishDownloaded(
            files: [(stagedURL: staged, fileName: "model.gguf")],
            displayName: "Rollback",
            repoId: "org/rollback",
            revision: nil,
            metadata: nil,
            checksum: nil,
            downloadJobID: UUID()
        )) { error in
            guard case LocalStorageError.registryUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertNil(store.models.first { $0.repoId == "org/rollback" })
        let namespace = store.modelsDirectory.appendingPathComponent(
            LocalModelStore.namespaceName(for: store.uniqueModelID(base: "Rollback", quantization: nil, repoId: "org/rollback")),
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.path))
    }

    /// A storage switch after launch must be visible on the next check: the
    /// roots resolve every access instead of freezing one folder at init.
    func testRootsFollowAStorageSwitchWithoutCaching() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-roots-\(UUID().uuidString)", isDirectory: true)
        let other = root.appendingPathComponent("other-models", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var active = root
        var usable = true
        let roots = DownloadRoots(
            downloads: root.appendingPathComponent("downloads"),
            journal: root.appendingPathComponent("downloads.json"),
            models: { active },
            storageUsable: { usable }
        )
        XCTAssertEqual(roots.models.standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(roots.storageUsable)

        active = other
        usable = false
        XCTAssertEqual(roots.models.standardizedFileURL, other.standardizedFileURL)
        XCTAssertFalse(roots.storageUsable)
    }

    // MARK: - Durable queue failures

    func testEnqueueFailsClosedWhenJournalCannotBeWritten() async throws {
        let locked = root.appendingPathComponent("locked-journal", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let journal = locked.appendingPathComponent("downloads.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: locked.path
            )
        }

        let body = payload(bytes: 4_096)
        let server = StubDownloadServer(StubConfig(payload: body))
        StubDownloadProtocol.server = server
        let publisher = RecordingPublisher()
        let manager = makeManager(publisher: publisher, journal: journal)

        XCTAssertThrowsError(try manager.startDownload(
            repoId: "org/model",
            fileName: "model.gguf",
            downloadURL: url("model.gguf"),
            expectedSize: UInt64(body.count)
        )) { error in
            guard case LocalStorageError.journalUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertNotNil(manager.journalError)
        XCTAssertEqual(server.recordedRequests().count, 0, "no request before a durable identity")
        XCTAssertTrue(jobDirectories().isEmpty, "a refused enqueue leaves no part directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testResumeFailsClosedWhenJournalBecomesUnwritable() async throws {
        let locked = root.appendingPathComponent("locked-resume", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let journal = locked.appendingPathComponent("downloads.json")

        let body = payload(bytes: 12_288)
        let server = StubDownloadServer(StubConfig(payload: body, stall: [0: 4_096]))
        StubDownloadProtocol.server = server
        let publisher = RecordingPublisher()
        let manager = makeManager(publisher: publisher, journal: journal)
        try manager.startDownload(
            repoId: "org/model",
            fileName: "model.gguf",
            downloadURL: url("model.gguf"),
            expectedSize: UInt64(body.count)
        )
        let started = try XCTUnwrap(manager.items.first)
        manager.pauseDownload(id: started.id)
        XCTAssertEqual(manager.items.first?.state, .paused)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: locked.path
            )
        }
        let before = server.recordedRequests().count
        manager.resumeDownload(id: started.id)

        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertEqual(manager.items.first?.id, started.id)
        XCTAssertNotNil(manager.items.first?.errorMessage)
        XCTAssertEqual(server.recordedRequests().count, before, "resume must not request bytes without a durable record")
    }

    // MARK: - Fixtures

    private var journalURL: URL { downloads.appendingPathComponent("downloads.json") }

    private func payload(bytes: Int, seed: UInt8 = 1) -> Data {
        var data = Data("GGUF".utf8)
        data.append(contentsOf: (4..<max(4, bytes)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
        return data
    }

    private func url(_ name: String) -> URL {
        // The stub protocol keys stalls by the last path component, so the URL
        // only has to be stable and recognisable.
        URL(string: "http://stub.melontools/org/model/\(name)")!
    }

    private func request(payload: Data, name: String = "model.gguf") -> HFDownloadRequest {
        HFDownloadRequest(
            rfilename: name,
            downloadURL: url(name),
            size: UInt64(payload.count),
            sha256: nil
        )
    }

    private func makeManager(
        publisher: RecordingPublisher,
        journal: URL? = nil
    ) -> LocalDownloadManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDownloadProtocol.self]
        let manager = LocalDownloadManager(
            roots: DownloadRoots(
                downloads: downloads,
                models: models,
                storageUsable: true,
                journal: journal
            ),
            publisher: publisher,
            configuration: configuration
        )
        managers.append(manager)
        return manager
    }

    private func forget(_ manager: LocalDownloadManager) {
        managers.removeAll { $0 === manager }
    }

    private func partURL(for item: DownloadItem) -> URL {
        downloads.appendingPathComponent(item.jobID.uuidString, isDirectory: true)
            .appendingPathComponent(item.fileName)
            .appendingPathExtension("part")
    }

    private func finalURL(for item: DownloadItem) -> URL {
        downloads.appendingPathComponent(item.jobID.uuidString, isDirectory: true)
            .appendingPathComponent(item.fileName)
    }

    private func sidecarURL(for item: DownloadItem) -> URL {
        downloads.appendingPathComponent(item.jobID.uuidString, isDirectory: true)
            .appendingPathComponent(item.fileName + ".part.json")
    }

    /// UUID-named job folders only; the journal file is not a folder.
    private func jobDirectories() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
        return entries.filter { UUID(uuidString: $0) != nil }
    }

    private func journalJobs() -> [String] {
        guard let data = try? Data(contentsOf: journalURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = object["jobs"] as? [[String: Any]] else { return [] }
        return jobs.compactMap { $0["id"] as? String }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out waiting for \(description)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Recording publisher

/// Stands in for `LocalModelStore`: records what would be registered and copies
/// the staged bytes so the manager may delete its own folder afterwards.
@MainActor
private final class RecordingPublisher: DownloadPublishSink {
    struct Publication {
        var repoId: String
        var displayName: String
        var names: [String]
        var contents: [String: Data]
        var checksum: String?
    }

    private(set) var publications: [Publication] = []
    private(set) var publishCalls = 0
    /// Number of registry writes that must fail before one succeeds.
    var failuresRemaining = 0
    private var published: [String: Data] = [:]

    func prefill(repoId: String, names: [String]) {
        for name in names { published["\(repoId)/\(name)"] = Data() }
    }

    func hasPublished(_ request: DownloadPublishRequest) -> Bool {
        guard !request.files.isEmpty else { return false }
        return request.files.allSatisfy {
            published["\(request.repoId)/\($0.fileName)"] != nil
        }
    }

    func publish(_ request: DownloadPublishRequest) throws {
        publishCalls += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NSError(
                domain: "MelonToolsTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "simulated registry failure"]
            )
        }
        var names: [String] = []
        var contents: [String: Data] = [:]
        for file in request.files {
            names.append(file.fileName)
            contents[file.fileName] = (try? Data(contentsOf: file.stagedURL)) ?? Data()
        }
        for name in names {
            published["\(request.repoId)/\(name)"] = contents[name]
        }
        publications.append(Publication(
            repoId: request.repoId,
            displayName: request.displayName,
            names: names,
            contents: contents,
            checksum: request.checksum
        ))
    }
}

// MARK: - Stub transport

private struct StubRequest {
    var url: URL
    var rangeStart: UInt64?
    var ifRange: String?
    var authorization: String?
    var index: Int
}

private struct StubResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    /// When set, only this many bytes are delivered and the connection is left
    /// open so the test can pause the task or pretend the process died.
    var stallAfter: Int?
}

private struct StubConfig {
    var payload: Data
    var etag: String = "\"rev-1\""
    var honorsRange = true
    /// Request index → bytes delivered before the connection is left open.
    var stall: [Int: Int] = [:]
    /// File name → bytes delivered before the connection is left open.
    var stallByPath: [String: Int] = [:]
    /// Omit `Content-Length`, so the client cannot learn the total size.
    var omitContentLength = false
    /// Request index answered with `416` and `Content-Range: bytes */<size>`.
    var notSatisfiableAt: Int?
    /// Different ETag/payload served from the second request on: the resource
    /// changed upstream between the pause and the resume.
    var changedETag: String?
    var changedPayload: Data?
    /// File name → bytes, so one server can host several shards.
    var payloadByPath: [String: Data] = [:]
}

/// Deterministic in-process HTTP server for `URLProtocol`: honours or ignores
/// `Range`, reports `Content-Range`, and can stop mid-body on request.
private final class StubDownloadServer {
    private let lock = NSLock()
    private let config: StubConfig
    private var requests: [StubRequest] = []
    private var consumedPathStalls: Set<String> = []

    init(_ config: StubConfig) {
        self.config = config
    }

    func recordedRequests() -> [StubRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func respond(to request: StubRequest) -> StubResponse {
        lock.lock()
        defer { lock.unlock() }

        var recorded = request
        recorded.index = requests.count
        requests.append(recorded)
        let index = recorded.index

        let start = recorded.rangeStart ?? 0
        let path = recorded.url.lastPathComponent
        let source = config.payloadByPath[path] ?? config.payload
        let payload = (index > 0 ? config.changedPayload : nil) ?? source
        let etag = (index > 0 ? config.changedETag : nil) ?? config.etag
        // A path stall applies once: the resumed request must be served.
        var stall = config.stall[index]
        if let pending = config.stallByPath[path], !consumedPathStalls.contains(path) {
            consumedPathStalls.insert(path)
            stall = pending
        }

        if config.notSatisfiableAt == index, start > 0 {
            return StubResponse(
                status: 416,
                headers: [
                    "Content-Range": "bytes */\(payload.count)",
                    "ETag": etag,
                    "Content-Length": "0",
                ],
                body: Data(),
                stallAfter: nil
            )
        }

        if start > 0, start < UInt64(payload.count), config.honorsRange {
            let slice = payload.subdata(in: Int(start)..<payload.count)
            return StubResponse(
                status: 206,
                headers: [
                    "Content-Range": "bytes \(start)-\(payload.count - 1)/\(payload.count)",
                    "ETag": etag,
                    "Content-Length": "\(slice.count)",
                ],
                body: slice,
                stallAfter: stall
            )
        }

        var headers = ["ETag": etag]
        if !config.omitContentLength {
            headers["Content-Length"] = "\(payload.count)"
        }
        return StubResponse(status: 200, headers: headers, body: payload, stallAfter: stall)
    }
}

/// Answers requests for `stub.melontools` from `StubDownloadServer`.
private final class StubDownloadProtocol: URLProtocol {
    static var server: StubDownloadServer?

    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.melontools"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = Self.server, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let stubRequest = StubRequest(
            url: url,
            rangeStart: Self.rangeStart(request.value(forHTTPHeaderField: "Range")),
            ifRange: request.value(forHTTPHeaderField: "If-Range"),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            index: -1
        )
        let response = server.respond(to: stubRequest)
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        let body = response.body
        let deliver = min(response.stallAfter ?? body.count, body.count)
        let chunk = body.prefix(deliver)
        let finishes = response.stallAfter == nil
        // Deliver after the response disposition, like a real connection, so a
        // truncating manager has applied its headers before the first byte.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.004) { [weak self] in
            guard let self, !self.isStopped() else { return }
            if deliver > 0 {
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            if finishes {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private static func rangeStart(_ header: String?) -> UInt64? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let tail = header.dropFirst("bytes=".count)
        guard let dash = tail.firstIndex(of: "-") else { return nil }
        return UInt64(tail[tail.startIndex..<dash])
    }
}

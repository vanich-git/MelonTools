import XCTest
@testable import MelonTools

/// End-to-end checks against the real `llama-server`. Opt-in: they load a
/// multi-gigabyte model into RAM, so they only run with
/// `MELON_LOCAL_ENGINE_E2E=1` (and `MELON_E2E_MODEL=/path/to/model.gguf`).
///
/// These cover what unit tests cannot: the router really reporting `loaded`
/// after `/models/load`, metrics answering with the model query, and Stop
/// leaving no stale `ready` state behind.
@MainActor
final class LocalAIEngineIntegrationTests: XCTestCase {

    private var overrideRoot: URL?

    override func tearDown() async throws {
        if let root = overrideRoot {
            // Stop while the temp vault is still installed: the real gateway is
            // running and must not receive the test model on its way out.
            LocalInferenceService.shared.suspendPublicationForTesting()
            await LocalInferenceService.shared.stop()
            // stop() starts an async publication task. Wait for it before
            // restoring live hooks, otherwise it can still be scheduled after
            // resetPublicationForTesting() and write the real gateway config.
            await LocalInferenceService.shared.waitForPublication()
            // Clear the test rows while the temp vault is still installed.
            // Reloading after clearing the override would read (and possibly
            // repair/save) the user's real registry and schedule a metadata
            // repair against it. No singleton is touched on a skipped run.
            LocalModelStore.shared.replaceModelsForTesting([])
            LocalPaths.baseOverride = nil
            LocalInferenceService.shared.customBinaryPath = nil
            LocalInferenceService.shared.resetPublicationForTesting()
            try? FileManager.default.removeItem(at: root)
            overrideRoot = nil
        }
        try await super.tearDown()
    }

    /// xcodebuild does not forward arbitrary environment variables to a macOS
    /// test host, so the switch is either the environment variable or a sentinel
    /// file. Both are opt-in and absent on a normal run.
    private static let sentinel = "/tmp/melon-local-ai-e2e"

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MELON_LOCAL_ENGINE_E2E"] == "1"
            || FileManager.default.fileExists(atPath: Self.sentinel)
    }

    private func requireEnvironment() throws -> (binary: URL, model: URL) {
        try XCTSkipUnless(
            isEnabled,
            "set MELON_LOCAL_ENGINE_E2E=1 or create /tmp/melon-local-ai-e2e to run the engine checks"
        )
        let modelPath = ProcessInfo.processInfo.environment["MELON_E2E_MODEL"]
            ?? (NSHomeDirectory() + "/Library/Application Support/MelonTools/models/Qwen3.5-2B-BF16.gguf")
        let model = URL(fileURLWithPath: modelPath)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: model.path),
            "no model at \(model.path)"
        )
        // `currentDirectoryPath` is `/` inside the test host, so resolve the
        // engine relative to this source file instead.
        let binary = ProcessInfo.processInfo.environment["MELON_LLAMA_SERVER"].map {
            URL(fileURLWithPath: $0)
        } ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MelonToolsTests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Resources/runtime/llama-server")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: binary.path),
            "no llama-server at \(binary.path)"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-engine-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Nothing above this line touched a shared service, so the override is
        // installed before the store (and the engine) can read any real path.
        LocalPaths.baseOverride = root
        overrideRoot = root
        LocalModelStore.shared.reloadFromDiskForTesting()
        LocalInferenceService.shared.customBinaryPath = binary.path
        // These tests own a real llama-server, not the user's gateway. Any
        // publication they trigger must stay in the temp vault: no config
        // write, no catalog refresh, no monitor. The dedicated real-gateway
        // test installs its own hooks pointed at its temp config.
        LocalInferenceService.shared.publicationHooks = Self.isolatedPublicationHooks
        print("E2E isolated vault: \(root.path)")
        return (binary, model)
    }

    private static var isolatedPublicationHooks: LocalInferenceService.PublicationHooks {
        LocalInferenceService.PublicationHooks(
            writeConfig: {},
            refreshCatalog: {},
            gatewayIsRunning: { false },
            servedModelIDs: { [] },
            readyAliases: { [] }
        )
    }

    private func linkedModel(_ url: URL) -> LocalModel {
        var settings = LocalModelSettings.defaultSettings(forContext: 2048)
        settings.contextLength = 2048
        settings.maxOutputTokens = 256
        settings.reasoningEnabled = false
        settings.gpuOffloadLayers = 99
        return LocalModel(
            id: "local/e2e",
            displayName: "E2E",
            provider: "Local AI",
            source: "custom",
            repoId: nil,
            revision: nil,
            files: [url.path],
            fileSize: AtomicFileOps.fileSize(url),
            quantization: "BF16",
            format: "GGUF",
            contextLength: 262_144,
            configuredContext: 2048,
            blockCount: 24,
            architecture: "qwen35",
            backend: .metal,
            gpuOffload: 99,
            threads: 4,
            runtimeStatus: .installed,
            capabilities: [.text],
            installedAt: Date(),
            updatedAt: Date(),
            lastUsedAt: nil,
            license: nil,
            checksum: nil,
            userSettings: settings
        )
    }

    /// M1: Start must wait for the *model*, not just for `/health`. The router
    /// answers health while every model is still `unloaded`.
    func testStartWaitsForModelAndReportsLoaded() async throws {
        let environment = try requireEnvironment()
        let model = linkedModel(environment.model)
        LocalModelStore.shared.addOrUpdateModel(model)

        try await LocalInferenceService.shared.loadModel(model)

        XCTAssertTrue(LocalInferenceService.shared.status.isRunning)
        XCTAssertEqual(LocalInferenceService.shared.currentModel?.id, model.id)
        XCTAssertEqual(LocalInferenceService.shared.routerStates[model.id], .loaded)
        let stored = try XCTUnwrap(LocalModelStore.shared.models.first { $0.id == model.id })
        XCTAssertEqual(stored.runtimeStatus, .ready)

        // The engine reports the context it really allocated (2048 here).
        XCTAssertEqual(stored.configuredContext, 2048)

        // R2: a ready model must reach the gateway contract. `effectiveSources`
        // is the single list both the catalog and `config.yaml` are built from.
        await LocalInferenceService.shared.waitForPublication()
        let sources = ModelSourcesStore.effectiveSources(
            base: [],
            localModels: LocalModelStore.shared.models,
            port: LocalInferenceService.shared.publishedPort,
            token: LocalInferenceService.shared.internalToken,
            slots: LocalInferenceService.parallelRequests
        )
        let local = try XCTUnwrap(sources.first { $0.kind == .localAI })
        XCTAssertEqual(local.id, "melon-local-ai")
        XCTAssertEqual(local.baseURL, "http://127.0.0.1:\(LocalInferenceService.shared.publishedPort)/v1")
        XCTAssertTrue(local.models.contains { $0.alias == model.id || $0.alias == "local/\(model.id)" })
        let yaml = ModelSourcesStore.gatewayYAML(sources: sources)
        XCTAssertTrue(yaml.contains("name: \"melon-local-ai\""), yaml)
        XCTAssertTrue(yaml.contains("alias: \"\(model.id)\""), yaml)
        XCTAssertTrue(yaml.contains("proxy-url: \"direct\""), yaml)

        // M5: the console pane has to receive real output, and the loopback API
        // key must never appear in it.
        var logs: [String] = []
        for _ in 0..<25 {
            logs = LocalInferenceService.shared.logLines
            if !logs.isEmpty { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertFalse(logs.isEmpty, "the engine produced no console output")
        let token = LocalInferenceService.shared.internalToken
        XCTAssertFalse(logs.contains { $0.contains(token) }, "the API key leaked into the log")

        // R2: Stop removes the source from the same contract; a stale ready row
        // or a lingering local source would keep advertising a dead endpoint.
        await LocalInferenceService.shared.stop()
        XCTAssertFalse(LocalInferenceService.shared.status.isRunning)
        // Build the contract from a pure empty base. Reading the real
        // `ModelSourcesStore.shared` here would load/migrate/save the user's
        // sources just to prove that this test's stopped engine is absent.
        let stoppedSources = ModelSourcesStore.effectiveSources(
            base: [],
            localModels: LocalModelStore.shared.models,
            port: LocalInferenceService.shared.publishedPort,
            token: LocalInferenceService.shared.internalToken,
            slots: LocalInferenceService.parallelRequests
        )
        XCTAssertFalse(
            stoppedSources.contains { $0.kind == .localAI },
            "a stopped engine must not stay in effectiveSources"
        )
    }

    /// M4: the metrics endpoint needs `?model=` and the app used to poll without
    /// it, which produced a permanent 400 and zeroes.
    func testMetricsAreReadableForTheLoadedModel() async throws {
        let environment = try requireEnvironment()
        let model = linkedModel(environment.model)
        LocalModelStore.shared.addOrUpdateModel(model)
        try await LocalInferenceService.shared.loadModel(model)

        var metrics: LocalInferenceService.InferenceMetrics?
        for _ in 0..<10 {
            if let snapshot = LocalInferenceService.shared.metrics {
                metrics = snapshot
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertNotNil(metrics, "metrics were never populated")
        XCTAssertNil(LocalInferenceService.shared.metricsError)

        let direct = await LocalInferenceService.fetchMetrics(
            port: LocalInferenceService.shared.port,
            token: LocalInferenceService.shared.internalToken,
            modelId: model.id
        )
        XCTAssertNotNil(direct.metrics)
        XCTAssertNil(direct.error)
    }

    /// M2: a Stop issued while a Start is still in flight must win, and must not
    /// leave a process, a `ready` row or gateway routes behind.
    func testStopDuringStartLeavesNothingRunning() async throws {
        let environment = try requireEnvironment()
        let model = linkedModel(environment.model)
        LocalModelStore.shared.addOrUpdateModel(model)

        let start = Task { try await LocalInferenceService.shared.loadModel(model) }
        try await Task.sleep(nanoseconds: 400_000_000)
        await LocalInferenceService.shared.stop()

        _ = try? await start.value
        XCTAssertFalse(LocalInferenceService.shared.status.isRunning)
        XCTAssertNil(LocalInferenceService.shared.currentModel)
        XCTAssertNil(LocalInferenceService.shared.routerStates[model.id])
        for stored in LocalModelStore.shared.models {
            XCTAssertNotEqual(stored.runtimeStatus, .ready, "stale ready state after stop")
        }

        // A fresh start after the aborted one must still work.
        try await LocalInferenceService.shared.loadModel(model)
        XCTAssertTrue(LocalInferenceService.shared.status.isRunning)
        XCTAssertEqual(LocalInferenceService.shared.routerStates[model.id], .loaded)
    }

    /// Deleting the loaded model has to stop the engine first: `unlink` does not
    /// release mapped pages, so the router keeps serving a deleted file.
    func testDeletionReleasesTheRunningModel() async throws {
        let environment = try requireEnvironment()
        let model = linkedModel(environment.model)
        LocalModelStore.shared.addOrUpdateModel(model)
        try await LocalInferenceService.shared.loadModel(model)

        await LocalInferenceService.shared.releaseModelFiles(model)
        XCTAssertFalse(LocalInferenceService.shared.status.isRunning)
        XCTAssertNil(LocalInferenceService.shared.routerStates[model.id])
    }

    /// Direct children of `pid`, so a crash test can clean up the model child
    /// process it deliberately orphans.
    private func childPIDs(of pid: Int32) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// M2/M9: a crashed engine must not leave `ready` rows or a stale running
    /// status behind. The router is killed for real, and only its own children
    /// are cleaned up afterwards.
    func testEngineCrashIsDetectedAndNormalizesState() async throws {
        let environment = try requireEnvironment()
        let model = linkedModel(environment.model)
        LocalModelStore.shared.addOrUpdateModel(model)
        try await LocalInferenceService.shared.loadModel(model)

        let pid = try XCTUnwrap(LocalInferenceService.shared.processIdentifier)
        let children = childPIDs(of: pid)
        XCTAssertFalse(children.isEmpty, "the router should have started a model child")
        kill(pid, SIGKILL)
        defer {
            for child in children { kill(child, SIGKILL) }
        }

        var failed = false
        for _ in 0..<40 {
            if case .failed = LocalInferenceService.shared.status {
                failed = true
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(failed, "a dead router was still reported as running")
        XCTAssertNil(LocalInferenceService.shared.processIdentifier)
        XCTAssertTrue(LocalInferenceService.shared.routerStates.isEmpty)
        XCTAssertFalse(LocalInferenceService.shared.status.isRunning)
        for stored in LocalModelStore.shared.models {
            XCTAssertNotEqual(stored.runtimeStatus, .ready, "stale ready state after a crash")
        }
    }

    /// M2: «Start A → Start B» must end with B loaded and A not advertised. Both
    /// entries point at the same file so the test costs one model in RAM.
    func testSwitchingBetweenModelsLeavesOnlyTheSecondLoaded() async throws {
        let environment = try requireEnvironment()
        let first = linkedModel(environment.model)
        var second = first
        second.id = "local/e2e-b"
        second.displayName = "E2E B"
        LocalModelStore.shared.addOrUpdateModel(first)
        LocalModelStore.shared.addOrUpdateModel(second)

        try await LocalInferenceService.shared.loadModel(first)
        XCTAssertEqual(LocalInferenceService.shared.routerStates[first.id], .loaded)

        try await LocalInferenceService.shared.loadModel(second)
        XCTAssertEqual(LocalInferenceService.shared.currentModel?.id, second.id)
        XCTAssertEqual(LocalInferenceService.shared.routerStates[second.id], .loaded)
        XCTAssertNotEqual(LocalInferenceService.shared.routerStates[first.id], .loaded)
        for stored in LocalModelStore.shared.models where stored.id == first.id {
            XCTAssertNotEqual(stored.runtimeStatus, .ready)
        }
    }

    // MARK: - Publication contract (no engine opt-in required)

    /// The exact YAML the app hands to the engine, normalised to placeholders.
    /// The tracked fixture makes the engine-facing contract reviewable without
    /// a live gateway; `/tmp` is the artifact the engine harness can consume.
    func testNativeGatewayYAMLMatchesTheTrackedFixture() throws {
        let alias = "__MODEL_ALIAS__"
        let model = SourceModel(
            id: "__MODEL_ID__",
            display: alias,
            contextLength: 4096,
            enabled: true,
            alias: alias
        )
        let source = ModelSource(
            id: "melon-local-ai",
            kind: .localAI,
            title: "Local AI",
            baseURL: "http://127.0.0.1:59999/v1",
            apiKey: "__LOCAL_TOKEN__",
            enabled: true,
            models: [model]
        )
        let yaml = ModelSourcesStore.gatewayYAML(sources: [source])
            .replacingOccurrences(of: "59999", with: "__LOCAL_PORT__")
            .trimmingCharacters(in: .newlines)

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/local-ai-gateway.yaml")
        let expected = try String(contentsOf: fixture, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        XCTAssertEqual(yaml, expected)

        let output = URL(fileURLWithPath: "/tmp/melon-local-ai-macos.yaml")
        try Data((yaml + "\n").utf8).write(to: output, options: .atomic)
        XCTAssertFalse(yaml.contains("59999"), "a real port leaked into the fixture")
    }

    /// A ready model must be published without any opt-in switch: the only
    /// filter in the loop is readiness, and verification happens after the
    /// gateway lists the alias.
    func testReadyModelIsPublishedWithoutOptIn() async throws {
        let service = LocalInferenceService.shared
        var writes = 0
        var catalogSyncs = 0
        var written = ""
        let alias = "local/ready"

        service.publicationHooks = .init(
            writeConfig: {
                writes += 1
                written = ModelSourcesStore.gatewayYAML(sources: [Self.localSource(alias: alias)])
            },
            refreshCatalog: { catalogSyncs += 1 },
            gatewayIsRunning: { true },
            servedModelIDs: { written.contains("alias: \"\(alias)\"") ? [alias] : [] },
            readyAliases: { [alias] }
        )

        service.publishLocalRoutes()
        await service.waitForPublication()

        XCTAssertNil(service.publicationError)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(catalogSyncs, 1)
        XCTAssertTrue(written.contains("name: \"melon-local-ai\""))
        XCTAssertTrue(written.contains("alias: \"\(alias)\""))
    }

    /// A catalog failure must stay visible. It used to be assigned and then
    /// cleared by the success path of the same publication.
    func testCatalogFailureIsNotMaskedBySuccessfulVerification() async throws {
        let service = LocalInferenceService.shared
        var servedCalls = 0
        service.publicationHooks = .init(
            writeConfig: {},
            refreshCatalog: { throw PublicationTestError("catalog is read-only") },
            gatewayIsRunning: { true },
            servedModelIDs: { servedCalls += 1; return ["local/ready"] },
            readyAliases: { ["local/ready"] }
        )

        service.publishLocalRoutes()
        await service.waitForPublication()

        let error = try XCTUnwrap(service.publicationError)
        XCTAssertTrue(error.contains("catalog"), error)
        XCTAssertTrue(error.contains("catalog is read-only"), error)
        XCTAssertEqual(servedCalls, 0, "verification must not run after a failed publish")
    }

    func testWriterFailureIsSurfaced() async throws {
        let service = LocalInferenceService.shared
        var catalogSyncs = 0
        service.publicationHooks = .init(
            writeConfig: { throw PublicationTestError("disk is full") },
            refreshCatalog: { catalogSyncs += 1 },
            gatewayIsRunning: { true },
            servedModelIDs: { ["local/ready"] },
            readyAliases: { ["local/ready"] }
        )

        service.publishLocalRoutes()
        await service.waitForPublication()

        let error = try XCTUnwrap(service.publicationError)
        XCTAssertTrue(error.contains(String(format: L("Local AI routes were not written: %@"), "disk is full")), error)
        XCTAssertEqual(catalogSyncs, 0)
    }

    /// A queued task can be cancelled before the main actor ever runs it. It
    /// must not capture the current hooks and write through them: teardown may
    /// already have restored the live gateway by the time it is scheduled.
    func testPublicationCancelledBeforeStartingDoesNotWrite() async {
        let service = LocalInferenceService.shared
        var writes = 0
        var catalogSyncs = 0
        var servedCalls = 0
        service.publicationHooks = .init(
            writeConfig: { writes += 1 },
            refreshCatalog: { catalogSyncs += 1 },
            gatewayIsRunning: { true },
            servedModelIDs: { servedCalls += 1; return ["local/ready"] },
            readyAliases: { ["local/ready"] }
        )

        service.publishLocalRoutes()
        // No suspension has happened since the task was created, so it cannot
        // have started yet; the cancel is deterministic.
        service.cancelPendingPublicationForTesting()
        await service.waitForPublication()

        XCTAssertEqual(writes, 0, "a cancelled-before-start task wrote the config")
        XCTAssertEqual(catalogSyncs, 0)
        XCTAssertEqual(servedCalls, 0)
    }

    /// Cancelling publication A and starting B must leave B's result in place;
    /// A's late answer may not overwrite the newer state.
    func testStalePublicationCannotOverwriteTheNewerResult() async throws {
        let service = LocalInferenceService.shared
        var servedCalls = 0
        var firstStarted = false
        service.publicationHooks = .init(
            writeConfig: {},
            refreshCatalog: {},
            gatewayIsRunning: { true },
            servedModelIDs: {
                servedCalls += 1
                if servedCalls == 1 {
                    firstStarted = true
                    // A is cancelled while suspended here.
                    try await Task.sleep(nanoseconds: 200_000_000)
                    return []
                }
                return ["local/ready"]
            },
            readyAliases: { ["local/ready"] },
            wait: { _ in }
        )

        service.publishLocalRoutes()
        while !firstStarted { await Task.yield() }
        service.publishLocalRoutes() // cancels the first task
        await service.waitForPublication()

        XCTAssertNil(service.publicationError)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(service.publicationError, "a cancelled publication overwrote the newer result")
        XCTAssertEqual(servedCalls, 2)
    }

    /// Stop rewrites the config and proves the alias is gone, instead of
    /// assuming the watcher applied the removal.
    func testStopVerifiesThatTheAliasIsNoLongerServed() async throws {
        let service = LocalInferenceService.shared
        var writes = 0
        var servedCalls = 0
        var served: Set<String> = ["local/old"]
        service.publicationHooks = .init(
            writeConfig: {
                writes += 1
                if writes == 2 { served = [] }
            },
            refreshCatalog: {},
            gatewayIsRunning: { true },
            servedModelIDs: { servedCalls += 1; return served },
            readyAliases: { [] },
            wait: { _ in }
        )

        service.publishLocalRoutes(expectingAbsent: ["local/old"])
        await service.waitForPublication()

        XCTAssertNil(service.publicationError)
        XCTAssertEqual(writes, 2, "the retry must rewrite the config in place")
        XCTAssertEqual(servedCalls, 2)
    }

    func testStopReportsAnAliasThatStaysServed() async throws {
        let service = LocalInferenceService.shared
        service.publicationHooks = .init(
            writeConfig: {},
            refreshCatalog: {},
            gatewayIsRunning: { true },
            servedModelIDs: { ["local/old"] },
            readyAliases: { [] },
            wait: { _ in }
        )

        service.publishLocalRoutes(expectingAbsent: ["local/old"])
        await service.waitForPublication()

        let error = try XCTUnwrap(service.publicationError)
        XCTAssertTrue(error.contains(String(format: L("Local AI models are still served after stop: %@"), "local/old")), error)
        XCTAssertTrue(error.contains("local/old"), error)
    }

    func testStoppedGatewayClearsThePublicationError() async throws {
        let service = LocalInferenceService.shared
        var servedCalls = 0
        service.publicationHooks = .init(
            writeConfig: {},
            refreshCatalog: {},
            gatewayIsRunning: { false },
            servedModelIDs: { servedCalls += 1; return [] },
            readyAliases: { ["local/ready"] }
        )

        service.publishLocalRoutes()
        await service.waitForPublication()

        XCTAssertNil(service.publicationError)
        XCTAssertEqual(servedCalls, 0)
    }

    // MARK: - Real gateway app-path convergence

    /// The exact production path a Ready model takes: `effectiveSources` →
    /// `gatewayYAML` → atomic config write → the real engine's `/v1/models`.
    /// The gateway runs against a temporary support directory and port; the
    /// installed app, its config and its gateway process are never touched.
    /// Skips only when no engine binary is available (CI); on a developer Mac
    /// with the installed app this test executes the real process.
    func testProductionWriterPublishesAndRemovesRoutesOnARealGateway() async throws {
        guard let binary = Self.gatewayBinary() else {
            throw XCTSkip("no gateway engine binary; set MELON_GATEWAY_BIN to run the real-process check")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-gateway-e2e-\(UUID().uuidString)", isDirectory: true)
        let authDir = root.appendingPathComponent("auths", isDirectory: true)
        let configURL = root.appendingPathComponent("config.yaml")
        let logURL = root.appendingPathComponent("gateway.log")
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        let gatewayPort = try Self.freePort()
        let localPort = try Self.freePort()
        let gatewayKey = "test-gateway-\(UUID().uuidString)"
        let localToken = "test-local-\(UUID().uuidString)"
        let alias = "local/qwen3-integrated"

        var models = [publicationModel(status: .installed, alias: alias)]
        var writeCount = 0
        var servedCalls = 0

        func writeConfig() throws {
            let sources = ModelSourcesStore.effectiveSources(
                base: [],
                localModels: models,
                port: localPort,
                token: localToken,
                slots: 2
            )
            let yaml = Self.gatewayBaseConfig(
                port: gatewayPort,
                apiKey: gatewayKey,
                authDir: authDir.path
            ) + ModelSourcesStore.gatewayYAML(sources: sources)
            try SecureFile.write(Data(yaml.utf8), to: configURL)
            writeCount += 1
        }

        // Start with an installed-only model: the real gateway must come up
        // without any local route, so the later publication is the only cause.
        try writeConfig()
        XCTAssertFalse(try String(contentsOf: configURL, encoding: .utf8).contains(alias))
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-config", configURL.path]
        process.currentDirectoryURL = root
        process.standardOutput = log
        process.standardError = log
        try process.run()
        defer {
            LocalInferenceService.shared.resetPublicationForTesting()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }

        var started = false
        for _ in 0..<40 {
            if !process.isRunning { break }
            if let ids = try? await Self.gatewayModelIDs(port: gatewayPort, key: gatewayKey),
               !ids.contains(alias) {
                started = true
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(started, "gateway did not answer: \(Self.tail(logURL))")

        let service = LocalInferenceService.shared
        service.resetPublicationForTesting()
        service.publicationHooks = LocalInferenceService.PublicationHooks(
            writeConfig: writeConfig,
            refreshCatalog: {},
            gatewayIsRunning: { process.isRunning },
            servedModelIDs: {
                servedCalls += 1
                return try await Self.gatewayModelIDs(port: gatewayPort, key: gatewayKey)
            },
            readyAliases: { LocalInferenceService.readyAliases(in: models) }
        )

        // Ready: the production generator must add the route to the live API.
        let writesBeforeAdd = writeCount
        models = [publicationModel(status: .ready, alias: alias)]
        service.publishLocalRoutes()
        await service.waitForPublication()
        XCTAssertNil(service.publicationError)
        // The first write can be observed before the watcher answers; a retry
        // is allowed but not required. The retry path has its own deterministic
        // hooks test.
        XCTAssertGreaterThanOrEqual(writeCount, writesBeforeAdd + 1)
        XCTAssertGreaterThan(servedCalls, 0)
        let served = try await Self.gatewayModelIDs(port: gatewayPort, key: gatewayKey)
        XCTAssertTrue(served.contains(alias), "published routes: \(served.sorted())")

        // Stop/delete: the same production generator must remove it again.
        let writesBeforeRemove = writeCount
        models = [publicationModel(status: .installed, alias: alias)]
        service.publishLocalRoutes(expectingAbsent: [alias])
        await service.waitForPublication()
        XCTAssertNil(service.publicationError)
        XCTAssertGreaterThanOrEqual(writeCount, writesBeforeRemove + 1)
        let remaining = try await Self.gatewayModelIDs(port: gatewayPort, key: gatewayKey)
        XCTAssertFalse(remaining.contains(alias), "stale routes: \(remaining.sorted())")
    }

    private func publicationModel(status: ModelRuntimeStatus, alias: String) -> LocalModel {
        var model = LocalModel(
            id: String(alias.dropFirst("local/".count)),
            displayName: "Qwen 3 Integrated",
            provider: "Local AI",
            source: "import",
            repoId: nil,
            revision: nil,
            files: ["integrated.gguf"],
            fileSize: 1,
            quantization: "Q4_K_M",
            format: "GGUF",
            contextLength: 8192,
            configuredContext: 8192,
            backend: .metal,
            gpuOffload: nil,
            threads: nil,
            runtimeStatus: status,
            capabilities: [.text],
            installedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: nil,
            license: nil,
            checksum: nil,
            userSettings: .defaultSettings(forContext: 8192)
        )
        model.userSettings.contextLength = 8192
        return model
    }

    private static func gatewayBinary() -> URL? {
        let environment = ProcessInfo.processInfo.environment["MELON_GATEWAY_BIN"]
        let candidates = [
            environment,
            NSHomeDirectory() + "/Library/Application Support/MelonTools/gateway/bin/cliproxyapi",
            "/Applications/Melon Tools.app/Contents/Resources/gateway/cliproxyapi",
        ].compactMap { $0 }
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func gatewayBaseConfig(port: Int, apiKey: String, authDir: String) -> String {
        """
        # Melon Tools test gateway — temporary config, never the user's.
        config-version: 8

        server:
          host: "127.0.0.1"
          port: \(port)

        access:
          api-keys:
            - "\(apiKey)"

        oauth:
          auth-dir: "\(authDir)"

        remote-management:
          allow-remote: false
          secret-key: "test-management-\(UUID().uuidString)"
          disable-control-panel: true
          disable-auto-update-panel: true

        routing:
          strategy: "round-robin"
        request-retry: 3
        max-retry-interval: 45
        transient-error-cooldown-seconds: 20
        stream-bootstrap-timeout-seconds: 30

        requests:
          proxy-url: ""

        """
    }

    private static func gatewayModelIDs(port: Int, key: String) async throws -> Set<String> {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        request.timeoutInterval = 2
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await NetworkProxy.directSession().data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Payload: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        return Set(try JSONDecoder().decode(Payload.self, from: data).data.map(\.id))
    }

    private static func freePort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PublicationTestError("socket() failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw PublicationTestError("bind() failed") }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw PublicationTestError("getsockname() failed") }
        return Int(UInt16(bigEndian: local.sin_port))
    }

    private static func tail(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return String(text.suffix(1200))
    }

    private static func localSource(alias: String) -> ModelSource {
        let model = SourceModel(
            id: String(alias.dropFirst("local/".count)),
            display: "Ready",
            contextLength: 4096,
            enabled: true,
            alias: alias
        )
        return ModelSource(
            id: "melon-local-ai",
            kind: .localAI,
            title: "Local AI",
            baseURL: "http://127.0.0.1:59999/v1",
            apiKey: "__LOCAL_TOKEN__",
            enabled: true,
            models: [model]
        )
    }
}

private struct PublicationTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

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
        await LocalInferenceService.shared.stop()
        if let root = overrideRoot {
            LocalPaths.baseOverride = nil
            try? FileManager.default.removeItem(at: root)
            overrideRoot = nil
        }
        LocalInferenceService.shared.customBinaryPath = nil
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
        LocalPaths.baseOverride = root
        overrideRoot = root
        LocalInferenceService.shared.customBinaryPath = binary.path
        return (binary, model)
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
}

import XCTest
@testable import MelonTools

/// Regression tests for the 2026-11-04 audit findings: GGUF bounds, split
/// completeness, unique storage, atomic publish, settings precedence, metrics,
/// memory estimation and the migration backup.
@MainActor
final class LocalAICoreTests: XCTestCase {

    func testEngineLogContinuesAfterInSessionRotation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("melon-engine-log-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
        }
        let sink = EngineLogSink()
        sink.reset(fileURL: url, redactions: ["secret-key"])
        let block = Data((String(repeating: "x", count: 60_000) + "\n").utf8)
        for _ in 0..<150 { sink.append(block) }
        sink.append(Data("latest secret-key marker\n".utf8))
        let bytes = try Data(contentsOf: url)
        let previous = try Data(contentsOf: url.appendingPathExtension("1"))
        XCTAssertLessThanOrEqual(bytes.count, 4 * 1024 * 1024)
        XCTAssertLessThanOrEqual(previous.count, 4 * 1024 * 1024)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("latest «redacted» marker"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret-key"))
        sink.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    // MARK: - GGUF fixtures

    /// Small builder for synthetic GGUF headers.
    private struct GgufBuilder {
        var data = Data()

        init(version: UInt32 = 3, tensorCount: UInt64 = 0) {
            data.append(contentsOf: [0x47, 0x47, 0x55, 0x46])
            append(UInt32(version).littleEndian)
            append(tensorCount.littleEndian)
            // kv count patched by `finish`
            append(UInt64(0).littleEndian)
        }

        private mutating func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }

        mutating func u32(_ key: String, _ value: UInt32) {
            string(key)
            append(UInt32(4).littleEndian)
            append(value.littleEndian)
        }

        mutating func u64(_ key: String, _ value: UInt64) {
            string(key)
            append(UInt32(10).littleEndian)
            append(value.littleEndian)
        }

        mutating func stringValue(_ key: String, _ value: String) {
            string(key)
            append(UInt32(8).littleEndian)
            string(value)
        }

        mutating func u32Array(_ key: String, _ values: [UInt32]) {
            string(key)
            append(UInt32(9).littleEndian)
            append(UInt32(4).littleEndian)
            append(UInt64(values.count).littleEndian)
            for value in values { append(value.littleEndian) }
        }

        /// Raw array header with an arbitrary (possibly hostile) length.
        mutating func hostileU8Array(_ key: String, length: UInt64) {
            string(key)
            append(UInt32(9).littleEndian)
            append(UInt32(0).littleEndian)
            append(length.littleEndian)
        }

        private mutating func string(_ value: String) {
            append(UInt64(value.utf8.count).littleEndian)
            data.append(contentsOf: Array(value.utf8))
        }

        func finish(kvCount: UInt64) -> Data {
            var copy = data
            let offset = 4 + 4 + 8
            let bytes = withUnsafeBytes(of: kvCount.littleEndian) { Array($0) }
            copy.replaceSubrange(offset..<(offset + 8), with: bytes)
            return copy
        }
    }

    private func writeFixture(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-core-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    // MARK: - GGUF bounds (audit F5)

    /// `UInt64.max` as an array length used to trap in `Int(length)`, which made
    /// a corrupt file crash the app at every launch.
    func testGgufParserRejectsHostileArrayLengthWithoutTrapping() throws {
        var builder = GgufBuilder()
        builder.hostileU8Array("qwen2.tokenizer.ggml.tokens", length: UInt64.max)
        let url = try writeFixture(builder.finish(kvCount: 1), name: "hostile.gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GgufMetadataReader.read(from: url))
    }

    func testGgufParserRejectsTruncatedString() throws {
        var builder = GgufBuilder()
        // Declares a 4 KB string, then the file ends.
        builder.stringValue("general.name", "short")
        var data = builder.finish(kvCount: 1)
        data = data.prefix(data.count - 3)
        let url = try writeFixture(data, name: "truncated.gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GgufMetadataReader.read(from: url))
    }

    /// A file whose metadata block is bigger than the budget is refused instead
    /// of being read into memory.
    func testGgufParserRefusesOversizedMetadataBlock() throws {
        var builder = GgufBuilder()
        builder.hostileU8Array("vocab", length: 200_000_000)
        let url = try writeFixture(builder.finish(kvCount: 1), name: "huge.gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GgufMetadataReader.read(from: url))
    }

    // MARK: - GGUF metadata (audit R1, F10)

    func testGgufParserReadsHybridAttentionMetadata() throws {
        var builder = GgufBuilder()
        builder.stringValue("general.architecture", "qwen35")
        builder.u32("qwen35.context_length", 262_144)
        builder.u32("qwen35.block_count", 24)
        builder.u32("qwen35.embedding_length", 2048)
        builder.u32("qwen35.attention.head_count", 16)
        builder.u32Array("qwen35.attention.head_count_kv", [2, 2, 2, 2, 2, 2])
        builder.u32("qwen35.attention.key_length", 256)
        builder.u32("qwen35.attention.value_length", 256)
        builder.u32("qwen35.attention.sliding_window", 4096)
        builder.u32("qwen35.attention.full_attention_interval", 4)
        builder.u32("qwen35.ssm.inner_size", 4096)
        builder.u32("qwen35.ssm.state_size", 128)
        builder.u32("qwen35.ssm.conv_kernel", 4)
        let url = try writeFixture(builder.finish(kvCount: 13), name: "hybrid.gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try GgufMetadataReader.read(from: url)
        XCTAssertEqual(info.architecture, "qwen35")
        XCTAssertEqual(info.contextLength, 262_144)
        XCTAssertEqual(info.blockCount, 24)
        XCTAssertEqual(info.embeddingLength, 2048)
        XCTAssertEqual(info.headCount, 16)
        XCTAssertEqual(info.headCountKV, [2, 2, 2, 2, 2, 2])
        XCTAssertEqual(info.keyLength, 256)
        XCTAssertEqual(info.valueLength, 256)
        XCTAssertEqual(info.slidingWindow, 4096)
        XCTAssertEqual(info.fullAttentionInterval, 4)
        XCTAssertEqual(info.ssmInnerSize, 4096)
        XCTAssertEqual(info.ssmStateSize, 128)
        XCTAssertTrue(info.isHybridAttention)
        // 24 blocks with a full-attention layer every 4 = 6 KV-carrying layers.
        XCTAssertEqual(info.attentionLayerCount, 6)
        XCTAssertEqual(info.kvHeads(forLayerLayer: 0), 2)
        XCTAssertEqual(info.kvHeads(forLayerLayer: 99), 2)
    }

    /// Values 36–42 were shifted by two entries against the pinned `llama.h`.
    func testGgufFileTypeTableMatchesPinnedEngine() throws {
        let expected: [(UInt32, String)] = [
            (36, "TQ1_0"), (37, "TQ2_0"), (38, "MXFP4_MOE"),
            (39, "NVFP4"), (40, "Q1_0"), (41, "Q2_0"), (42, "F8_E4M3"),
        ]
        for (raw, name) in expected {
            var builder = GgufBuilder()
            builder.stringValue("general.architecture", "llama")
            builder.u32("general.file_type", raw)
            let url = try writeFixture(builder.finish(kvCount: 2), name: "ftype-\(raw).gguf")
            defer { try? FileManager.default.removeItem(at: url) }
            let info = try GgufMetadataReader.read(from: url)
            XCTAssertEqual(info.quantization, name, "file_type \(raw) mapped wrong")
        }
    }

    // MARK: - Storage identity (audit F1, F2, F6)

    func testNamespaceNameIsDeterministicAndCollisionFree() {
        let first = LocalModelStore.namespaceName(for: "local/model")
        XCTAssertEqual(first, LocalModelStore.namespaceName(for: "local/model"))
        XCTAssertNotEqual(first, LocalModelStore.namespaceName(for: "local-MODEL"))
        XCTAssertNotEqual(first, LocalModelStore.namespaceName(for: "local/model-2"))
        XCTAssertTrue(first.range(of: #"^[a-z0-9._-]+-[0-9a-f]{8}$"#, options: .regularExpression) != nil)
    }

    func testSafeFileNameRejectsTraversalAndSeparators() {
        XCTAssertTrue(AtomicFileOps.isSafeFileName("model.gguf"))
        XCTAssertFalse(AtomicFileOps.isSafeFileName("../model.gguf"))
        XCTAssertFalse(AtomicFileOps.isSafeFileName("sub/model.gguf"))
        XCTAssertFalse(AtomicFileOps.isSafeFileName(".."))
        XCTAssertFalse(AtomicFileOps.isSafeFileName(""))
        XCTAssertFalse(AtomicFileOps.isSafeFileName(".hidden.gguf"))
        XCTAssertEqual(AtomicFileOps.safeFileName("sub/model.gguf"), "model.gguf")
        XCTAssertEqual(AtomicFileOps.safeFileName("../../evil.gguf"), "evil.gguf")
    }

    func testOwnedNamespaceDirectoryOnlyForManagedLayout() {
        let root = URL(fileURLWithPath: "/tmp/models")
        let namespace = LocalModelStore.namespaceName(for: "local/model")

        func model(files: [String]) -> LocalModel {
            LocalModel(
                id: "local/model", displayName: "M", provider: "Local AI", source: "import",
                repoId: nil, revision: nil, files: files, fileSize: 1,
                quantization: "Q4_K_M", format: "GGUF", contextLength: 8192, configuredContext: 8192,
                backend: .metal, gpuOffload: nil, threads: nil, runtimeStatus: .installed,
                capabilities: [.text], installedAt: Date(), updatedAt: Date(), lastUsedAt: nil,
                license: nil, checksum: nil, userSettings: .defaultSettings()
            )
        }

        XCTAssertEqual(
            model(files: ["\(namespace)/a.gguf"]).ownedNamespaceDirectory(in: root)?.lastPathComponent,
            namespace
        )
        // A legacy flat entry is a single file, not a folder we may delete.
        XCTAssertNil(model(files: ["a.gguf"]).ownedNamespaceDirectory(in: root))
        // Two different folders are not one namespace.
        XCTAssertNil(model(files: ["\(namespace)/a.gguf", "other-1234abcd/b.gguf"])
            .ownedNamespaceDirectory(in: root))
        // Arbitrary folders outside our naming scheme are never claimed.
        XCTAssertNil(model(files: ["documents/a.gguf"]).ownedNamespaceDirectory(in: root))
    }

    func testAtomicCopyRefusesToOverwriteAndKeepsExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.bin")
        try Data("new".utf8).write(to: source)
        let destination = root.appendingPathComponent("destination.bin")
        try Data("keep".utf8).write(to: destination)

        XCTAssertThrowsError(try AtomicFileOps.copyVerifying(source: source, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
    }

    func testAtomicCopyVerifiesSizeAndContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.bin")
        let payload = Data(repeating: 0x42, count: 128 * 1024)
        try payload.write(to: source)
        let destination = root.appendingPathComponent("nested/destination.bin")

        let written = try AtomicFileOps.copyVerifying(source: source, destination: destination)
        XCTAssertEqual(written, UInt64(payload.count))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    // MARK: - Split GGUF completeness (audit F4)

    private func prepared(_ name: String) -> LocalModelStore.PreparedImport {
        LocalModelStore.PreparedImport(
            storedPath: name,
            stagedURL: URL(fileURLWithPath: "/tmp/\(name)"),
            fileSize: 1,
            fileName: name,
            sha256: nil,
            metadata: nil,
            isLinked: true
        )
    }

    func testSplitSetValidationAcceptsOnlyCompleteSets() throws {
        let complete = try LocalModelStore.validateSplitSet([
            prepared("m-00003-of-00003.gguf"),
            prepared("m-00001-of-00003.gguf"),
            prepared("m-00002-of-00003.gguf"),
        ])
        XCTAssertEqual(complete.map { $0.fileName }, [
            "m-00001-of-00003.gguf", "m-00002-of-00003.gguf", "m-00003-of-00003.gguf",
        ])

        // 1 + 3 of 3 used to be accepted and registered as an installed model.
        XCTAssertThrowsError(try LocalModelStore.validateSplitSet([
            prepared("m-00001-of-00003.gguf"),
            prepared("m-00003-of-00003.gguf"),
        ])) { error in
            guard case LocalStorageError.incompleteSplit(let missing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(missing, [2])
        }

        XCTAssertThrowsError(try LocalModelStore.validateSplitSet([
            prepared("m-00001-of-00002.gguf"),
            prepared("m-00002-of-00003.gguf"),
        ]))
    }

    // MARK: - Preset / settings (audit M6, M7, R3)

    func testPresetCarriesSamplingDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent("preset-\(UUID().uuidString).gguf")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var settings = LocalModelSettings.defaultSettings(forContext: 4096)
        settings.temperature = 0.25
        settings.topP = 0.5
        settings.topK = 7
        settings.repeatPenalty = 1.3
        settings.maxOutputTokens = 777
        settings.seed = 42

        let model = LocalModel(
            id: "local/preset", displayName: "P", provider: "Local AI", source: "import",
            repoId: nil, revision: nil, files: [file.lastPathComponent], fileSize: 0,
            quantization: "Q4_K_M", format: "GGUF", contextLength: 8192, configuredContext: 4096,
            blockCount: 24, architecture: "qwen35", backend: .metal, gpuOffload: 99, threads: 8,
            runtimeStatus: .installed, capabilities: [.text], installedAt: Date(), updatedAt: Date(),
            lastUsedAt: nil, license: nil, checksum: nil, userSettings: settings
        )
        let body = LocalInferenceService.presetLines(
            models: [model], modelsDirectory: directory, backend: .metal, cpuCores: 8
        ).joined(separator: "\n")

        XCTAssertTrue(body.contains("temperature = 0.25"))
        XCTAssertTrue(body.contains("top-p = 0.50"))
        XCTAssertTrue(body.contains("top-k = 7"))
        XCTAssertTrue(body.contains("repeat-penalty = 1.30"))
        XCTAssertTrue(body.contains("n-predict = 777"))
        XCTAssertTrue(body.contains("seed = 42"))
        // `--parallel` is a command-line flag, not a preset key: an unknown key
        // makes the router refuse to start.
        XCTAssertFalse(body.contains("parallel ="))
    }

    func testSettingsChangeClassification() {
        let base = LocalModelSettings.defaultSettings(forContext: 8192)
        XCTAssertEqual(
            LocalInferenceService.classifySettingsChange(from: base, to: base),
            .none
        )
        var sampling = base
        sampling.temperature = 0.1
        XCTAssertEqual(
            LocalInferenceService.classifySettingsChange(from: base, to: sampling),
            .sampling
        )
        var engine = base
        engine.contextLength = 16384
        XCTAssertEqual(
            LocalInferenceService.classifySettingsChange(from: base, to: engine),
            .engine
        )
        var kv = base
        kv.kvCacheType = "q4_0"
        XCTAssertEqual(
            LocalInferenceService.classifySettingsChange(from: base, to: kv),
            .engine
        )
    }

    /// `--parallel` splits one context window, so a model configured at 8192 with
    /// four slots serves 2048 per request.
    func testEffectiveContextIsDividedBetweenSlots() {
        let model = LocalModel(
            id: "local/x", displayName: "X", provider: "Local AI", source: "import",
            repoId: nil, revision: nil, files: ["x.gguf"], fileSize: 0,
            quantization: "Q4_K_M", format: "GGUF", contextLength: 32768, configuredContext: 8192,
            backend: .metal, gpuOffload: nil, threads: nil, runtimeStatus: .installed,
            capabilities: [.text], installedAt: Date(), updatedAt: Date(), lastUsedAt: nil,
            license: nil, checksum: nil, userSettings: .defaultSettings(forContext: 8192)
        )
        XCTAssertEqual(model.effectiveContext(parallelSlots: 1), 8192)
        XCTAssertEqual(model.effectiveContext(parallelSlots: 4), 2048)
        XCTAssertEqual(model.effectiveContext(parallelSlots: 0), 8192)
        XCTAssertEqual(model.nativeContextLength, 32768)
    }

    func testModelSettingsSaveReportsFailureAndRollsBackMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("melon-save-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalModelStore(directory: directory)
        var model = LocalModel(
            id: "local/save", displayName: "Save", provider: "Local AI", source: "import",
            repoId: nil, revision: nil, files: ["save.gguf"], fileSize: 0,
            quantization: "Q4_K_M", format: "GGUF", contextLength: 32768, configuredContext: 8192,
            backend: .metal, gpuOffload: nil, threads: nil, runtimeStatus: .installed,
            capabilities: [.text], installedAt: Date(), updatedAt: Date(), lastUsedAt: nil,
            license: nil, checksum: nil, userSettings: .defaultSettings(forContext: 8192)
        )
        XCTAssertTrue(store.addOrUpdateModel(model))
        try FileManager.default.removeItem(at: store.registryFileURL)
        try FileManager.default.createDirectory(at: store.registryFileURL, withIntermediateDirectories: false)
        model.userSettings.contextLength = 4096
        XCTAssertFalse(store.addOrUpdateModel(model))
        XCTAssertEqual(store.models.first?.userSettings.contextLength, 8192)
    }

    // MARK: - Metrics (audit M4)

    func testMetricsParserHandlesLabelsAndTotals() {
        let body = """
        # HELP llamacpp:prompt_tokens_total Number of prompt tokens processed
        # TYPE llamacpp:prompt_tokens_total counter
        llamacpp:prompt_tokens_total{model="local/x"} 120
        llamacpp:prompt_tokens_total{model="local/y"} 30
        llamacpp:tokens_predicted_total 45
        llamacpp:prompt_seconds_total 1.5
        llamacpp:tokens_predicted_seconds_total 3.0
        """
        let metrics = LocalInferenceService.parseMetrics(body)
        let unwrapped = try? XCTUnwrap(metrics)
        XCTAssertEqual(unwrapped?.promptTokens, 150)
        XCTAssertEqual(unwrapped?.predictedTokens, 45)
        XCTAssertEqual(unwrapped?.promptPerSecond ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(unwrapped?.predictedPerSecond ?? 0, 15, accuracy: 0.001)
    }

    func testMetricsParserRejectsGarbage() {
        XCTAssertNil(LocalInferenceService.parseMetrics("not metrics at all"))
        XCTAssertNil(LocalInferenceService.parseMetrics(""))
    }

    func testMetricsParserTreatsZeroGaugesAsMissing() {
        // The engine reports 0 for *_tokens_seconds until a task finishes.
        let body = """
        llamacpp:prompt_tokens_total 1000
        llamacpp:tokens_predicted_total 200
        llamacpp:prompt_seconds_total 10
        llamacpp:tokens_predicted_seconds_total 20
        llamacpp:prompt_tokens_seconds 0
        llamacpp:predicted_tokens_seconds 0
        """
        let metrics = LocalInferenceService.parseMetrics(body)
        XCTAssertEqual(metrics?.promptPerSecond ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(metrics?.predictedPerSecond ?? 0, 10, accuracy: 0.001)
    }

    func testLiveRatesComeFromCounterDeltas() {
        let base = Date(timeIntervalSince1970: 1_000)
        var first = LocalInferenceService.InferenceMetrics()
        first.promptTokens = 100
        first.predictedTokens = 10
        first.updatedAt = base
        var second = LocalInferenceService.InferenceMetrics()
        second.promptTokens = 140
        second.predictedTokens = 14
        second.updatedAt = base.addingTimeInterval(2)

        let live = LocalInferenceService.withLiveRates(second, baseline: first)
        XCTAssertEqual(live?.promptTokens, 140)
        XCTAssertEqual(live?.predictedTokens, 14)
        XCTAssertEqual(live?.promptPerSecond ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(live?.predictedPerSecond ?? 0, 2, accuracy: 0.001)
    }

    func testLiveRatesSurviveCounterReset() {
        let base = Date(timeIntervalSince1970: 1_000)
        var first = LocalInferenceService.InferenceMetrics()
        first.predictedTokens = 500
        first.updatedAt = base
        var second = LocalInferenceService.InferenceMetrics()
        second.predictedTokens = 5
        second.predictedPerSecond = 12
        second.updatedAt = base.addingTimeInterval(2)

        // A restarted engine must not produce a negative rate.
        let live = LocalInferenceService.withLiveRates(second, baseline: first)
        XCTAssertEqual(live?.predictedPerSecond ?? 0, 12, accuracy: 0.001)
    }

    func testMetricsParserIgnoresAverageOverTinyElapsed() {
        // 2 tokens over 0.000002 s used to surface as 1_000_000.0 tok/s.
        let body = """
        llamacpp:prompt_tokens_total 2
        llamacpp:tokens_predicted_total 2
        llamacpp:prompt_seconds_total 0.000002
        llamacpp:tokens_predicted_seconds_total 0.000002
        llamacpp:prompt_tokens_seconds 0
        llamacpp:predicted_tokens_seconds 0
        """
        let metrics = LocalInferenceService.parseMetrics(body)
        XCTAssertEqual(metrics?.promptPerSecond ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(metrics?.predictedPerSecond ?? -1, 0, accuracy: 0.001)
    }

    func testLiveRatesRejectAbsurdDeltas() {
        let base = Date(timeIntervalSince1970: 1_000)
        var first = LocalInferenceService.InferenceMetrics()
        first.predictedTokens = 0
        first.predictedPerSecond = 21.5
        first.updatedAt = base
        var second = LocalInferenceService.InferenceMetrics()
        second.predictedTokens = 5_000_000
        second.updatedAt = base.addingTimeInterval(1)

        let live = LocalInferenceService.withLiveRates(second, baseline: first)
        XCTAssertEqual(live?.predictedPerSecond ?? 0, 21.5, accuracy: 0.001)
    }

    func testContentRangeStartParsing() {
        XCTAssertEqual(LocalDownloadManager.startByte(fromContentRange: "bytes 1024-2047/4096"), 1024)
        XCTAssertEqual(LocalDownloadManager.startByte(fromContentRange: "bytes 0-0/1"), 0)
        XCTAssertNil(LocalDownloadManager.startByte(fromContentRange: "bytes */4096"))
        XCTAssertNil(LocalDownloadManager.startByte(fromContentRange: nil))
    }

    // MARK: - Memory advisor (audit R1)

    private var hardware: HardwareInfo {
        HardwareInfo(
            osVersion: "macOS 27.0",
            architecture: "arm64",
            cpuModel: "Apple M",
            cpuCores: 10,
            totalRAM: 16 * 1024 * 1024 * 1024,
            freeRAM: 8 * 1024 * 1024 * 1024,
            gpuName: "Apple M",
            gpuHasUnifiedMemory: true,
            gpuDriver: "Metal",
            gpuRecommendedMaxWorkingSetSize: 12 * 1024 * 1024 * 1024,
            supportedBackends: [.metal, .cpu],
            recommendedBackend: .metal,
            modelsDiskFreeSpace: 0,
            modelsDiskTotalSpace: 0
        )
    }

    func testMemoryEstimateUsesHybridAttentionMetadata() {
        let profile = GgufMemoryProfile(info: GgufInfo(
            version: 3, tensorCount: 0, architecture: "qwen35", name: nil,
            contextLength: 262_144, blockCount: 24, embeddingLength: 2048,
            headCount: 16, headCountKV: [2], keyLength: 256, valueLength: 256,
            slidingWindow: 4096, fullAttentionInterval: 4,
            ssmInnerSize: 4096, ssmStateSize: 128, ssmConvKernel: 4,
            expertCount: nil, quantization: "BF16", chatTemplate: nil,
            license: nil, fileType: 32
        ))
        XCTAssertNotNil(profile)

        let hybrid = LocalHardwareService.calculateMemoryEstimation(
            info: hardware,
            weightsSize: 3_775_709_216,
            contextLength: 32768,
            kvCacheType: "f16",
            batchSize: 512,
            gpuLayers: 99,
            totalLayers: 24,
            profile: profile,
            slots: 1,
            backend: .metal
        )
        let naive = LocalHardwareService.calculateMemoryEstimation(
            info: hardware,
            weightsSize: 3_775_709_216,
            contextLength: 32768,
            kvCacheType: "f16",
            batchSize: 512,
            gpuLayers: 99,
            totalLayers: 24,
            profile: nil,
            slots: 1,
            backend: .metal
        )

        // Only 6 of 24 layers keep a KV cache in a hybrid model; treating all 24
        // as ordinary attention over-estimates by a wide margin.
        XCTAssertLessThan(hybrid.kvCacheSize, naive.kvCacheSize)
        XCTAssertGreaterThan(hybrid.stateCacheSize, 0)
        XCTAssertEqual(hybrid.confidence, .low)
        XCTAssertLessThanOrEqual(hybrid.totalLow, hybrid.totalRequired)
        XCTAssertGreaterThanOrEqual(hybrid.totalHigh, hybrid.totalRequired)
        // The advisor explains itself; the exact wording is localized, so the
        // property checked here is that an explanation exists at all.
        XCTAssertFalse(hybrid.assumptions.isEmpty)
    }

    func testMemoryEstimateIsLowConfidenceWithoutMetadata() {
        let estimate = LocalHardwareService.calculateMemoryEstimation(
            info: hardware,
            weightsSize: 4 * 1024 * 1024 * 1024,
            contextLength: 8192,
            kvCacheType: "f16",
            batchSize: 512,
            gpuLayers: 0,
            totalLayers: 32,
            profile: nil,
            slots: 1,
            backend: .cpu
        )
        XCTAssertEqual(estimate.confidence, .low)
        XCTAssertFalse(estimate.assumptions.isEmpty)
        XCTAssertLessThanOrEqual(estimate.totalLow, estimate.totalHigh)
    }

    func testMemoryEstimateKeepsTotalKVCapacityAcrossSlots() {
        let single = LocalHardwareService.calculateMemoryEstimation(
            info: hardware, weightsSize: 4 * 1024 * 1024 * 1024, contextLength: 8192,
            kvCacheType: "f16", batchSize: 512, gpuLayers: 99, totalLayers: 32,
            profile: nil, slots: 1, backend: .metal
        )
        let four = LocalHardwareService.calculateMemoryEstimation(
            info: hardware, weightsSize: 4 * 1024 * 1024 * 1024, contextLength: 8192,
            kvCacheType: "f16", batchSize: 512, gpuLayers: 99, totalLayers: 32,
            profile: nil, slots: 4, backend: .metal
        )
        XCTAssertEqual(four.kvCacheSize, single.kvCacheSize)
    }

    func testGgufScalarKVHeadsAndZeroLayerEntriesArePreserved() throws {
        var scalar = GgufBuilder()
        scalar.u32("llama.attention.head_count_kv", 8)
        let scalarURL = try writeFixture(scalar.finish(kvCount: 1), name: "scalar-kv.gguf")
        defer { try? FileManager.default.removeItem(at: scalarURL) }
        XCTAssertEqual(try GgufMetadataReader.read(from: scalarURL).headCountKV, [8])
        var array = GgufBuilder()
        array.u32Array("qwen35.attention.head_count_kv", [0, 0, 2, 0])
        let arrayURL = try writeFixture(array.finish(kvCount: 1), name: "layer-kv.gguf")
        defer { try? FileManager.default.removeItem(at: arrayURL) }
        XCTAssertEqual(try GgufMetadataReader.read(from: arrayURL).headCountKV, [0, 0, 2, 0])
    }

    private func attentionProfile(heads: [Int] = [8], interval: Int? = nil) -> GgufMemoryProfile? {
        GgufMemoryProfile(info: GgufInfo(
            version: 3, tensorCount: 0, architecture: "llama", name: nil,
            contextLength: 32768, blockCount: 4, embeddingLength: 4096,
            headCount: 32, headCountKV: heads, keyLength: 128, valueLength: 64,
            slidingWindow: interval == nil ? nil : 4096, fullAttentionInterval: interval,
            ssmInnerSize: nil, ssmStateSize: nil, ssmConvKernel: nil,
            expertCount: nil, quantization: "Q4_K_M", chatTemplate: nil,
            license: nil, fileType: 15
        ))
    }

    func testMemoryUsesAsymmetricHeadsAndPerLayerZeroEntries() {
        let estimate = LocalHardwareService.calculateMemoryEstimation(
            info: hardware, weightsSize: 1_000_000, contextLength: 8192,
            kvCacheType: "f16", batchSize: 128, gpuLayers: 0, totalLayers: 4,
            profile: attentionProfile(heads: [0, 2, 0, 4]), backend: .cpu
        )
        XCTAssertEqual(estimate.kvCacheSize, UInt64((128 + 64) * 6 * 8192 * 2))
    }

    func testSlidingIntervalDoesNotMakeLayersRecurrent() {
        let estimate = LocalHardwareService.calculateMemoryEstimation(
            info: hardware, weightsSize: 1_000_000, contextLength: 8192,
            kvCacheType: "f16", batchSize: 128, gpuLayers: 0, totalLayers: 4,
            profile: attentionProfile(interval: 4), backend: .cpu
        )
        XCTAssertEqual(estimate.kvCacheSize, UInt64((128 + 64) * 8 * 4 * 8192 * 2))
        XCTAssertEqual(estimate.stateCacheSize, 0)
    }

    func testOffloadAndFlashAttentionUseSeparateBudgets() {
        let cpu = LocalHardwareService.calculateMemoryEstimation(
            info: hardware, weightsSize: 1_000_000, contextLength: 8192,
            kvCacheType: "f16", batchSize: 512, gpuLayers: 0, totalLayers: 4,
            profile: attentionProfile(), backend: .metal
        )
        let gpu = LocalHardwareService.calculateMemoryEstimation(
            info: hardware, weightsSize: 1_000_000, contextLength: 8192,
            kvCacheType: "f16", batchSize: 512, gpuLayers: 4, totalLayers: 4,
            profile: attentionProfile(), backend: .metal, flashAttention: false
        )
        XCTAssertEqual(cpu.gpuRequired, 0)
        XCTAssertNil(cpu.gpuBudget)
        XCTAssertEqual(gpu.gpuBudget, hardware.gpuRecommendedMaxWorkingSetSize)
        XCTAssertGreaterThan(gpu.computeBuffers, cpu.computeBuffers)
        XCTAssertEqual(gpu.ramRequired, gpu.totalRequired) // unified counted once
    }

    // MARK: - Migration (audit F9)

    func testMigrationBacksUpEverythingAndOnlyThenMarksCompletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = LocalPaths.baseOverride
        LocalPaths.baseOverride = root
        defer {
            LocalPaths.baseOverride = previous
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: LocalPaths.metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: LocalPaths.base.appendingPathComponent("gateway"), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: LocalPaths.registry)
        try Data("gateway".utf8).write(to: LocalPaths.gatewayConfig)

        let report = LocalAIMigration.runIfNeeded()
        XCTAssertTrue(report.performed, report.failure ?? "")
        let backup = try XCTUnwrap(report.backupDirectory)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: LocalPaths.metadata.appendingPathComponent("migrated-6.0.0.json").path
        ))
        let manifest = try JSONDecoder().decode(
            LocalAIMigration.BackupManifest.self,
            from: Data(contentsOf: backup.appendingPathComponent("backup-manifest.json"))
        )
        XCTAssertTrue(manifest.files.contains { $0.name == "models.json" })
        XCTAssertEqual(
            manifest.files.first { $0.name == "models.json" }?.sha256,
            AtomicFileOps.sha256Hex(of: LocalPaths.registry)
        )

        // A second run must not overwrite the snapshot.
        XCTAssertFalse(LocalAIMigration.runIfNeeded().performed)

        // Restore puts the original bytes back.
        try Data("changed".utf8).write(to: LocalPaths.registry)
        try LocalAIMigration.restore(from: backup)
        XCTAssertEqual(try Data(contentsOf: LocalPaths.registry), Data("registry".utf8))
    }

    func testMaintenanceRemovesOldStagingButKeepsResumableParts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-gc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = LocalPaths.baseOverride
        LocalPaths.baseOverride = root
        defer {
            LocalPaths.baseOverride = previous
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: LocalPaths.models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: LocalPaths.downloads, withIntermediateDirectories: true)

        let oldStaging = LocalPaths.models.appendingPathComponent(".staging-old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldStaging, withIntermediateDirectories: true)

        let activeJob = UUID()
        let jobDirectory = LocalPaths.downloads.appendingPathComponent(activeJob.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: jobDirectory.appendingPathComponent("model.gguf.part"))
        try Data("{}".utf8).write(to: jobDirectory.appendingPathComponent("model.gguf.part.json"))

        let oldDate = Date().addingTimeInterval(-72 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldStaging.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: jobDirectory.path)

        let removed = LocalAIMigration.runMaintenance(activeDownloadJobs: [activeJob])
        XCTAssertTrue(removed.contains { $0.contains(".staging-old") })
        // The resumable part of an active job is never touched.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: jobDirectory.appendingPathComponent("model.gguf.part").path
        ))
    }

    // MARK: - Import collisions (audit F1/F2 regression)

    /// A minimal but valid GGUF v3 file, so import actually parses it.
    private func writeGGUF(at url: URL, name: String = "model") throws {
        var builder = GgufBuilder()
        builder.stringValue("general.architecture", "qwen2")
        builder.u32("qwen2.context_length", 4096)
        builder.u32("qwen2.block_count", 24)
        try builder.finish(kvCount: 3).write(to: url)
    }

    /// Two repositories with the same file name used to share one path, one
    /// registry slot and one deletion target.
    func testTwoImportsWithTheSameFileNameDoNotCollide() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = LocalPaths.baseOverride
        LocalPaths.baseOverride = root
        defer {
            LocalPaths.baseOverride = previous
            try? FileManager.default.removeItem(at: root)
        }

        let sourceA = root.appendingPathComponent("a", isDirectory: true)
        let sourceB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        try writeGGUF(at: sourceA.appendingPathComponent("model.gguf"))
        try writeGGUF(at: sourceB.appendingPathComponent("model.gguf"))

        let store = LocalModelStore.shared
        try store.connectModelsDirectory(nil)
        let first = try await store.importGGUFFileAsync(from: sourceA.appendingPathComponent("model.gguf"))
        let second = try await store.importGGUFFileAsync(from: sourceB.appendingPathComponent("model.gguf"))

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.files, second.files)
        for model in [first, second] {
            let url = model.fileURLs(in: store.modelsDirectory).first
            XCTAssertEqual(url.map { FileManager.default.fileExists(atPath: $0.path) }, true)
        }

        // Deleting one must not take the other file with it.
        let survivorURL = try XCTUnwrap(second.fileURLs(in: store.modelsDirectory).first)
        _ = store.removeModel(id: first.id, deleteFiles: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivorURL.path))
        XCTAssertNil(store.models.first { $0.id == first.id })
        XCTAssertNotNil(store.models.first { $0.id == second.id })
    }

    /// A split model is one entry, and an incomplete set is refused instead of
    /// being registered as an installed model.
    func testSplitFolderImportGroupsAndRejectsIncompleteSets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = LocalPaths.baseOverride
        LocalPaths.baseOverride = root
        defer {
            LocalPaths.baseOverride = previous
            try? FileManager.default.removeItem(at: root)
        }

        let complete = root.appendingPathComponent("complete", isDirectory: true)
        try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true)
        for index in 1...3 {
            try writeGGUF(at: complete.appendingPathComponent(
                String(format: "m-0000%d-of-00003.gguf", index)
            ))
        }

        let store = LocalModelStore.shared
        try store.connectModelsDirectory(nil)
        let imported = try await store.importGGUFFolderAsync(from: complete)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.files.count, 3)
        XCTAssertEqual(imported.first?.files.allSatisfy { $0.contains("-0000") }, true)

        let incomplete = root.appendingPathComponent("incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        for index in [1, 3] {
            try writeGGUF(at: incomplete.appendingPathComponent(
                String(format: "n-0000%d-of-00003.gguf", index)
            ))
        }
        do {
            _ = try await store.importGGUFFolderAsync(from: incomplete)
            XCTFail("an incomplete split set was accepted")
        } catch {
            guard case LocalStorageError.incompleteSplit(let missing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(missing, [2])
        }
    }

    /// Case-insensitive APFS: `Model.gguf` and `model.gguf` are one file on disk,
    /// so the second import must still get its own directory.
    func testCaseOnlyDifferentNamesDoNotShareAFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = LocalPaths.baseOverride
        LocalPaths.baseOverride = root
        defer {
            LocalPaths.baseOverride = previous
            try? FileManager.default.removeItem(at: root)
        }

        let firstDirectory = root.appendingPathComponent("one", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try writeGGUF(at: firstDirectory.appendingPathComponent("Model.gguf"))
        try writeGGUF(at: secondDirectory.appendingPathComponent("model.gguf"))

        let store = LocalModelStore.shared
        try store.connectModelsDirectory(nil)
        let first = try await store.importGGUFFileAsync(from: firstDirectory.appendingPathComponent("Model.gguf"))
        let second = try await store.importGGUFFileAsync(from: secondDirectory.appendingPathComponent("model.gguf"))
        XCTAssertNotEqual(first.files, second.files)
    }
}

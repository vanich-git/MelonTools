import XCTest
@testable import MelonTools

@MainActor
final class LocalAITests: XCTestCase {

    func testCodexModelCatalogLocalAIBandAndTag() {
        XCTAssertEqual(CodexModelCatalog.priorityBase(for: .localAI), 800)
        XCTAssertEqual(CodexModelCatalog.providerTag(for: .localAI), "Local AI")
    }

    func testLocalModelSettingsDefaults() {
        let settings = LocalModelSettings.defaultSettings(forContext: 16384)
        XCTAssertEqual(settings.contextLength, 16384)
        XCTAssertEqual(settings.temperature, 0.7)
        XCTAssertEqual(settings.batchSize, 512)
        XCTAssertEqual(settings.profile, .auto)
        XCTAssertTrue(settings.flashAttention)
    }

    func testLocalModelCodableRoundtrip() throws {
        let model = LocalModel(
            id: "local/test-model-q4",
            displayName: "Test Model Q4",
            provider: "Local AI",
            source: "import",
            repoId: nil,
            revision: nil,
            files: ["test-model-q4.gguf"],
            fileSize: 4_000_000_000,
            quantization: "Q4_K_M",
            format: "GGUF",
            contextLength: 8192,
            configuredContext: 8192,
            backend: .metal,
            gpuOffload: 99,
            threads: 8,
            runtimeStatus: .installed,
            capabilities: [.text, .tools],
            installedAt: Date(),
            updatedAt: Date(),
            lastUsedAt: nil,
            license: "Apache-2.0",
            checksum: nil,
            userSettings: .defaultSettings(forContext: 8192)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(model)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(LocalModel.self, from: data)

        XCTAssertEqual(decoded.id, model.id)
        XCTAssertEqual(decoded.displayName, model.displayName)
        XCTAssertEqual(decoded.quantization, "Q4_K_M")
        XCTAssertEqual(decoded.capabilities, [.text, .tools])
        XCTAssertEqual(decoded.backend, .metal)
    }

    func testHardwareInfoFormatting() {
        let formattedGB = LocalHardwareService.formatBytes(4 * 1024 * 1024 * 1024)
        XCTAssertTrue(formattedGB.contains("4"))

        let formattedMB = LocalHardwareService.formatBytes(512 * 1024 * 1024)
        XCTAssertTrue(formattedMB.contains("512"))
    }

    /// "F16" is a substring of "BF16"; matching in declaration order labels
    /// every BF16 file as F16.
    func testQuantizationDetectionPrefersTheLongestMatch() {
        XCTAssertEqual(
            HuggingFaceService.extractQuantization(from: "Qwen3.5-2B-BF16.gguf"),
            "BF16"
        )
        XCTAssertEqual(
            HuggingFaceService.extractQuantization(from: "Qwen3.5-2B-F16.gguf"),
            "F16"
        )
        XCTAssertEqual(
            HuggingFaceService.extractQuantization(from: "model-q4_k_m.gguf"),
            "Q4_K_M"
        )
        XCTAssertEqual(
            HuggingFaceService.extractQuantization(from: "model-iq4_xs.gguf"),
            "IQ4_XS"
        )
        XCTAssertEqual(
            HuggingFaceService.extractQuantization(from: "model-unknown.gguf"),
            "GGUF"
        )
    }

    /// The Local AI screens were the only ones shipped without a Russian
    /// table, so English labels sat next to a localized "Отмена" button.
    func testLocalAIStringsAreLocalized() {
        let keys = [
            "System Prompt",
            "Added to every Chat Completions and Responses request this model serves through the local gateway. Empty sends none.",
            "Configuration Profile",
            "Compute & Metal Acceleration",
            "Context Window (Tokens)",
            "KV Cache Quantization",
            "Sampling Parameters",
            "Chat Template",
            "Estimated memory",
            "Save Settings",
            "Reset to Defaults",
        ]
        for key in keys {
            XCTAssertNotNil(L10n.ru[key], "missing Russian translation for \(key)")
        }
    }

    /// The Start button relied on `isRunning` alone, so a launch that takes up
    /// to a minute looked like nothing happened.
    func testServiceStatusExposesTheStartingPhase() {
        let starting = LocalInferenceService.ServiceStatus.starting(modelId: "local/qwen")
        XCTAssertTrue(starting.isStarting)
        XCTAssertFalse(starting.isRunning)
        XCTAssertEqual(starting.startingModelId, "local/qwen")

        XCTAssertFalse(LocalInferenceService.ServiceStatus.stopped.isStarting)
        XCTAssertNil(LocalInferenceService.ServiceStatus.stopped.startingModelId)
        XCTAssertFalse(LocalInferenceService.ServiceStatus.running(port: 1, modelId: "x").isStarting)
    }

    // MARK: - Download size plumbing

    /// HF puts the byte size under `lfs` for LFS-backed files and at the top
    /// level otherwise; both shapes must resolve, or the progress bar stays at
    /// 0% with a "0 KB" total.
    func testGGUFFileSizeReadsBothSiblingShapes() {
        XCTAssertEqual(
            HuggingFaceService.ggufFileSize(fromSibling: ["lfs": ["size": 3_780_000_000]]),
            3_780_000_000
        )
        XCTAssertEqual(
            HuggingFaceService.ggufFileSize(fromSibling: ["size": 123_456]),
            123_456
        )
        // `lfs` wins when both are present.
        XCTAssertEqual(
            HuggingFaceService.ggufFileSize(
                fromSibling: ["size": 1, "lfs": ["size": 999]]
            ),
            999
        )
        XCTAssertEqual(HuggingFaceService.ggufFileSize(fromSibling: [:]), 0)
    }

    @MainActor
    func testContentRangeTotalParsing() {
        XCTAssertEqual(
            LocalDownloadManager.totalBytes(fromContentRange: "bytes 0-1023/4096"),
            4096
        )
        XCTAssertEqual(
            LocalDownloadManager.totalBytes(fromContentRange: "bytes 1024-2047/4096"),
            4096
        )
        // Unsatisfied range: the total is still knowable.
        XCTAssertEqual(
            LocalDownloadManager.totalBytes(fromContentRange: "bytes */4096"),
            4096
        )
        // Unknown total, missing header, and junk all degrade to nil.
        XCTAssertNil(LocalDownloadManager.totalBytes(fromContentRange: "bytes 0-1023/*"))
        XCTAssertNil(LocalDownloadManager.totalBytes(fromContentRange: nil))
        XCTAssertNil(LocalDownloadManager.totalBytes(fromContentRange: "4096"))
        XCTAssertNil(LocalDownloadManager.totalBytes(fromContentRange: "bytes 0-1023/"))
    }

    /// The parser must take architecture, context and depth from the file, not
    /// from constants or the name (§7.4).
    func testGgufParserReadsMetadataFromTheFile() throws {
        var data = Data()
        data.append(contentsOf: [0x47, 0x47, 0x55, 0x46]) // "GGUF"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(3).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt64(0).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt64(4).littleEndian) { Array($0) })

        func putString(_ value: String) {
            data.append(contentsOf: withUnsafeBytes(of: UInt64(value.utf8.count).littleEndian) { Array($0) })
            data.append(contentsOf: Array(value.utf8))
        }
        func putU32(_ key: String, _ value: UInt32) {
            putString(key)
            data.append(contentsOf: withUnsafeBytes(of: UInt32(4).littleEndian) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }

        putString("general.architecture")
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8).littleEndian) { Array($0) })
        putString("qwen2")
        putU32("qwen2.context_length", 32768)
        putU32("qwen2.block_count", 28)
        putU32("general.file_type", 15) // Q4_K_M

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-test-\(UUID().uuidString)-NAME-LIES-Q8_0.gguf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try GgufMetadataReader.read(from: url)
        XCTAssertEqual(info.architecture, "qwen2")
        XCTAssertEqual(info.contextLength, 32768)
        XCTAssertEqual(info.blockCount, 28)
        XCTAssertEqual(info.effectiveLayerCount, 28)
        // From general.file_type, not from the misleading file name.
        XCTAssertEqual(info.quantization, "Q4_K_M")
    }

    func testGgufParserRejectsForeignFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-bad-\(UUID().uuidString).gguf")
        try Data("NOTG".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GgufMetadataReader.read(from: url))
    }

    /// A pasted Hugging Face link must resolve to `owner/repo`.
    func testRepositoryIDParsesLinksAndIdentifiers() {
        XCTAssertEqual(
            HuggingFaceService.repositoryID(from: "https://huggingface.co/Qwen/Qwen3.5-2B-GGUF"),
            "Qwen/Qwen3.5-2B-GGUF"
        )
        XCTAssertEqual(
            HuggingFaceService.repositoryID(from: "https://huggingface.co/Qwen/Qwen3.5-2B-GGUF/tree/main"),
            "Qwen/Qwen3.5-2B-GGUF"
        )
        XCTAssertEqual(HuggingFaceService.repositoryID(from: "Qwen/Qwen3.5-2B-GGUF"), "Qwen/Qwen3.5-2B-GGUF")
        XCTAssertNil(HuggingFaceService.repositoryID(from: "just-a-search-term"))
        XCTAssertNil(HuggingFaceService.repositoryID(from: ""))
    }

    /// Streaming SHA-256 must match a known digest.
    func testSHA256MatchesKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-sha-\(UUID().uuidString).bin")
        // SHA-256 of "abc".
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = LocalDownloadManager.sha256Hex(of: url)
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Metrics parsing keeps missing values at zero instead of inventing them.
    func testInferenceMetricsDefaultsAreZero() {
        let metrics = LocalInferenceService.InferenceMetrics()
        XCTAssertEqual(metrics.promptTokens, 0)
        XCTAssertEqual(metrics.predictedTokens, 0)
        XCTAssertEqual(metrics.promptPerSecond, 0)
        XCTAssertEqual(metrics.predictedPerSecond, 0)
    }

    /// Every UI string used through L() must have a Russian translation.
    func testAllLocalizedStringsResolve() {
        let keys = L10n.ru.keys
        XCTAssertFalse(keys.isEmpty)
        for key in ["Copy API Model ID", "Load more", "Verified", "Bundled", "Generation"] {
            XCTAssertNotNil(L10n.ru[key], "missing translation for \(key)")
        }
    }

    /// Markdown must become real blocks: headings, bullets, code, emphasis.
    func testMarkdownBlockParsing() {
        let source = """
        ### Возможности
        Я — **Qwen3.5**, умею:
        - контекст до **256K**
        - код на `Python`
        1. первый
        2. второй
        ```
        let x = 1
        ```
        """
        let blocks = MarkdownText.parse(source)
        XCTAssertTrue(blocks.contains { if case .heading(let level, _) = $0 { return level == 3 }; return false })
        XCTAssertTrue(blocks.contains { if case .bullet(let text, _) = $0 { return text.contains("контекст"); return false }; return false })
        XCTAssertTrue(blocks.contains { if case .numbered = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .code(let code) = $0 { return code.contains("let x"); return false }; return false })
    }

    /// Literal asterisks and hashes must not survive as visible markup.
    func testMarkdownDoesNotLeakRawMarkup() {
        let blocks = MarkdownText.parse("### **Заголовок**\n- **Пункт**")
        let rendered = blocks.map { block -> String in
            switch block {
            case .heading(_, let text): return text
            case .bullet(let text, _): return text
            case .paragraph(let text): return text
            default: return ""
            }
        }.joined(separator: " ")
        XCTAssertFalse(rendered.contains("###"))
        XCTAssertTrue(rendered.contains("Заголовок"))
        XCTAssertTrue(rendered.contains("Пункт"))
    }

    /// Split GGUF names must resolve to base, index and total.
    func testShardNameParsing() {
        let first = LocalModelStore.shardInfo(for: "Qwen3.5-2B-Q4_K_M-00001-of-00003.gguf")
        XCTAssertEqual(first?.base, "Qwen3.5-2B-Q4_K_M")
        XCTAssertEqual(first?.index, 1)
        XCTAssertEqual(first?.total, 3)

        let last = LocalModelStore.shardInfo(for: "Qwen3.5-2B-Q4_K_M-00003-of-00003.gguf")
        XCTAssertEqual(last?.index, 3)

        // A plain model is not a shard.
        XCTAssertNil(LocalModelStore.shardInfo(for: "Qwen3.5-2B-BF16.gguf"))
        // A dashes-heavy name without the marker is not a shard either.
        XCTAssertNil(LocalModelStore.shardInfo(for: "my-model-2024.gguf"))
    }

    /// The manifest shape must round-trip and match the file written by the
    /// runtime fetch script (§13.3).
    func testRuntimeManifestDecodesFetchedFormat() throws {
        let json = """
        {
          "id": "metal-macos-arm64-b12099",
          "backend": "metal",
          "platform": "macos-arm64",
          "build": "b12099",
          "version": "0.8.0-dev",
          "sha256": "6ee74e226e931c63d32b9da160d4102427b6b98c194726f46e8c31e91976a88c",
          "cpu_extensions": [],
          "size_bytes": 83099648,
          "bundled": true
        }
        """
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.backend, "metal")
        XCTAssertEqual(manifest.build, "b12099")
        XCTAssertTrue(manifest.isBundled)
        XCTAssertEqual(manifest.sizeBytes, 83_099_648)
    }

    /// A digest helper is shared by the download manager and the runtime store.
    func testRuntimeDigestMatchesKnownValue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-rt-\(UUID().uuidString).bin")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            RuntimeStore.sha256Hex(of: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// The router preset must carry the saved per-model values, otherwise the
    /// engine keeps running with the previous context and KV type.
    func testPresetCarriesSavedSettings() throws {
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent("preset-\(UUID().uuidString).gguf")
        // The builder only checks existence, so an empty file is enough.
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var settings = LocalModelSettings.defaultSettings(forContext: 32768)
        settings.contextLength = 32768
        settings.kvCacheType = "q4_0"
        settings.reasoningEnabled = false
        settings.gpuOffloadLayers = 999

        let model = LocalModel(
            id: "local/test-preset",
            displayName: "Test",
            provider: "Local AI",
            source: "import",
            repoId: nil,
            revision: nil,
            files: [file.lastPathComponent],
            fileSize: 0,
            quantization: "Q4_K_M",
            format: "GGUF",
            contextLength: 262144,
            configuredContext: 32768,
            blockCount: 24,
            architecture: "qwen35",
            backend: .metal,
            gpuOffload: 999,
            threads: 10,
            runtimeStatus: .installed,
            capabilities: [.text],
            installedAt: Date(),
            updatedAt: Date(),
            lastUsedAt: nil,
            license: nil,
            checksum: nil,
            userSettings: settings
        )

        let lines = LocalInferenceService.presetLines(
            models: [model],
            modelsDirectory: directory,
            backend: .metal,
            cpuCores: 10
        )
        let body = lines.joined(separator: "\n")

        XCTAssertTrue(body.contains("[local/test-preset]"))
        XCTAssertTrue(body.contains("ctx-size = 32768"))
        XCTAssertTrue(body.contains("cache-type-k = q4_0"))
        XCTAssertTrue(body.contains("reasoning = off"))
        XCTAssertTrue(body.contains("n-gpu-layers = 999"))
    }

    /// A CPU-only backend must not offload layers to the GPU.
    func testPresetDisablesGpuOffloadOnCpuBackend() throws {
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent("preset-cpu-\(UUID().uuidString).gguf")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let model = LocalModel(
            id: "local/cpu", displayName: "CPU", provider: "Local AI", source: "import",
            repoId: nil, revision: nil, files: [file.lastPathComponent], fileSize: 0,
            quantization: "Q4_K_M", format: "GGUF", contextLength: 8192, configuredContext: 8192,
            blockCount: 24, architecture: "qwen35", backend: .cpu, gpuOffload: nil, threads: nil,
            runtimeStatus: .installed, capabilities: [.text], installedAt: Date(), updatedAt: Date(),
            lastUsedAt: nil, license: nil, checksum: nil, userSettings: .defaultSettings()
        )

        let body = LocalInferenceService.presetLines(
            models: [model], modelsDirectory: directory, backend: .cpu, cpuCores: 8
        ).joined(separator: "\n")
        XCTAssertTrue(body.contains("n-gpu-layers = 0"))
    }

    // MARK: - Runtime package installation

    /// Identifiers and digests reach the filesystem and the network, so both
    /// must be constrained before any I/O happens.
    func testRuntimePackageValidationRejectsUnsafeIDsAndDigests() {
        XCTAssertTrue(RuntimePackageInstaller.validID("metal-macos-arm64-b12099"))
        XCTAssertFalse(RuntimePackageInstaller.validID(""))
        XCTAssertFalse(RuntimePackageInstaller.validID(".."))
        XCTAssertFalse(RuntimePackageInstaller.validID("a/b"))
        XCTAssertFalse(RuntimePackageInstaller.validID("a\\b"))
        XCTAssertFalse(RuntimePackageInstaller.validID(String(repeating: "a", count: 121)))

        let digest = String(repeating: "a", count: 64)
        XCTAssertTrue(RuntimePackageInstaller.validDigest(digest))
        XCTAssertTrue(RuntimePackageInstaller.validDigest(String(repeating: "F", count: 64)))
        XCTAssertFalse(RuntimePackageInstaller.validDigest(""))
        XCTAssertFalse(RuntimePackageInstaller.validDigest(String(repeating: "a", count: 63)))
        XCTAssertFalse(RuntimePackageInstaller.validDigest(String(repeating: "g", count: 64)))
        XCTAssertFalse(RuntimePackageInstaller.validDigest("../../etc/passwd"))
    }

    /// A package that links to the filesystem outside its folder must not be
    /// imported; the check runs before anything is copied.
    func testRuntimeTreeRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-rt-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("secrets")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("llama-server"), withDestinationURL: target
        )
        XCTAssertThrowsError(try RuntimePackageInstaller.inspectTree(root))
    }

    /// A wrong archive digest aborts before extraction and never touches the
    /// installed runtimes.
    func testRuntimeArchiveDigestMismatchLeavesInstallDirectoryUntouched() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-rt-archive-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let archive = base.appendingPathComponent("runtime.tar.gz")
        try Data("not really a tar".utf8).write(to: archive)

        XCTAssertThrowsError(
            try RuntimePackageInstaller.installArchive(
                archive, expectedSHA256: String(repeating: "0", count: 64), into: root
            )
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    /// Successful folder installs are staged and published under the manifest
    /// id; a second package with the same id is refused instead of replacing
    /// the installed runtime.
    func testRuntimeFolderInstallStagesAndRefusesDuplicates() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-rt-install-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let root = base.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let binary = source.appendingPathComponent("llama-server")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        guard let digest = RuntimeStore.sha256Hex(of: binary) else {
            return XCTFail("cannot hash fixture binary")
        }

        #if arch(arm64)
        let platform = "macos-arm64"
        #else
        let platform = "macos-x64"
        #endif
        let manifest = RuntimeManifest(
            id: "cpu-test-runtime", backend: "cpu", platform: platform, build: "test",
            version: "test", sha256: digest, cpuExtensions: [], sizeBytes: 166_480,
            isBundled: false
        )
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("runtime.json"))

        let installed = try RuntimePackageInstaller.installFolder(source, into: root)
        XCTAssertEqual(installed.id, "cpu-test-runtime")
        XCTAssertFalse(installed.isBundled)
        let published = root.appendingPathComponent("cpu-test-runtime", isDirectory: true)
        XCTAssertEqual(
            RuntimeStore.sha256Hex(of: published.appendingPathComponent("llama-server")), digest
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".install-x").path)
        )
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(entries.filter { $0.hasPrefix(".") }, [])

        // Same id again must fail and keep the published bytes intact.
        XCTAssertThrowsError(try RuntimePackageInstaller.installFolder(source, into: root))
        XCTAssertEqual(
            RuntimeStore.sha256Hex(of: published.appendingPathComponent("llama-server")), digest
        )
    }

    /// `lipo -verify_arch arm64` fails on arm64e slices; the arch list must
    /// accept them instead of rejecting a runnable engine.
    func testRuntimeArchitectureCheckAcceptsNativeSlices() throws {
        let binary = URL(fileURLWithPath: "/bin/echo")
        #if arch(arm64)
        XCTAssertTrue(try RuntimePackageInstaller.supportsArchitecture(binary, "arm64"))
        #else
        XCTAssertTrue(try RuntimePackageInstaller.supportsArchitecture(binary, "x86_64"))
        #endif

        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-not-a-binary-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        XCTAssertThrowsError(try RuntimePackageInstaller.supportsArchitecture(text, "arm64"))
    }

    /// End-to-end archive install: a real `.tar.gz` is verified, extracted,
    /// validated and published; a package containing a symlink is rejected
    /// before extraction and leaves the runtime directory untouched.
    func testRuntimeArchiveInstallPublishesAndRejectsLinks() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-rt-tar-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("runtimes", isDirectory: true)
        let source = base.appendingPathComponent("metal-test-echo", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let binary = source.appendingPathComponent("llama-server")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        guard let binaryDigest = RuntimeStore.sha256Hex(of: binary) else {
            return XCTFail("cannot hash fixture binary")
        }
        #if arch(arm64)
        let platform = "macos-arm64"
        #else
        let platform = "macos-x64"
        #endif
        let manifest = RuntimeManifest(
            id: "metal-test-echo", backend: "metal", platform: platform, build: "test",
            version: "test", sha256: binaryDigest, cpuExtensions: [], sizeBytes: 166_480,
            isBundled: false
        )
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("runtime.json"))

        let archive = base.appendingPathComponent("runtime.tar.gz")
        try runTar(["-czf", archive.path, "-C", base.path, "metal-test-echo"])
        guard let archiveDigest = RuntimeStore.sha256Hex(of: archive) else {
            return XCTFail("cannot hash fixture archive")
        }
        let installed = try RuntimePackageInstaller.installArchive(
            archive, expectedSHA256: archiveDigest, into: root
        )
        XCTAssertEqual(installed.id, "metal-test-echo")
        XCTAssertEqual(
            RuntimeStore.sha256Hex(
                of: root.appendingPathComponent("metal-test-echo/llama-server")
            ),
            binaryDigest
        )

        // Archive with a symlink entry: rejected by the type listing.
        let linked = base.appendingPathComponent("metal-test-link", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try JSONEncoder().encode(
            RuntimeManifest(id: "metal-test-link", backend: "metal", platform: platform,
                            build: "test", version: "test", sha256: binaryDigest,
                            cpuExtensions: [], sizeBytes: 1, isBundled: false)
        ).write(to: linked.appendingPathComponent("runtime.json"))
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("llama-server"),
            withDestinationURL: URL(fileURLWithPath: "/bin/echo")
        )
        let linkedArchive = base.appendingPathComponent("linked.tar.gz")
        try runTar(["-czf", linkedArchive.path, "-C", base.path, "metal-test-link"])
        guard let linkedDigest = RuntimeStore.sha256Hex(of: linkedArchive) else {
            return XCTFail("cannot hash linked archive")
        }
        XCTAssertThrowsError(
            try RuntimePackageInstaller.installArchive(linkedArchive, expectedSHA256: linkedDigest, into: root)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["metal-test-echo"]
        )
    }

    private func runTar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "tar \(arguments) failed")
    }

    /// The selector must offer every KV cache type the pinned engine accepts,
    /// and the memory estimate must get cheaper as precision drops.
    func testKVCacheTypeCatalogAndEstimateOrdering() {
        XCTAssertEqual(LocalHardwareService.supportedKVCacheTypes, [
            "f32", "f16", "bf16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl",
        ])
        XCTAssertEqual(LocalHardwareService.kvCacheBytesPerElement("f16"), 2.0)
        XCTAssertEqual(LocalHardwareService.kvCacheBytesPerElement("bf16"), 2.0)
        XCTAssertEqual(LocalHardwareService.kvCacheBytesPerElement("q8_0"), 1.0625)
        XCTAssertEqual(LocalHardwareService.kvCacheBytesPerElement("q4_0"), 0.5625)
        XCTAssertEqual(LocalHardwareService.kvCacheBytesPerElement("IQ4_NL"), 0.5625)
        XCTAssertEqual(LocalHardwareService.kvCacheBytesPerElement("unknown"), 2.0)

        let f32 = LocalHardwareService.kvCacheBytesPerElement("f32")
        let f16 = LocalHardwareService.kvCacheBytesPerElement("f16")
        let q8 = LocalHardwareService.kvCacheBytesPerElement("q8_0")
        let q5 = LocalHardwareService.kvCacheBytesPerElement("q5_0")
        let q4 = LocalHardwareService.kvCacheBytesPerElement("q4_0")
        XCTAssertGreaterThan(f32, f16)
        XCTAssertGreaterThan(f16, q8)
        XCTAssertGreaterThan(q8, q5)
        XCTAssertGreaterThan(q5, q4)
    }

    /// The catalog must only offer releases with both macOS slices and a
    /// SHA-256 digest from the same GitHub response.
    func testRuntimeCatalogParsingFiltersIncompleteReleases() throws {
        let digest = String(repeating: "a", count: 64)
        let json = """
        [
          {
            "tag_name": "b999",
            "name": "b999",
            "published_at": "2026-11-01T10:00:00Z",
            "draft": false,
            "prerelease": false,
            "assets": [
              {"name": "llama-b999-bin-macos-arm64.tar.gz", "size": 16000000,
               "digest": "sha256:\(digest)",
               "browser_download_url": "https://github.com/ggml-org/llama.cpp/releases/download/b999/llama-b999-bin-macos-arm64.tar.gz"},
              {"name": "llama-b999-bin-macos-x64.tar.gz", "size": 12000000,
               "digest": "sha256:\(digest)",
               "browser_download_url": "https://github.com/ggml-org/llama.cpp/releases/download/b999/llama-b999-bin-macos-x64.tar.gz"}
            ]
          },
          {
            "tag_name": "b998",
            "name": "b998",
            "published_at": "2026-10-31T10:00:00Z",
            "draft": false,
            "prerelease": false,
            "assets": [
              {"name": "llama-b998-bin-macos-arm64.tar.gz", "size": 16000000,
               "digest": "sha256:\(digest)",
               "browser_download_url": "https://github.com/ggml-org/llama.cpp/releases/download/b998/llama-b998-bin-macos-arm64.tar.gz"},
              {"name": "llama-b998-bin-macos-x64.tar.gz", "size": 12000000,
               "digest": null,
               "browser_download_url": "https://github.com/ggml-org/llama.cpp/releases/download/b998/llama-b998-bin-macos-x64.tar.gz"}
            ]
          },
          {
            "tag_name": "b997",
            "name": "b997",
            "published_at": "2026-10-30T10:00:00Z",
            "draft": true,
            "prerelease": false,
            "assets": [
              {"name": "llama-b997-bin-macos-arm64.tar.gz", "size": 16000000,
               "digest": "sha256:\(digest)",
               "browser_download_url": "https://github.com/ggml-org/llama.cpp/releases/download/b997/llama-b997-bin-macos-arm64.tar.gz"},
              {"name": "llama-b997-bin-macos-x64.tar.gz", "size": 12000000,
               "digest": "sha256:\(digest)",
               "browser_download_url": "https://github.com/ggml-org/llama.cpp/releases/download/b997/llama-b997-bin-macos-x64.tar.gz"}
            ]
          }
        ]
        """
        let releases = try RuntimeCatalogService.parse(Data(json.utf8))
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.tag, "b999")
        XCTAssertEqual(releases.first?.totalBytes, 28_000_000)
        XCTAssertEqual(releases.first?.arm64.sha256, digest)
        XCTAssertEqual(releases.first?.x64.downloadURL.scheme, "https")
    }

    /// Opt-in end-to-end check of the runtime catalog: fetches a real release,
    /// downloads both slices, merges, validates and publishes into a temporary
    /// directory. Slow and network-dependent, so it only runs when
    /// MELON_RUNTIME_CATALOG_E2E=1 is set.
    func testRuntimeCatalogInstallEndToEnd() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MELON_RUNTIME_CATALOG_E2E"] == "1",
            "set MELON_RUNTIME_CATALOG_E2E=1 to run the network install"
        )
        let catalog = RuntimeCatalogService()
        await catalog.load(force: true)
        let release = try XCTUnwrap(catalog.releases.first, catalog.error ?? "no releases")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(directory: root)
        store.install(catalog: release)

        let deadline = Date().addingTimeInterval(300)
        while store.isInstalling && Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertFalse(store.isInstalling)
        XCTAssertNil(store.installError)
        let installed = store.runtimes.first { $0.build == release.tag }
        XCTAssertNotNil(installed, "catalog runtime was not published")
        if let installed {
            let binary = store.directory(for: installed).appendingPathComponent("llama-server")
            XCTAssertEqual(RuntimeStore.sha256Hex(of: binary), installed.sha256)
            try? store.delete(installed)
        }
    }

    // MARK: - System prompt relay

    private func chatBody(_ messages: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["model": "local/test", "messages": messages])
    }

    private func messages(from data: Data) -> [[String: Any]] {
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return object["messages"] as! [[String: Any]]
    }

    /// Most chat templates render only the first system message, so a prompt
    /// with no client system message has to become the leading one.
    func testSystemPromptLeadsWhenClientSendsNoSystemMessage() throws {
        let body = chatBody([["role": "user", "content": "hi"]])
        let merged = try XCTUnwrap(
            SystemPromptProxy.merge(prompt: "You are terse.", path: "/v1/chat/completions", body: body)
        )
        let result = messages(from: merged)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["role"] as? String, "system")
        XCTAssertEqual(result[0]["content"] as? String, "You are terse.")
        XCTAssertEqual(result[1]["role"] as? String, "user")
    }

    /// A client that already carries instructions keeps them: the stored prompt
    /// is merged into the same message instead of replacing or shadowing it.
    func testSystemPromptMergesIntoClientSystemMessage() throws {
        let body = chatBody([
            ["role": "system", "content": "Always answer in Russian."],
            ["role": "user", "content": "hi"],
        ])
        let merged = try XCTUnwrap(
            SystemPromptProxy.merge(prompt: "You are terse.", path: "/v1/chat/completions", body: body)
        )
        let result = messages(from: merged)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["content"] as? String, "You are terse.\n\nAlways answer in Russian.")
    }

    /// Content parts (vision) are not string content, so the prompt becomes a
    /// separate leading message and the parts survive untouched.
    func testSystemPromptKeepsContentParts() throws {
        let body = chatBody([["role": "system", "content": [["type": "text", "text": "rules"]]]])
        let merged = try XCTUnwrap(
            SystemPromptProxy.merge(prompt: "You are terse.", path: "/v1/chat/completions", body: body)
        )
        let result = messages(from: merged)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["role"] as? String, "system")
        XCTAssertEqual(result[0]["content"] as? String, "You are terse.")
        XCTAssertNotNil(result[1]["content"] as? [[String: Any]])
    }

    /// The Responses API carries the system prompt in `instructions`.
    func testSystemPromptFillsResponsesInstructions() throws {
        let withInstructions = try JSONSerialization.data(withJSONObject: [
            "model": "local/test",
            "instructions": "Be brief.",
            "input": "hi",
        ])
        let merged = try XCTUnwrap(
            SystemPromptProxy.merge(prompt: "You are terse.", path: "/v1/responses", body: withInstructions)
        )
        let object = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        XCTAssertEqual(object["instructions"] as? String, "You are terse.\n\nBe brief.")

        let without = try JSONSerialization.data(withJSONObject: ["model": "local/test", "input": "hi"])
        let filled = try XCTUnwrap(
            SystemPromptProxy.merge(prompt: "You are terse.", path: "/v1/responses", body: without)
        )
        let filledObject = try JSONSerialization.jsonObject(with: filled) as! [String: Any]
        XCTAssertEqual(filledObject["instructions"] as? String, "You are terse.")
    }

    /// Nothing to inject means the relay must forward the original bytes.
    func testSystemPromptSkipsEmptyPromptsAndForeignBodies() {
        let body = chatBody([["role": "user", "content": "hi"]])
        XCTAssertNil(SystemPromptProxy.merge(prompt: "   ", path: "/v1/chat/completions", body: body))
        XCTAssertNil(SystemPromptProxy.merge(prompt: "x", path: "/v1/models", body: body))
        XCTAssertNil(
            SystemPromptProxy.merge(
                prompt: "x",
                path: "/v1/chat/completions",
                body: Data(#"{"model":"local/test"}"#.utf8)
            )
        )
    }

    func testSystemPromptRewriteTargetsOnlyChatAndResponses() {
        XCTAssertTrue(SystemPromptProxy.isRewritable(path: "/v1/chat/completions?x=1"))
        XCTAssertTrue(SystemPromptProxy.isRewritable(path: "/v1/responses"))
        XCTAssertFalse(SystemPromptProxy.isRewritable(path: "/v1/models"))
        XCTAssertFalse(SystemPromptProxy.isRewritable(path: "/v1/completions"))
    }

    /// A model addressed by its `local/` alias must still resolve to the same
    /// registry entry, otherwise the prompt silently stops applying.
    func testSystemPromptLookupAcceptsLocalAlias() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            LocalPaths.baseOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        LocalPaths.baseOverride = root
        try FileManager.default.createDirectory(at: LocalPaths.metadata, withIntermediateDirectories: true)

        let json = """
        [{"id":"qwen-test","userSettings":{"systemPrompt":"You are terse.","contextLength":4096}}]
        """
        try Data(json.utf8).write(to: LocalPaths.registry)

        XCTAssertEqual(SystemPromptProxy.systemPrompt(for: "qwen-test"), "You are terse.")
        XCTAssertEqual(SystemPromptProxy.systemPrompt(for: "local/qwen-test"), "You are terse.")
        XCTAssertNil(SystemPromptProxy.systemPrompt(for: "other-model"))
    }

    /// End-to-end: a real socket, the relay in the middle and a fake router
    /// behind it. The unit tests cover the JSON; this covers the framing that
    /// they do not — header rewrite, Content-Length body and relay back.
    func testRelayInjectsPromptAndRelaysTheAnswer() throws {
        try withPromptRegistry("You are terse.") {
            let router = try XCTUnwrap(OneShotHTTPServer(chunked: false))
            SystemPromptProxy.shared.setUpstream(port: router.port)
            let relay = SystemPromptProxy.shared.start()
            XCTAssertGreaterThan(relay, 0)

            let body = #"{"model":"qwen-test","messages":[{"role":"user","content":"hi"}]}"#
            let response = sendHTTP(
                port: relay,
                method: "POST",
                path: "/v1/chat/completions",
                body: body
            )

            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertTrue(response.contains(#""content":"ok""#))
            XCTAssertTrue(response.lowercased().contains("connection: close\r\n"))

            XCTAssertTrue(router.waitUntilServed())
            let forwarded = try XCTUnwrap(router.receivedBody)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: forwarded) as? [String: Any]
            )
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.first?["role"] as? String, "system")
            XCTAssertEqual(messages.first?["content"] as? String, "You are terse.")
        }
    }

    /// Streaming answers arrive chunked; the relay has to keep the framing
    /// intact, otherwise clients hang waiting for a terminator that never came.
    func testRelayPassesChunkedResponsesThrough() throws {
        try withPromptRegistry("You are terse.") {
            let router = try XCTUnwrap(OneShotHTTPServer(chunked: true))
            SystemPromptProxy.shared.setUpstream(port: router.port)
            let relay = SystemPromptProxy.shared.start()
            XCTAssertGreaterThan(relay, 0)

            let response = sendHTTP(port: relay, method: "GET", path: "/v1/models", body: "")
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertTrue(response.contains(#""content":"ok""#))
            XCTAssertTrue(router.waitUntilServed())
        }
    }

    // MARK: - Relay test fixtures

    /// Points the registry at a temporary folder holding one model with a
    /// prompt, so the relay's lookup reads what the settings sheet would write.
    private func withPromptRegistry(_ prompt: String, _ body: () throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-relay-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        LocalPaths.baseOverride = root
        try? FileManager.default.createDirectory(at: LocalPaths.metadata, withIntermediateDirectories: true)
        let json = "[{\"id\":\"qwen-test\",\"userSettings\":{\"systemPrompt\":\"\(prompt)\",\"contextLength\":4096}}]"
        try? Data(json.utf8).write(to: LocalPaths.registry)
        defer {
            LocalPaths.baseOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        try body()
    }

    /// Sends one request straight to the relay and returns the raw answer.
    private func sendHTTP(port: UInt16, method: String, path: String, body: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return "" }

        let request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: keep-alive\r\n\r\n" + body
        var bytes = Array(request.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 { return "" }
            offset += written
        }

        var response = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            response.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: response, as: UTF8.self)
    }
}

/// Minimal one-shot HTTP server standing in for the llama.cpp router, so the
/// relay's request shaping and response framing are exercised without a model.
private final class OneShotHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let chunked: Bool
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedBody: Data?

    var receivedBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedBody
    }

    init?(chunked: Bool) {
        self.chunked = chunked
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length) == 0
            }
        }
        guard named else {
            close(fd)
            return nil
        }
        listenFD = fd
        port = UInt16(bigEndian: assigned.sin_port)
        Thread.detachNewThread { [weak self] in
            self?.serve()
        }
    }

    func waitUntilServed() -> Bool {
        finished.wait(timeout: .now() + 10) == .success
    }

    private func serve() {
        defer { finished.signal() }
        var clientAddress = sockaddr()
        var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
        let client = accept(listenFD, &clientAddress, &clientLength)
        guard client >= 0 else { return }
        defer { close(client) }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var expected = -1
        while true {
            if let end = headerEnd(in: buffer) {
                if expected < 0 {
                    let head = String(decoding: buffer[..<end], as: UTF8.self)
                    expected = Self.contentLength(in: head, headerBytes: end)
                }
                if expected >= 0, buffer.count - end >= expected {
                    let body = Data(buffer[end..<(end + expected)])
                    lock.lock()
                    storedBody = body
                    lock.unlock()
                    break
                }
            }
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
        }

        let payload = #"{"id":"x","choices":[{"message":{"role":"assistant","content":"ok"}}]}"#
        var response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        if chunked {
            response += "Transfer-Encoding: chunked\r\n\r\n"
            response += String(payload.utf8.count, radix: 16) + "\r\n" + payload + "\r\n0\r\n\r\n"
        } else {
            response += "Content-Length: \(payload.utf8.count)\r\n\r\n" + payload
        }
        var bytes = Array(response.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(client, base.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 { return }
            offset += written
        }
    }

    private func headerEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0..<(bytes.count - 3)
        where bytes[index] == 13 && bytes[index + 1] == 10
            && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index + 4
        }
        return nil
    }

    private static func contentLength(in head: String, headerBytes: Int) -> Int {
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}

import Foundation

/// Lifecycle states of a local model according to Technical Specification section 6.4.
enum ModelRuntimeStatus: String, Codable, CaseIterable {
    case notInstalled = "not_installed"
    case downloading = "downloading"
    case paused = "paused"
    case verifying = "verifying"
    case installed = "installed"
    case loading = "loading"
    case ready = "ready"
    case generating = "generating"
    case unloading = "unloading"
    case error = "error"
    case unsupported = "unsupported"

    var displayName: String {
        switch self {
        case .notInstalled: return "Not Installed"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .verifying: return "Verifying"
        case .installed: return "Installed"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .generating: return "Generating"
        case .unloading: return "Unloading"
        case .error: return "Error"
        case .unsupported: return "Unsupported"
        }
    }

    var isActionable: Bool {
        self == .installed || self == .ready || self == .error
    }

    /// States that describe a live engine, not a durable property of the model.
    /// Persisting them across launches is what left stale `ready` rows behind a
    /// crashed router, so they are normalised back to `installed` on bootstrap.
    var isTransient: Bool {
        switch self {
        case .loading, .ready, .generating, .unloading: return true
        default: return false
        }
    }
}

/// Model capabilities confirmed by metadata.
enum ModelCapability: String, Codable, CaseIterable, Identifiable {
    case text = "text"
    case tools = "tools"
    case vision = "vision"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .tools: return "Tool Calling"
        case .vision: return "Vision"
        }
    }
}

/// Configuration preset profile.
enum ModelConfigProfile: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case balanced = "Balanced"
    case performance = "Performance"
    case memorySaver = "Memory Saver"
    case custom = "Custom"

    var id: String { rawValue }
}

/// Per-model runtime parameters and generation settings.
struct LocalModelSettings: Codable, Equatable {
    var contextLength: Int
    var maxOutputTokens: Int?
    var temperature: Double
    var topP: Double
    var topK: Int
    var repeatPenalty: Double
    var seed: Int?
    var cpuThreads: Int?
    var gpuOffloadLayers: Int?
    var flashAttention: Bool
    var kvCacheType: String
    var batchSize: Int
    var chatTemplate: String?
    /// System prompt merged into every Chat Completions / Responses request the
    /// local gateway serves for this model. Optional so registries written
    /// before the field existed still decode; `nil` means none.
    var systemPrompt: String?
    var profile: ModelConfigProfile
    /// Thinking/reasoning pass. Optional so registries written before the flag
    /// existed still decode; `nil` means off.
    ///
    /// Off by default: small local models spend the whole token budget in the
    /// scratchpad and return an empty `content`, which reaches OpenAI clients
    /// as a blank answer.
    var reasoningEnabled: Bool?

    /// Effective reasoning switch.
    var isReasoningOn: Bool { reasoningEnabled ?? false }

    static func defaultSettings(forContext context: Int = 8192) -> LocalModelSettings {
        LocalModelSettings(
            contextLength: context,
            maxOutputTokens: 4096,
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            repeatPenalty: 1.1,
            seed: nil,
            cpuThreads: nil,
            gpuOffloadLayers: nil,
            flashAttention: true,
            kvCacheType: "f16",
            batchSize: 512,
            chatTemplate: nil,
            systemPrompt: nil,
            profile: .auto,
            reasoningEnabled: false
        )
    }
}

/// The GGUF fields the memory advisor needs, kept in the registry so a model
/// can be estimated without re-reading a multi-gigabyte header on every UI tick.
struct GgufMemoryProfile: Codable, Equatable {
    var embeddingLength: Int?
    var headCount: Int?
    /// KV heads per attention layer (the last value for per-layer metadata).
    var headCountKV: Int?
    var keyLength: Int?
    var valueLength: Int?
    var slidingWindow: Int?
    var fullAttentionInterval: Int?
    var ssmInnerSize: Int?
    var ssmStateSize: Int?
    var ssmConvKernel: Int?

    init?(info: GgufInfo) {
        guard info.embeddingLength != nil || info.headCount != nil || info.ssmInnerSize != nil else {
            return nil
        }
        embeddingLength = info.embeddingLength
        headCount = info.headCount
        headCountKV = info.headCountKV.max()
        keyLength = info.keyLength
        valueLength = info.valueLength
        slidingWindow = info.slidingWindow
        fullAttentionInterval = info.fullAttentionInterval
        ssmInnerSize = info.ssmInnerSize
        ssmStateSize = info.ssmStateSize
        ssmConvKernel = info.ssmConvKernel
    }

    /// Layers that keep a KV cache, out of `blockCount`.
    func attentionLayers(blockCount: Int) -> Int {
        let layers = max(1, blockCount)
        guard let interval = fullAttentionInterval, interval > 1 else { return layers }
        return max(1, Int((Double(layers) / Double(interval)).rounded(.up)))
    }

    /// Head dimension of K and V. Falls back to `embedding_length / head_count`,
    /// which is what almost every GQA model uses.
    var headDimensions: (key: Int, value: Int)? {
        if let keyLength, let valueLength, keyLength > 0, valueLength > 0 {
            return (keyLength, valueLength)
        }
        if let keyLength, keyLength > 0 { return (keyLength, keyLength) }
        if let embeddingLength, let headCount, headCount > 0, embeddingLength > 0 {
            let dim = embeddingLength / headCount
            return dim > 0 ? (dim, dim) : nil
        }
        return nil
    }
}

/// A registered local GGUF model.
struct LocalModel: Identifiable, Codable, Equatable {
    var id: String // e.g. "local/qwen2.5-1.5b-instruct"
    var displayName: String
    var provider: String
    var source: String // "huggingface", "import", "custom"
    var repoId: String?
    var revision: String?
    var files: [String] // relative file name(s) in models directory or absolute path
    var fileSize: UInt64
    var quantization: String
    var format: String // "GGUF"
    var contextLength: Int
    var configuredContext: Int
    /// Transformer depth from `*.block_count` in the GGUF metadata. Optional so
    /// registries written before the parser existed still decode.
    var blockCount: Int?
    /// `general.architecture`, e.g. "qwen2".
    var architecture: String?
    /// KV/attention shape from the GGUF header, used by the memory advisor.
    var memoryProfile: GgufMemoryProfile?
    var backend: InferenceBackend
    var gpuOffload: Int?
    var threads: Int?
    var runtimeStatus: ModelRuntimeStatus
    var capabilities: [ModelCapability]
    var installedAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var license: String?
    var checksum: String?
    var userSettings: LocalModelSettings
    /// Download job that produced these files. A publication interrupted by a
    /// crash is then recognised by identity instead of by file name, which
    /// cannot tell two revisions of one repository apart. Older registries
    /// decode without it.
    var downloadJobID: UUID? = nil
    /// Legacy array registries omit this field; future writers can prevent an
    /// older app from discarding fields it does not understand.
    var schemaVersion: Int? = PersistenceSchema.current

    var isSingleFile: Bool {
        files.count == 1
    }

    var primaryFileName: String {
        files.first ?? "\(id).gguf"
    }

    /// True if the model file is accessible on disk.
    func fileExists(in directory: URL) -> Bool {
        for file in files {
            let path = file.hasPrefix("/") ? URL(fileURLWithPath: file) : directory.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: path.path) {
                return false
            }
        }
        return !files.isEmpty
    }

    /// Resolves absolute URL for the primary model file.
    func primaryFileURL(in directory: URL) -> URL {
        if let first = files.first, first.hasPrefix("/") {
            return URL(fileURLWithPath: first)
        }
        return directory.appendingPathComponent(primaryFileName)
    }

    /// Absolute URLs of every file of this model, in declaration order.
    func fileURLs(in directory: URL) -> [URL] {
        files.map { file in
            file.hasPrefix("/") ? URL(fileURLWithPath: file) : directory.appendingPathComponent(file)
        }
    }

    /// Context the engine actually gives one parallel slot.
    ///
    /// `llama-server` splits `--ctx-size` between `--parallel` slots, so a model
    /// configured at 8192 with 4 slots serves 2048 per request. Advertising the
    /// configured number instead was what made Codex overflow in the middle of a
    /// conversation.
    func effectiveContext(parallelSlots: Int) -> Int {
        let configured = max(1, min(userSettings.contextLength, max(contextLength, 1)))
        let slots = max(1, parallelSlots)
        return max(1, configured / slots)
    }

    /// Native maximum from the GGUF header, independent of the working context.
    var nativeContextLength: Int {
        max(contextLength, configuredContext, userSettings.contextLength)
    }
}

extension LocalModel {
    /// Directory this model owns, when its files were published into a
    /// per-model namespace. Deleting the namespace removes every part of a split
    /// model, and the name pattern check keeps unrelated folders untouched.
    func ownedNamespaceDirectory(in root: URL) -> URL? {
        let relatives = files.filter { !$0.hasPrefix("/") }
        guard !relatives.isEmpty else { return nil }
        let parents = relatives.map { file -> String in
            let parts = file.split(separator: "/").dropLast()
            return parts.joined(separator: "/")
        }
        guard let first = parents.first, !first.isEmpty, parents.allSatisfy({ $0 == first }) else {
            return nil
        }
        guard !first.contains("..") else { return nil }
        let url = root.appendingPathComponent(first, isDirectory: true)
        let name = url.lastPathComponent
        guard name.range(of: #"^[a-z0-9._-]+-[0-9a-f]{8}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return url
    }
}

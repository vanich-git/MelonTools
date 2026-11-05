import Foundation
import Metal

/// Hardware acceleration backend supported by local inference runtimes.
enum InferenceBackend: String, Codable, CaseIterable, Identifiable {
    case metal = "Metal"
    case cuda = "CUDA"
    case vulkan = "Vulkan"
    case cpu = "CPU"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .metal: return "Apple Metal"
        case .cuda: return "NVIDIA CUDA"
        case .vulkan: return "Vulkan"
        case .cpu: return "CPU Fallback"
        }
    }
}

/// Evaluation of whether a model fits in system/GPU memory.
enum CompatibilityRecommendation: String, Codable {
    case recommended = "Recommended"
    case fitsWithLimitations = "Fits with limitations"
    case highMemoryUsage = "High memory usage"
    case insufficientMemory = "Insufficient memory"
    case unsupportedArchitecture = "Unsupported architecture"
    case unknown = "Unknown compatibility"
}

/// How much the estimate can be trusted, derived from what the GGUF header
/// actually told us. The old advisor always looked equally certain.
enum EstimationConfidence: String, Codable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
}

/// Detailed memory estimation for a model configuration.
///
/// Every component is reported separately (weights / KV / recurrent state /
/// compute buffers / OS reserve) and as a range, because a point figure derived
/// from a heuristic invited decisions the data did not support.
struct MemoryEstimation: Codable, Equatable {
    let weightsSize: UInt64
    let kvCacheSize: UInt64
    let kvCacheLow: UInt64
    let kvCacheHigh: UInt64
    /// Recurrent/SSM state of hybrid models, which have little or no KV cache.
    let stateCacheSize: UInt64
    let computeBuffers: UInt64
    let osReserve: UInt64
    let totalRequired: UInt64
    let totalLow: UInt64
    let totalHigh: UInt64
    let recommendation: CompatibilityRecommendation
    let confidence: EstimationConfidence
    let warning: String?
    /// What the numbers were derived from, shown in the UI instead of a bare GB.
    let assumptions: [String]

    /// True when the range is wide enough that the point value should not be
    /// quoted as a promise.
    var isRangeWide: Bool {
        totalHigh > totalLow + (totalLow / 10)
    }
}

/// Complete hardware information snapshot for local AI runtime.
struct HardwareInfo: Codable, Equatable {
    let osVersion: String
    let architecture: String
    let cpuModel: String
    let cpuCores: Int
    let totalRAM: UInt64
    let freeRAM: UInt64
    let gpuName: String?
    let gpuHasUnifiedMemory: Bool
    /// Human-readable driver/build string. On macOS the GPU driver ships with
    /// the OS, so this reports the Metal stack and the system version; on
    /// Windows it is the real driver version from the vendor API (§13.1).
    let gpuDriver: String?
    let gpuRecommendedMaxWorkingSetSize: UInt64?
    let supportedBackends: [InferenceBackend]
    let recommendedBackend: InferenceBackend
    let modelsDiskFreeSpace: UInt64
    let modelsDiskTotalSpace: UInt64
}

/// Discovers host hardware capabilities: RAM, Metal GPU, Unified Memory, disk space, and memory requirements.
@MainActor
final class LocalHardwareService: ObservableObject {
    static let shared = LocalHardwareService()

    @Published private(set) var hardwareInfo: HardwareInfo

    private init() {
        self.hardwareInfo = Self.detectHardware(modelsDirectory: nil)
    }

    /// Refresh hardware detection, optionally providing the active models directory.
    func refresh(modelsDirectory: URL? = nil) {
        self.hardwareInfo = Self.detectHardware(modelsDirectory: modelsDirectory)
    }

    /// Estimate memory needed to load and run a model.
    ///
    /// `profile` is the KV/attention shape read from the GGUF header; when it is
    /// missing the estimate falls back to a heuristic and says so through
    /// `confidence`, instead of pretending the guess is exact.
    func estimateMemory(
        weightsSize: UInt64,
        contextLength: Int = 8192,
        kvCacheType: String = "f16",
        batchSize: Int = 512,
        gpuLayers: Int? = nil,
        totalLayers: Int = 32,
        profile: GgufMemoryProfile? = nil,
        slots: Int = 1,
        backend: InferenceBackend? = nil
    ) -> MemoryEstimation {
        Self.calculateMemoryEstimation(
            info: hardwareInfo,
            weightsSize: weightsSize,
            contextLength: contextLength,
            kvCacheType: kvCacheType,
            batchSize: batchSize,
            gpuLayers: gpuLayers,
            totalLayers: totalLayers,
            profile: profile,
            slots: slots,
            backend: backend ?? hardwareInfo.recommendedBackend
        )
    }

    /// Estimate for a registered model with its saved settings.
    func estimateMemory(for model: LocalModel) -> MemoryEstimation {
        estimateMemory(
            weightsSize: model.fileSize,
            contextLength: model.userSettings.contextLength,
            kvCacheType: model.userSettings.kvCacheType,
            batchSize: model.userSettings.batchSize,
            gpuLayers: model.userSettings.gpuOffloadLayers,
            totalLayers: model.blockCount ?? 32,
            profile: model.memoryProfile,
            slots: LocalInferenceService.parallelRequests,
            backend: model.backend
        )
    }

    // MARK: - Detection Logic

    nonisolated static func detectHardware(modelsDirectory: URL? = nil) -> HardwareInfo {
        let osVersion = "\(ProcessInfo.processInfo.operatingSystemVersionString)"
        let cpuCores = ProcessInfo.processInfo.activeProcessorCount
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let freeRAM = getFreeMemoryBytes()

        let arch = getCpuArchitecture()
        let cpuModel = getCpuBrandString()

        // Metal detection
        let device = MTLCreateSystemDefaultDevice()
        let gpuName = device?.name
        // There is no separate GPU driver on macOS: Metal is part of the OS.
        let osSemver = ProcessInfo.processInfo.operatingSystemVersion
        let gpuDriver = device == nil
            ? nil
            : "Metal · macOS \(osSemver.majorVersion).\(osSemver.minorVersion).\(osSemver.patchVersion)"
        let gpuHasUnifiedMemory = device?.hasUnifiedMemory ?? false
        let gpuRecommendedMaxWorkingSetSize = device?.recommendedMaxWorkingSetSize

        var supportedBackends: [InferenceBackend] = []
        if device != nil {
            supportedBackends.append(.metal)
        }
        supportedBackends.append(.cpu)

        let recommendedBackend: InferenceBackend = (device != nil) ? .metal : .cpu

        // Disk space for models directory
        let targetDir = modelsDirectory ?? defaultModelsDirectory
        let (diskFree, diskTotal) = getDiskSpace(for: targetDir)

        return HardwareInfo(
            osVersion: osVersion,
            architecture: arch,
            cpuModel: cpuModel,
            cpuCores: cpuCores,
            totalRAM: totalRAM,
            freeRAM: freeRAM,
            gpuName: gpuName,
            gpuHasUnifiedMemory: gpuHasUnifiedMemory,
            gpuDriver: gpuDriver,
            gpuRecommendedMaxWorkingSetSize: gpuRecommendedMaxWorkingSetSize,
            supportedBackends: supportedBackends,
            recommendedBackend: recommendedBackend,
            modelsDiskFreeSpace: diskFree,
            modelsDiskTotalSpace: diskTotal
        )
    }

    nonisolated static var defaultModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MelonTools", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static func getDiskSpace(for directory: URL) -> (free: UInt64, total: UInt64) {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            return (free, total)
        } catch {
            return (0, 0)
        }
    }

    nonisolated static func getCpuArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    nonisolated static func getCpuBrandString() -> String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else {
            #if arch(arm64)
            return "Apple Silicon"
            #else
            return "Intel CPU"
            #endif
        }
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        return String(cString: brand).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func getFreeMemoryBytes() -> UInt64 {
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()

        let kerr = withUnsafeMutablePointer(to: &vmStat) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            return 0
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let freePages = UInt64(vmStat.free_count)
        let inactivePages = UInt64(vmStat.inactive_count)
        return (freePages + inactivePages) * pageSize
    }

    // MARK: - Memory Calculation

    /// Every KV cache type accepted by `llama-server -ctk/-ctv` (b12099).
    static let supportedKVCacheTypes = [
        "f32", "f16", "bf16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl",
    ]

    /// Bytes per element, including the per-block scale for quantized types.
    nonisolated static func kvCacheBytesPerElement(_ type: String) -> Double {
        switch type.lowercased() {
        case "f32": return 4.0
        case "bf16": return 2.0
        case "q8_0": return 1.0625
        case "q5_1": return 0.75
        case "q5_0": return 0.6875
        case "q4_1": return 0.625
        case "q4_0", "iq4_nl": return 0.5625
        default: return 2.0 // f16
        }
    }

    nonisolated static func calculateMemoryEstimation(
        info: HardwareInfo,
        weightsSize: UInt64,
        contextLength: Int,
        kvCacheType: String,
        batchSize: Int,
        gpuLayers: Int?,
        totalLayers: Int,
        profile: GgufMemoryProfile? = nil,
        slots: Int = 1,
        backend: InferenceBackend = .metal
    ) -> MemoryEstimation {
        let bytesPerElement = kvCacheBytesPerElement(kvCacheType)
        let layers = max(1, totalLayers)
        let parallelSlots = max(1, slots)
        // `--parallel` splits one context window between slots, so the KV cache
        // holds `context / slots` tokens per request, not `context` per slot.
        let tokensPerSlot = max(1, contextLength / parallelSlots)

        var assumptions: [String] = []
        var confidence: EstimationConfidence = .low

        // Attention shape: heads and head dimensions from the file when present.
        let attentionLayers = profile?.attentionLayers(blockCount: layers) ?? layers
        let dimensions = profile?.headDimensions
        let kvHeads: Int
        if let profileHeads = profile?.headCountKV, profileHeads > 0 {
            kvHeads = profileHeads
        } else if let heads = profile?.headCount, heads > 0 {
            kvHeads = heads
        } else if let embedding = profile?.embeddingLength, embedding > 0 {
            // Conservative fallback: no GQA metadata means every head may keep
            // its own K/V, which over-estimates rather than under-estimates.
            kvHeads = max(1, embedding / 128)
        } else {
            kvHeads = 32
        }

        let embeddingFallback: Int
        if let embedding = profile?.embeddingLength, embedding > 0 {
            embeddingFallback = embedding
        } else if weightsSize < 2_500_000_000 {
            embeddingFallback = 2048
        } else if weightsSize < 6_000_000_000 {
            embeddingFallback = 4096
        } else {
            embeddingFallback = 5120
        }

        let headDim: (key: Int, value: Int)
        if let dimensions {
            headDim = dimensions
        } else {
            let dim = max(1, embeddingFallback / max(1, profile?.headCount ?? 32))
            headDim = (dim, dim)
            assumptions.append(L("Head dimensions were not in the GGUF metadata; derived from embedding size."))
        }

        if profile?.headCountKV != nil, dimensions != nil, profile?.fullAttentionInterval != nil {
            confidence = .high
        } else if profile?.headCountKV != nil, dimensions != nil {
            confidence = .high
        } else if profile != nil {
            confidence = .medium
        } else {
            assumptions.append(L("No GGUF shape metadata: KV size is a heuristic, not a measurement."))
        }

        if profile?.headCountKV == nil {
            assumptions.append(L("KV heads were not in the GGUF metadata; assuming one K/V per attention head."))
        }

        // KV: full-attention layers keep the whole window. Hybrid models keep a
        // shorter window on sliding layers and a fixed recurrent state on the
        // layers that have no attention at all.
        let fullLayers: Int
        let slidingLayers: Int
        if let interval = profile?.fullAttentionInterval, interval > 1 {
            fullLayers = max(1, Int((Double(layers) / Double(interval)).rounded(.up)))
            slidingLayers = max(0, layers - fullLayers)
            assumptions.append(String(
                format: L("Hybrid attention: %d of %d layers keep a KV cache."),
                fullLayers, layers
            ))
            if confidence == .low { confidence = .medium }
        } else {
            fullLayers = attentionLayers
            slidingLayers = max(0, layers - attentionLayers)
        }

        let bytesPerToken = Double(headDim.key + headDim.value) * Double(kvHeads) * bytesPerElement
        var kvBytes = bytesPerToken * Double(tokensPerSlot) * Double(fullLayers)
        if slidingLayers > 0, let window = profile?.slidingWindow, window > 0 {
            let windowTokens = Double(min(window, tokensPerSlot))
            kvBytes += bytesPerToken * windowTokens * Double(slidingLayers)
            assumptions.append(String(
                format: L("Sliding-window layers keep at most %d tokens."), window
            ))
        }

        // Recurrent (Mamba/DeltaNet) state: per layer, a convolution state and a
        // recurrent state of `inner_size × state_size` floats.
        var stateBytes: UInt64 = 0
        let recurrentLayers = max(0, layers - fullLayers)
        if recurrentLayers > 0, let inner = profile?.ssmInnerSize, inner > 0 {
            let kernel = max(1, profile?.ssmConvKernel ?? 4)
            let state = max(1, profile?.ssmStateSize ?? 128)
            let perLayer = UInt64(kernel) * UInt64(inner) * 4
                + UInt64(inner) * UInt64(state) * 4
            stateBytes = perLayer * UInt64(recurrentLayers)
            assumptions.append(L("Recurrent-layer state is an estimate: the engine's allocator is not queried."))
            if confidence == .high { confidence = .medium }
        }

        let kvCacheBytes = UInt64(kvBytes)
        let kvLow = UInt64(kvBytes * 0.85)
        let kvHigh = UInt64(kvBytes * 1.20) + 64 * 1024 * 1024

        // Compute buffers scale with the batch and the hidden size, not with the
        // context: the old `batchSize * 1 MB` was unrelated to either.
        let batch = max(1, batchSize)
        let computePerToken = Double(embeddingFallback) * 4.0 * 3.0
        let computeBuffers = max(256 * 1024 * 1024, UInt64(computePerToken * Double(batch)))
        let osReserve: UInt64 = max(2 * 1024 * 1024 * 1024, UInt64(Double(info.totalRAM) * 0.15))

        let base = weightsSize + computeBuffers + osReserve
        let totalRequired = base + kvCacheBytes + stateBytes
        let totalLow = base + kvLow + UInt64(Double(stateBytes) * 0.8)
        let totalHigh = base + kvHigh + UInt64(Double(stateBytes) * 1.5)

        // Offload decides which budget matters: a CPU-only model is limited by
        // RAM, an offloaded one by the GPU working set. Ignoring `gpuLayers` made
        // "0 layers on GPU" look like a GPU memory question.
        let offloadsToGPU = backend != .cpu && (gpuLayers ?? 99) > 0
        let availableMemory: UInt64
        if offloadsToGPU, info.gpuHasUnifiedMemory,
           let maxWorkingSet = info.gpuRecommendedMaxWorkingSetSize, maxWorkingSet > 0 {
            availableMemory = maxWorkingSet
        } else {
            availableMemory = info.totalRAM
        }

        if !offloadsToGPU {
            assumptions.append(L("CPU-only inference: no GPU working set is used."))
        }

        var recommendation: CompatibilityRecommendation
        var warning: String? = nil

        // RAM exhaustion is checked first: a large model on an Intel Mac is not
        // "fits with limitations" when the weights alone exceed physical memory.
        if totalLow > info.totalRAM {
            recommendation = .insufficientMemory
            warning = String(
                format: L("Even the low estimate (%@) exceeds physical RAM (%@)."),
                formatBytes(totalLow), formatBytes(info.totalRAM)
            )
        } else if totalRequired > info.totalRAM {
            recommendation = .highMemoryUsage
            warning = String(
                format: L("Total estimated memory (%@) may exceed physical RAM (%@)."),
                formatBytes(totalRequired), formatBytes(info.totalRAM)
            )
        } else if totalHigh > availableMemory {
            recommendation = .highMemoryUsage
            warning = String(
                format: L("High memory usage: up to %@ of the %@ budget may be needed."),
                formatBytes(totalHigh), formatBytes(availableMemory)
            )
        } else if totalHigh > (availableMemory * 85 / 100) {
            recommendation = .fitsWithLimitations
            warning = L("Model fits, but context length or offload may need adjustment under heavy system load.")
        } else {
            recommendation = .recommended
        }

        if confidence == .low, recommendation == .insufficientMemory {
            // Do not turn a guess into a verdict: keep the warning, but the UI
            // presents the number as an estimate.
            warning = (warning ?? "") + " " + L("The estimate is uncertain because the GGUF metadata is incomplete.")
        }

        return MemoryEstimation(
            weightsSize: weightsSize,
            kvCacheSize: kvCacheBytes,
            kvCacheLow: kvLow,
            kvCacheHigh: kvHigh,
            stateCacheSize: stateBytes,
            computeBuffers: computeBuffers,
            osReserve: osReserve,
            totalRequired: totalRequired,
            totalLow: totalLow,
            totalHigh: totalHigh,
            recommendation: recommendation,
            confidence: confidence,
            warning: warning,
            assumptions: assumptions
        )
    }

    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

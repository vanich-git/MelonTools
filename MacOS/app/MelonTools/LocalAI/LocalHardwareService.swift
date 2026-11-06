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
    var ramRequired: UInt64? = nil
    var gpuRequired: UInt64? = nil
    var gpuBudget: UInt64? = nil

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
        backend: InferenceBackend? = nil,
        flashAttention: Bool = true
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
            backend: backend ?? hardwareInfo.recommendedBackend,
            flashAttention: flashAttention
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
            backend: model.backend,
            flashAttention: model.userSettings.flashAttention
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
        backend: InferenceBackend = .metal,
        flashAttention: Bool = true
    ) -> MemoryEstimation {
        let bytesPerElement = kvCacheBytesPerElement(kvCacheType)
        let layers = max(1, totalLayers)
        let parallelSlots = max(1, slots)
        // --ctx-size is the TOTAL KV capacity, shared across parallel slots.
        let totalTokens = max(1, contextLength)

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

        // Metadata can describe KV geometry, never the engine allocator's total.
        if profile?.headCountKV != nil, dimensions != nil, profile?.blockCount != nil {
            confidence = .medium
        } else {
            assumptions.append(L("No complete GGUF shape metadata: KV size is a heuristic, not a measurement."))
        }
        if profile?.headCountKV == nil {
            assumptions.append(L("KV heads were not in the GGUF metadata; assuming one K/V per attention head."))
        }

        let hasRecurrentState = profile?.ssmInnerSize != nil
        let interval = max(1, profile?.fullAttentionInterval ?? 1)
        let perLayerHeads = profile?.headCountKVByLayer
        let hasLayerShape = perLayerHeads?.count == layers
        // full_attention_interval also occurs in SWA models: it does NOT imply
        // that the other layers are recurrent. Keep full KV unless SSM says so.
        let fullLayers = hasRecurrentState && interval > 1 ? layers / interval : attentionLayers
        func rowBytes(_ width: Int) -> Double {
            let quantized = kvCacheType.lowercased().hasPrefix("q") || kvCacheType.lowercased() == "iq4_nl"
            return quantized ? ceil(Double(width) / 32) * 32 * bytesPerElement : Double(width) * bytesPerElement
        }
        let headsAcrossLayers: Int
        if hasLayerShape, let perLayerHeads {
            headsAcrossLayers = perLayerHeads.reduce(0) { $0 + max(0, $1) }
        } else {
            headsAcrossLayers = kvHeads * (hasRecurrentState ? fullLayers : layers)
        }
        let bytesPerLayer: Double
        if hasLayerShape, let perLayerHeads {
            bytesPerLayer = perLayerHeads.reduce(0.0) { total, heads in
                total + rowBytes(headDim.key * max(0, heads)) + rowBytes(headDim.value * max(0, heads))
            }
        } else {
            bytesPerLayer = (rowBytes(headDim.key * kvHeads) + rowBytes(headDim.value * kvHeads))
                * Double(headsAcrossLayers) / Double(max(1, kvHeads))
        }
        let kvBytes = bytesPerLayer * Double(totalTokens)
        if profile?.slidingWindow != nil {
            assumptions.append(L("Sliding-window KV is budgeted at the full context; allocator reuse is not measured."))
        }
        var stateBytes: UInt64 = 0
        let recurrentLayers = hasLayerShape
            ? (perLayerHeads?.filter { $0 == 0 }.count ?? 0)
            : (hasRecurrentState ? max(0, layers - fullLayers) : 0)
        if recurrentLayers > 0, let inner = profile?.ssmInnerSize, inner > 0 {
            let kernel = max(1, profile?.ssmConvKernel ?? 4)
            let state = max(1, profile?.ssmStateSize ?? 128)
            stateBytes = UInt64((Double(kernel) + Double(state)) * Double(inner) * 4
                * Double(recurrentLayers) * Double(parallelSlots))
            assumptions.append(L("Recurrent state is architecture-dependent; this SSM estimate is not an allocator measurement."))
            confidence = .low
        }
        if hasRecurrentState && interval == 1 && !hasLayerShape {
            confidence = .low
            assumptions.append(L("Hybrid layer layout is missing; full KV is a conservative fallback."))
        }
        if profile?.architecture?.contains("deepseek") == true {
            confidence = .low
            assumptions.append(L("MLA cache layout is runtime-dependent; standard K/V geometry is only a fallback."))
        }
        let kvCacheBytes = UInt64(kvBytes)
        let kvLow = UInt64(kvBytes * (confidence == .low ? 0.5 : 1.0))
        let kvHigh = UInt64(kvBytes * (confidence == .low ? 2.0 : 1.1)) + 64 * 1024 * 1024

        // Compute buffers scale with the batch and the hidden size, not with the
        // context: the old `batchSize * 1 MB` was unrelated to either.
        let batch = max(1, batchSize)
        let computePerToken = Double(embeddingFallback) * 4.0 * 3.0
        var computeBuffers = max(256 * 1024 * 1024, UInt64(computePerToken * Double(batch)))
        if !flashAttention {
            // Non-FA attention materializes scores for a microbatch. The real
            // microbatch is runtime-dependent, so cap this heuristic at 512.
            computeBuffers += UInt64(Double(min(batch, 512)) * Double(totalTokens)
                * Double(max(1, profile?.headCount ?? 32)) * 4)
        }
        assumptions.append(L("Compute buffers and weight residency are estimates; mmap, microbatch, Flash Attention and runtime version affect actual usage."))
        assumptions.append(L("The total includes an OS reserve, not current free memory; GPU and RAM budgets are checked separately."))
        let osReserve: UInt64 = max(2 * 1024 * 1024 * 1024, UInt64(Double(info.totalRAM) * 0.15))

        let base = weightsSize + computeBuffers + osReserve
        let totalRequired = base + kvCacheBytes + stateBytes
        let totalLow = base + kvLow + UInt64(Double(stateBytes) * 0.8)
        let totalHigh = base + kvHigh + UInt64(Double(stateBytes) * 1.5)

        let offloadedLayers = backend == .cpu ? 0 : min(layers, max(0, gpuLayers ?? layers))
        let fraction = Double(offloadedLayers) / Double(layers)
        let gpuRequired = offloadedLayers > 0
            ? UInt64(Double(weightsSize + kvCacheBytes + stateBytes) * fraction) + computeBuffers : 0
        let ramRequired = info.gpuHasUnifiedMemory || offloadedLayers == 0
            ? totalRequired
            : totalRequired - UInt64(Double(weightsSize + kvCacheBytes + stateBytes) * fraction)
        let gpuBudget = offloadedLayers > 0 ? info.gpuRecommendedMaxWorkingSetSize : nil
        if offloadedLayers > 0 {
            assumptions.append(L("GPU layer placement uses proportional weights; embeddings, output tensors and per-layer sizes may differ."))
            if gpuBudget == nil {
                confidence = .low
                assumptions.append(L("GPU memory budget is unavailable; GPU compatibility cannot be confirmed."))
            }
        } else {
            assumptions.append(L("CPU-only inference: no GPU working set is used."))
        }
        let availableMemory = info.totalRAM

        var recommendation: CompatibilityRecommendation
        var warning: String? = nil

        // RAM exhaustion is checked first: a large model on an Intel Mac is not
        // "fits with limitations" when the weights alone exceed physical memory.
        if ramRequired > info.totalRAM {
            recommendation = .insufficientMemory
            warning = String(
                format: L("Estimated RAM requirement (%@) exceeds physical RAM (%@)."),
                formatBytes(ramRequired), formatBytes(info.totalRAM)
            )
        } else if let gpuBudget, gpuRequired > gpuBudget {
            recommendation = .highMemoryUsage
            warning = String(
                format: L("Estimated GPU allocation (%@) may exceed the GPU budget (%@)."),
                formatBytes(gpuRequired), formatBytes(gpuBudget)
            )
        } else if offloadedLayers > 0 && gpuBudget == nil {
            recommendation = .unknown
            warning = L("GPU memory budget is unavailable; RAM alone cannot confirm compatibility.")
        } else if totalHigh > availableMemory && info.gpuHasUnifiedMemory {
            recommendation = .highMemoryUsage
            warning = String(
                format: L("High memory usage: up to %@ of the %@ budget may be needed."),
                formatBytes(totalHigh), formatBytes(availableMemory)
            )
        } else if ramRequired > (availableMemory * 85 / 100) {
            recommendation = .fitsWithLimitations
            warning = L("Model fits, but context length or offload may need adjustment under heavy system load.")
        } else if confidence == .low {
            recommendation = .fitsWithLimitations
            warning = L("Incomplete geometry: this estimate is not a fit guarantee. Verify actual runtime allocation.")
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
            assumptions: assumptions,
            ramRequired: ramRequired,
            gpuRequired: gpuRequired,
            gpuBudget: gpuBudget
        )
    }

    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

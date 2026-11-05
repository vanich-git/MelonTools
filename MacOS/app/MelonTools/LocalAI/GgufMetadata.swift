import Foundation

/// Real GGUF header/metadata reader.
///
/// The reader is bounded on purpose: every length and every skipped array is
/// validated against the remaining file size and a metadata budget, and skips
/// seek instead of allocating. A malformed header used to trap on
/// `Int(UInt64.max)` and could ask `readData` for hundreds of megabytes from a
/// ten-byte file; both are impossible here, so a corrupt file fails cleanly and
/// cannot crash-loop the app at launch.
///
/// Layout (little endian), see ggml-org/ggml `gguf.md`:
/// ```
/// uint32 magic      "GGUF"
/// uint32 version
/// uint64 tensor_count
/// uint64 metadata_kv_count
/// kv[]  { string key, uint32 value_type, value }
/// ```
struct GgufInfo: Equatable {
    var version: UInt32
    var tensorCount: UInt64
    /// `general.architecture`, e.g. "qwen2", "llama", "gemma3".
    var architecture: String
    /// `general.name` when present.
    var name: String?
    /// Architecture-prefixed `*.context_length`.
    var contextLength: Int?
    /// Architecture-prefixed `*.block_count` — the real transformer depth.
    var blockCount: Int?
    /// Architecture-prefixed `*.embedding_length`.
    var embeddingLength: Int?
    /// `*.attention.head_count`.
    var headCount: Int?
    /// `*.attention.head_count_kv`. Per-layer in hybrid models, so an array;
    /// a single value means "the same for every attention layer".
    var headCountKV: [Int]
    /// `*.attention.key_length` (head dimension of K).
    var keyLength: Int?
    /// `*.attention.value_length` (head dimension of V).
    var valueLength: Int?
    /// `*.attention.sliding_window` — tokens kept per sliding-window layer.
    var slidingWindow: Int?
    /// `*.attention.full_attention_interval` — hybrid models put a full
    /// attention layer every N blocks and use linear/SSM attention elsewhere.
    var fullAttentionInterval: Int?
    /// Mamba/SSM parameters of hybrid models.
    var ssmInnerSize: Int?
    var ssmStateSize: Int?
    var ssmConvKernel: Int?
    /// `*.expert_count` for mixture-of-experts models.
    var expertCount: Int?
    /// Quantization derived from `general.file_type`, falling back to the name.
    var quantization: String
    /// Embedded Jinja chat template, when the file carries one.
    var chatTemplate: String?
    var license: String?
    /// Raw `general.file_type` enum value, kept for diagnostics.
    var fileType: UInt32?

    /// Total layers for memory estimation; never zero.
    var effectiveLayerCount: Int { blockCount ?? 32 }

    /// True when the file describes a hybrid (attention + SSM) model, where
    /// only a fraction of the layers keep a KV cache.
    var isHybridAttention: Bool { (fullAttentionInterval ?? 1) > 1 || ssmInnerSize != nil }

    /// Layers that keep a KV cache. A hybrid model with
    /// `full_attention_interval = 4` has one full-attention layer per four
    /// blocks; everything else is a recurrent/linear layer with a fixed state.
    var attentionLayerCount: Int {
        let layers = effectiveLayerCount
        guard let interval = fullAttentionInterval, interval > 1 else { return layers }
        return max(1, Int((Double(layers) / Double(interval)).rounded(.up)))
    }

    /// KV heads of one specific layer, honouring per-layer metadata.
    func kvHeads(forLayerLayer index: Int) -> Int? {
        guard !headCountKV.isEmpty else { return nil }
        if index < headCountKV.count { return headCountKV[index] }
        return headCountKV.last
    }
}

enum GgufParseError: LocalizedError {
    case notGguf
    case unsupportedVersion(UInt32)
    case truncated(String)
    case unsupportedValueType(UInt32)
    case metadataBudgetExceeded
    case implausibleValue(String)

    var errorDescription: String? {
        switch self {
        case .notGguf:
            return "Not a GGUF file (magic header mismatch)."
        case .unsupportedVersion(let version):
            return "Unsupported GGUF version: \(version)."
        case .truncated(let field):
            return "GGUF file is truncated while reading \(field)."
        case .unsupportedValueType(let type):
            return "Unsupported GGUF metadata value type: \(type)."
        case .metadataBudgetExceeded:
            return "GGUF metadata block is larger than the accepted limit."
        case .implausibleValue(let field):
            return "GGUF metadata field \(field) has an implausible value."
        }
    }
}

enum GgufMetadataReader {
    /// ggml `general.file_type` → quantization label (`llama_ftype` in
    /// llama.cpp, include/llama.h). Values 33–35 are retired aliases and 36+
    /// are the newer formats; the previous table was shifted by two entries.
    private static let fileTypeNames: [UInt32: String] = [
        0: "F32", 1: "F16",
        2: "Q4_0", 3: "Q4_1",
        7: "Q8_0", 8: "Q5_0", 9: "Q5_1",
        10: "Q2_K", 11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L",
        14: "Q4_K_S", 15: "Q4_K_M", 16: "Q5_K_S", 17: "Q5_K_M",
        18: "Q6_K", 19: "IQ2_XXS", 20: "IQ2_XS",
        21: "Q2_K_S", 22: "IQ3_XS", 23: "IQ3_XXS",
        24: "IQ1_S", 25: "IQ4_NL", 26: "IQ3_S", 27: "IQ3_M",
        28: "IQ2_S", 29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M",
        32: "BF16",
        36: "TQ1_0", 37: "TQ2_0", 38: "MXFP4_MOE", 39: "NVFP4",
        40: "Q1_0", 41: "Q2_0", 42: "F8_E4M3",
    ]

    /// Upper bound for the whole metadata block. Real files carry a few KiB of
    /// metadata plus a vocabulary; tens of megabytes means the header is junk.
    static let metadataBudget: UInt64 = 64 * 1024 * 1024
    /// Upper bound for a single string (templates are the biggest legitimate one).
    static let stringLimit: UInt64 = 8 * 1024 * 1024
    /// A GGUF header cannot declare more keys than this many 12-byte entries.
    static let maxKVCount: UInt64 = 1_000_000

    private static let tUInt8: UInt32 = 0
    private static let tInt8: UInt32 = 1
    private static let tUInt16: UInt32 = 2
    private static let tInt16: UInt32 = 3
    private static let tUInt32: UInt32 = 4
    private static let tInt32: UInt32 = 5
    private static let tFloat32: UInt32 = 6
    private static let tBool: UInt32 = 7
    private static let tString: UInt32 = 8
    private static let tArray: UInt32 = 9
    private static let tUInt64: UInt32 = 10
    private static let tInt64: UInt32 = 11
    private static let tFloat64: UInt32 = 12

    /// Reads the header and the KV block without touching tensor data.
    static func read(from url: URL) throws -> GgufInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw GgufParseError.truncated("file")
        }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize >= 20 else { throw GgufParseError.truncated("header") }

        var reader = BoundedReader(handle: handle, fileSize: fileSize, budget: metadataBudget)

        let magic = try reader.read(4, "magic")
        guard magic[0] == 0x47, magic[1] == 0x47, magic[2] == 0x55, magic[3] == 0x46 else {
            throw GgufParseError.notGguf
        }

        let version = try reader.readUInt32("version")
        guard version >= 2, version <= 3 else {
            throw GgufParseError.unsupportedVersion(version)
        }
        let tensorCount = try reader.readUInt64("tensor_count")
        let kvCount = try reader.readUInt64("metadata_kv_count")

        // Every entry costs at least 12 bytes (key length + value type), so a
        // count larger than the remaining file is a lie and would spin here.
        guard kvCount <= maxKVCount, kvCount <= reader.remaining / 12 else {
            throw GgufParseError.implausibleValue("metadata_kv_count")
        }

        var architecture = "llama"
        var name: String?
        var contextLength: Int?
        var blockCount: Int?
        var embeddingLength: Int?
        var headCount: Int?
        var headCountKV: [Int] = []
        var keyLength: Int?
        var valueLength: Int?
        var slidingWindow: Int?
        var fullAttentionInterval: Int?
        var ssmInnerSize: Int?
        var ssmStateSize: Int?
        var ssmConvKernel: Int?
        var expertCount: Int?
        var fileType: UInt32?
        var chatTemplate: String?
        var license: String?

        for _ in 0..<kvCount {
            let key = try reader.readString("key")
            let type = try reader.readUInt32("value_type")

            switch type {
            case tString:
                let value = try reader.readString(key)
                switch key {
                case "general.architecture": architecture = value
                case "general.name": name = value
                case "tokenizer.chat_template": chatTemplate = value
                case "general.license", "license": license = value
                default: break
                }
            case tArray:
                let values = try reader.readIntegerArray(key: key)
                applyIntegerArray(values, key: key, into: &headCountKV)
            case tBool, tUInt8, tInt8:
                let raw = try reader.readUInt8(key)
                applyInteger(Int(raw), key: key, fileType: &fileType,
                             contextLength: &contextLength, blockCount: &blockCount,
                             embeddingLength: &embeddingLength, headCount: &headCount,
                             keyLength: &keyLength, valueLength: &valueLength,
                             slidingWindow: &slidingWindow,
                             fullAttentionInterval: &fullAttentionInterval,
                             ssmInnerSize: &ssmInnerSize, ssmStateSize: &ssmStateSize,
                             ssmConvKernel: &ssmConvKernel, expertCount: &expertCount)
            case tUInt16, tInt16:
                let raw = try reader.readUInt16(key)
                applyInteger(Int(raw), key: key, fileType: &fileType,
                             contextLength: &contextLength, blockCount: &blockCount,
                             embeddingLength: &embeddingLength, headCount: &headCount,
                             keyLength: &keyLength, valueLength: &valueLength,
                             slidingWindow: &slidingWindow,
                             fullAttentionInterval: &fullAttentionInterval,
                             ssmInnerSize: &ssmInnerSize, ssmStateSize: &ssmStateSize,
                             ssmConvKernel: &ssmConvKernel, expertCount: &expertCount)
            case tUInt32, tInt32, tFloat32:
                let raw = try reader.readUInt32(key)
                if type == tFloat32 {
                    // Not used by any field we read; consume and ignore.
                    break
                }
                applyInteger(Int(raw), key: key, fileType: &fileType,
                             contextLength: &contextLength, blockCount: &blockCount,
                             embeddingLength: &embeddingLength, headCount: &headCount,
                             keyLength: &keyLength, valueLength: &valueLength,
                             slidingWindow: &slidingWindow,
                             fullAttentionInterval: &fullAttentionInterval,
                             ssmInnerSize: &ssmInnerSize, ssmStateSize: &ssmStateSize,
                             ssmConvKernel: &ssmConvKernel, expertCount: &expertCount)
            case tUInt64, tInt64, tFloat64:
                let raw = try reader.readUInt64(key)
                if type == tFloat64 { break }
                if let value = Int(exactly: raw) {
                    applyInteger(value, key: key, fileType: &fileType,
                                 contextLength: &contextLength, blockCount: &blockCount,
                                 embeddingLength: &embeddingLength, headCount: &headCount,
                                 keyLength: &keyLength, valueLength: &valueLength,
                                 slidingWindow: &slidingWindow,
                                 fullAttentionInterval: &fullAttentionInterval,
                                 ssmInnerSize: &ssmInnerSize, ssmStateSize: &ssmStateSize,
                                 ssmConvKernel: &ssmConvKernel, expertCount: &expertCount)
                } else {
                    throw GgufParseError.implausibleValue(key)
                }
            default:
                throw GgufParseError.unsupportedValueType(type)
            }
        }

        let quantization = fileType.flatMap { fileTypeNames[$0] }
            ?? extractQuantization(from: url.lastPathComponent)

        return GgufInfo(
            version: version,
            tensorCount: tensorCount,
            architecture: architecture,
            name: name,
            contextLength: contextLength,
            blockCount: blockCount,
            embeddingLength: embeddingLength,
            headCount: headCount,
            headCountKV: headCountKV,
            keyLength: keyLength,
            valueLength: valueLength,
            slidingWindow: slidingWindow,
            fullAttentionInterval: fullAttentionInterval,
            ssmInnerSize: ssmInnerSize,
            ssmStateSize: ssmStateSize,
            ssmConvKernel: ssmConvKernel,
            expertCount: expertCount,
            quantization: quantization,
            chatTemplate: chatTemplate,
            license: license,
            fileType: fileType
        )
    }

    /// Routes one integer metadata value into the field it belongs to. Keys are
    /// architecture-prefixed (`qwen35.context_length`), so suffixes are matched
    /// and a nonsensical value is dropped instead of trusted.
    private static func applyInteger(
        _ value: Int,
        key: String,
        fileType: inout UInt32?,
        contextLength: inout Int?,
        blockCount: inout Int?,
        embeddingLength: inout Int?,
        headCount: inout Int?,
        keyLength: inout Int?,
        valueLength: inout Int?,
        slidingWindow: inout Int?,
        fullAttentionInterval: inout Int?,
        ssmInnerSize: inout Int?,
        ssmStateSize: inout Int?,
        ssmConvKernel: inout Int?,
        expertCount: inout Int?
    ) {
        guard value >= 0 else { return }
        if key == "general.file_type" {
            if let raw = UInt32(exactly: value) { fileType = raw }
            return
        }
        guard value > 0 else { return }
        if key.hasSuffix(".context_length") { contextLength = value }
        else if key.hasSuffix(".block_count") { blockCount = value }
        else if key.hasSuffix(".embedding_length") { embeddingLength = value }
        else if key.hasSuffix(".attention.head_count") { headCount = value }
        else if key.hasSuffix(".attention.key_length") { keyLength = value }
        else if key.hasSuffix(".attention.value_length") { valueLength = value }
        else if key.hasSuffix(".attention.sliding_window") { slidingWindow = value }
        else if key.hasSuffix(".attention.full_attention_interval") { fullAttentionInterval = value }
        else if key.hasSuffix(".ssm.inner_size") { ssmInnerSize = value }
        else if key.hasSuffix(".ssm.state_size") { ssmStateSize = value }
        else if key.hasSuffix(".ssm.conv_kernel") { ssmConvKernel = value }
        else if key.hasSuffix(".expert_count") { expertCount = value }
    }

    private static func applyIntegerArray(
        _ values: [Int],
        key: String,
        into headCountKV: inout [Int]
    ) {
        guard key.hasSuffix(".attention.head_count_kv"), !values.isEmpty else { return }
        headCountKV = values.filter { $0 > 0 }
    }

    /// Quantization from a file name — fallback for files without
    /// `general.file_type`, and for catalog entries before download.
    static func extractQuantization(from filename: String) -> String {
        let quants = [
            "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_0", "Q4_1", "Q4_K_S", "Q4_K_M",
            "Q5_0", "Q5_1", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0",
            "F16", "F32", "BF16", "F8_E4M3", "IQ1_S", "IQ1_M", "IQ2_XXS", "IQ2_XS",
            "IQ2_S", "IQ2_M", "IQ3_XXS", "IQ3_XS", "IQ3_S", "IQ3_M", "IQ4_XS", "IQ4_NL",
            "TQ1_0", "TQ2_0", "MXFP4", "NVFP4", "Q1_0", "Q2_0",
        ]
        let upper = filename.uppercased()
        // Longest match first: "F16" is a substring of "BF16".
        for quant in quants.sorted(by: { $0.count > $1.count }) where upper.contains(quant) {
            return quant
        }
        return "GGUF"
    }

    /// Bounded cursor over a GGUF file: never reads past EOF, never allocates a
    /// skipped payload, and stops after `budget` bytes of actual reads.
    private struct BoundedReader {
        let handle: FileHandle
        let fileSize: UInt64
        var offset: UInt64 = 0
        var budget: UInt64
        var remaining: UInt64 { fileSize - offset }

        init(handle: FileHandle, fileSize: UInt64, budget: UInt64) {
            self.handle = handle
            self.fileSize = fileSize
            self.budget = budget
        }

        mutating func read(_ count: Int, _ field: String) throws -> Data {
            guard count >= 0, UInt64(count) <= remaining else {
                throw GgufParseError.truncated(field)
            }
            guard UInt64(count) <= budget else {
                throw GgufParseError.metadataBudgetExceeded
            }
            let data = handle.readData(ofLength: count)
            guard data.count == count else { throw GgufParseError.truncated(field) }
            offset += UInt64(count)
            budget -= UInt64(count)
            return data
        }

        mutating func skip(_ count: UInt64, _ field: String) throws {
            guard count <= remaining else { throw GgufParseError.truncated(field) }
            guard count > 0 else { return }
            do {
                try handle.seek(toOffset: offset + count)
            } catch {
                throw GgufParseError.truncated(field)
            }
            offset += count
        }

        mutating func readUInt8(_ field: String) throws -> UInt8 {
            let data = try read(1, field)
            return data[data.startIndex]
        }

        mutating func readUInt16(_ field: String) throws -> UInt16 {
            let data = try read(2, field)
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }

        mutating func readUInt32(_ field: String) throws -> UInt32 {
            let data = try read(4, field)
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }

        mutating func readUInt64(_ field: String) throws -> UInt64 {
            let data = try read(8, field)
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }

        mutating func readString(_ field: String) throws -> String {
            let length = try readUInt64(field)
            guard length <= GgufMetadataReader.stringLimit else {
                throw GgufParseError.implausibleValue(field)
            }
            guard let count = Int(exactly: length) else {
                throw GgufParseError.implausibleValue(field)
            }
            let data = try read(count, field)
            return String(decoding: data, as: UTF8.self)
        }

        /// Reads an integer array. Only bounded numeric arrays are materialised
        /// (they describe layers); string arrays such as the vocabulary are
        /// skipped with seeks, which is what keeps a 128k-token vocabulary from
        /// allocating anything.
        mutating func readIntegerArray(key: String) throws -> [Int] {
            let elementType = try readUInt32("\(key).array_type")
            let count = try readUInt64("\(key).array_length")

            let elementSize: UInt64
            switch elementType {
            case GgufMetadataReader.tUInt8, GgufMetadataReader.tInt8, GgufMetadataReader.tBool:
                elementSize = 1
            case GgufMetadataReader.tUInt16, GgufMetadataReader.tInt16:
                elementSize = 2
            case GgufMetadataReader.tUInt32, GgufMetadataReader.tInt32:
                elementSize = 4
            case GgufMetadataReader.tUInt64, GgufMetadataReader.tInt64:
                elementSize = 8
            case GgufMetadataReader.tString:
                try skipStringArray(key: key, count: count)
                return []
            case GgufMetadataReader.tFloat32, GgufMetadataReader.tFloat64:
                let size: UInt64 = elementType == GgufMetadataReader.tFloat32 ? 4 : 8
                guard count <= remaining / size else {
                    throw GgufParseError.truncated("\(key).array")
                }
                try skip(count * size, "\(key).array")
                return []
            default:
                throw GgufParseError.unsupportedValueType(elementType)
            }

            guard count <= remaining / elementSize else {
                throw GgufParseError.truncated("\(key).array")
            }
            // Per-layer arrays are tiny; a multi-million entry array is not a
            // shape this reader needs to materialise.
            guard count <= 16_384 else {
                try skip(count * elementSize, "\(key).array")
                return []
            }
            var values: [Int] = []
            values.reserveCapacity(Int(count))
            for _ in 0..<count {
                switch elementSize {
                case 1:
                    values.append(Int(try readUInt8(key)))
                case 2:
                    values.append(Int(try readUInt16(key)))
                case 4:
                    values.append(Int(try readUInt32(key)))
                default:
                    let raw = try readUInt64(key)
                    guard let value = Int(exactly: raw) else {
                        throw GgufParseError.implausibleValue(key)
                    }
                    values.append(value)
                }
            }
            return values
        }

        private mutating func skipStringArray(key: String, count: UInt64) throws {
            for _ in 0..<count {
                let length = try readUInt64("\(key).array_item_length")
                guard length <= GgufMetadataReader.stringLimit else {
                    throw GgufParseError.implausibleValue(key)
                }
                try skip(length, "\(key).array_item")
            }
        }
    }
}

import Foundation

/// A downloadable model, not an individual part of a split GGUF.
struct HFDownloadVariant: Identifiable, Equatable {
    let files: [HFGGUFFile]
    var id: String { files[0].rfilename }
    var file: HFGGUFFile { files[0] }
    var size: UInt64 { files.reduce(0) { $0 + $1.size } }
    var hasKnownSize: Bool { files.allSatisfy { $0.size > 0 } }
    var isComplete: Bool {
        guard let shard = file.shard else { return true }
        return Set(files.compactMap { $0.shard?.index }) == Set(1...shard.total)
    }
    var isAuxiliary: Bool {
        (file.rfilename as NSString).lastPathComponent.lowercased().contains("mmproj")
    }
    var fitsEstimatedMemory: Bool {
        guard hasKnownSize, isComplete else { return false }
        return file.estimation.recommendation == .recommended || file.estimation.recommendation == .fitsWithLimitations
    }
    var name: String { file.shard?.base ?? (file.rfilename as NSString).lastPathComponent }

    static func variants(from files: [HFGGUFFile]) -> [Self] {
        var seen = Set<String>()
        return files.compactMap { file in
            let group = HuggingFaceService.splitGroup(for: file, in: files)
            guard let first = group.first, seen.insert(first.id).inserted else { return nil }
            return Self(files: group)
        }.sorted { $0.size == $1.size ? $0.id < $1.id : $0.size < $1.size }
    }

    /// Prefer a complete Q4_K_M which fits the estimate. Do not recommend a
    /// projector, unknown-size file or an oversized Q4 simply because of its name.
    static func recommended(in variants: [Self]) -> Self? {
        let fitting = variants.filter { $0.fitsEstimatedMemory && !$0.isAuxiliary }
        return fitting.first { $0.file.quantization == "Q4_K_M" } ?? fitting.first
    }

    static func defaultSelection(in variants: [Self]) -> Self? {
        recommended(in: variants) ?? variants.first { $0.isComplete && !$0.isAuxiliary }
    }
}

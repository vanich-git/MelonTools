import XCTest
@testable import MelonTools

@MainActor
final class HuggingFaceCatalogTests: XCTestCase {
    func testMissingMetadataStaysAbsentAndSafetensorsNeverImpliesCompatibility() async throws {
        let data = Data(#"{"id":"owner/claims-8B","safetensors":{"total":8000000000},"siblings":[{"rfilename":"model.safetensors","size":1000}]}"#.utf8)
        let details = try await HuggingFaceService.parseModelDetails(data, repoId: "owner/claims-8B")
        XCTAssertNil(details.downloads)
        XCTAssertNil(details.likes)
        XCTAssertNil(details.architecture)
        XCTAssertNil(details.license)
        XCTAssertTrue(details.description.isEmpty)
        XCTAssertTrue(details.capabilities.isEmpty)
        XCTAssertTrue(details.ggufFiles.isEmpty)
        XCTAssertEqual(details.parameterCount, 8_000_000_000)
        XCTAssertNil(HFDownloadVariant.recommended(in: HFDownloadVariant.variants(from: details.ggufFiles)))
    }

    func testRealMetadataAndSplitWeightsUseCompleteSize() async throws {
        let json = #"{"author":"owner","downloads":0,"likes":12,"gguf":{"architecture":"qwen2","total":7000000000},"cardData":{"description":"Published summary","license":"apache-2.0"},"tags":["text-generation","tool-use"],"siblings":[{"rfilename":"model-Q4_K_M-00001-of-00002.gguf","lfs":{"size":1000000000}},{"rfilename":"model-Q4_K_M-00002-of-00002.gguf","lfs":{"size":2000000000}}]}"#
        let details = try await HuggingFaceService.parseModelDetails(Data(json.utf8), repoId: "owner/repo")
        XCTAssertEqual(details.downloads, 0)
        XCTAssertEqual(details.description, "Published summary")
        XCTAssertEqual(details.architecture, "qwen2")
        XCTAssertEqual(details.parameterCount, 7_000_000_000)
        XCTAssertEqual(details.license, "apache-2.0")
        XCTAssertEqual(details.capabilities, ["text-generation", "tool-use"])
        XCTAssertEqual(details.ggufFiles.count, 2)
        XCTAssertTrue(details.ggufFiles.allSatisfy { $0.estimation.weightsSize == 3_000_000_000 })
        let variants = HFDownloadVariant.variants(from: details.ggufFiles)
        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants.first?.size, 3_000_000_000)
        XCTAssertTrue(variants.first?.isComplete == true)
    }

    func testDefaultPrefersFittingQ4ButNotOversizedQ4OrProjector() {
        let q8 = file("model-Q8_0.gguf", size: 8, fits: true)
        let q4 = file("model-Q4_K_M.gguf", size: 4, fits: true)
        let projector = file("mmproj-Q4_K_M.gguf", size: 1, fits: true)
        let variants = HFDownloadVariant.variants(from: [q8, projector, q4])
        XCTAssertEqual(HFDownloadVariant.defaultSelection(in: variants)?.id, q4.id)
        let oversized = file("large-Q4_K_M.gguf", size: 40, fits: false)
        let alternatives = HFDownloadVariant.variants(from: [oversized, q8])
        XCTAssertEqual(HFDownloadVariant.recommended(in: alternatives)?.id, q8.id)
        XCTAssertNil(HFDownloadVariant.recommended(in: HFDownloadVariant.variants(from: [projector])))
    }

    func testUnknownSizeAndIncompleteSplitAreNotRecommended() {
        let unknown = file("model-Q4_K_M.gguf", size: 0, fits: true)
        let incomplete = file("model-Q4_K_M-00001-of-00002.gguf", size: 4, fits: true)
        let variants = HFDownloadVariant.variants(from: [unknown, incomplete])
        XCTAssertNil(HFDownloadVariant.recommended(in: variants))
        XCTAssertFalse(variants.first(where: { $0.id == incomplete.id })!.isComplete)
    }

    func testSplitGroupsDoNotMixDirectories() {
        let files = [
            file("a/model-Q4_K_M-00001-of-00002.gguf", size: 1, fits: true),
            file("b/model-Q4_K_M-00002-of-00002.gguf", size: 2, fits: true)
        ]
        let variants = HFDownloadVariant.variants(from: files)
        XCTAssertEqual(variants.count, 2)
        XCTAssertTrue(variants.allSatisfy { !$0.isComplete })
    }

    func testReadmeTablesCodeAndFrontmatter() {
        let text = "---\nlicense: apache-2.0\n---\n# Model\n\n| Quant | Size |\n| :--- | ---: |\n| Q4_K_M | 4 GB |\n\n```swift\nlet table = \"a|b\"\n```"
        let sections = HFReadmeView.sections(text)
        XCTAssertEqual(sections.first?.markdown, "# Model\n")
        XCTAssertEqual(sections.first(where: { $0.header != nil })?.header, ["Quant", "Size"])
        XCTAssertEqual(sections.first(where: { $0.header != nil })?.rows, [["Q4_K_M", "4 GB"]])
        XCTAssertTrue(sections.last?.markdown.contains("let table") == true)
        XCTAssertFalse(sections.contains { $0.markdown.contains("license:") })
        let fenced = HFReadmeView.sections("```\n| A | B |\n| --- | --- |\n```")
        XCTAssertFalse(fenced.contains { $0.header != nil })
    }

    func testRepositoryParserRejectsForeignURLsAndUnsafeIDs() {
        XCTAssertNil(HuggingFaceService.repositoryID(from: "https://example.com/owner/repo"))
        XCTAssertNil(HuggingFaceService.repositoryID(from: "https://fake-huggingface.co/owner/repo"))
        XCTAssertNil(HuggingFaceService.repositoryID(from: "../repo"))
        XCTAssertNil(HuggingFaceService.downloadURL(repoId: "../repo", rfilename: "file.gguf"))
        XCTAssertEqual(HuggingFaceService.repositoryID(from: "https://huggingface.co/owner/repo/tree/main"), "owner/repo")
    }

    func testResolveURLPreservesReservedCharactersAndRejectsTraversal() throws {
        let url = try XCTUnwrap(HuggingFaceService.downloadURL(repoId: "owner/repo", rfilename: "folder/model#1?%.gguf"))
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.query)
        XCTAssertTrue(url.absoluteString.contains("model%231%3F%25.gguf"))
        XCTAssertNil(HuggingFaceService.downloadURL(repoId: "owner/repo", rfilename: "../model.gguf"))
    }

    private func file(_ name: String, size: UInt64, fits: Bool) -> HFGGUFFile {
        let estimate = MemoryEstimation(
            weightsSize: size, kvCacheSize: 0, kvCacheLow: 0, kvCacheHigh: 0,
            stateCacheSize: 0, computeBuffers: 0, osReserve: 0,
            totalRequired: size, totalLow: size, totalHigh: size,
            recommendation: fits ? .recommended : .insufficientMemory,
            confidence: .low, warning: nil, assumptions: []
        )
        return HFGGUFFile(rfilename: name, size: size,
            downloadURL: URL(string: "https://huggingface.co/owner/repo/resolve/main/model.gguf")!,
            quantization: HuggingFaceService.extractQuantization(from: name), estimation: estimate,
            shard: LocalModelStore.shardInfo(for: name))
    }
}

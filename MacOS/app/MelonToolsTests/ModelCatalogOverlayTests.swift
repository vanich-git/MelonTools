import XCTest
@testable import MelonTools

/// The overlay is the only place that knows which Antigravity ids the official
/// catalog is missing. These tests pin the merge contract the engine relies on:
/// unique ids, the three extra entries, and a catalog that passes validation.
final class ModelCatalogOverlayTests: XCTestCase {
    private func templateCatalog() -> [String: Any] {
        var catalog: [String: Any] = [:]
        for section in ModelCatalogOverlay.requiredSections {
            catalog[section] = [[String: Any]]()
        }
        catalog["antigravity"] = [
            [
                "id": "gemini-3.8-flash-high",
                "object": "model",
                "owned_by": "antigravity",
                "type": "antigravity",
                "name": "gemini-3.8-flash-high",
                "display_name": "Gemini 3.8 Flash",
                "context_length": 1_048_576,
                "max_completion_tokens": 65_536,
            ],
            [
                "id": "gemini-3-flash",
                "object": "model",
                "owned_by": "antigravity",
                "type": "antigravity",
            ],
        ]
        catalog["gemini"] = [
            [
                "id": "gemini-2.5-pro",
                "object": "model",
                "owned_by": "google",
                "type": "gemini",
                "name": "models/gemini-2.5-pro",
                "display_name": "Gemini 2.5 Pro",
                "inputTokenLimit": 1_048_576,
                "outputTokenLimit": 65_536,
            ],
        ]
        return catalog
    }

    private func antigravityIDs(_ catalog: [String: Any]) -> [String] {
        let models = (catalog["antigravity"] as? [[String: Any]]) ?? []
        return models.compactMap { $0["id"] as? String }
    }

    func testMergeAddsTheThreeMissingAntigravityModels() {
        let merged = ModelCatalogOverlay.merge(templateCatalog())
        let ids = antigravityIDs(merged)
        XCTAssertEqual(ids.filter { $0 == "gemini-3.8-flash-low" }.count, 1)
        XCTAssertEqual(ids.filter { $0 == "gemini-3.8-flash-medium" }.count, 1)
        XCTAssertEqual(ids.filter { $0 == "gemini-2.5-pro" }.count, 1)

        let models = (merged["antigravity"] as? [[String: Any]]) ?? []
        let pro = models.first { $0["id"] as? String == "gemini-2.5-pro" }
        XCTAssertEqual(pro?["owned_by"] as? String, "antigravity")
        XCTAssertEqual(pro?["type"] as? String, "antigravity")
        XCTAssertEqual(pro?["context_length"] as? Int, 1_048_576)
        XCTAssertEqual(pro?["max_completion_tokens"] as? Int, 65_536)

        let medium = models.first { $0["id"] as? String == "gemini-3.8-flash-medium" }
        XCTAssertEqual(medium?["display_name"] as? String, "Gemini 3.8 Flash (Medium)")
        XCTAssertEqual(medium?["context_length"] as? Int, 1_048_576)
    }

    func testMergeDeduplicatesIdsSoTheEngineAcceptsTheCatalog() {
        var catalog = templateCatalog()
        var antigravity = (catalog["antigravity"] as? [[String: Any]]) ?? []
        antigravity.append(antigravity[0])
        catalog["antigravity"] = antigravity

        let merged = ModelCatalogOverlay.merge(catalog)
        let ids = antigravityIDs(merged)
        XCTAssertEqual(ids.filter { $0 == "gemini-3.8-flash-high" }.count, 1)
        XCTAssertNil(ModelCatalogOverlay.validate(merged))
    }

    func testMergeDoesNotDuplicateAnEntryThatAlreadyExists() {
        var catalog = templateCatalog()
        var antigravity = (catalog["antigravity"] as? [[String: Any]]) ?? []
        antigravity.append([
            "id": "gemini-3.8-flash-low",
            "object": "model",
            "owned_by": "antigravity",
            "type": "antigravity",
        ])
        catalog["antigravity"] = antigravity

        let merged = ModelCatalogOverlay.merge(catalog)
        XCTAssertEqual(antigravityIDs(merged).filter { $0 == "gemini-3.8-flash-low" }.count, 1)
    }

    func testMergeWithoutTemplateLeavesTheCatalogIntact() {
        var catalog = templateCatalog()
        catalog["antigravity"] = [[String: Any]]()
        catalog["gemini"] = [[String: Any]]()
        let merged = ModelCatalogOverlay.merge(catalog)
        XCTAssertEqual(antigravityIDs(merged), [])
        XCTAssertNil(ModelCatalogOverlay.validate(merged))
    }

    func testValidateRejectsMissingSection() {
        var catalog = templateCatalog()
        catalog.removeValue(forKey: "xai")
        XCTAssertEqual(ModelCatalogOverlay.validate(catalog), "missing section xai")
    }

    func testValidateRejectsDuplicateAndEmptyIds() {
        var catalog = templateCatalog()
        catalog["antigravity"] = [
            ["id": "gemini-3-flash"],
            ["id": "gemini-3-flash"],
        ]
        XCTAssertNotNil(ModelCatalogOverlay.validate(catalog))

        catalog["antigravity"] = [["id": "  "]]
        XCTAssertNotNil(ModelCatalogOverlay.validate(catalog))
    }

    func testGatewayYAMLOnlyReferencesAnExistingFile() throws {
        let missing = NSTemporaryDirectory() + "/melon-missing-\(UUID().uuidString).json"
        XCTAssertEqual(ModelCatalogOverlay.gatewayYAML(catalogPath: missing), "")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("melon-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("models.json")
        try Data("{}".utf8).write(to: file)

        let block = ModelCatalogOverlay.gatewayYAML(catalogPath: file.path)
        XCTAssertEqual(block, "\nmodels:\n  catalog: \"\(file.path)\"\n")
    }

    func testNeedsRefreshFollowsTheFileAge() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("melon-overlay-age-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("models.json")
        try Data("{}".utf8).write(to: file)

        let now = Date()
        XCTAssertFalse(ModelCatalogOverlay.needsRefresh(now: now, path: file.path))
        XCTAssertTrue(ModelCatalogOverlay.needsRefresh(
            now: now.addingTimeInterval(ModelCatalogOverlay.refreshInterval + 60),
            path: file.path
        ))
        XCTAssertTrue(ModelCatalogOverlay.needsRefresh(
            now: now,
            path: directory.appendingPathComponent("absent.json").path
        ))
    }
}

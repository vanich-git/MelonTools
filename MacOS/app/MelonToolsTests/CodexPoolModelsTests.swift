import XCTest
@testable import MelonTools

@MainActor
final class CodexPoolModelsTests: XCTestCase {
    func testMergedCacheKeepsCodexMetadataAndReplacesModels() {
        let existing: [String: Any] = [
            "identity": ["email": "user@example.com"],
            "etag": "models-v1",
            "models": [["slug": "old"]],
        ]
        let fresh: [[String: Any]] = [
            ["slug": "gpt-6.1-terra", "display_name": "GPT-6.1 Terra", "visibility": "list"],
        ]
        let object = CodexPoolModelsStore.mergedCacheObject(
            existing: existing,
            models: fresh,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(object["etag"] as? String, "models-v1")
        XCTAssertNotNil(object["identity"])
        XCTAssertEqual((object["models"] as? [[String: Any]])?.first?["slug"] as? String, "gpt-6.1-terra")
        XCTAssertEqual(object["client_version"] as? String, CodexService.modelsClientVersion)
        XCTAssertNotNil(object["fetched_at"] as? String)
    }

    func testModelCacheRefreshRemovesTheStaleVisibleSet() {
        let object = CodexPoolModelsStore.mergedCacheObject(
            existing: ["models": [["slug": "gpt-5.6-terra"]]],
            models: [["slug": "gpt-6.1-terra"]],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let slugs = (object["models"] as? [[String: Any]])?.compactMap { $0["slug"] as? String }
        XCTAssertEqual(slugs, ["gpt-6.1-terra"])
    }
}

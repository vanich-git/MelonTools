import XCTest
@testable import MelonTools

final class AntigravityPoolTests: XCTestCase {
    func testQuotaGroupsGeminiAndThirdPartyPools() throws {
        let data = Data("""
        {"models":{
          "gemini-a":{"modelProvider":"MODEL_PROVIDER_GOOGLE","quotaInfo":{"remainingFraction":0.75,"resetTime":"2026-11-01T16:15:53Z"}},
          "gemini-b":{"modelProvider":"MODEL_PROVIDER_GOOGLE","quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-11-01T16:15:53Z"}},
          "claude-a":{"modelProvider":"MODEL_PROVIDER_ANTHROPIC","quotaInfo":{"remainingFraction":0.9,"resetTime":"2026-11-01T20:47:28Z"}}
        }}
        """.utf8)
        let quota = try XCTUnwrap(AntigravityPoolStore.parseQuota(data: data))
        XCTAssertEqual(quota.gemini?.remaining, 0.5)
        XCTAssertEqual(quota.gemini?.modelIDs, ["gemini-a", "gemini-b"])
        XCTAssertEqual(quota.claude?.remaining, 0.9)
        XCTAssertEqual(quota.claude?.modelIDs, ["claude-a"])
        XCTAssertNil(quota.error)
    }

    func testQuotaWithoutQuotaInfoIsRejected() {
        let data = Data(#"{"models":{"m":{"modelProvider":"MODEL_PROVIDER_GOOGLE"}}}"#.utf8)
        XCTAssertNil(AntigravityPoolStore.parseQuota(data: data))
    }

    func testCatalogOnlyReturnsEntriesNoAccountHas() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("models.json")
        let json = """
        {"antigravity":[
          {"id":"available","display_name":"Available"},
          {"id":"locked","display_name":"Locked"},
          {"id":"also-locked","display_name":"Also Locked"}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let result = AntigravityPoolStore.catalogOnlyModels(entitled: ["available"], catalogURL: url)
        XCTAssertEqual(result.map(\.id), ["also-locked", "locked"])
        XCTAssertEqual(result.map(\.displayName), ["Also Locked", "Locked"])
    }

    func testCatalogOnlyMissingFileIsEmpty() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(AntigravityPoolStore.catalogOnlyModels(entitled: [], catalogURL: url).isEmpty)
    }
}

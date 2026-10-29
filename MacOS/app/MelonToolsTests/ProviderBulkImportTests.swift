import XCTest
@testable import MelonTools

final class ProviderBulkImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("melon-provider-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testPlatformNamesMapToProviderKinds() {
        XCTAssertEqual(ProviderBulkImport.kind(forPlatform: "anthropic"), .claude)
        XCTAssertEqual(ProviderBulkImport.kind(forPlatform: "claude"), .claude)
        XCTAssertEqual(ProviderBulkImport.kind(forPlatform: "google-antigravity"), .antigravity)
        XCTAssertEqual(ProviderBulkImport.kind(forPlatform: "Antigravity"), .antigravity)
        XCTAssertNil(ProviderBulkImport.kind(forPlatform: "openai"))
        XCTAssertNil(ProviderBulkImport.kind(forPlatform: "gemini"))
    }

    func testClaudeAndAntigravityFilesGetEngineFields() throws {
        let claude = try XCTUnwrap(ProviderBulkImport.parse([
            "platform": "anthropic",
            "credentials": [
                "email": "claude@example.com",
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "expires_at": "2026-11-01T12:00:00Z",
            ],
        ], kind: .claude))
        let antigravity = try XCTUnwrap(ProviderBulkImport.parse([
            "platform": "antigravity",
            "credentials": [
                "email": "google@example.com",
                "access_token": "access-2",
                "refresh_token": "refresh-2",
                "project_id": "project-2",
                "expires_in": 3600,
            ],
        ], kind: .antigravity))

        let written = try ProviderBulkImport.write([claude, antigravity], to: directory)
        XCTAssertEqual(written.claude, 1)
        XCTAssertEqual(written.antigravity, 1)

        let claudeURL = directory.appendingPathComponent("claude-claude@example.com.json")
        let claudeJSON = try json(at: claudeURL)
        XCTAssertEqual(claudeJSON["type"] as? String, "claude")
        XCTAssertEqual(claudeJSON["access_token"] as? String, "access-1")
        XCTAssertEqual(claudeJSON["expired"] as? String, "2026-11-01T12:00:00Z")

        let antigravityURL = directory.appendingPathComponent(
            "antigravity-google@example.com.json"
        )
        let antigravityJSON = try json(at: antigravityURL)
        XCTAssertEqual(antigravityJSON["type"] as? String, "antigravity")
        XCTAssertEqual(antigravityJSON["project_id"] as? String, "project-2")
        XCTAssertEqual(antigravityJSON["expires_in"] as? Int, 3600)
        XCTAssertNotNil(antigravityJSON["expired"] as? String)
    }

    func testExistingEngineMetadataSurvivesImport() throws {
        let path = directory.appendingPathComponent(
            "claude-00f765af-user@example.com.json"
        )
        try Data(#"{"type":"claude","email":"user@example.com","access_token":"old","disabled":true,"claude_device_ids":["device-1"],"organization_uuid":"org-1"}"#.utf8)
            .write(to: path)

        let credential = try XCTUnwrap(ProviderBulkImport.parse([
            "platform": "claude",
            "credentials": [
                "email": "user@example.com",
                "access_token": "new",
                "refresh_token": "refresh-1",
                "organization_uuid": "org-1",
            ],
        ], kind: .claude))

        _ = try ProviderBulkImport.write([credential], to: directory)

        let object = try json(at: path)
        XCTAssertEqual(object["access_token"] as? String, "new")
        XCTAssertEqual(object["refresh_token"] as? String, "refresh-1")
        XCTAssertEqual(object["claude_device_ids"] as? [String], ["device-1"])
        XCTAssertNil(object["disabled"])
    }

    func testDuplicateEntriesAreWrittenOnce() throws {
        let first = try XCTUnwrap(ProviderBulkImport.parse([
            "email": "same@example.com",
            "access_token": "a",
            "refresh_token": "r",
        ], kind: .claude))
        let second = try XCTUnwrap(ProviderBulkImport.parse([
            "email": "SAME@example.com",
            "access_token": "b",
            "refresh_token": "r2",
        ], kind: .claude))

        let written = try ProviderBulkImport.write([first, second], to: directory)
        XCTAssertEqual(written.claude, 1)
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

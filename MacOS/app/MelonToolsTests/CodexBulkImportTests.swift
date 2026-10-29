import XCTest
@testable import MelonTools

final class CodexBulkImportTests: XCTestCase {
    func testCockpitArrayImportKeepsRefreshTokenAndAccountId() throws {
        let text = """
        [
          {
            "email": "user@example.com",
            "account_id": "3cc8f901-de86-4f42-af0e-9d111ce21885",
            "access_token": "access-1",
            "refresh_token": "refresh-1",
            "id_token": "id-1"
          }
        ]
        """
        let result = try CodexBulkImport.parse(text)
        XCTAssertEqual(result.accounts.count, 1)
        let account = try XCTUnwrap(result.accounts.first)
        XCTAssertEqual(account.tokens.refresh_token, "refresh-1")
        XCTAssertEqual(account.tokens.access_token, "access-1")
        XCTAssertEqual(account.accountId, "3cc8f901-de86-4f42-af0e-9d111ce21885")
        XCTAssertEqual(account.email, "user@example.com")
    }

    func testSub2APIImportReadsCodexAndProviderCredentials() throws {
        let text = """
        {
          "type": "sub2api-data",
          "version": 1,
          "accounts": [
            {
              "name": "user@example.com",
              "platform": "openai",
              "type": "oauth",
              "credentials": {
                "email": "user@example.com",
                "chatgpt_account_id": "acct-2",
                "access_token": "access-2",
                "refresh_token": "refresh-2",
                "id_token": "id-2"
              }
            },
            {
              "name": "other@example.com",
              "platform": "anthropic",
              "credentials": { "access_token": "x", "refresh_token": "y" }
            },
            {
              "name": "google@example.com",
              "platform": "antigravity",
              "credentials": { "access_token": "g", "refresh_token": "gr", "project_id": "p" }
            }
          ]
        }
        """
        let result = try CodexBulkImport.parse(text)
        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(result.providers.count, 2)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.accounts.first?.tokens.refresh_token, "refresh-2")
        XCTAssertEqual(result.accounts.first?.accountId, "acct-2")
        XCTAssertEqual(result.providers.first?.kind, .claude)
        XCTAssertEqual(result.providers.last?.projectID, "p")
    }

    func testProviderOnlyExportIsAccepted() throws {
        let text = """
        [{"platform":"claude","email":"c@example.com","access_token":"x","refresh_token":"y"}]
        """
        let result = try CodexBulkImport.parse(text)
        XCTAssertTrue(result.accounts.isEmpty)
        XCTAssertEqual(result.providers.count, 1)
        XCTAssertEqual(result.skipped, 0)
    }

    func testBulkImportRejectsMissingTokens() {
        XCTAssertThrowsError(try CodexBulkImport.parse("[]"))
        XCTAssertThrowsError(try CodexBulkImport.parse("{\"accounts\":[{\"email\":\"a@b.c\"}]}"))
    }

    func testDuplicateAccountIdsAreSkipped() throws {
        let text = """
        [
          {"account_id":"same","access_token":"a","refresh_token":"r"},
          {"account_id":"same","access_token":"b","refresh_token":"r2"}
        ]
        """
        let result = try CodexBulkImport.parse(text)
        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(result.skipped, 1)
    }
}

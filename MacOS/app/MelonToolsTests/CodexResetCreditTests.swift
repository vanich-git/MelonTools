import XCTest
@testable import MelonTools

final class CodexResetCreditTests: XCTestCase {
    func testParsesAvailableResetCreditsAndNearestExpiry() throws {
        let data = Data(#"""
        {
          "available_count": 2,
          "credits": [
            {
              "id": "RateLimitResetCredit_b",
              "status": "available",
              "title": "Full reset (Weekly + 5 hr)",
              "granted_at": "2026-06-17T00:00:00Z",
              "expires_at": "2026-08-20T10:00:00Z"
            },
            {
              "id": "RateLimitResetCredit_a",
              "status": "available",
              "granted_at": "2026-06-18T00:00:00Z",
              "expires_at": "2026-08-10T10:00:00Z"
            },
            {
              "id": "RateLimitResetCredit_used",
              "status": "redeemed",
              "expires_at": "2026-07-01T10:00:00Z"
            }
          ]
        }
        """#.utf8)

        let details = try CodexService.parseResetCredits(data)

        XCTAssertEqual(details.available, 2)
        XCTAssertEqual(details.credits.map(\.id), ["RateLimitResetCredit_b", "RateLimitResetCredit_a"])
        XCTAssertEqual(details.credits.first?.title, "Full reset (Weekly + 5 hr)")
        XCTAssertNotNil(details.credits.first?.grantedAt)
        XCTAssertEqual(details.nextExpiry, ISO8601DateFormatter().date(from: "2026-08-10T10:00:00Z"))
    }

    func testParsesNestedResetCreditResponse() throws {
        let data = Data(#"""
        {
          "data": {
            "availableCount": 1,
            "credits": [
              { "credit_id": "credit-1", "status": "available", "expires_at": 1800000000 }
            ]
          }
        }
        """#.utf8)

        let details = try CodexService.parseResetCredits(data)

        XCTAssertEqual(details.available, 1)
        XCTAssertEqual(details.credits.map(\.id), ["credit-1"])
        XCTAssertEqual(details.nextExpiry, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testEmptyCreditListFallsBackToZeroWhenRecordArrayIsPresent() throws {
        let details = try CodexService.parseResetCredits(Data(#"{"available_count": 0, "credits": []}"#.utf8))
        XCTAssertEqual(details.available, 0)
        XCTAssertTrue(details.credits.isEmpty)
        XCTAssertNil(details.nextExpiry)
    }

    func testParsesEveryConsumeOutcomeInBothNamingStyles() throws {
        func outcome(_ json: String) throws -> CodexService.ResetCreditOutcome {
            try CodexService.parseResetCreditOutcome(Data(json.utf8))
        }

        XCTAssertEqual(try outcome(#"{"outcome": "reset"}"#), .reset)
        XCTAssertEqual(try outcome(#"{"outcome": "nothing_to_reset"}"#), .nothingToReset)
        XCTAssertEqual(try outcome(#"{"code": "nothingToReset"}"#), .nothingToReset)
        XCTAssertEqual(try outcome(#"{"outcome": "no_credit"}"#), .noCredit)
        XCTAssertEqual(try outcome(#"{"code": "noCredit"}"#), .noCredit)
        XCTAssertEqual(try outcome(#"{"outcome": "already_redeemed"}"#), .alreadyRedeemed)
        XCTAssertEqual(try outcome(#"{"code": "alreadyRedeemed"}"#), .alreadyRedeemed)
    }

    func testUnknownConsumeOutcomeThrows() {
        XCTAssertThrowsError(try CodexService.parseResetCreditOutcome(Data(#"{"outcome": "mystery"}"#.utf8)))
        XCTAssertThrowsError(try CodexService.parseResetCreditOutcome(Data(#"{"outcome": null}"#.utf8)))
    }
}

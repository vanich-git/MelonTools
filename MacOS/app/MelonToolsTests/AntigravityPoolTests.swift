import XCTest
@testable import MelonTools

final class AntigravityPoolTests: XCTestCase {

    /// The dashboard card must agree with the Providers card: a paused account
    /// or one in a cooldown cannot serve a request, and the two 5-hour pools
    /// are summed separately because Antigravity has no weekly window.
    func testDashboardHealthCountsPausedAndCoolingAccounts() {
        func account(
            _ name: String,
            disabled: Bool = false,
            cooling: Bool = false,
            gemini: Double? = nil,
            claude: Double? = nil,
            error: String? = nil
        ) -> AntigravityAccount {
            AntigravityAccount(
                name: name,
                email: nil,
                projectID: nil,
                authIndex: nil,
                priority: 0,
                disabled: disabled,
                status: nil,
                statusMessage: nil,
                unavailable: false,
                cooldowns: cooling
                    ? [AntigravityCooldown(
                        scope: "account",
                        modelKey: nil,
                        reason: "quota",
                        retryAt: nil,
                        remainingSeconds: 60,
                        httpStatus: nil
                    )]
                    : [],
                modelIDs: [],
                geminiQuota: gemini.map {
                    AntigravityQuotaWindow(remaining: $0, resetAt: nil, modelIDs: [])
                },
                claudeQuota: claude.map {
                    AntigravityQuotaWindow(remaining: $0, resetAt: nil, modelIDs: [])
                },
                quotaError: error
            )
        }

        let accounts = [
            account("a", gemini: 1, claude: 0.5),
            account("b", disabled: true, gemini: 0.25, claude: 1),
            account("c", cooling: true),
            account("d", error: "quota"),
        ]
        let health = DashboardMetrics.antigravityHealth(accounts: accounts)

        XCTAssertEqual(health.total, 4)
        XCTAssertEqual(health.usable, 2)
        XCTAssertEqual(health.paused, 2)
        XCTAssertEqual(health.errors, 1)
        XCTAssertEqual(health.geminiTotal ?? -1, 125, accuracy: 0.001)
        XCTAssertEqual(health.claudeTotal ?? -1, 150, accuracy: 0.001)
    }

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

    func testWatchdogModelsCoversEveryFirstTokenCooldown() {
        let cooldowns = [
            AntigravityCooldown(scope: "model", modelKey: "gemini-3.8-flash-high",
                                reason: "transient_error", retryAt: nil,
                                remainingSeconds: 60, httpStatus: 504),
            AntigravityCooldown(scope: "model", modelKey: "gemini-2.5-pro",
                                reason: "transient_error", retryAt: nil,
                                remainingSeconds: 60, httpStatus: 504),
            AntigravityCooldown(scope: "model", modelKey: "gemini-3.8-flash-high",
                                reason: "transient_error", retryAt: nil,
                                remainingSeconds: 60, httpStatus: 504),
            AntigravityCooldown(scope: "model", modelKey: "gemini-3.8-flash-low",
                                reason: "quota", retryAt: nil,
                                remainingSeconds: 600, httpStatus: 429),
        ]
        XCTAssertEqual(
            AntigravityPoolStore.watchdogModels(in: cooldowns),
            ["gemini-2.5-pro", "gemini-3.8-flash-high"]
        )
    }

    func testWatchdogModelsIgnoresQuotaOnlyCooldowns() {
        let cooldowns = [
            AntigravityCooldown(scope: "credential", modelKey: nil,
                                reason: "credential_quota", retryAt: nil,
                                remainingSeconds: 600, httpStatus: 429),
        ]
        XCTAssertTrue(AntigravityPoolStore.watchdogModels(in: cooldowns).isEmpty)
    }
}

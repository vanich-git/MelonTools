import XCTest
@testable import MelonTools

final class CodexLiveQuotaTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testParsesLiveSignalsFromManagementResponse() throws {
        let data = Data(#"""
        {
          "name": "codex-a.json",
          "auth_index": "auth-a",
          "disabled": false,
          "provider": "codex",
          "quota": {
            "observed_at": "2027-01-15T08:00:00Z",
            "signals": {
              "X-Codex-Primary-Used-Percent": "98",
              "X-Codex-Primary-Window-Minutes": "300",
              "X-Codex-Primary-Reset-After-Seconds": "120",
              "X-Codex-Secondary-Used-Percent": "27.5"
            }
          }
        }
        """#.utf8)
        let file = try JSONDecoder().decode(CodexManagementAuthFile.self, from: data)
        let quota = try XCTUnwrap(file.quota)
        let reading = try XCTUnwrap(CodexLiveQuota.parse(
            signals: quota.signals,
            observedAt: try XCTUnwrap(quota.observedAt)
        ))

        XCTAssertEqual(file.authIndex, "auth-a")
        XCTAssertEqual(reading.quota.hourlyRemainingPercent, 2)
        XCTAssertEqual(reading.quota.weeklyRemainingPercent, 72.5)
        XCTAssertEqual(reading.quota.hourlyWindowMinutes, 300)
        XCTAssertEqual(reading.quota.hourlyResetAt, reading.observedAt.addingTimeInterval(120))
    }

    func testExactReserveThresholdBlocksWithoutMargin() {
        var quota = CodexQuota()
        quota.hourlyRemainingPercent = 2
        XCTAssertEqual(
            CodexRoutingPlanner.quotaBlockCause(
                quota: quota,
                hourlyReserve: 2,
                weeklyReserve: nil,
                isFresh: true
            ),
            .hourlyReserve
        )

        quota.hourlyRemainingPercent = 2.0001
        XCTAssertNil(CodexRoutingPlanner.quotaBlockCause(
            quota: quota,
            hourlyReserve: 2,
            weeklyReserve: nil,
            isFresh: true
        ))
    }

    func testStaleReadingCannotCreateOrLiftBlockButPersistedPauseSticks() {
        var quota = CodexQuota()
        quota.hourlyRemainingPercent = 100
        var account = CodexAccount(tokens: CodexTokens())
        account.hourlyReservePercent = 2
        account.quota = quota
        account.quotaUpdatedAt = Date().addingTimeInterval(-CodexLiveQuota.maxSignalAge - 10)
        account.quotaSource = "gateway"

        XCTAssertNil(CodexRoutingPlanner.blockCause(account))

        let block = CodexQuotaBlock(
            cause: .hourlyReserve,
            remainingPercent: 1.8,
            thresholdPercent: 2,
            resetAt: observedAt,
            blockedAt: observedAt,
            source: "gateway"
        )
        account.quotaBlock = block
        XCTAssertEqual(CodexRoutingPlanner.blockCause(account), .hourlyReserve)
        XCTAssertFalse(CodexRoutingPlanner.blockRecovered(
            block,
            quota: quota,
            hourlyReserve: 2,
            weeklyReserve: nil,
            isFresh: false
        ))
        XCTAssertTrue(CodexRoutingPlanner.blockReason(account)?.contains("1.8%") == true)
    }

    func testFreshReadingAboveReserveRecoversBlock() {
        var quota = CodexQuota()
        quota.hourlyRemainingPercent = 2.01
        let block = CodexQuotaBlock(
            cause: .hourlyReserve,
            remainingPercent: 2,
            thresholdPercent: 2,
            resetAt: observedAt,
            blockedAt: observedAt,
            source: "gateway"
        )
        XCTAssertTrue(CodexRoutingPlanner.blockRecovered(
            block,
            quota: quota,
            hourlyReserve: 2,
            weeklyReserve: nil,
            isFresh: true
        ))
    }

    func testSignalParserIgnoresUnrelatedHeadersAndClampsPercent() {
        XCTAssertNil(CodexLiveQuota.parse(signals: ["Retry-After": "30"], observedAt: observedAt))

        let reading = CodexLiveQuota.parse(
            signals: ["X-Codex-Primary-Used-Percent": "120"],
            observedAt: observedAt
        )
        XCTAssertEqual(reading?.quota.hourlyRemainingPercent, 0)
    }
}

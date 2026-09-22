import XCTest
@testable import AIUsageWidget

final class ClaudeQuotaTests: XCTestCase {
    private func parse(_ text: String, isError: Bool = false) throws -> ClaudeUsageData {
        let output = try JSONSerialization.data(withJSONObject: ["is_error": isError, "result": text])
        var data = ClaudeUsageData()
        ClaudeDataReader.applyUsageOutput(output, to: &data)
        return data
    }

    func testAccountWindowsIgnoreLocalContributionPercentages() throws {
        let data = try parse("""
        Current session: 9% used · resets today
        Current week (all models): 45% used · resets Friday
        Current week (Fable): 80% used · resets Friday
        Approximate, based on local sessions on this machine
          75% of your usage was at >150k context
        """)
        XCTAssertEqual(data.sessionUsedPct, 9)
        XCTAssertEqual(data.weekAllModelsPct, 45)
        XCTAssertEqual(data.weekFablePct, 80)
        XCTAssertEqual(data.weekModelLabel, "Fable")
        XCTAssertEqual(data.weekAllModelsReset, "Friday")
        XCTAssertNotNil(data.quotaFetchedAt)
        XCTAssertEqual(UsageManager.claudeWeeklyMenuBarText(for: data), "45%")
    }

    func testPartialResponseDoesNotInventWeeklyZero() throws {
        let data = try parse("Current session: 25% used")
        XCTAssertTrue(data.hasLiveStatus)
        XCTAssertNil(data.weekAllModelsPct)
        XCTAssertNil(data.weekFablePct)
        XCTAssertNil(UsageManager.claudeWeeklyMenuBarText(for: data))
    }

    func testActualZeroAndDecimalRemainValid() throws {
        let data = try parse("Current session: 0% used\nCurrent week (all models): 12.5% used")
        XCTAssertEqual(data.sessionUsedPct, 0)
        XCTAssertEqual(data.weekAllModelsPct, 12.5)
        XCTAssertNil(data.weekFablePct)
    }

    func testInvalidOrUnrelatedPercentagesAreRejected() throws {
        for line in ["Current session: -5% used", "Current session: 101% used",
                     "Current session: unavailable; 20% used previously", "Current session: 20% remaining",
                     "Example: Current session: 25% used", "75% of your usage was at >150k context"] {
            let data = try parse(line)
            XCTAssertFalse(data.hasLiveStatus, line)
            XCTAssertNil(data.quotaFetchedAt)
            XCTAssertFalse(data.liveError.isEmpty)
        }
    }

    func testErrorResponseCannotSupplyQuota() throws {
        let data = try parse("Current week (all models): 45% used", isError: true)
        XCTAssertFalse(data.hasLiveStatus)
        XCTAssertNil(UsageManager.claudeWeeklyMenuBarText(for: data))
    }

    func testMalformedResponseClearsPreviouslyParsedQuota() throws {
        var data = try parse("Current week (all models): 45% used · resets Friday")
        ClaudeDataReader.applyUsageOutput(Data("not json".utf8), to: &data)
        XCTAssertNil(data.weekAllModelsPct)
        XCTAssertEqual(data.weekAllModelsReset, "")
        XCTAssertNil(data.quotaFetchedAt)
        XCTAssertFalse(data.hasLiveStatus)
    }
}

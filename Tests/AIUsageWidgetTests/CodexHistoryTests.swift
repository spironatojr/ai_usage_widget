import XCTest
@testable import AIUsageWidget

final class CodexHistoryTests: XCTestCase {
    private var directory: URL!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")! }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func event(_ date: String, total: Int, cached: Int = 0, lastTotal: Int? = nil,
                       lastCached: Int = 0, model: String = "gpt-5") throws -> Data {
        let totals: [String: Any] = ["input_tokens": 0, "output_tokens": 0,
            "cached_input_tokens": cached, "total_tokens": total]
        var info: [String: Any] = ["total_token_usage": totals]
        if let lastTotal {
            info["last_token_usage"] = ["input_tokens": 0, "output_tokens": 0,
                "cached_input_tokens": lastCached, "total_tokens": lastTotal]
        }
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "session-1"]],
            ["type": "turn_context", "payload": ["model": model]],
            ["type": "event_msg", "timestamp": date,
             "payload": ["type": "token_count", "info": info]]
        ]
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(10)
        }
        return data
    }

    func testAttributesCumulativeUsageToEventDayAndExcludesCacheReads() throws {
        var bytes = try event("2026-09-21T23:59:00Z", total: 1000, cached: 400, lastTotal: 1000, lastCached: 400)
        bytes.append(try event("2026-09-22T00:01:00Z", total: 1250, cached: 500, lastTotal: 250, lastCached: 100, model: "gpt-5-codex"))
        try bytes.write(to: directory.appendingPathComponent("session.jsonl"))
        try bytes.write(to: directory.appendingPathComponent("copied.jsonl"))
        let reader = CodexHistoryReader(roots: [directory])
        var data = CodexUsageData()

        reader.apply(to: &data, now: now, calendar: calendar)

        XCTAssertEqual(data.dailyUsage.first { $0.date == "2026-09-21" }?.tokensUsed, 600)
        XCTAssertEqual(data.dailyUsage.first { $0.date == "2026-09-22" }?.tokensUsed, 150)
        XCTAssertEqual(data.totalTokens, 750)
        XCTAssertEqual(data.modelBreakdown.first { $0.modelName == "gpt-5-codex" }?.totalTokens, 150)
        XCTAssertEqual(data.totalSessions, 1)
        XCTAssertFalse(data.historyIsPartial)
        XCTAssertEqual(reader.filesReadLastRefresh, 2)
        reader.apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(reader.filesReadLastRefresh, 0)
        XCTAssertEqual(data.totalTokens, 750)
    }

    func testBaselineAndResetWithoutTurnDeltaArePartialAndDoNotInventUsage() throws {
        var bytes = try event("2026-09-22T09:00:00Z", total: 10_000)
        bytes.append(try event("2026-09-22T10:00:00Z", total: 100))
        bytes.append(try event("2026-09-22T11:00:00Z", total: 250, lastTotal: 150))
        try bytes.write(to: directory.appendingPathComponent("partial.jsonl"))
        var data = CodexUsageData()
        CodexHistoryReader(roots: [directory]).apply(to: &data, now: now, calendar: calendar)

        XCTAssertEqual(data.todayTokens, 150)
        XCTAssertTrue(data.historyIsPartial)
        XCTAssertFalse(data.historyDiagnostic.isEmpty)
    }

    func testIncompleteTrailingLineDoesNotBreakValidHistory() throws {
        var bytes = try event("2026-09-22T09:00:00Z", total: 500, lastTotal: 500)
        bytes.append(Data("{\"type\":\"event_msg\"".utf8))
        try bytes.write(to: directory.appendingPathComponent("tail.jsonl"))
        var data = CodexUsageData()
        CodexHistoryReader(roots: [directory]).apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(data.todayTokens, 500)
    }
}

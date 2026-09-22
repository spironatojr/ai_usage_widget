import XCTest
@testable import AIUsageWidget

final class ClaudeHistoryTests: XCTestCase {
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

    private func record(_ id: String, date: String = "2026-09-21T12:00:00Z", output: Int = 10,
                        model: String = "test-model", session: String = "session1",
                        sidechain: Bool = false, includeID: Bool = true) throws -> Data {
        var message: [String: Any] = [
            "model": model, "usage": ["input_tokens": 100, "output_tokens": output,
                "cache_creation_input_tokens": 20, "cache_read_input_tokens": 999],
            "content": [["type": "tool_use", "id": "tool1", "name": "Read"]]
        ]
        if includeID { message["id"] = id }
        let root: [String: Any] = ["type": "assistant", "timestamp": date, "sessionId": session,
                                  "isSidechain": sidechain, "message": message]
        var result = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        result.append(10)
        return result
    }

    func testRebuildsPastDaysWithoutStatsCacheAndDeduplicatesStreamingAndCopies() throws {
        var records = try record("message1")
        records.append(try record("message1", output: 30))
        try records.write(to: directory.appendingPathComponent("one.jsonl"))
        try records.write(to: directory.appendingPathComponent("copy.jsonl"))
        let reader = ClaudeHistoryReader(projectsURL: directory)
        var data = ClaudeUsageData()
        reader.apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(data.totalMessages, 1)
        XCTAssertEqual(data.totalSessions, 1)
        XCTAssertEqual(data.grandTotalTokens, 150)
        XCTAssertEqual(data.dailyModelTokens.first?.totalTokens, 150)
        XCTAssertEqual(data.dailyActivity.first?.date, "2026-09-21")
        XCTAssertEqual(data.dailyActivity.first?.toolCallCount, 1)
        XCTAssertEqual(data.modelUsage.first?.cacheReadInputTokens, 999)
        XCTAssertEqual(reader.filesReadLastRefresh, 2)
        reader.apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(reader.filesReadLastRefresh, 0)
        XCTAssertEqual(data.grandTotalTokens, 150)
    }

    func testIncrementalRefreshHandlesAppendTruncateAndDelete() throws {
        let file = directory.appendingPathComponent("session.jsonl")
        var bytes = try record("one")
        try bytes.write(to: file)
        let reader = ClaudeHistoryReader(projectsURL: directory)
        var data = ClaudeUsageData()
        reader.apply(to: &data, now: now, calendar: calendar)
        bytes.append(try record("two", sidechain: true))
        try bytes.write(to: file)
        reader.apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(data.totalMessages, 2)
        XCTAssertEqual(data.totalSessions, 1)
        XCTAssertEqual(data.grandTotalTokens, 260)
        XCTAssertEqual(reader.filesReadLastRefresh, 1)
        try Data().write(to: file)
        reader.apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(data.totalMessages, 0)
        try FileManager.default.removeItem(at: file)
        reader.apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(data.grandTotalTokens, 0)
    }

    func testThirtyDayWindowAndLocalDayBoundary() throws {
        var local = calendar
        local.timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
        var bytes = try record("old", date: "2026-08-24T02:59:59Z")
        bytes.append(try record("boundary", date: "2026-08-24T03:00:00Z"))
        bytes.append(try record("yesterday", date: "2026-09-22T02:00:00Z"))
        bytes.append(try record("future", date: "2026-09-23T00:00:00Z"))
        try bytes.write(to: directory.appendingPathComponent("dates.jsonl"))
        var data = ClaudeUsageData()
        ClaudeHistoryReader(projectsURL: directory).apply(to: &data, now: now, calendar: local)
        XCTAssertEqual(data.totalMessages, 2)
        XCTAssertEqual(data.dailyActivity.map(\.date), ["2026-08-24", "2026-09-21"])
    }

    func testStableFallbackIDsAndIncompleteTail() throws {
        let file = directory.appendingPathComponent("session.jsonl")
        let line = try record("unused", includeID: false)
        var bytes = line
        bytes.append(line)
        bytes.append(Data("{\"type\":".utf8))
        try bytes.write(to: file)
        let reader = ClaudeHistoryReader(projectsURL: directory)
        var data = ClaudeUsageData()
        reader.apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(data.totalMessages, 1)
        XCTAssertEqual(data.grandTotalTokens, 130)
        XCTAssertTrue(data.historyDiagnostic.isEmpty)
        var completed = line
        completed.append(try record("completed"))
        try completed.write(to: file)
        reader.apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(data.totalMessages, 2)
    }

    func testMalformedRecordReportsPartialHistoryWithoutLosingValidUsage() throws {
        var bytes = Data("not-json\n".utf8)
        bytes.append(try record("valid"))
        try bytes.write(to: directory.appendingPathComponent("mixed.jsonl"))
        var data = ClaudeUsageData()
        ClaudeHistoryReader(projectsURL: directory).apply(to: &data, now: now, calendar: calendar)
        XCTAssertEqual(data.grandTotalTokens, 130)
        XCTAssertTrue(data.historyDiagnostic.contains("1 skipped records"))
    }

    func testSyntheticAssistantRecordDoesNotCountAsLocalUsage() throws {
        var bytes = try record("internal", model: "<synthetic>", session: "internal-session")
        bytes.append(try record("real"))
        try bytes.write(to: directory.appendingPathComponent("session.jsonl"))

        var data = ClaudeUsageData()
        ClaudeHistoryReader(projectsURL: directory).apply(to: &data, now: now, calendar: calendar)

        XCTAssertEqual(data.totalMessages, 1)
        XCTAssertEqual(data.totalSessions, 1)
        XCTAssertEqual(data.grandTotalTokens, 130)
        XCTAssertEqual(data.modelUsage.map(\.modelName), ["test-model"])
        XCTAssertEqual(data.dailyActivity.first?.messageCount, 1)
        XCTAssertEqual(data.dailyActivity.first?.toolCallCount, 1)
        XCTAssertTrue(data.historyDiagnostic.isEmpty)
    }

    func testClaudeModelDisplayNamesKeepVersionsDistinct() throws {
        var bytes = try record("opus-5", model: "claude-opus-5")
        bytes.append(try record("opus-5-5", model: "claude-opus-5-5"))
        try bytes.write(to: directory.appendingPathComponent("models.jsonl"))

        var data = ClaudeUsageData()
        ClaudeHistoryReader(projectsURL: directory).apply(to: &data, now: now, calendar: calendar)

        XCTAssertEqual(data.modelUsage.map(\.modelName), ["claude-opus-5", "claude-opus-5-5"])
        XCTAssertEqual(data.modelUsage.map(\.displayName), ["Claude Opus 5", "Claude Opus 5.5"])
        XCTAssertEqual(data.grandTotalTokens, 260)
    }
}

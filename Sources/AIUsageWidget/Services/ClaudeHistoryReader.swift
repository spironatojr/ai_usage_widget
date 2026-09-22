import Foundation
import CryptoKit

/// Reads local transcript metadata only; never writes to Claude's files.
final class ClaudeHistoryReader {
    private struct Tokens {
        var input: Int64 = 0
        var output: Int64 = 0
        var read: Int64 = 0
        var created: Int64 = 0

        mutating func mergeSnapshot(_ other: Tokens) {
            input = max(input, other.input)
            output = max(output, other.output)
            read = max(read, other.read)
            created = max(created, other.created)
        }
    }

    private struct Record {
        let id: String
        var timestamp: Date
        var sessions: Set<String>
        var model: String?
        var tokens: Tokens
        var tools: Set<String>
    }

    private struct CachedFile {
        let modified: Date
        let size: Int
        let records: [Record]
        let skipped: Int
    }

    private let projectsURL: URL
    private let lock = NSLock()
    private var cache: [URL: CachedFile] = [:]
    private var previousStart: Date?
    private let fractional = ISO8601DateFormatter()
    private let wholeSeconds = ISO8601DateFormatter()
    private(set) var filesReadLastRefresh = 0

    init(projectsURL: URL) {
        self.projectsURL = projectsURL
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func apply(to data: inout ClaudeUsageData, now: Date = Date(), calendar: Calendar = .current) {
        lock.lock()
        defer { lock.unlock() }
        let start = calendar.date(byAdding: .day, value: -(data.historyDays - 1), to: calendar.startOfDay(for: now))!
        // If the clock/time zone moves the window backwards, discarded records
        // may become relevant again and must be reread.
        if let previousStart, start < previousStart { cache.removeAll() }
        previousStart = start
        filesReadLastRefresh = 0
        var unavailable = 0
        var skipped = 0
        var present = Set<URL>()
        var records: [String: Record] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: projectsURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, _ in unavailable += 1; return true }
        )
        if let enumerator {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                present.insert(url)
                do {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    guard values.isRegularFile == true else { continue }
                    let modified = values.contentModificationDate ?? .distantPast
                    let size = values.fileSize ?? 0
                    let cached: CachedFile
                    if let existing = cache[url], existing.modified == modified, existing.size == size {
                        cached = existing
                    } else {
                        cached = try read(url, modified: modified, size: size, since: start)
                        cache[url] = cached
                        filesReadLastRefresh += 1
                    }
                    skipped += cached.skipped
                    for record in cached.records where record.timestamp >= start && record.timestamp <= now {
                        if var existing = records[record.id] {
                            // Streaming snapshots can repeat an ID with growing
                            // cumulative counts. Keep maxima, not their sum.
                            existing.tokens.mergeSnapshot(record.tokens)
                            existing.tools.formUnion(record.tools)
                            existing.sessions.formUnion(record.sessions)
                            existing.timestamp = min(existing.timestamp, record.timestamp)
                            if existing.model == nil { existing.model = record.model }
                            records[record.id] = existing
                        } else {
                            records[record.id] = record
                        }
                    }
                } catch {
                    cache.removeValue(forKey: url)
                    unavailable += 1
                }
            }
        }
        cache = cache.filter { present.contains($0.key) }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var dailyMessages: [String: Int] = [:]
        var dailySessions: [String: Set<String>] = [:]
        var dailyTools: [String: Int] = [:]
        var dailyTokens: [String: [String: Int64]] = [:]
        var modelTokens: [String: Tokens] = [:]
        var sessions = Set<String>()
        for record in records.values {
            let day = formatter.string(from: record.timestamp)
            dailyMessages[day, default: 0] += 1
            dailySessions[day, default: []].formUnion(record.sessions)
            sessions.formUnion(record.sessions)
            dailyTools[day, default: 0] += record.tools.count
            guard let model = record.model else { continue }
            let tokens = record.tokens
            dailyTokens[day, default: [:]][model, default: 0] += tokens.input + tokens.output + tokens.created
            var total = modelTokens[model] ?? Tokens()
            total.input += tokens.input
            total.output += tokens.output
            total.read += tokens.read
            total.created += tokens.created
            modelTokens[model] = total
        }
        data.dailyActivity = dailyMessages.keys.sorted().map {
            ClaudeDailyActivity(date: $0, messageCount: dailyMessages[$0] ?? 0,
                               sessionCount: dailySessions[$0]?.count ?? 0, toolCallCount: dailyTools[$0] ?? 0)
        }
        data.dailyModelTokens = dailyTokens.keys.sorted().map {
            ClaudeDailyModelTokens(date: $0, tokensByModel: dailyTokens[$0] ?? [:])
        }
        data.modelUsage = modelTokens.map {
            ClaudeModelDetail(modelName: $0.key, inputTokens: $0.value.input, outputTokens: $0.value.output,
                              cacheReadInputTokens: $0.value.read, cacheCreationInputTokens: $0.value.created)
        }.sorted { $0.totalTokens == $1.totalTokens ? $0.modelName < $1.modelName : $0.totalTokens > $1.totalTokens }
        data.totalMessages = records.count
        data.totalSessions = sessions.count
        data.historyUpdatedAt = now
        data.historyIsAvailable = FileManager.default.fileExists(atPath: projectsURL.path)
        data.historyIsPartial = unavailable > 0 || skipped > 0
        if unavailable > 0 || skipped > 0 {
            data.historyDiagnostic = "Local history may be incomplete: \(unavailable) unreadable files, \(skipped) skipped records."
        } else if records.isEmpty {
            data.historyDiagnostic = "No local Claude activity found in the last \(data.historyDays) days."
        } else {
            data.historyDiagnostic = ""
        }
    }

    private func read(_ url: URL, modified: Date, size: Int, since start: Date) throws -> CachedFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var records: [Record] = []
        var skipped = 0
        var droppingLongLine = false
        let maximumLineBytes = 8 * 1024 * 1024
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            var cursor = buffer.startIndex
            while let newline = buffer[cursor...].firstIndex(of: 10) {
                if !droppingLongLine {
                    if newline - cursor <= maximumLineBytes {
                        parse(Data(buffer[cursor..<newline]), since: start, records: &records, skipped: &skipped)
                    } else { skipped += 1 }
                }
                droppingLongLine = false
                cursor = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<cursor)
            if buffer.count > maximumLineBytes {
                if !droppingLongLine { skipped += 1 }
                buffer.removeAll(keepingCapacity: true)
                droppingLongLine = true
            }
        }
        // An active session may have an unfinished final JSON line. Retry it
        // when the file grows, without marking ordinary streaming as corruption.
        if !droppingLongLine, !buffer.isEmpty,
           (try? JSONSerialization.jsonObject(with: buffer)) != nil {
            parse(buffer, since: start, records: &records, skipped: &skipped)
        }
        return CachedFile(modified: modified, size: size, records: records, skipped: skipped)
    }

    private func parse(_ line: Data, since start: Date, records: inout [Record], skipped: inout Int) {
        guard !line.isEmpty else { return }
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            skipped += 1
            return
        }
        guard let type = root["type"] as? String, type == "assistant" || type == "user",
              root["isMeta"] as? Bool != true else { return }
        guard let rawTimestamp = root["timestamp"] as? String,
              let timestamp = fractional.date(from: rawTimestamp) ?? wholeSeconds.date(from: rawTimestamp),
              let message = root["message"] as? [String: Any] else { skipped += 1; return }
        guard timestamp >= start else { return }
        // Claude Code uses this marker for internal assistant records, not a model response.
        guard type != "assistant" || message["model"] as? String != "<synthetic>" else { return }
        let messageID = type == "assistant" ? message["id"] as? String : nil
        let id = messageID ?? (root["uuid"] as? String) ?? {
            let canonical = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? line
            return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        }()
        var sessions = Set<String>()
        if root["isSidechain"] as? Bool != true, let session = root["sessionId"] as? String {
            sessions.insert(session)
        }
        var tokens = Tokens()
        var model: String?
        var tools = Set<String>()
        if type == "assistant" {
            if let usage = message["usage"] as? [String: Any] {
                // Reject unreasonable/corrupt counters rather than overflowing totals.
                func count(_ key: String) -> Int64 {
                    guard let value = usage[key] as? NSNumber else { return 0 }
                    let number = value.doubleValue
                    guard number.isFinite, number >= 0, number <= 1_000_000_000_000 else { return 0 }
                    return value.int64Value
                }
                tokens = Tokens(input: count("input_tokens"), output: count("output_tokens"),
                                read: count("cache_read_input_tokens"), created: count("cache_creation_input_tokens"))
                model = message["model"] as? String
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                tools.insert((block["id"] as? String) ?? {
                    let encoded = (try? JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])) ?? Data()
                    return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
                }())
            }
        }
        records.append(Record(id: "\(type):\(id)", timestamp: timestamp, sessions: sessions,
                              model: model, tokens: tokens, tools: tools))
    }
}

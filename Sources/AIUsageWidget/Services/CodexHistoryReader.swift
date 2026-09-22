import Foundation

/// Builds usage from timestamped cumulative snapshots, never session creation dates.
final class CodexHistoryReader {
    private struct Counters {
        let total: Int64
        let cached: Int64
        var billable: Int64 { max(0, total - cached) }
        init?(_ value: Any?) {
            guard let object = value as? [String: Any],
                  let total = object["total_tokens"] as? NSNumber else { return nil }
            let cache = (object["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0
            guard total.doubleValue.isFinite, total.doubleValue >= 0, total.doubleValue <= 1_000_000_000_000,
                  cache >= 0, cache <= total.int64Value else { return nil }
            self.total = total.int64Value
            self.cached = cache
        }
    }
    private struct Event {
        let date: Date
        let model: String
        let total: Counters
        let last: Counters?
        let order: Int
    }
    private struct FileSnapshot {
        let modified: Date
        let size: Int
        let session: String
        let events: [Event]
        let skipped: Int
    }
    private let roots: [URL]
    private var cache: [URL: FileSnapshot] = [:]
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    private let wholeSeconds = ISO8601DateFormatter()
    private(set) var filesReadLastRefresh = 0

    init(roots: [URL]) {
        self.roots = roots
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func apply(to data: inout CodexUsageData, now: Date = Date(), calendar: Calendar = .current) {
        lock.lock()
        defer { lock.unlock() }
        filesReadLastRefresh = 0
        var present = Set<URL>()
        var sessions: [String: [Event]] = [:]
        var issues = 0
        var foundRoot = false
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            foundRoot = true
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
                errorHandler: { _, _ in issues += 1; return true }
            ) else { issues += 1; continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard present.insert(url).inserted else { continue }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    guard values.isRegularFile == true else { continue }
                    let modified = values.contentModificationDate ?? .distantPast
                    let size = values.fileSize ?? 0
                    let snapshot: FileSnapshot
                    if let old = cache[url], old.modified == modified, old.size == size {
                        snapshot = old
                    } else {
                        snapshot = try read(url, modified: modified, size: size)
                        cache[url] = snapshot
                        filesReadLastRefresh += 1
                    }
                    issues += snapshot.skipped
                    sessions[snapshot.session, default: []].append(contentsOf: snapshot.events)
                } catch { cache.removeValue(forKey: url); issues += 1 }
            }
        }
        cache = cache.filter { present.contains($0.key) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        var daily: [String: Int64] = [:]
        var dailySessions: [String: Set<String>] = [:]
        var models: [String: Int64] = [:]
        var modelSessions: [String: Set<String>] = [:]
        var allSessions = Set<String>()
        var weekSessions = Set<String>()
        var weekTokens: Int64 = 0
        for (session, events) in sessions {
            var previous: Counters?
            var seen = Set<String>()
            for event in events.sorted(by: { $0.date == $1.date ? $0.order < $1.order : $0.date < $1.date }) {
                guard event.date <= now else { continue }
                let key = "\(event.date.timeIntervalSince1970):\(event.total.total):\(event.total.cached)"
                guard seen.insert(key).inserted else { continue }
                let tokens: Int64
                if let old = previous {
                    if event.total.total == old.total && event.total.cached == old.cached { continue }
                    if event.total.total >= old.total && event.total.cached >= old.cached {
                        tokens = max(0, (event.total.total - old.total) - (event.total.cached - old.cached))
                    } else if let last = event.last {
                        tokens = last.billable
                    } else {
                        // A reset without a per-turn snapshot has no reliable delta.
                        previous = event.total
                        if event.date >= start { issues += 1 }
                        continue
                    }
                } else if let last = event.last {
                    tokens = last.billable
                    if event.total.total > last.total && event.date >= start { issues += 1 }
                } else {
                    // Do not attribute an unknown lifetime total to the first day
                    // of a partial transcript. Establish a baseline for later events.
                    previous = event.total
                    if event.date >= start { issues += 1 }
                    continue
                }
                previous = event.total
                guard event.date >= start else { continue }
                let day = formatter.string(from: event.date)
                daily[day, default: 0] += tokens
                dailySessions[day, default: []].insert(session)
                models[event.model, default: 0] += tokens
                modelSessions[event.model, default: []].insert(session)
                allSessions.insert(session)
                if event.date >= week {
                    weekTokens += tokens
                    weekSessions.insert(session)
                }
            }
        }
        data.dailyUsage = daily.keys.sorted(by: >).map {
            CodexDailyUsage(date: $0, sessionCount: dailySessions[$0]?.count ?? 0, tokensUsed: daily[$0] ?? 0)
        }
        data.modelBreakdown = models.map {
            CodexModelUsage(modelName: $0.key, sessionCount: modelSessions[$0.key]?.count ?? 0, totalTokens: $0.value)
        }.sorted { $0.totalTokens == $1.totalTokens ? $0.modelName < $1.modelName : $0.totalTokens > $1.totalTokens }
        data.totalTokens = daily.values.reduce(0, +)
        data.totalSessions = allSessions.count
        data.tokensIn1WeekWindow = weekTokens
        data.sessionsIn1WeekWindow = weekSessions.count
        data.historyIsAvailable = foundRoot
        data.historyIsPartial = issues > 0
        data.historyDiagnostic = issues > 0 ? "Local history is incomplete: \(issues) unreadable or missing records."
            : (foundRoot ? "" : "No local Codex session history found.")
    }

    private func read(_ url: URL, modified: Date, size: Int) throws -> FileSnapshot {
        var session = url.deletingPathExtension().lastPathComponent
        var model = "unknown"
        var events: [Event] = []
        var skipped = 0
        func parse(_ line: Data) {
            guard !line.isEmpty else { return }
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { skipped += 1; return }
            guard let payload = root["payload"] as? [String: Any] else { return }
            switch root["type"] as? String {
            case "session_meta":
                if let id = payload["id"] as? String { session = id }
            case "turn_context":
                if let name = payload["model"] as? String { model = name }
            case "event_msg":
                guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any] else { return }
                guard let timestamp = root["timestamp"] as? String,
                      let date = fractional.date(from: timestamp) ?? wholeSeconds.date(from: timestamp),
                      let total = Counters(info["total_token_usage"]) else { skipped += 1; return }
                events.append(Event(date: date, model: model, total: total,
                                    last: Counters(info["last_token_usage"]), order: events.count))
            default: break
            }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var dropping = false
        let maximumLine = 8 * 1024 * 1024
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            var cursor = buffer.startIndex
            while let newline = buffer[cursor...].firstIndex(of: 10) {
                if !dropping {
                    if newline - cursor <= maximumLine { parse(Data(buffer[cursor..<newline])) }
                    else { skipped += 1 }
                }
                dropping = false
                cursor = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<cursor)
            if buffer.count > maximumLine {
                if !dropping { skipped += 1 }
                dropping = true
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !dropping, !buffer.isEmpty, (try? JSONSerialization.jsonObject(with: buffer)) != nil { parse(buffer) }
        return FileSnapshot(modified: modified, size: size, session: session, events: events, skipped: skipped)
    }
}

import Foundation

class CodexDataReader {
    static let shared = CodexDataReader()
    
    private let historyReader: CodexHistoryReader
    private let authFilePath: String
    private let configFilePath: String
    private let sessionsDirectoryPath: String
    
    init(customPath: String? = nil) {
        if let path = customPath {
            self.authFilePath = (path as NSString).deletingLastPathComponent + "/auth.json"
            self.configFilePath = (path as NSString).deletingLastPathComponent + "/config.toml"
            self.sessionsDirectoryPath = (path as NSString).deletingLastPathComponent + "/sessions"
        } else {
            self.authFilePath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
            self.configFilePath = NSString(string: "~/.codex/config.toml").expandingTildeInPath
            self.sessionsDirectoryPath = NSString(string: "~/.codex/sessions").expandingTildeInPath
        }
        let sessions = URL(fileURLWithPath: sessionsDirectoryPath)
        self.historyReader = CodexHistoryReader(roots: [sessions, sessions.deletingLastPathComponent().appendingPathComponent("archived_sessions")])
    }
    
    func fetchUsageData() -> CodexUsageData {
        var data = CodexUsageData()
        
        // 1. Read Auth & Account Info from auth.json
        if FileManager.default.fileExists(atPath: authFilePath),
           let authData = try? Data(contentsOf: URL(fileURLWithPath: authFilePath)),
           let authRoot = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
           let idTokenStr = authRoot["tokens"] as? [String: Any],
           let idToken = idTokenStr["id_token"] as? String {
            
            let parts = idToken.components(separatedBy: ".")
            if parts.count >= 2,
               let payloadData = base64UrlDecode(parts[1]),
               let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                if let email = payload["email"] as? String {
                    data.accountEmail = email
                }
                if let authObj = payload["https://api.openai.com/auth"] as? [String: Any],
                   let plan = authObj["chatgpt_plan_type"] as? String {
                    data.accountPlan = plan.capitalized
                }
            }
        }
        
        // 2. Read Configured Model from config.toml
        if FileManager.default.fileExists(atPath: configFilePath),
           let configText = try? String(contentsOfFile: configFilePath, encoding: .utf8) {
            let lines = configText.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("model =") {
                    let parts = trimmed.components(separatedBy: "=")
                    if parts.count >= 2 {
                        let m = parts[1].trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        if !m.isEmpty {
                            data.activeModel = m
                        }
                    }
                }
            }
        }
        
        // 3. Query the same Codex account service used by the `/status` and
        // `/usage` screens. Fall back to the latest real CLI session snapshot
        // when the local app-server is unavailable.
        _ = applyLiveAccountStatus(to: &data)
        if data.fiveHourLimitUsedPct == nil || data.weeklyLimitUsedPct == nil {
            applyLatestRateLimits(to: &data)
        }

        // Attribute usage to token-event timestamps, including sessions spanning midnight.
        historyReader.apply(to: &data)

        return data
    }

    private func applyLatestRateLimits(to data: inout CodexUsageData) {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sessionsDirectoryPath),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let files = enumerator.compactMap { item -> (URL, Date)? in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(20)

        for (url, _) in files {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n").reversed() {
                guard let lineData = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let payload = root["payload"] as? [String: Any],
                      let rateLimits = payload["rate_limits"] as? [String: Any] else { continue }

                applyRateLimits(rateLimits, to: &data, onlyIfMissing: true)
                if data.fiveHourLimitUsedPct != nil && data.weeklyLimitUsedPct != nil {
                    return
                }
            }
        }
    }

    private func applyLiveAccountStatus(to data: inout CodexUsageData) -> Bool {
        guard let codexBinary = findCodexBinary() else { return false }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: codexBinary)
        task.arguments = ["app-server", "--stdio"]
        task.currentDirectoryURL = FileManager.default.temporaryDirectory
        task.standardError = FileHandle.nullDevice

        let homeDir = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        let codexBinDir = (codexBinary as NSString).deletingLastPathComponent
        var pathComponents = [
            codexBinDir,
            "\(homeDir)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let nvmRoot = "\(homeDir)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            pathComponents.append(contentsOf: versions.map { "\(nvmRoot)/\($0)/bin" })
        }
        env["PATH"] = pathComponents.joined(separator: ":")
        env["HOME"] = homeDir
        env["USER"] = NSUserName()
        task.environment = env

        let input = Pipe()
        let output = Pipe()
        task.standardInput = input
        task.standardOutput = output

        do {
            try task.run()
            let responseReady = DispatchSemaphore(value: 0)
            let responseLock = NSLock()
            var responseData = Data()
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                responseLock.lock()
                responseData.append(chunk)
                let hasResponse = responseData.range(of: Data(#""id":2"#.utf8)) != nil
                responseLock.unlock()
                if hasResponse { responseReady.signal() }
            }

            let requests = [
                #"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"ai-usage-widget","title":"AI Usage Widget","version":"1.0.0"}}}"#,
                #"{"method":"initialized","params":{}}"#,
                #"{"method":"account/rateLimits/read","id":2,"params":{}}"#
            ].joined(separator: "\n") + "\n"
            input.fileHandleForWriting.write(Data(requests.utf8))

            _ = responseReady.wait(timeout: .now() + 30)
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if task.isRunning { task.terminate() }

            responseLock.lock()
            let capturedData = responseData
            responseLock.unlock()
            guard let responseText = String(data: capturedData, encoding: .utf8) else { return false }

            for line in responseText.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (root["id"] as? NSNumber)?.intValue == 2,
                      let result = root["result"] as? [String: Any] else { continue }

                if let rateLimits = result["rateLimits"] as? [String: Any] {
                    applyRateLimits(rateLimits, to: &data)
                    if let planType = rateLimits["planType"] as? String, !planType.isEmpty {
                        data.accountPlan = planType.capitalized
                    }
                } else if let rateLimitsByLimitId = result["rateLimitsByLimitId"] as? [String: Any],
                          let codexLimits = rateLimitsByLimitId["codex"] as? [String: Any] {
                    applyRateLimits(codexLimits, to: &data)
                    if let planType = codexLimits["planType"] as? String, !planType.isEmpty {
                        data.accountPlan = planType.capitalized
                    }
                }

                applyResetCredits(result["rateLimitResetCredits"], to: &data)
                return data.fiveHourLimitUsedPct != nil
                    || data.weeklyLimitUsedPct != nil
                    || data.availableResetCreditsCount != nil
            }
        } catch {
            if task.isRunning { task.terminate() }
        }
        return false
    }

    func applyRateLimits(
        _ value: Any?,
        to data: inout CodexUsageData,
        onlyIfMissing: Bool = false
    ) {
        guard let rateLimits = value as? [String: Any] else { return }

        if let primary = rateLimits["primary"] as? [String: Any] {
            applyRateLimitWindow(primary, defaultWindow: .fiveHour, to: &data, onlyIfMissing: onlyIfMissing)
        }
        if let secondary = rateLimits["secondary"] as? [String: Any] {
            applyRateLimitWindow(secondary, defaultWindow: .weekly, to: &data, onlyIfMissing: onlyIfMissing)
        }
    }

    private enum RateLimitWindowKind {
        case fiveHour
        case weekly
    }

    private func applyRateLimitWindow(
        _ window: [String: Any],
        defaultWindow: RateLimitWindowKind,
        to data: inout CodexUsageData,
        onlyIfMissing: Bool
    ) {
        guard let used = number(in: window, camelCase: "usedPercent", snakeCase: "used_percent")?.doubleValue else {
            return
        }

        let durationMinutes = number(
            in: window,
            camelCase: "windowDurationMins",
            snakeCase: "window_minutes"
        )?.intValue
        let kind: RateLimitWindowKind
        if let durationMinutes {
            kind = durationMinutes >= 10_080 ? .weekly : .fiveHour
        } else {
            kind = defaultWindow
        }

        let resetTimestamp = number(in: window, camelCase: "resetsAt", snakeCase: "resets_at")?.doubleValue
        let resetText = resetTimestamp.map {
            "resets \(Self.formatResetDate(Date(timeIntervalSince1970: $0)))"
        } ?? ""
        let clampedUsed = max(0, min(100, used))

        switch kind {
        case .fiveHour:
            guard !onlyIfMissing || data.fiveHourLimitUsedPct == nil else { return }
            data.fiveHourLimitUsedPct = clampedUsed
            data.fiveHourLimitResetText = resetText
        case .weekly:
            guard !onlyIfMissing || data.weeklyLimitUsedPct == nil else { return }
            data.weeklyLimitUsedPct = clampedUsed
            data.weeklyLimitResetText = resetText
        }
    }

    private func number(
        in dictionary: [String: Any],
        camelCase: String,
        snakeCase: String
    ) -> NSNumber? {
        (dictionary[camelCase] as? NSNumber) ?? (dictionary[snakeCase] as? NSNumber)
    }

    func applyResetCredits(_ value: Any?, to data: inout CodexUsageData) {
        guard let summary = value as? [String: Any] else { return }
        data.availableResetCreditsCount = (summary["availableCount"] as? NSNumber)?.intValue
        guard let credits = summary["credits"] as? [[String: Any]] else { return }
        
        let availableCredits = credits.filter { credit in
            guard let status = credit["status"] as? String else { return false }
            return status.lowercased() == "available"
        }
        
        data.resets = availableCredits.enumerated().map { index, credit in
            let title = (credit["title"] as? String) ?? "Full reset"
            let expiry: String
            if let timestamp = (credit["expiresAt"] as? NSNumber)?.doubleValue {
                expiry = Self.formatResetDate(Date(timeIntervalSince1970: timestamp))
            } else {
                expiry = "No expiry"
            }
            return CodexResetItem(index: index + 1, name: title, expiryText: expiry)
        }
    }

    private func findCodexBinary() -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            candidates.append(contentsOf: versions.sorted().reversed().map {
                "\(nvmRoot)/\($0)/bin/codex"
            })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return formatter.string(from: date)
    }
    
    private func base64UrlDecode(_ base64Url: String) -> Data? {
        var base64 = base64Url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }
}

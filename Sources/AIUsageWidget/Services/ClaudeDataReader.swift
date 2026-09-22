import Foundation

class ClaudeDataReader {
    static let shared = ClaudeDataReader()
    
    private let historyReader: ClaudeHistoryReader
    private let claudeBinaryPath: String
    
    init(customPath: String? = nil) {
        let root = customPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        self.historyReader = ClaudeHistoryReader(projectsURL: root.appendingPathComponent("projects"))

        let candidates = [
            NSString(string: "~/.local/bin/claude").expandingTildeInPath,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        self.claudeBinaryPath = candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? ""
    }
    
    func fetchUsageData() -> ClaudeUsageData {
        var data = ClaudeUsageData()
        historyReader.apply(to: &data)
        fetchLiveCLIUsage(&data)
        return data
    }

    private func fetchLiveCLIUsage(_ data: inout ClaudeUsageData) {
        guard !claudeBinaryPath.isEmpty else {
            data.liveError = "Install Claude Code on this Mac to read account limits"
            return
        }
        
        let homeDir = NSHomeDirectory()
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.aiusagetracker.app", isDirectory: true)
            .appendingPathComponent("cli_workdir", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: claudeBinaryPath)
        task.arguments = [
            "--safe-mode",
            "-p", "/usage",
            "--output-format", "json",
            "--tools", "",
            "--no-session-persistence"
        ]
        
        task.currentDirectoryURL = workDirectory
        
        // Clean environment: avoid setting SHELL to prevent loading login shell configs (.zprofile, .zshrc)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:\(homeDir)/.local/bin"
        env["HOME"] = homeDir
        env["USER"] = NSUserName()
        env["TERM"] = "dumb"
        env["CI"] = "1"
        env["NO_COLOR"] = "1"
        env.removeValue(forKey: "SHELL")
        task.environment = env
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        
        do {
            try task.run()
            let deadline = Date().addingTimeInterval(15)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if task.isRunning {
                task.terminate()
                data.liveError = "Account limits request timed out"
                return
            }
            let rawData = pipe.fileHandleForReading.readDataToEndOfFile()
            guard task.terminationStatus == 0 else {
                data.liveError = "Could not read account limits. Check Claude Code login and version on this Mac."
                return
            }
            Self.applyUsageOutput(rawData, to: &data)
        } catch {
            data.liveError = "Could not launch Claude Code on this Mac"
        }
    }

    // Only parse successful CLI results. Missing or malformed windows stay nil;
    // a valid session percentage does not imply that the weekly value is known.
    static func applyUsageOutput(_ output: Data, to data: inout ClaudeUsageData) {
        data.sessionUsedPct = nil
        data.weekAllModelsPct = nil
        data.weekFablePct = nil
        data.sessionReset = ""
        data.weekAllModelsReset = ""
        data.weekFableReset = ""
        data.weekModelLabel = "Model-specific weekly limit"
        data.quotaFetchedAt = nil
        data.liveError = "Account limits unavailable. Check Claude Code login on this Mac."

        guard let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              root["is_error"] as? Bool == false,
              let result = root["result"] as? String else { return }

        for line in result.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The rest of /usage includes local-session analysis with percentages.
            // Anchor parsing to quota headings so those figures cannot become limits.
            if trimmed.hasPrefix("Current session:") {
                data.sessionUsedPct = extractPercentage(String(trimmed.dropFirst("Current session:".count)))
                data.sessionReset = extractResetText(trimmed) ?? ""
            } else if trimmed.hasPrefix("Current week (all models):") {
                data.weekAllModelsPct = extractPercentage(String(trimmed.dropFirst("Current week (all models):".count)))
                data.weekAllModelsReset = extractResetText(trimmed) ?? ""
            } else if trimmed.hasPrefix("Current week ("), let close = trimmed.range(of: "):") {
                data.weekFablePct = extractPercentage(String(trimmed[close.upperBound...]))
                let labelStart = trimmed.index(trimmed.startIndex, offsetBy: "Current week (".count)
                data.weekModelLabel = String(trimmed[labelStart..<close.lowerBound])
                data.weekFableReset = extractResetText(trimmed) ?? ""
            }
        }
        if data.hasLiveStatus {
            data.liveError = ""
            data.quotaFetchedAt = Date()
        }
    }

    private static func extractPercentage(_ value: String) -> Double? {
        let pattern = #"^\s*(\d+(?:\.\d+)?)%\s+used\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value),
              let percentage = Double(value[range]),
              percentage.isFinite, (0...100).contains(percentage) else { return nil }
        return percentage
    }

    private static func extractResetText(_ str: String) -> String? {
        if let resetRange = str.range(of: "resets ") {
            return String(str[resetRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

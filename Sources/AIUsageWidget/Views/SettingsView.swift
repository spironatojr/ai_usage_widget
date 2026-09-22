import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: UsageManager
    @Binding var selectedTab: AppTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header Title
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(MacTheme.accentBlue)
                    
                    Text("Settings & Configuration")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(MacTheme.textPrimary)
                }
                .padding(.horizontal, 2)

                // Menu Bar Display Options Group
                GlassCard(cornerRadius: 12, padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MENU BAR DISPLAY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(MacTheme.textSecondary)
                            .tracking(0.5)

                        Toggle(isOn: $manager.showQuotaInMenuBar) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show live quota percentages in Menu Bar")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(MacTheme.textPrimary)
                                Text("Shows weekly percent used for Claude, Codex, and Antigravity")
                                    .font(.system(size: 9.5, weight: .regular))
                                    .foregroundColor(MacTheme.textSecondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                // Refresh Interval Card Group
                GlassCard(cornerRadius: 12, padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REFRESH INTERVAL")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(MacTheme.textSecondary)
                            .tracking(0.5)

                        HStack {
                            Text("Auto-refresh background interval")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(MacTheme.textPrimary)
                            
                            Spacer()

                            Picker("", selection: $manager.refreshIntervalSeconds) {
                                Text("1 minute").tag(60.0)
                                Text("5 minutes").tag(300.0)
                                Text("10 minutes").tag(600.0)
                                Text("30 minutes").tag(1800.0)
                                Text("Manual Only").tag(0.0)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 130)
                        }
                    }
                }

                // Live service availability
                GlassCard(cornerRadius: 12, padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LIVE SERVICES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(MacTheme.textSecondary)
                            .tracking(0.5)

                        StatusRow(
                            name: "Google Antigravity Live Quotas",
                            detail: antigravityLiveDetail,
                            isAvailable: manager.antigravityData.hasLiveStatus,
                            availableText: "Live",
                            unavailableText: "Offline"
                        )
                    }
                }

                // Local history source availability
                GlassCard(cornerRadius: 12, padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LOCAL HISTORY SOURCES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(MacTheme.textSecondary)
                            .tracking(0.5)

                        StatusRow(
                            name: "Codex Local Sessions",
                            detail: "~/.codex/sessions",
                            isAvailable: sourceExists("~/.codex/sessions")
                        )

                        StatusRow(
                            name: "Claude Local Sessions",
                            detail: "~/.claude/projects",
                            isAvailable: sourceExists("~/.claude/projects")
                        )

                        StatusRow(
                            name: "Antigravity Conversations",
                            detail: "~/.gemini/antigravity/conversations",
                            isAvailable: sourceExists("~/.gemini/antigravity/conversations")
                        )

                        StatusRow(
                            name: "Antigravity CLI Conversations",
                            detail: "~/.gemini/antigravity-cli/conversations",
                            isAvailable: sourceExists("~/.gemini/antigravity-cli/conversations")
                        )
                    }
                }

                // Application Info & Actions Card
                GlassCard(cornerRadius: 12, padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("APPLICATION")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(MacTheme.textSecondary)
                            .tracking(0.5)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI Usage Tracker for macOS")
                                    .font(.system(size: 11, weight: .bold))
                                Text("\(appVersionText) · Native SwiftUI & SQLite")
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(MacTheme.textSecondary)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                NSApplication.shared.terminate(nil)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "power")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("Quit App")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .foregroundColor(MacTheme.danger)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(MacTheme.danger.opacity(0.12))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(MacTheme.danger.opacity(0.3), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func sourceExists(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: NSString(string: path).expandingTildeInPath
        )
    }

    private var antigravityLiveDetail: String {
        if manager.antigravityData.hasLiveStatus {
            let source = manager.antigravityData.liveSource
            return source.isEmpty ? "Local quota service responding" : "\(source) local quota service"
        }
        return manager.antigravityData.liveError.isEmpty
            ? "Open Antigravity to read live quotas"
            : manager.antigravityData.liveError
    }

    private var appVersionText: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Development"
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Version \(version) (build \($0))" } ?? "Version \(version)"
    }
}

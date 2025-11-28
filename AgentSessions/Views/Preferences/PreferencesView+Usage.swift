import SwiftUI

extension PreferencesView {

    var usageTrackingTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Usage Tracking")
                .font(.title2)
                .fontWeight(.semibold)

            // Sources
            sectionHeader("Usage Sources")
            VStack(alignment: .leading, spacing: 10) {
                // Codex
                HStack(spacing: 12) {
                    toggleRow("Enable Codex tracking", isOn: $codexUsageEnabled, help: "Turn Codex usage tracking on or off (independent of strip/menu bar)")
                    Button("Refresh now") { CodexUsageModel.shared.refreshNow() }
                        .buttonStyle(.bordered)
                        .disabled(!codexUsageEnabled)
                }
                labeledRow("Refresh every") {
                    Picker("", selection: $codexPollingInterval) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .help("How often to refresh Codex usage")
                }

                Divider().padding(.vertical, 6)

                // Claude
                HStack(spacing: 12) {
                    toggleRow("Enable Claude tracking", isOn: $claudeUsageEnabled, help: "Turn Claude usage tracking on or off (independent of strip/menu bar)")
                    Button("Refresh now") { ClaudeUsageModel.shared.refreshNow() }
                        .buttonStyle(.bordered)
                        .disabled(!claudeUsageEnabled)
                }
                labeledRow("Refresh every") {
                    Picker("", selection: $claudePollingInterval) {
                        Text("3 minutes").tag(180)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    .help("How often to refresh Claude usage")
                }
            }

            // Strip options (shared)
            sectionHeader("Strip Options")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    toggleRow("Show Codex strip", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showCodexStrip) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showCodexStrip) }
                    ), help: "Show the Codex usage strip at the bottom of the Unified window")
                        .disabled(!codexUsageEnabled)
                    toggleRow("Show Claude strip", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showClaudeStrip) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showClaudeStrip) }
                    ), help: "Show the Claude usage strip at the bottom of the Unified window")
                        .disabled(!claudeUsageEnabled)
                }
                HStack(spacing: 12) {
                    toggleRow("Show reset times", isOn: $stripShowResetTime, help: "Display the usage reset timestamp next to each meter")
                }
            }

            // Display style (shared across Codex & Claude)
            sectionHeader("Display Style")
            VStack(alignment: .leading, spacing: 10) {
                labeledRow("Limits display") {
                    Picker("", selection: Binding(
                        get: { UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left },
                        set: { usageDisplayModeRaw = $0.rawValue }
                    )) {
                        ForEach(UsageDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 480)
                    .help("Choose whether usage meters show remaining (left) or used percentages.")
                }
                Text("Applies to Codex and Claude usage strips and menu bar reset meters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Menu Bar controls moved to the Menu Bar pane
        }
    }

}

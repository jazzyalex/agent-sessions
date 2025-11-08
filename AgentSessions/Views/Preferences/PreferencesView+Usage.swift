import SwiftUI

extension PreferencesView {

    var usageTrackingTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Usage Tracking")
                .font(.title2)
                .fontWeight(.semibold)

            // Sources + strips
            sectionHeader("Usage Sources")
            VStack(alignment: .leading, spacing: 12) {
                // Codex
                HStack(spacing: 16) {
                    toggleRow("Enable Codex tracking", isOn: $codexUsageEnabled, help: "Turn Codex usage tracking on or off (independent of strip/menu bar)")
                    Button("Refresh Codex now") { CodexUsageModel.shared.refreshNow() }
                        .buttonStyle(.bordered)
                        .disabled(!codexUsageEnabled)
                }
                HStack(spacing: 16) {
                    toggleRow("Show Codex strip", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showCodexStrip) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showCodexStrip) }
                    ), help: "Show the Codex usage strip at the bottom of the Unified window")
                    .disabled(!codexUsageEnabled)
                }
                labeledRow("Refresh Interval") {
                    Picker("", selection: $codexPollingInterval) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .help("How often to refresh Codex usage")
                }
                Text("Tracking limits for Codex is not using tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                // Claude
                HStack(spacing: 16) {
                    toggleRow("Enable Claude tracking", isOn: $claudeUsageEnabled, help: "Turn Claude usage tracking on or off (independent of strip/menu bar)")
                    Button("Refresh Claude now") { ClaudeUsageModel.shared.refreshNow() }
                        .buttonStyle(.bordered)
                        .disabled(!claudeUsageEnabled)
                }
                HStack(spacing: 16) {
                    toggleRow("Show Claude strip", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showClaudeStrip) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showClaudeStrip) }
                    ), help: "Show the Claude usage strip at the bottom of the Unified window")
                    .disabled(!claudeUsageEnabled)
                }
                labeledRow("Refresh Interval") {
                    Picker("", selection: $claudePollingInterval) {
                        Text("30 minutes").tag(1800)
                        Text("60 minutes").tag(3600)
                        Text("120 minutes").tag(7200)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    .help("How often to refresh Claude usage")
                }
                Text("Claude limit tracking consumes one message per probe and decreases Claude's usage.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Strip options (shared)
            sectionHeader("Strip Options")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    toggleRow("Show reset times", isOn: $stripShowResetTime, help: "Display the usage reset timestamp next to each meter")
                }
                Text("Strips stack vertically when both are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Menu Bar controls moved to the Menu Bar pane
        }
    }

}

import SwiftUI

extension PreferencesView {

    private var webApiEffectivelyEnabled: Bool {
        let mode = ClaudeUsageMode(rawValue: UserDefaults.standard.string(forKey: PreferencesKey.claudeUsageMode) ?? "auto") ?? .auto
        if mode == .webOnly { return true }
        if mode == .auto && UserDefaults.standard.bool(forKey: PreferencesKey.claudeWebApiEnabled) { return true }
        return false
    }

    var usageTrackingTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Usage Tracking")
                .font(.title2)
                .fontWeight(.semibold)

            // Sources
            sectionHeader("Usage Sources")
            VStack(alignment: .leading, spacing: 12) {
                // Codex
                HStack(spacing: 12) {
                    toggleRow("Enable Codex tracking", isOn: $codexUsageEnabled, help: "Turn Codex usage tracking on or off (independent of strip/menu bar)")
                    Button("Refresh now") { CodexUsageModel.shared.refreshNow() }
                        .buttonStyle(.bordered)
                        .disabled(!codexUsageEnabled || !codexAgentEnabled)
                }
                .disabled(!codexAgentEnabled)
                labeledRow("Refresh every") {
                    Picker("", selection: $codexPollingInterval) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                    }
                    .pickerStyle(.segmented)
                    .help("How often to refresh Codex usage")
                }
                .disabled(!codexAgentEnabled)

                Divider().padding(.vertical, 6)

                // Claude
                HStack(spacing: 12) {
                    toggleRow("Enable Claude tracking", isOn: $claudeUsageEnabled, help: "Turn Claude usage tracking on or off (independent of strip/menu bar)")
                    Button("Refresh now") { ClaudeUsageModel.shared.refreshNow() }
                        .buttonStyle(.bordered)
                        .disabled(!claudeUsageEnabled || !claudeAgentEnabled)
                }
                .disabled(!claudeAgentEnabled)
                labeledRow("Data source") {
                    Picker("", selection: Binding(
                        get: { ClaudeUsageMode(rawValue: UserDefaults.standard.string(forKey: PreferencesKey.claudeUsageMode) ?? "auto") ?? .auto },
                        set: { UserDefaults.standard.set($0.rawValue, forKey: PreferencesKey.claudeUsageMode) }
                    )) {
                        ForEach(ClaudeUsageMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    .help("Auto: OAuth endpoint (60s), falls back to tmux on failure. Web API only: claude.ai session cookie. tmux only: legacy behavior.")
                }
                .disabled(!claudeAgentEnabled || !claudeUsageEnabled)
                toggleRow(
                    "Include Web API in Auto fallback",
                    isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.claudeWebApiEnabled) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.claudeWebApiEnabled) }
                    ),
                    help: "When enabled, Auto mode falls back to the claude.ai Web API before tmux. Reads Safari session cookie. May require Full Disk Access on macOS 14+."
                )
                .disabled(!claudeAgentEnabled || !claudeUsageEnabled ||
                          (ClaudeUsageMode(rawValue: UserDefaults.standard.string(forKey: PreferencesKey.claudeUsageMode) ?? "auto") ?? .auto) != .auto)
                if webApiEffectivelyEnabled {
                    PreferenceCallout(iconName: "lock.shield", tint: .blue) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Web API reads the Safari session cookie for claude.ai. On macOS 14+, this requires Full Disk Access.")
                                .font(.caption)
                            Button("Open Full Disk Access Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
                labeledRow("Refresh every") {
                    Picker("", selection: $claudePollingInterval) {
                        Text("3 minutes").tag(180)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                    }
                    .pickerStyle(.segmented)
                    .help("How often to refresh Claude usage (applies to tmux path; OAuth always refreshes every 60s)")
                }
                .disabled(!claudeAgentEnabled || !claudeUsageEnabled)
            }

            // Strip options (shared)
            sectionHeader("Strip Options")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show Codex strip", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showCodexStrip) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showCodexStrip) }
                ), help: "Show the Codex usage strip at the bottom of the Unified window")
                    .disabled(!codexUsageEnabled || !codexAgentEnabled)
                toggleRow("Show Claude strip", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showClaudeStrip) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showClaudeStrip) }
                ), help: "Show the Claude usage strip at the bottom of the Unified window")
                    .disabled(!claudeUsageEnabled || !claudeAgentEnabled)
                toggleRow("Show reset times", isOn: $stripShowResetTime, help: "Display the usage reset timestamp next to each meter")
            }

            // Display style (shared across Codex & Claude)
            sectionHeader("Display Style")
            VStack(alignment: .leading, spacing: 12) {
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

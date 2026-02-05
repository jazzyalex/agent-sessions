import SwiftUI

extension PreferencesView {

    var generalTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("General")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Appearance")
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Theme") {
                    Picker("", selection: Binding(
                        get: { indexer.appAppearance },
                        set: { indexer.setAppearance($0) }
                    )) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Choose the overall app appearance")
                }
            }

            sectionHeader("Resume")
            VStack(alignment: .leading, spacing: 12) {
                // Terminal app preference for both Codex and Claude resumes
                labeledRow("Terminal App") {
                    Picker("", selection: Binding(
                        get: { (resumeSettings.launchMode == .iterm || claudeSettings.preferITerm) ? 1 : 0 },
                        set: { idx in
                            // Apply to Codex
                            resumeSettings.setLaunchMode(idx == 1 ? .iterm : .terminal)
                            // Apply to Claude
                            claudeSettings.setPreferITerm(idx == 1)
                        }
                    )) {
                        Text("Terminal").tag(0)
                        Text("iTerm2").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    .help("Choose which terminal application handles Resume for both Codex and Claude")
                }
                Text("Affects Resume actions in the Sessions window for Codex and Claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Active CLI agents")
            VStack(alignment: .leading, spacing: 6) {
                let enabledCount = [codexAgentEnabled, claudeAgentEnabled, geminiAgentEnabled, openCodeAgentEnabled, copilotAgentEnabled, droidAgentEnabled, openClawAgentEnabled].filter { $0 }.count

                agentEnableToggle(title: "Codex", source: .codex, isOn: $codexAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Claude", source: .claude, isOn: $claudeAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Gemini", source: .gemini, isOn: $geminiAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "OpenCode", source: .opencode, isOn: $openCodeAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Copilot", source: .copilot, isOn: $copilotAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Droid", source: .droid, isOn: $droidAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "OpenClaw", source: .openclaw, isOn: $openClawAgentEnabled, enabledCount: enabledCount)

                Text("Disabled agents are hidden across the app and background work is paused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

        }
    }

    var advancedTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Advanced")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Git Context")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show Git Context button", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableGitInspector) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.enableGitInspector) }
                ))
                .help("Show the Git Context toolbar button in Sessions (⌘⇧G)")

                Text("Adds a Git Context button to the Sessions toolbar and context menus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

		            sectionHeader("Search")
		            VStack(alignment: .leading, spacing: 12) {
	                    Toggle("Index full tool I/O for recent sessions", isOn: Binding(
	                        get: {
	                            UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) == nil
	                                ? true
                                : UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex)
                        },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) }
                    ))
                    .help("Build a token-based index over tool inputs and outputs for sessions from the last 90 days. Improves Instant search but may increase disk usage and indexing time. Older indexed tool I/O is retained up to 25 MB.")

	                Toggle("Include large tool outputs in global search", isOn: Binding(
	                    get: {
	                        UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch) == nil
	                            ? false
	                            : UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch)
	                    },
	                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch) }
	                ))
	                .help("When enabled, global search continues scanning large tool outputs in the background after showing indexed results. This can be noticeably slower on large histories.")

	                Text("This finds additional matches inside large tool outputs that may not appear in Instant search. Leaving this off keeps search more responsive.")
	                    .font(.caption)
	                    .foregroundStyle(.secondary)
	            }

            sectionHeader("OpenClaw")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Include deleted OpenClaw sessions", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions) }
                ))
                .help("Show OpenClaw/Clawdbot transcripts ending in .jsonl.deleted.<timestamp>. Hidden by default.")

                Text("Deleted sessions are usually backups or tombstones. Keeping them hidden reduces noise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Saved Sessions")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Save also keeps locally", isOn: $starPinsSessions)
                    .help("When enabled, saving a session also archives its source files into Agent Sessions storage so it cannot disappear when the upstream CLI prunes history.")
                HStack(spacing: 12) {
                    Text("Stop syncing after inactivity")
                    Picker("", selection: $stopSyncAfterInactivityMinutes) {
                        Text("10 min").tag(10)
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                .help("After a saved session stops changing upstream for this long, Agent Sessions stops syncing the local copy. If it changes later, syncing resumes.")
                Toggle("Remove from Saved deletes local copy", isOn: $unstarRemovesArchive)
                    .help("When enabled, removing a session from Saved also deletes the local archive copy. By default, removing from Saved is non-destructive.")
            }
        }
    }

            var unifiedTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Unified Window")
                .font(.title2)
                .fontWeight(.semibold)

            // Sessions List header removed per guidance; keep content compact
            VStack(alignment: .leading, spacing: 12) {
                // Modified Date (moved from General)
                labeledRow("Modified Date") {
                    Picker("", selection: $modifiedDisplay) {
                        ForEach(SessionIndexer.ModifiedDisplay.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: modifiedDisplay) { _, newValue in
                        indexer.setModifiedDisplay(newValue)
                    }
                    .help("Switch between relative and absolute modified timestamps")
                }

                sectionHeader("Appearance")
                labeledRow("Agent Accents") {
                    Picker("", selection: Binding(
                        get: { stripMonochromeGlobal ? 1 : 0 },
                        set: { stripMonochromeGlobal = ($0 == 1) }
                    )) {
                        Text("Color").tag(0)
                        Text("Monochrome").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .help("Choose colored or monochrome styling for agent accents")
                }
                Text("Affects usage strips, source labels, and CLI Agent colors in Sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                sectionHeader("Session View")
                labeledRow("Auto-scroll in Session View") {
                    let key = PreferencesKey.Unified.sessionViewAutoScrollTarget
                    Picker("", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: key) ?? SessionViewAutoScrollTarget.lastUserPrompt.rawValue },
                        set: { UserDefaults.standard.set($0, forKey: key) }
                    )) {
                        ForEach(SessionViewAutoScrollTarget.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .help("When opening a session without a search query, choose which prompt to jump to in Session view")
                }

                Toggle("Show inline image thumbnails in Session view", isOn: $inlineSessionImageThumbnailsEnabled)
                    .help("Show small image thumbnails inline in Session view. Thumbnails load after scrolling stops to reduce CPU and I/O during fast scroll.")

                // Columns section
                sectionHeader("Columns")
                // First row: three columns to reduce height
                HStack(spacing: 16) {
                    Toggle("Session titles", isOn: $columnVisibility.showTitleColumn)
                        .help("Show or hide the Session title column in the Sessions list")
                    Toggle("Project names", isOn: $columnVisibility.showProjectColumn)
                        .help("Show or hide the Project column in the Sessions list")
                    Toggle("Source column", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showSourceColumn) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showSourceColumn) }
                    ))
                    .help("Show or hide the CLI Agent source column in the Unified list")
                }
                // Second row: remaining columns
                HStack(spacing: 16) {
                    Toggle("Message counts", isOn: $columnVisibility.showMsgsColumn)
                        .help("Show or hide message counts in the Sessions list")
                    Toggle("Modified date", isOn: $columnVisibility.showModifiedColumn)
                        .help("Show or hide the modified date column")
                    Toggle("Size column", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: PreferencesKey.Unified.showSizeColumn) as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showSizeColumn) }
                    ))
                    .help("Show or hide the file size column in the Unified list")
                    Toggle("Save", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: PreferencesKey.Unified.showStarColumn) as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showStarColumn) }
                    ))
                    .help("Show or hide the Save button. Saved sessions can be kept locally to prevent upstream pruning from removing them.")
                }

                // Filters section
                sectionHeader("Filters")
                    .padding(.top, 8)
                HStack(spacing: 16) {
                    Toggle("Hide 0-message sessions", isOn: $hideZeroMessageSessionsPref)
                        .onChange(of: hideZeroMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                        .help("Exclude sessions that contain no user or assistant messages")
                    Toggle("Hide 1–2 message sessions", isOn: $hideLowMessageSessionsPref)
                        .onChange(of: hideLowMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                        .help("Exclude sessions with only one or two messages (but keep 0-message sessions unless also excluded above)")
                    Toggle("Hide housekeeping-only sessions", isOn: Binding(
                        get: { !showHousekeepingSessions },
                        set: { showHousekeepingSessions = !$0 }
                    ))
                    .onChange(of: showHousekeepingSessions) { _, _ in indexer.recomputeNow() }
                    .help("Exclude sessions that contain no assistant output and no meaningful prompt content (for example Codex rollouts that only captured preamble, or Claude local-command-only transcripts)")
                    Toggle("Hide sessions without tool calls (strict)", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.hasCommandsOnly) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.hasCommandsOnly) }
                    ))
                    .help("Exclude sessions that contain no recorded tool/command calls. Strict: Claude/Gemini are excluded unless tool calls are present in the parsed transcript.")
                }

                Divider()
                Toggle("Skip preambles when parsing (Codex + Claude)", isOn: Binding(
                    get: {
                        let d = UserDefaults.standard
                        if d.object(forKey: PreferencesKey.Unified.skipAgentsPreamble) == nil { return true }
                        return d.bool(forKey: PreferencesKey.Unified.skipAgentsPreamble)
                    },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.skipAgentsPreamble); indexer.recomputeNow() }
                ))
                .help("Ignore Codex Agents.md instructions and Claude local-command caveats when deriving titles and jumping to the first prompt (content remains visible)")
            }

            // Usage Tracking moved to General pane
        }
    }

}

private extension PreferencesView {
    func agentEnableToggle(title: String, source: SessionSource, isOn: Binding<Bool>, enabledCount: Int) -> some View {
        let installed = AgentEnablement.binaryInstalled(for: source)
        let available = installed || AgentEnablement.isAvailable(source)
        let statusText: String = installed ? "Installed" : (available ? "Data folder found" : "Not installed")
        let isCurrentlyOn = isOn.wrappedValue
        let canDisable = !(enabledCount == 1 && isCurrentlyOn)
        let canEnable = available || isCurrentlyOn
        let accent = Color.agentColor(for: source, monochrome: stripMonochromeGlobal)

        return Toggle(isOn: Binding(
            get: { isOn.wrappedValue },
            set: { newValue in
                _ = AgentEnablement.setEnabled(source, enabled: newValue)
            }
        )) {
            HStack {
                Text(title)
                    .foregroundStyle(accent)
                    .opacity(isCurrentlyOn ? 1.0 : 0.6)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!(canDisable && canEnable))
    }
}

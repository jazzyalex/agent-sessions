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
                        get: { (resumeSettings.launchMode == .iterm || claudeSettings.preferITerm || opencodeSettings.preferITerm || copilotSettings.preferITerm || geminiSettings.preferITerm || cursorSettings.preferITerm) ? 1 : 0 },
                        set: { idx in
                            // Apply to Codex
                            resumeSettings.setLaunchMode(idx == 1 ? .iterm : .terminal)
                            // Apply to Claude
                            claudeSettings.setPreferITerm(idx == 1)
                            // Apply to OpenCode
                            opencodeSettings.setPreferITerm(idx == 1)
                            // Apply to Copilot
                            copilotSettings.setPreferITerm(idx == 1)
                            // Apply to Gemini
                            geminiSettings.setPreferITerm(idx == 1)
                            // Apply to Cursor
                            cursorSettings.setPreferITerm(idx == 1)
                        }
                    )) {
                        Text("Terminal").tag(0)
                        Text("iTerm2").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    .help("Choose which terminal application handles Resume for all CLI agents")
                }
                Text("Affects Resume actions in the Sessions window for all CLI agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Active CLI agents")
            VStack(alignment: .leading, spacing: 6) {
                let enabledCount = [codexAgentEnabled, claudeAgentEnabled, geminiAgentEnabled, openCodeAgentEnabled, copilotAgentEnabled, droidAgentEnabled, openClawAgentEnabled, cursorAgentEnabled].filter { $0 }.count

                agentEnableToggle(title: "Codex", source: .codex, isOn: $codexAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Claude", source: .claude, isOn: $claudeAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Gemini", source: .gemini, isOn: $geminiAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "OpenCode", source: .opencode, isOn: $openCodeAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Copilot", source: .copilot, isOn: $copilotAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Droid", source: .droid, isOn: $droidAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "OpenClaw", source: .openclaw, isOn: $openClawAgentEnabled, enabledCount: enabledCount)
                agentEnableToggle(title: "Cursor", source: .cursor, isOn: $cursorAgentEnabled, enabledCount: enabledCount)

                Text("Disabled agents are hidden across the app and background work is paused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

        }
    }

    var agentCockpitTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Agent Cockpit")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Appearance")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Reduce transparency", isOn: $cockpitReduceTransparency)
                    .help("Uses a denser window background for better readability over dark or busy wallpapers.")
                Text("Also respects macOS System Settings > Accessibility > Display > Reduce transparency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Live Sessions + Cockpit BETA")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable live session detection + Cockpit (Beta)", isOn: $codexActiveSessionsEnabled)
                    .help("Beta feature. Tracks live/open Codex and Claude sessions, enables Cockpit live rows, and powers live dots/focus actions in Sessions.")

                HStack(spacing: 12) {
                    TextField("Active registry directory (optional)", text: $codexActiveRegistryRootOverride)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit { validateCodexActiveRegistryRootOverride() }
                        .onChange(of: codexActiveRegistryRootOverride) { _, _ in
                            validateCodexActiveRegistryRootOverride()
                            codexActiveRegistryRootDebounce?.cancel()
                            let work = DispatchWorkItem { validateCodexActiveRegistryRootOverride() }
                            codexActiveRegistryRootDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                        .help("Override the directory used for active-session presence files. Leave blank to use $CODEX_HOME/active or ~/.codex/active.")

                    Button(action: pickCodexActiveRegistryFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for a directory containing active-session presence JSON files")
                }

                if !codexActiveRegistryRootValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Status: Beta. Scope in this release: Codex + Claude live/open detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Default: $CODEX_HOME/active or ~/.codex/active")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Compact Mode")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show agent name in compact mode", isOn: $cockpitShowAgentNameInCompact)
                    .help("When disabled, compact rows hide the agent-name text to free horizontal space. Status dot and row numbering remain visible.")

                labeledRow("Default Compact Size") {
                    Picker("", selection: $cockpitCompactBaselineRows) {
                        Text("Small").tag(3)
                        Text("Medium").tag(4)
                        Text("Large").tag(6)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .help("Sets the default compact window height by visible rows. Sessions above this count scroll inside the list.")
                }

                Toggle("Auto-fit compact height to visible sessions", isOn: $cockpitCompactAutoFitEnabled)
                    .help("When enabled, compact mode grows/shrinks with visible session count. Off keeps compact height stable and uses scrolling.")
            }

            sectionHeader("Full Mode")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show tab subtitle under agent name", isOn: $cockpitShowTabSubtitleInFullMode)
                    .help("Displays iTerm tab title as a muted subtitle under the agent label in full Agent Cockpit rows. Long titles are truncated with hover tooltips.")
                Toggle("Show usage limits footer", isOn: $cockpitShowLimitsFooter)
                    .help("Shows a compact limits footer at the bottom of the Cockpit window with 5-hour and weekly usage percentages for enabled providers.")
            }
        }
    }

    var advancedTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Advanced")
                .font(.title2)
                .fontWeight(.semibold)

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

            sectionHeader("Search")
            VStack(alignment: .leading, spacing: 12) {
                    Toggle("Index full tool I/O for recent sessions", isOn: Binding(
                        get: {
                            UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) == nil
	                                ? false
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

            Toggle("Hide Dock icon", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: PreferencesKey.Advanced.hideDockIcon) as? Bool ?? false },
                set: { newValue in
                    if newValue {
                        // Ensure there is always a persistent way to reopen app windows.
                        let menuBarEnabled = UserDefaults.standard.bool(forKey: PreferencesKey.menuBarEnabled)
                        if !menuBarEnabled {
                            UserDefaults.standard.set(true, forKey: PreferencesKey.menuBarEnabled)
                        }
                    }
                    UserDefaults.standard.set(newValue, forKey: PreferencesKey.Advanced.hideDockIcon)
                }
            ))
            .help("Removes Agent Sessions from the Dock by switching the app to accessory activation mode. When enabled, Agent Sessions automatically keeps the menu bar item enabled so the app remains accessible.")

            Toggle("Show Git Context button", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableGitInspector) },
                set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.enableGitInspector) }
            ))
            .help("Show the Git Context toolbar button in Sessions (⌘⇧G)")

            sectionHeader("Indexing")
            VStack(alignment: .leading, spacing: 8) {
                Button("Rebuild Core Index…") {
                    showCoreIndexRebuildConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .help("Clear and rebuild the core sessions index. Use only when indexing appears corrupted.")

                Text("This is an advanced repair action and can be CPU-intensive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                sectionHeader("Rich Transcript")
                Toggle("Enable review cards for Codex internal review JSON", isOn: $transcriptEnableReviewCards)
                    .help("When enabled, recognized Codex internal review payloads render as summary cards instead of raw JSON.")
                Toggle("Enable file-link click targets in transcript", isOn: $transcriptEnableLinkification)
                    .help("Turn file path references like Foo.swift:56 into clickable links that open in your editor.")
                Toggle("Show line numbers for code and diff blocks", isOn: $transcriptEnableCodeDiffLineNumbers)
                    .help("Show per-block line numbers for semantic code and diff transcript blocks.")
                labeledRow("Preferred Editor") {
                    Picker("", selection: Binding(
                        get: { IDEOpener.Target(rawValue: transcriptPreferredIDETargetRaw) ?? .systemDefault },
                        set: { transcriptPreferredIDETargetRaw = $0.rawValue }
                    )) {
                        Text("System Default").tag(IDEOpener.Target.systemDefault)
                        Text("Cursor").tag(IDEOpener.Target.cursor)
                        Text("VS Code").tag(IDEOpener.Target.vscode)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    .help("Choose which app receives transcript file links.")
                }
                labeledRow("Editor CLI Override") {
                    TextField("Optional binary path (for Cursor/VS Code)", text: $transcriptIDEBinaryOverridePath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .help("Optional override for the editor CLI binary used for line-targeted opens.")
                }
            }

            // Usage Tracking moved to General pane
        }
    }

}

private extension PreferencesView {
    func agentEnableToggle(title: String, source: SessionSource, isOn: Binding<Bool>, enabledCount: Int) -> some View {
        let availability = AgentEnablement.availabilityStatus(for: source)
        let isCurrentlyOn = isOn.wrappedValue
        let canDisable = !(enabledCount == 1 && isCurrentlyOn)
        let canEnable = availability.isAvailable || isCurrentlyOn
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
                Text(availability.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!(canDisable && canEnable))
    }
}

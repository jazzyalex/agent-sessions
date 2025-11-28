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
                    Picker("", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearance) { _, newValue in
                        indexer.setAppearance(newValue)
                    }
                    .help("Choose the overall app appearance")
                }

                Divider()

                // Modified Date moved to Unified Window pane

                // Agent color is controlled by UI Elements (Monochrome/Color)

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
                    Toggle("Favorite (star)", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: PreferencesKey.Unified.showStarColumn) as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showStarColumn) }
                    ))
                    .help("Show or hide the favorite star button in the CLI Agent column")
                }
                // Filters section
                sectionHeader("Filters")
                    .padding(.top, 8)
                HStack(spacing: 16) {
                    Toggle("Zero msgs", isOn: $hideZeroMessageSessionsPref)
                        .onChange(of: hideZeroMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                        .help("Hide sessions that contain no user or assistant messages")
                    Toggle("1–2 messages", isOn: $hideLowMessageSessionsPref)
                        .onChange(of: hideLowMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                        .help("Hide sessions with only one or two messages")
                    Toggle("Tool calls (Codex & OpenCode)", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.hasCommandsOnly) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.hasCommandsOnly) }
                    ))
                    .help("Show only Codex and OpenCode sessions that contain recorded tool/command calls. Claude and Gemini are excluded when enabled.")
                }

                // CLI toolbar filter visibility
                sectionHeader("CLI Toolbar Filters")
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $showCodexToolbarFilter) {
                        HStack {
                            Text("Codex")
                            Spacer()
                            Text("⌘1").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!codexCLIAvailable)
                    .help("Show or hide the Codex source filter button in the Sessions toolbar")

                    Toggle(isOn: $showClaudeToolbarFilter) {
                        HStack {
                            Text("Claude")
                            Spacer()
                            Text("⌘2").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!claudeCLIAvailable)
                    .help("Show or hide the Claude source filter button in the Sessions toolbar")

                    Toggle(isOn: $showGeminiToolbarFilter) {
                        HStack {
                            Text("Gemini")
                            Spacer()
                            Text("⌘3").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!geminiCLIAvailable)
                    .help("Show or hide the Gemini source filter button in the Sessions toolbar")

                    Toggle(isOn: $showOpenCodeToolbarFilter) {
                        HStack {
                            Text("OpenCode")
                            Spacer()
                            Text("⌘4").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!openCodeCLIAvailable)
                    .help("Show or hide the OpenCode source filter button in the Sessions toolbar")

                    Text("Keyboard shortcuts: Codex ⌘1 · Claude ⌘2 · Gemini ⌘3 · OpenCode ⌘4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                Divider()
                Toggle("Skip Agents.md lines when parsing", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.skipAgentsPreamble) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.skipAgentsPreamble); indexer.recomputeNow() }
                ))
                .help("Ignore agents.md-style preambles for titles and previews (content remains visible in transcripts)")
            }

            // Usage Tracking moved to General pane
        }
    }

}

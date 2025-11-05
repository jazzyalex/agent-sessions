import SwiftUI
import AppKit

private let labelColumnWidth: CGFloat = 170

struct PreferencesView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @EnvironmentObject var updaterController: UpdaterController
    @EnvironmentObject var columnVisibility: ColumnVisibilityStore
    @State private var selectedTab: PreferencesTab?
    // Persist last-selected tab for smoother navigation across launches
    @AppStorage("PreferencesLastSelectedTab") private var lastSelectedTabRaw: String = PreferencesTab.general.rawValue
    private let initialTabArg: PreferencesTab
    @ObservedObject private var resumeSettings = CodexResumeSettings.shared
    @ObservedObject private var claudeSettings = ClaudeResumeSettings.shared
    @ObservedObject private var geminiSettings = GeminiCLISettings.shared
    @State private var showingResetConfirm: Bool = false
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    // Codex tracking master toggle
    @AppStorage("CodexUsageEnabled") private var codexUsageEnabled: Bool = false
    // Codex auto-probe pref (secondary tmux-based /status probe when stale)
    @AppStorage("CodexAllowStatusProbe") private var codexAllowStatusProbe: Bool = false
    // Codex probe cleanup prefs
    @AppStorage("CodexProbeCleanupMode") private var codexProbeCleanupMode: String = "none" // none | auto
    @State private var showConfirmCodexAutoDelete: Bool = false
    @State private var showConfirmCodexDeleteNow: Bool = false
    // Claude tracking master toggle
    @AppStorage("ClaudeUsageEnabled") private var claudeUsageEnabled: Bool = false
    // Claude Probe cleanup prefs
    @AppStorage("ClaudeProbeCleanupMode") private var claudeProbeCleanupMode: String = "none" // none | auto
    // Debug: show probe sessions in lists
    @AppStorage("ShowSystemProbeSessions") private var showSystemProbeSessions: Bool = false
    @State private var showConfirmAutoDelete: Bool = false
    @State private var showConfirmDeleteNow: Bool = false
    @State private var cleanupFlashText: String? = nil
    @State private var cleanupFlashColor: Color = .secondary
    // Menu bar prefs
    @AppStorage("MenuBarEnabled") private var menuBarEnabled: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("StripShowResetTime") private var stripShowResetTime: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochromeGlobal: Bool = false
    @AppStorage("HideZeroMessageSessions") private var hideZeroMessageSessionsPref: Bool = true
    @AppStorage("HideLowMessageSessions") private var hideLowMessageSessionsPref: Bool = true
    @AppStorage("UsagePollingInterval") private var usagePollingInterval: Int = 300 // seconds (default 5 min)

    init(initialTab: PreferencesTab = .general) {
        self.initialTabArg = initialTab
        _selectedTab = State(initialValue: initialTab)
    }

    // General tab state
    @State private var appearance: AppAppearance = .system
    @State private var modifiedDisplay: SessionIndexer.ModifiedDisplay = .relative

    // Codex CLI tab state
    @State private var codexPath: String = ""
    @State private var codexPathValid: Bool = true
    @State private var codexBinaryOverride: String = ""
    @State private var codexBinaryValid: Bool = true
    @State private var defaultResumeDirectory: String = ""
    @State private var defaultResumeDirectoryValid: Bool = true
    @State private var preferredLaunchMode: CodexLaunchMode = .terminal
    @State private var probeState: ProbeState = .idle
    @State private var probeVersion: CodexVersion? = nil
    @State private var resolvedCodexPath: String? = nil
    @State private var codexPathDebounce: DispatchWorkItem? = nil
    @State private var codexProbeDebounce: DispatchWorkItem? = nil

    // Claude CLI probe state (for Resume tab)
    @State private var claudeProbeState: ProbeState = .idle
    @State private var claudeVersionString: String? = nil
    @State private var claudeResolvedPath: String? = nil
    @State private var claudeProbeDebounce: DispatchWorkItem? = nil
    @State private var showClaudeExperimentalWarning: Bool = false
    // Claude Sessions directory override
    @State private var claudePath: String = ""
    @State private var claudePathValid: Bool = true
    @State private var claudePathDebounce: DispatchWorkItem? = nil

    // Gemini CLI probe state
    @State private var geminiProbeState: ProbeState = .idle
    @State private var geminiVersionString: String? = nil
    @State private var geminiResolvedPath: String? = nil
    @State private var geminiProbeDebounce: DispatchWorkItem? = nil

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(visibleTabs, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.iconName)
                    .tag(tab)
            }
            // Fix the sidebar width to avoid horizontal jumps when switching panes
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        } detail: {
            // Make content scrollable so footer actions remain visible on smaller panes
            VStack(spacing: 0) {
                ScrollView {
                    tabBody
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 12)
                }
                Divider()
                footer
            }
        }
        .frame(width: 740, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadCurrentSettings()
            // Respect caller-provided tab, otherwise restore last selection
            if initialTabArg == .general, let restored = PreferencesTab(rawValue: lastSelectedTabRaw) {
                selectedTab = restored
            }
            // Trigger any probes needed for the initial/visible tab
            if let tab = selectedTab ?? .some(initialTabArg) { maybeProbe(for: tab) }
        }
        // Keep UI feeling responsive when switching between panes
        .animation(.easeInOut(duration: 0.12), value: selectedTab)
        .onChange(of: selectedTab) { _, newValue in
            guard let t = newValue else { return }
            lastSelectedTabRaw = t.rawValue
            maybeProbe(for: t)
        }
        .alert("Claude Usage Tracking (Experimental)", isPresented: $showClaudeExperimentalWarning) {
            Button("Cancel", role: .cancel) { }
                .help("Keep Claude usage tracking disabled")
            Button("Enable Anyway") {
                UserDefaults.standard.set(true, forKey: "ShowClaudeUsageStrip")
                ClaudeUsageModel.shared.setEnabled(true)
            }
            .help("Enable the experimental Claude usage tracker despite the warning")
        } message: {
            Text("""
            This feature runs Claude CLI headlessly every 60s via tmux to fetch /usage data.

            Requirements: Claude CLI + tmux installed and authenticated

            Install tmux (via Homebrew):
              brew install tmux

            ⚠️ Warnings:
            - Experimental - may fail or cause slowdowns
            - Disable immediately if you notice performance issues
            - First use requests file access permission (one-time)

            Privacy: Only reads usage percentages, no conversation data accessed.
            """)
        }
    }

    // MARK: Layout chrome

    private var tabBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch selectedTab ?? .general {
            case .general:
                generalTab
            case .usageTracking:
                usageTrackingTab
            case .usageProbes:
                usageProbesTab
            case .menuBar:
                menuBarTab
            case .unified:
                unifiedTab
            case .codexCLI:
                codexCLITab
            case .claudeResume:
                claudeResumeTab
            case .geminiCLI:
                geminiCLITab
            case .about:
                aboutTab
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .controlSize(.small)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Reset to Defaults") { showingResetConfirm = true }
                .buttonStyle(.bordered)
                .help("Revert all preferences to their original values")
            Button("Close", action: closeWindow)
                .buttonStyle(.borderedProminent)
                .help("Dismiss preferences without additional changes")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .alert("Reset All Preferences?", isPresented: $showingResetConfirm) {
            Button("Reset", role: .destructive) { resetToDefaults() }
                .help("Confirm and restore default settings across all tabs")
            Button("Cancel", role: .cancel) {}
                .help("Abort resetting preferences")
        } message: {
            Text("This will reset General, Sessions, Resume (Codex & Claude), Usage, and Menu Bar settings.")
        }
    }

    // MARK: Tabs

    private var generalTab: some View {
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

    private var unifiedTab: some View {
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
                // Micro-header for columns
                Text("Columns")
                    .font(.subheadline)
                Divider()
                // First row: three columns to reduce height
                HStack(spacing: 16) {
                    Toggle("Session titles", isOn: $columnVisibility.showTitleColumn)
                        .help("Show or hide the Session title column in the Sessions list")
                    Toggle("Project names", isOn: $columnVisibility.showProjectColumn)
                        .help("Show or hide the Project column in the Sessions list")
                    Toggle("Source column", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "UnifiedShowSourceColumn") },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedShowSourceColumn") }
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
                        get: { UserDefaults.standard.object(forKey: "UnifiedShowSizeColumn") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedShowSizeColumn") }
                    ))
                    .help("Show or hide the file size column in the Unified list")
                    Toggle("Favorite (star)", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "UnifiedShowStarColumn") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedShowStarColumn") }
                    ))
                    .help("Show or hide the favorite star button in the CLI Agent column")
                }
                // Micro-header for filters
                Text("Filters")
                    .padding(.top, 8)
                    .font(.subheadline)
                Divider()
                HStack(spacing: 16) {
                    Toggle("Zero msgs", isOn: $hideZeroMessageSessionsPref)
                        .onChange(of: hideZeroMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                        .help("Hide sessions that contain no user or assistant messages")
                    Toggle("1–2 messages", isOn: $hideLowMessageSessionsPref)
                        .onChange(of: hideLowMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                        .help("Hide sessions with only one or two messages")
                    Toggle("Tool calls (Codex only)", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "UnifiedHasCommandsOnly") },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedHasCommandsOnly") }
                    ))
                    .help("Show only Codex sessions that contain recorded tool/command calls. Claude and Gemini are excluded when enabled.")
                }

                Divider()
                Toggle("Skip Agents.md lines when parsing", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "SkipAgentsPreamble") },
                    set: { UserDefaults.standard.set($0, forKey: "SkipAgentsPreamble"); indexer.recomputeNow() }
                ))
                .help("Ignore agents.md-style preambles for titles and previews (content remains visible in transcripts)")
            }

            // Usage Tracking moved to General pane
        }
    }

    // New Usage Tracking pane (combines usage strips and menu bar configuration)
    private var usageTrackingTab: some View {
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
                        get: { UserDefaults.standard.bool(forKey: "UnifiedShowCodexStrip") },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedShowCodexStrip") }
                    ), help: "Show the Codex usage strip at the bottom of the Unified window")
                    .disabled(!codexUsageEnabled)
                }

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
                        get: { UserDefaults.standard.bool(forKey: "UnifiedShowClaudeStrip") },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedShowClaudeStrip") }
                    ), help: "Show the Claude usage strip at the bottom of the Unified window")
                    .disabled(!claudeUsageEnabled)
                }
            }

            // Strip options
            sectionHeader("Strip Options")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    toggleRow("Show reset times", isOn: $stripShowResetTime, help: "Display the usage reset timestamp next to each meter")
                }
                labeledRow("Refresh Interval") {
                    Picker("", selection: $usagePollingInterval) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .help("How often to refresh usage data (affects both Codex and Claude)")
                }
                Text("Longer intervals reduce CPU usage. Strips stack vertically when both are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Menu Bar controls moved to the Menu Bar pane
        }
    }

    // New separate pane for terminal probes and cleanup
    private var usageProbesTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Usage Probes")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Runs short, terminal-based probes in dedicated working folders to refresh usage limits. Cleanup only removes validated probe sessions; normal projects are never touched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Debug visibility
            Toggle("Show system probe sessions for debugging", isOn: $showSystemProbeSessions)
                .toggleStyle(.switch)
                .help("Reveal probe sessions in the Sessions list. Leave OFF for normal use to avoid noise.")

            // Claude subsection
            sectionHeader("Claude")
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: Binding(
                    get: { claudeProbeCleanupMode },
                    set: { newVal in
                        if newVal == "auto" {
                            showConfirmAutoDelete = true
                        } else {
                            claudeProbeCleanupMode = "none"
                            ClaudeProbeProject.setCleanupMode(.none)
                        }
                    }
                )) {
                    Text("No delete").tag("none")
                    Text("Auto-delete after each probe").foregroundStyle(.red).tag("auto")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                HStack(spacing: 12) {
                    Button("Delete Claude probe sessions now") { showConfirmDeleteNow = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            .alert("Enable Automatic Cleanup?", isPresented: $showConfirmAutoDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Enable", role: .destructive) {
                    claudeProbeCleanupMode = "auto"
                    ClaudeProbeProject.setCleanupMode(.auto)
                    showCleanupFlash("Claude auto-delete enabled. Will remove probe sessions after each probe.", color: .green)
                }
            } message: {
                Text("After each usage probe, only the dedicated Claude probe project is deleted once safety checks verify it contains only probe sessions.")
            }
            .alert("Delete Claude Probe Sessions Now?", isPresented: $showConfirmDeleteNow) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    let res = ClaudeProbeProject.cleanupNowUserInitiated()
                    handleCleanupResult(res, manual: true)
                }
            } message: {
                Text("Removes only the Agent Sessions Claude probe project after validation. If any session doesn’t look like a probe, nothing is deleted.")
            }

            // Codex subsection
            sectionHeader("Codex")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Toggle("Allow auto /status probe when stale", isOn: $codexAllowStatusProbe)
                        .toggleStyle(.checkbox)
                        .help("When Codex limits look stale and the strip or menu bar is visible, ask Codex CLI (/status) via tmux for a fresh update.")
                    Button(action: { CodexUsageModel.shared.refreshNow() }) { Text("Refresh Codex now").underline() }
                        .buttonStyle(.plain)
                        .help("Force Codex to refresh now. Runs the log refresh and a one-shot /status probe.")
                }
                Text("Primary tracking remains the JSONL log parser; /status is a secondary source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { codexProbeCleanupMode },
                    set: { newVal in
                        if newVal == "auto" {
                            showConfirmCodexAutoDelete = true
                        } else {
                            codexProbeCleanupMode = "none"
                            CodexProbeCleanup.setCleanupMode(.none)
                        }
                    }
                )) {
                    Text("No delete").tag("none")
                    Text("Auto-delete after each probe").foregroundStyle(.red).tag("auto")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                HStack(spacing: 12) {
                    Button("Delete Codex probe sessions now") { showConfirmCodexDeleteNow = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            .alert("Enable Automatic Cleanup?", isPresented: $showConfirmCodexAutoDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Enable", role: .destructive) {
                    codexProbeCleanupMode = "auto"
                    CodexProbeCleanup.setCleanupMode(.auto)
                    showCleanupFlash("Codex auto-delete enabled. Will remove probe sessions after each probe.", color: .green)
                }
            } message: {
                Text("After each status probe, only Codex probe sessions are deleted once safety checks verify they contain only probe markers.")
            }
            .alert("Delete Codex Probe Sessions Now?", isPresented: $showConfirmCodexDeleteNow) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    let res = CodexProbeCleanup.cleanupNowUserInitiated()
                    handleCodexCleanupResult(res)
                }
            } message: {
                Text("Removes only Codex probe sessions after validation. If any session doesn’t look like a probe, nothing is deleted.")
            }

        }
        .onReceive(NotificationCenter.default.publisher(for: CodexProbeCleanup.didRunCleanupNotification)) { note in
            if let info = note.userInfo as? [String: Any], let status = info["status"] as? String {
                switch status {
                case "success":
                    if let n = info["deleted"] as? Int { showCleanupFlash("Deleted \(n) Codex probe file(s).", color: .green) }
                    else { showCleanupFlash("Deleted Codex probe sessions.", color: .green) }
                case "not_found": showCleanupFlash("No Codex probe sessions to delete.", color: .secondary)
                case "unsafe": showCleanupFlash("Skipped: Codex sessions contained non-probe content.", color: .orange)
                case "io_error": showCleanupFlash("Failed to delete Codex probe sessions.", color: .red)
                case "disabled": break
                default: break
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ClaudeProbeProject.didRunCleanupNotification)) { note in
            if let info = note.userInfo as? [String: Any], let status = info["status"] as? String {
                switch status {
                case "success": showCleanupFlash("Deleted Claude probe project.", color: .green)
                case "not_found": showCleanupFlash("No Claude probe project to delete.", color: .secondary)
                case "unsafe": showCleanupFlash("Skipped: Claude project contained non-probe sessions.", color: .orange)
                case "io_error": showCleanupFlash("Failed to delete Claude probe project.", color: .red)
                case "disabled": break
                default: break
                }
            }
        }
    }

    private var menuBarTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Menu Bar")
                .font(.title2)
                .fontWeight(.semibold)

            // Status item settings (no extra section header per request)
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show menu bar usage", isOn: $menuBarEnabled, help: "Add a menu bar item that displays usage meters")

                labeledRow("Source") {
                    Picker("Source", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "MenuBarSource") ?? MenuBarSource.codex.rawValue },
                        set: { UserDefaults.standard.set($0, forKey: "MenuBarSource") }
                    )) {
                        ForEach(MenuBarSource.allCases) { s in
                            Text(s.title).tag(s.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!menuBarEnabled)
                    .frame(maxWidth: 360)
                    .help("Choose which agent usage the menu bar item displays")
                }

                labeledRow("Scope") {
                    Picker("Scope", selection: $menuBarScopeRaw) {
                        ForEach(MenuBarScope.allCases) { s in
                            Text(s.title).tag(s.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!menuBarEnabled)
                    .frame(maxWidth: 360)
                    .help("Select whether the menu bar shows 5-hour, weekly, or both usage windows")
                }

                labeledRow("Style") {
                    Picker("Style", selection: $menuBarStyleRaw) {
                        ForEach(MenuBarStyleKind.allCases) { k in
                            Text(k.title).tag(k.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!menuBarEnabled)
                    .frame(maxWidth: 360)
                    .help("Switch between bar graphs and numeric usage in the menu bar")
                }

                Text("Source: Codex, Claude, or Both. Style: Bars or numbers. Scope: 5h, weekly, or both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var codexCLITab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Codex CLI")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Codex CLI Binary")
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Binary Source") {
                    Picker("", selection: Binding(
                        get: { codexBinaryOverride.isEmpty ? 0 : 1 },
                        set: { idx in
                            if idx == 0 {
                                // Auto: clear override
                                codexBinaryOverride = ""
                                validateBinaryOverride()
                                resumeSettings.setBinaryOverride("")
                                scheduleCodexProbe()
                            } else {
                                // Custom: open file picker
                                pickCodexBinary()
                            }
                        }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Choose the Codex binary automatically or specify a custom executable")
                }

                if codexBinaryOverride.isEmpty {
                    // Auto mode: show detected binary
                    HStack {
                        Text("Detected:").font(.caption)
                        Text(probeVersion?.description ?? "unknown").font(.caption).monospaced()
                    }
                    if let path = resolvedCodexPath {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }

                    // Show helpful message if binary not found
                    if probeState == .failure && probeVersion == nil {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Codex CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install via npm: npm install -g @openai/codex-cli")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }

                    HStack(spacing: 12) {
                        Button("Check Version") { probeCodex() }
                            .buttonStyle(.bordered)
                            .help("Query the currently detected Codex binary for its version")
                        Button("Copy Path") {
                            if let p = resolvedCodexPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy the detected Codex binary path to clipboard")
                        .disabled(resolvedCodexPath == nil)
                        Button("Reveal") {
                            if let p = resolvedCodexPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal the detected Codex binary in Finder")
                        .disabled(resolvedCodexPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 10) {
                        TextField("/path/to/codex", text: $codexBinaryOverride)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { validateBinaryOverride(); commitCodexBinaryIfValid() }
                            .onChange(of: codexBinaryOverride) { _, _ in validateBinaryOverride(); commitCodexBinaryIfValid() }
                            .help("Enter the full path to a custom Codex binary")
                        Button("Choose…", action: pickCodexBinary)
                            .buttonStyle(.borderedProminent)
                            .help("Select the Codex binary from the filesystem")
                        Button("Clear") {
                            codexBinaryOverride = ""
                            validateBinaryOverride()
                            resumeSettings.setBinaryOverride("")
                            scheduleCodexProbe()
                        }
                        .buttonStyle(.bordered)
                        .help("Remove the custom binary override")
                    }
                    if !codexBinaryValid {
                        Label("Must be an executable file", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            sectionHeader("Sessions Directory")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Custom path (optional)", text: $codexPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit {
                            validateCodexPath()
                            commitCodexPathIfValid()
                        }
                        .onChange(of: codexPath) { _, _ in
                            validateCodexPath()
                            // Debounce commit on typing to avoid thrash
                            codexPathDebounce?.cancel()
                            let work = DispatchWorkItem { commitCodexPathIfValid() }
                            codexPathDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                        .help("Override the Codex sessions directory. Leave blank to use the default location")

                    Button(action: pickCodexFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for a directory to store Codex session logs")
                }

                if !codexPathValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Default: $CODEX_HOME/sessions or ~/.codex/sessions")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var claudeResumeTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Claude Code").font(.title2).fontWeight(.semibold)

            // Binary Source
            VStack(alignment: .leading, spacing: 10) {
                // Binary source segmented: Auto | Custom
                labeledRow("Binary Source") {
                    Picker("", selection: Binding(
                        get: { claudeSettings.binaryPath.isEmpty ? 0 : 1 },
                        set: { idx in
                            if idx == 0 {
                                // Auto: clear override
                                claudeSettings.setBinaryPath("")
                                scheduleClaudeProbe()
                            } else {
                                // Custom: open file picker
                                pickClaudeBinary()
                            }
                        }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Use the auto-detected Claude CLI or supply a custom path")
                }

                // Auto row (detected path + version + actions)
                if claudeSettings.binaryPath.isEmpty {
                    HStack {
                        Text("Detected:").font(.caption)
                        Text(claudeVersionString ?? "unknown").font(.caption).monospaced()
                    }
                    if let path = claudeResolvedPath {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }

                    // Show helpful message if binary not found
                    if claudeProbeState == .failure && claudeVersionString == nil {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Claude CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Download from claude.ai/download or install via npm: npm install -g @anthropic/claude-cli")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }

                    HStack(spacing: 12) {
                        Button("Check Version") { probeClaude() }
                            .buttonStyle(.bordered)
                            .help("Query the detected Claude CLI for its version")
                        Button("Copy Path") {
                            if let p = claudeResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy the detected Claude CLI path to clipboard")
                        .disabled(claudeResolvedPath == nil)
                        Button("Reveal") {
                            if let p = claudeResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal the detected Claude CLI binary in Finder")
                        .disabled(claudeResolvedPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 10) {
                        TextField("/path/to/claude", text: Binding(get: { claudeSettings.binaryPath }, set: { claudeSettings.setBinaryPath($0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { scheduleClaudeProbe() }
                            .onChange(of: claudeSettings.binaryPath) { _, _ in scheduleClaudeProbe() }
                            .help("Enter the full path to a custom Claude CLI binary")
                        Button("Choose…", action: pickClaudeBinary)
                            .buttonStyle(.borderedProminent)
                            .help("Select the Claude CLI binary from the filesystem")
                        Button("Clear") {
                            claudeSettings.setBinaryPath("")
                        }
                        .buttonStyle(.bordered)
                        .help("Remove the custom binary override")
                    }
                }
            }

            // Sessions Directory (Claude)
            sectionHeader("Sessions Directory")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Custom path (optional)", text: $claudePath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit {
                            validateClaudePath()
                            commitClaudePathIfValid()
                        }
                        .onChange(of: claudePath) { _, _ in
                            validateClaudePath()
                            claudePathDebounce?.cancel()
                            let work = DispatchWorkItem { commitClaudePathIfValid() }
                            claudePathDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                        .help("Override the Claude sessions directory. Leave blank to use the default location")

                    Button(action: pickClaudeFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Browse for a directory to store Claude session logs")
                }

                if !claudePathValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Default: ~/.claude")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Usage Tracking moved to Unified Window tab.

            // Probe cleanup controls moved to Usage Tracking → Usage Terminal Probes
        }
    }

    // MARK: - Cleanup flash helpers
    private func showCleanupFlash(_ text: String, color: Color) {
        cleanupFlashText = text
        cleanupFlashColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            withAnimation { cleanupFlashText = nil }
        }
    }
    private func handleCleanupResult(_ res: ClaudeProbeProject.ResultStatus, manual: Bool) {
        switch res {
        case .success: showCleanupFlash("Deleted probe project.", color: .green)
        case .notFound: showCleanupFlash("No probe project to delete.", color: .secondary)
        case .unsafe: showCleanupFlash("Skipped: project contained non-probe sessions.", color: .orange)
        case .ioError: showCleanupFlash("Failed to delete probe project.", color: .red)
        case .disabled: break
        }
    }
    private func handleCodexCleanupResult(_ res: CodexProbeCleanup.ResultStatus) {
        switch res {
        case .success(let n): showCleanupFlash("Deleted \(n) Codex probe file(s).", color: .green)
        case .notFound(let s): showCleanupFlash(s, color: .secondary)
        case .unsafe(let s): showCleanupFlash(s, color: .orange)
        case .ioError(let s): showCleanupFlash(s, color: .red)
        case .disabled: break
        }
    }

    private var geminiCLITab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Gemini CLI").font(.title2).fontWeight(.semibold)

            // Binary Source
            VStack(alignment: .leading, spacing: 10) {
                // Binary source segmented: Auto | Custom
                labeledRow("Binary Source") {
                    Picker("", selection: Binding(
                        get: { geminiSettings.binaryOverride.isEmpty ? 0 : 1 },
                        set: { idx in
                            if idx == 0 {
                                // Auto: clear override
                                geminiSettings.setBinaryOverride("")
                                scheduleGeminiProbe()
                            } else {
                                // Custom: open file picker
                                pickGeminiBinary()
                            }
                        }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Use the auto-detected Gemini CLI or supply a custom path")
                }

                // Auto row (detected path + version + actions)
                if geminiSettings.binaryOverride.isEmpty {
                    HStack {
                        Text("Detected:").font(.caption)
                        Text(geminiVersionString ?? "unknown").font(.caption).monospaced()
                    }
                    if let path = geminiResolvedPath {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }

                    // Show helpful message if binary not found
                    if geminiProbeState == .failure && geminiVersionString == nil {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Gemini CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install via npm: npm install -g @google/generative-ai-cli")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }

                    HStack(spacing: 12) {
                        Button("Check Version") { probeGemini() }
                            .buttonStyle(.bordered)
                            .help("Query the detected Gemini CLI for its version")
                        Button("Copy Path") {
                            if let p = geminiResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy the detected Gemini CLI path to clipboard")
                        .disabled(geminiResolvedPath == nil)
                        Button("Reveal") {
                            if let p = geminiResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal the detected Gemini CLI binary in Finder")
                        .disabled(geminiResolvedPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 10) {
                        TextField("/path/to/gemini", text: Binding(get: { geminiSettings.binaryOverride }, set: { geminiSettings.setBinaryOverride($0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onSubmit { scheduleGeminiProbe() }
                            .onChange(of: geminiSettings.binaryOverride) { _, _ in scheduleGeminiProbe() }
                            .help("Enter the full path to a custom Gemini CLI binary")
                        Button("Choose…", action: pickGeminiBinary)
                            .buttonStyle(.borderedProminent)
                            .help("Select the Gemini CLI binary from the filesystem")
                        Button("Clear") {
                            geminiSettings.setBinaryOverride("")
                        }
                        .buttonStyle(.bordered)
                        .help("Remove the custom binary override")
                    }
                }
            }

            // Usage Tracking moved to Unified Window tab.
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("About")
                .font(.title2)
                .fontWeight(.semibold)

            // App Icon
            HStack {
                Spacer()
                if let appIcon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 85, height: 85)
                        .cornerRadius(11)
                        .shadow(radius: 3)
                }
                Spacer()
            }
            .padding(.vertical, 8)

            sectionHeader("Agent Sessions")
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Version:")
                        .frame(width: labelColumnWidth, alignment: .leading)
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text(version)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Website:")
                        .frame(width: labelColumnWidth, alignment: .leading)
                    Button("jazzyalex.github.io/agent-sessions") {
                        UpdateCheckModel.shared.openURL("https://jazzyalex.github.io/agent-sessions/")
                    }
                    .buttonStyle(.link)
                }

                HStack {
                    Text("GitHub:")
                        .frame(width: labelColumnWidth, alignment: .leading)
                    Button("github.com/jazzyalex/agent-sessions") {
                        UpdateCheckModel.shared.openURL("https://github.com/jazzyalex/agent-sessions")
                    }
                    .buttonStyle(.link)
                }

                HStack {
                    Text("X (Twitter):")
                        .frame(width: labelColumnWidth, alignment: .leading)
                    Button("@jazzyalex") {
                        UpdateCheckModel.shared.openURL("https://x.com/jazzyalex")
                    }
                    .buttonStyle(.link)
                }
            }

            sectionHeader("Updates")
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent Sessions uses automatic updates to keep you up to date with the latest features and bug fixes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if updaterController.hasGentleReminder {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.blue)
                        Text("An update is available")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }

                Divider()

                Button("Check for Updates...") {
                    updaterController.checkForUpdates(nil)
                }
                .buttonStyle(.bordered)
                .help("Check for new versions and install updates")
            }

            Spacer()
        }
    }

    // MARK: Actions

    private func loadCurrentSettings() {
        codexPath = indexer.sessionsRootOverride
        validateCodexPath()
        // Load Claude sessions override from defaults
        let cp = UserDefaults.standard.string(forKey: "ClaudeSessionsRootOverride") ?? ""
        claudePath = cp
        validateClaudePath()
        appearance = indexer.appAppearance
        modifiedDisplay = indexer.modifiedDisplay
        codexBinaryOverride = resumeSettings.binaryOverride
        validateBinaryOverride()
        defaultResumeDirectory = resumeSettings.defaultWorkingDirectory
        validateDefaultDirectory()
        preferredLaunchMode = resumeSettings.launchMode
        // Reset probe state; actual probing is triggered when related tab is shown
        probeState = .idle
        probeVersion = nil
        resolvedCodexPath = nil
    }

    private func validateCodexPath() {
        guard !codexPath.isEmpty else {
            codexPathValid = true
            return
        }
        var isDir: ObjCBool = false
        codexPathValid = FileManager.default.fileExists(atPath: codexPath, isDirectory: &isDir) && isDir.boolValue
    }

    private func commitCodexPathIfValid() {
        guard codexPathValid else { return }
        // Persist and refresh index once
        if indexer.sessionsRootOverride != codexPath {
            indexer.sessionsRootOverride = codexPath
            indexer.refresh()
        }
    }

    private func pickCodexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                codexPath = url.path
                validateCodexPath()
                commitCodexPathIfValid()
            }
        }
    }

    private func validateClaudePath() {
        guard !claudePath.isEmpty else {
            claudePathValid = true
            return
        }
        var isDir: ObjCBool = false
        claudePathValid = FileManager.default.fileExists(atPath: claudePath, isDirectory: &isDir) && isDir.boolValue
    }

    private func commitClaudePathIfValid() {
        guard claudePathValid else { return }
        let current = UserDefaults.standard.string(forKey: "ClaudeSessionsRootOverride") ?? ""
        if current != claudePath {
            UserDefaults.standard.set(claudePath, forKey: "ClaudeSessionsRootOverride")
            // ClaudeSessionIndexer listens to UserDefaults changes and triggers its own refresh
        }
    }

    private func pickClaudeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                claudePath = url.path
                validateClaudePath()
                commitClaudePathIfValid()
            }
        }
    }

    private func validateBinaryOverride() {
        guard !codexBinaryOverride.isEmpty else {
            codexBinaryValid = true
            return
        }
        let expanded = (codexBinaryOverride as NSString).expandingTildeInPath
        codexBinaryValid = FileManager.default.isExecutableFile(atPath: expanded)
    }

    private func commitCodexBinaryIfValid() {
        if codexBinaryOverride.isEmpty {
            // handled by Clear path
            return
        }
        if codexBinaryValid {
            resumeSettings.setBinaryOverride(codexBinaryOverride)
            scheduleCodexProbe()
        }
    }

    private func pickCodexBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                codexBinaryOverride = url.path
                validateBinaryOverride()
                commitCodexBinaryIfValid()
            }
        }
    }

    private func pickClaudeBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                claudeSettings.setBinaryPath(url.path)
            }
        }
    }

    private func pickGeminiBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                geminiSettings.setBinaryOverride(url.path)
            }
        }
    }

    private func validateDefaultDirectory() {
        guard !defaultResumeDirectory.isEmpty else {
            defaultResumeDirectoryValid = true
            return
        }
        var isDir: ObjCBool = false
        defaultResumeDirectoryValid = FileManager.default.fileExists(atPath: defaultResumeDirectory, isDirectory: &isDir) && isDir.boolValue
    }

    private func pickDefaultDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                defaultResumeDirectory = url.path
                validateDefaultDirectory()
            }
        }
    }

    private func resetToDefaults() {
        codexPath = ""
        indexer.sessionsRootOverride = ""
        validateCodexPath()

        appearance = .system
        indexer.setAppearance(.system)

        modifiedDisplay = .relative
        indexer.setModifiedDisplay(.relative)

        columnVisibility.restoreDefaults()

        codexBinaryOverride = ""
        resumeSettings.setBinaryOverride("")
        validateBinaryOverride()

        defaultResumeDirectory = ""
        resumeSettings.setDefaultWorkingDirectory("")
        validateDefaultDirectory()

        preferredLaunchMode = .terminal
        resumeSettings.setLaunchMode(.terminal)

        geminiSettings.setBinaryOverride("")

        // Reset usage strip preferences
        UserDefaults.standard.set(false, forKey: "ShowClaudeUsageStrip")
        ClaudeUsageModel.shared.setEnabled(false)

        // Re-probe after reset
        scheduleCodexProbe()
        scheduleClaudeProbe()
        scheduleGeminiProbe()
    }

    private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    // MARK: Helpers

    private func toggleRow(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .frame(width: labelColumnWidth, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(label))
                .help(help)
        }
    }

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .frame(width: labelColumnWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            Divider()
        }
    }
}

// MARK: - Tabs

enum PreferencesTab: String, CaseIterable, Identifiable {
    case general
    case usageTracking
    case usageProbes
    case menuBar
    case unified
    case codexCLI
    case claudeResume
    case geminiCLI
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .usageTracking: return "Usage Tracking"
        case .usageProbes: return "Usage Probes"
        case .menuBar: return "Menu Bar"
        case .unified: return "Unified Window"
        case .codexCLI: return "Codex CLI"
        case .claudeResume: return "Claude Code"
        case .geminiCLI: return "Gemini CLI"
        case .about: return "About"
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .usageTracking: return "chart.bar"
        case .usageProbes: return "wrench.and.screwdriver"
        case .menuBar: return "menubar.rectangle"
        case .unified: return "square.grid.2x2"
        case .codexCLI: return "terminal"
        case .claudeResume: return "chevron.left.slash.chevron.right"
        case .geminiCLI: return "g.circle"
        case .about: return "info.circle"
        }
    }
}

private extension PreferencesView {
    // Sidebar order: General → Codex CLI → Claude Code → Gemini CLI → Unified Window → Usage Tracking → About
    var visibleTabs: [PreferencesTab] { [.general, .codexCLI, .claudeResume, /*.geminiCLI,*/ .unified, .usageTracking, .usageProbes, .menuBar, .about] }
}

// MARK: - Probe helpers

private extension PreferencesView {
    enum ProbeState { case idle, probing, success, failure }

    func probeCodex() {
        if probeState == .probing { return }
        probeState = .probing
        probeVersion = nil
        resolvedCodexPath = nil
        let override = codexBinaryOverride.isEmpty ? (resumeSettings.binaryOverride) : codexBinaryOverride
        DispatchQueue.global(qos: .userInitiated).async {
            let env = CodexCLIEnvironment()
            let result = env.probeVersion(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    self.probeVersion = data.version
                    self.resolvedCodexPath = data.binaryURL.path
                    self.probeState = .success
                case .failure:
                    self.probeVersion = nil
                    self.resolvedCodexPath = nil
                    self.probeState = .failure
                }
            }
        }
    }

    func probeClaude() {
        if claudeProbeState == .probing { return }
        claudeProbeState = .probing
        claudeVersionString = nil
        claudeResolvedPath = nil
        let override = claudeSettings.binaryPath.isEmpty ? nil : claudeSettings.binaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let env = ClaudeCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.claudeVersionString = res.versionString
                    self.claudeResolvedPath = res.binaryURL.path
                    self.claudeProbeState = .success
                case .failure:
                    self.claudeVersionString = nil
                    self.claudeResolvedPath = nil
                    self.claudeProbeState = .failure
                }
            }
        }
    }

    func probeGemini() {
        if geminiProbeState == .probing { return }
        geminiProbeState = .probing
        geminiVersionString = nil
        geminiResolvedPath = nil
        let override = geminiSettings.binaryOverride.isEmpty ? nil : geminiSettings.binaryOverride
        DispatchQueue.global(qos: .userInitiated).async {
            let env = GeminiCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.geminiVersionString = res.versionString
                    self.geminiResolvedPath = res.binaryURL.path
                    self.geminiProbeState = .success
                case .failure:
                    self.geminiVersionString = nil
                    self.geminiResolvedPath = nil
                    self.geminiProbeState = .failure
                }
            }
        }
    }

    // Trigger background probes only when a relevant pane is active
    func maybeProbe(for tab: PreferencesTab) {
        switch tab {
        case .codexCLI, .usageTracking:
            if probeVersion == nil && probeState != .probing { probeCodex() }
        case .claudeResume:
            if claudeVersionString == nil && claudeProbeState != .probing { probeClaude() }
        case .geminiCLI:
            if geminiVersionString == nil && geminiProbeState != .probing { probeGemini() }
        case .menuBar, .usageProbes, .general, .unified, .about:
            break
        }
    }

    func scheduleCodexProbe() {
        codexProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeCodex() }
        codexProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func scheduleClaudeProbe() {
        claudeProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeClaude() }
        claudeProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func scheduleGeminiProbe() {
        geminiProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeGemini() }
        geminiProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

// MARK: - Supporting Views

// Old PreferenceCard removed in favor of flat, sectioned layout.

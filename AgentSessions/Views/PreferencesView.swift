import SwiftUI
import AppKit

private let labelColumnWidth: CGFloat = 170

struct PreferencesView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @State private var selectedTab: PreferencesTab?
    // Persist last-selected tab for smoother navigation across launches
    @AppStorage("PreferencesLastSelectedTab") private var lastSelectedTabRaw: String = PreferencesTab.general.rawValue
    private let initialTabArg: PreferencesTab
    @ObservedObject private var resumeSettings = CodexResumeSettings.shared
    @ObservedObject private var claudeSettings = ClaudeResumeSettings.shared
    @State private var showingResetConfirm: Bool = false
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    // Menu bar prefs
    @AppStorage("MenuBarEnabled") private var menuBarEnabled: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("StripShowResetTime") private var stripShowResetTime: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochromeGlobal: Bool = false
    @AppStorage("HideZeroMessageSessions") private var hideZeroMessageSessionsPref: Bool = true
    @AppStorage("HideLowMessageSessions") private var hideLowMessageSessionsPref: Bool = false
    @AppStorage("UsagePollingInterval") private var usagePollingInterval: Int = 120 // seconds (default 2 min)

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

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(visibleTabs, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.iconName)
                    .tag(tab)
            }
            // Fix the sidebar width to avoid horizontal jumps when switching panes
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        } detail: {
            VStack(spacing: 0) {
                tabBody
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
            case .menuBar:
                menuBarTab
            case .unified:
                unifiedTab
            case .codexCLI:
                codexCLITab
            case .claudeResume:
                claudeResumeTab
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

                // Agent color is controlled by UI Elements (Monochrome/Color)

                labeledRow("UI Elements") {
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
                Text("Affects usage strips, Unified toolbar source labels, and CLI Agent column coloring in Sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Sessions List")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Toggle("Session titles", isOn: $indexer.showTitleColumn)
                        .help("Show or hide the Session title column in the Sessions list")
                    Toggle("Project names", isOn: $indexer.showProjectColumn)
                        .help("Show or hide the Project column in the Sessions list")
                }
                HStack(spacing: 16) {
                    Toggle("Message counts", isOn: $indexer.showMsgsColumn)
                        .help("Show or hide message counts in the Sessions list")
                    Toggle("Modified date", isOn: $indexer.showModifiedColumn)
                        .help("Show or hide the modified date column")
                }
                HStack(spacing: 16) {
                    Toggle("Source column", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "UnifiedShowSourceColumn") },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedShowSourceColumn") }
                    ))
                    .help("Show or hide the CLI Agent source column in the Unified list")
                }
                Divider()
                Text("Exclude Sessions with:")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                HStack(spacing: 16) {
                    Toggle("Zero msgs", isOn: $hideZeroMessageSessionsPref)
                        .onChange(of: hideZeroMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                        .help("Hide sessions that contain no user or assistant messages")
                    Toggle("1–2 messages", isOn: $hideLowMessageSessionsPref)
                        .onChange(of: hideLowMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                        .help("Hide sessions with only one or two messages")
                }

                Divider()
                Toggle("Skip Agents.md lines when parsing", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "SkipAgentsPreamble") },
                    set: { UserDefaults.standard.set($0, forKey: "SkipAgentsPreamble"); indexer.recomputeNow() }
                ))
                .help("Ignore agents.md-style preambles for titles and previews (content remains visible in transcripts)")
            }

        }
    }

    private var unifiedTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Unified Window")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Display")
            VStack(alignment: .leading, spacing: 12) {
                // Controls for columns are available in General → Sessions List
                Text("Configure list columns in General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Usage Tracking")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    toggleRow("Codex strip", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "UnifiedShowCodexStrip") },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedShowCodexStrip") }
                    ), help: "Show the Codex usage strip at the bottom of the Unified window")
                    toggleRow("Claude strip", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "UnifiedShowClaudeStrip") },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedShowClaudeStrip") }
                    ), help: "Show the Claude usage strip at the bottom of the Unified window")
                }
                HStack(spacing: 12) {
                    Toggle("Activate Claude usage", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "ShowClaudeUsageStrip") },
                        set: { newValue in
                            if newValue {
                                showClaudeExperimentalWarning = true
                            } else {
                                UserDefaults.standard.set(false, forKey: "ShowClaudeUsageStrip")
                                ClaudeUsageModel.shared.setEnabled(false)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .help("Enable periodic Claude CLI checks to show usage data (requires tmux)")
                    Button(action: { ClaudeUsageModel.shared.refreshNow() }) { Text("Refresh Now").underline() }
                        .buttonStyle(.plain)
                        .disabled(!UserDefaults.standard.bool(forKey: "ShowClaudeUsageStrip"))
                        .help("Force a usage refresh immediately when Claude tracking is enabled")
                }
                HStack(spacing: 16) { toggleRow("Show reset times", isOn: $stripShowResetTime, help: "Display the usage reset timestamp next to each meter") }

                Divider()

                labeledRow("Polling Interval") {
                    Picker("", selection: $usagePollingInterval) {
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("3 minutes").tag(180)
                        Text("10 minutes").tag(600)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .help("How often to check usage data (affects both Codex and Claude)")
                }
                Text("Longer intervals reduce CPU usage. Strips stack vertically when both are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            sectionHeader("Codex CLI Version")
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Detected version:").font(.caption)
                    Text(probeVersion?.description ?? "unknown").font(.caption).monospaced()
                }
                if let path = resolvedCodexPath {
                    Text(path).font(.caption2).foregroundStyle(.secondary)
                }
                Button("Re-probe") { probeCodex() }
                    .buttonStyle(.bordered)
                    .help("Check again for the Codex CLI version and path")
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

            sectionHeader("Binary")
            VStack(alignment: .leading, spacing: 10) {
                labeledRow("Binary Source") {
                    Picker("Binary Source", selection: Binding(
                        get: { codexBinaryOverride.isEmpty ? 0 : 1 },
                        set: { idx in if idx == 0 { codexBinaryOverride = ""; validateBinaryOverride(); resumeSettings.setBinaryOverride(""); scheduleCodexProbe() } }
                    )) {
                        Text("Auto").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .help("Choose the Codex binary automatically or specify a custom executable")
                }

                if codexBinaryOverride.isEmpty {
                    HStack(spacing: 10) {
                        Text(resolvedCodexPath ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let version = probeVersion { Text("• v\(version.description)").font(.caption).foregroundStyle(.secondary) }
                        Button(action: probeCodex) { Text("Check Version").underline() }
                            .buttonStyle(.plain).foregroundColor(.accentColor)
                            .help("Query the currently detected Codex binary for its version")
                        Button(action: { if let p = resolvedCodexPath { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string) } }) { Text("Copy").underline() }
                            .buttonStyle(.plain).foregroundColor(.accentColor)
                            .help("Copy the detected Codex binary path")
                        Button(action: { if let p = resolvedCodexPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }) { Text("Reveal").underline() }
                            .buttonStyle(.plain).foregroundColor(.accentColor)
                            .help("Reveal the detected Codex binary in Finder")
                    }
                } else {
                    HStack(spacing: 10) {
                        TextField("/path/to/codex", text: $codexBinaryOverride)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { validateBinaryOverride(); commitCodexBinaryIfValid() }
                            .onChange(of: codexBinaryOverride) { _, _ in validateBinaryOverride(); commitCodexBinaryIfValid() }
                            .help("Enter the full path to a custom Codex binary")
                        Button("Choose…", action: pickCodexBinary).buttonStyle(.bordered)
                            .help("Select the Codex binary from the filesystem")
                        Button("Clear") { codexBinaryOverride = ""; validateBinaryOverride(); resumeSettings.setBinaryOverride(""); scheduleCodexProbe() }.buttonStyle(.bordered)
                            .help("Remove the custom binary override")
                    }
                    if !codexBinaryValid {
                        Label("Must be an executable file", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    }
                }
            }

            // Usage Tracking controls live in the Unified Window tab.
        }
    }

    private var claudeResumeTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Claude Code").font(.title2).fontWeight(.semibold)

            sectionHeader("Resume")
            VStack(alignment: .leading, spacing: 10) {
                labeledRow("Terminal App") {
                    Picker("Terminal App", selection: Binding(get: { claudeSettings.preferITerm ? 1 : 0 }, set: { claudeSettings.setPreferITerm($0 == 1) })) {
                        Text("Terminal").tag(0)
                        Text("iTerm2").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .help("Choose which terminal application handles Claude resume commands")
                }

                // Binary source segmented: Auto | Custom
                labeledRow("Binary Source") {
                    Picker("Binary Source", selection: Binding(
                        get: { claudeSettings.binaryPath.isEmpty ? 0 : 1 },
                        set: { idx in if idx == 0 { claudeSettings.setBinaryPath(""); scheduleClaudeProbe() } }
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
                    HStack(spacing: 10) {
                        // Path and version
                        Text(claudeResolvedPath ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let ver = claudeVersionString { Text("• v\(ver)").font(.caption).foregroundStyle(.secondary) }
                        Button(action: probeClaude) { Text("Check Version").underline() }
                            .buttonStyle(.plain).foregroundColor(.accentColor)
                            .help("Query the detected Claude CLI for its version")
                        Button(action: { if let p = claudeResolvedPath { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string) } }) { Text("Copy").underline() }
                            .buttonStyle(.plain).foregroundColor(.accentColor)
                            .help("Copy the detected Claude CLI path")
                        Button(action: { if let p = claudeResolvedPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }) { Text("Reveal").underline() }
                            .buttonStyle(.plain).foregroundColor(.accentColor)
                            .help("Reveal the detected Claude CLI binary in Finder")
                    }
                } else {
                    // Custom row
                    HStack(spacing: 10) {
                        TextField("/path/to/claude", text: Binding(get: { claudeSettings.binaryPath }, set: { claudeSettings.setBinaryPath($0) }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { scheduleClaudeProbe() }
                            .onChange(of: claudeSettings.binaryPath) { _, _ in scheduleClaudeProbe() }
                            .help("Specify a custom Claude CLI executable path")
                        Button("Choose…", action: pickClaudeBinary).buttonStyle(.bordered)
                            .help("Select the Claude CLI executable")
                        Button("Clear") { claudeSettings.setBinaryPath("") }.buttonStyle(.bordered)
                            .help("Remove the custom Claude CLI path")
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
                        .frame(width: 128, height: 128)
                        .cornerRadius(16)
                        .shadow(radius: 4)
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
                // Update status
                switch UpdateCheckModel.shared.state {
                case .idle:
                    Text("Updates have not been checked yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .checking:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking for updates...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .available(let version, let releaseURL, let assetURL):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Version \(version) is available")
                            .font(.headline)
                            .foregroundStyle(.green)

                        HStack(spacing: 8) {
                            Button("Release Notes") {
                                UpdateCheckModel.shared.openURL(releaseURL)
                            }
                            .buttonStyle(.bordered)
                            .help("Open release notes in your browser")

                            Button("Download") {
                                UpdateCheckModel.shared.openURL(assetURL)
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Download the latest version")

                            Button("Skip Launch Dialog") {
                                UpdateCheckModel.shared.skipVersionForLaunchOnly(version)
                            }
                            .buttonStyle(.bordered)
                            .help("Don't show update dialog on launch for this version")
                        }
                    }

                case .upToDate:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("You're up to date")
                            .font(.subheadline)
                    }

                case .error(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Error: \(message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Button("Check for Updates") {
                    UpdateCheckModel.shared.checkManually()
                }
                .buttonStyle(.bordered)
                .help("Manually check for new versions")
            }

            Spacer()
        }
    }

    // MARK: Actions

    private func loadCurrentSettings() {
        codexPath = indexer.sessionsRootOverride
        validateCodexPath()
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

        indexer.showTitleColumn = true
        indexer.showProjectColumn = true
        indexer.showMsgsColumn = true
        indexer.showModifiedColumn = true

        codexBinaryOverride = ""
        resumeSettings.setBinaryOverride("")
        validateBinaryOverride()

        defaultResumeDirectory = ""
        resumeSettings.setDefaultWorkingDirectory("")
        validateDefaultDirectory()

        preferredLaunchMode = .terminal
        resumeSettings.setLaunchMode(.terminal)

        // Reset usage strip preferences
        UserDefaults.standard.set(false, forKey: "ShowClaudeUsageStrip")
        ClaudeUsageModel.shared.setEnabled(false)

        // Re-probe after reset
        scheduleCodexProbe()
        scheduleClaudeProbe()
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
    case menuBar
    case unified
    case codexCLI
    case claudeResume
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .unified: return "Unified Window"
        case .codexCLI: return "Codex CLI"
        case .claudeResume: return "Claude Code"
        case .about: return "About"
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .unified: return "square.grid.2x2"
        case .codexCLI: return "terminal"
        case .claudeResume: return "chevron.left.slash.chevron.right"
        case .about: return "info.circle"
        }
    }
}

private extension PreferencesView {
    // Sidebar order: General → Codex CLI → Claude Code → Unified Window → Menu Bar → About
    var visibleTabs: [PreferencesTab] { [.general, .codexCLI, .claudeResume, .unified, .menuBar, .about] }
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

    // Trigger background probes only when a relevant pane is active
    func maybeProbe(for tab: PreferencesTab) {
        switch tab {
        case .codexCLI, .menuBar:
            if probeVersion == nil && probeState != .probing { probeCodex() }
        case .claudeResume:
            if claudeVersionString == nil && claudeProbeState != .probing { probeClaude() }
        case .general, .unified, .about:
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
}

// MARK: - Supporting Views

// Old PreferenceCard removed in favor of flat, sectioned layout.

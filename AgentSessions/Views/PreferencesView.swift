import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @EnvironmentObject var updaterController: UpdaterController
    @EnvironmentObject var columnVisibility: ColumnVisibilityStore
    @State var selectedTab: PreferencesTab?
    // Persist last-selected tab for smoother navigation across launches
    @AppStorage(PreferencesKey.lastSelectedTab) var lastSelectedTabRaw: String = PreferencesTab.general.rawValue
    private let initialTabArg: PreferencesTab
    @ObservedObject var resumeSettings = CodexResumeSettings.shared
    @ObservedObject var claudeSettings = ClaudeResumeSettings.shared
    @ObservedObject var geminiSettings = GeminiCLISettings.shared
    @ObservedObject var copilotSettings = CopilotSettings.shared
    @State var showingResetConfirm: Bool = false
    @AppStorage(PreferencesKey.showUsageStrip) var showUsageStrip: Bool = false
    // Codex tracking master toggle
    @AppStorage(PreferencesKey.codexUsageEnabled) var codexUsageEnabled: Bool = false
    // Codex auto-probe pref (secondary tmux-based /status probe when stale)
    @AppStorage(PreferencesKey.codexAllowStatusProbe) var codexAllowStatusProbe: Bool = false
    // Codex probe cleanup prefs
    @AppStorage(PreferencesKey.codexProbeCleanupMode) var codexProbeCleanupMode: String = "none" // none | auto
    @State var showConfirmCodexAutoDelete: Bool = false
    @State var showConfirmCodexDeleteNow: Bool = false
    // Claude tracking master toggle
    @AppStorage(PreferencesKey.claudeUsageEnabled) var claudeUsageEnabled: Bool = false
    // Claude Probe cleanup prefs
    @AppStorage(PreferencesKey.claudeProbeCleanupMode) var claudeProbeCleanupMode: String = "none" // none | auto
    // Debug: show probe sessions in lists
    @AppStorage(PreferencesKey.showSystemProbeSessions) var showSystemProbeSessions: Bool = false
    @State var showConfirmAutoDelete: Bool = false
    @State var showConfirmDeleteNow: Bool = false
    @State var showClaudeCleanupResult: Bool = false
    @State var claudeCleanupMessage: String = ""
    @State var showCodexCleanupResult: Bool = false
    @State var codexCleanupMessage: String = ""
    @State var showCodexProbeResult: Bool = false
    @State var codexProbeMessage: String = ""
    @State var isCodexHardProbeRunning: Bool = false
    @State var showClaudeProbeResult: Bool = false
    @State var claudeProbeMessage: String = ""
    @State var isClaudeHardProbeRunning: Bool = false
    @State var cleanupFlashText: String? = nil
    @State var cleanupFlashColor: Color = .secondary
    // CLI availability (assume installed until a probe fails)
    @AppStorage(PreferencesKey.codexCLIAvailable) var codexCLIAvailable: Bool = true
    @AppStorage(PreferencesKey.claudeCLIAvailable) var claudeCLIAvailable: Bool = true
    @AppStorage(PreferencesKey.geminiCLIAvailable) var geminiCLIAvailable: Bool = true
    @AppStorage(PreferencesKey.openCodeCLIAvailable) var openCodeCLIAvailable: Bool = true
    @AppStorage(PreferencesKey.copilotCLIAvailable) var copilotCLIAvailable: Bool = true
    @AppStorage(PreferencesKey.droidCLIAvailable) var droidCLIAvailable: Bool = true
    // Global agent enablement
    @AppStorage(PreferencesKey.Agents.codexEnabled) var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.geminiEnabled) var geminiAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openCodeEnabled) var openCodeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.copilotEnabled) var copilotAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.droidEnabled) var droidAgentEnabled: Bool = true
    // Menu bar prefs
    @AppStorage(PreferencesKey.menuBarEnabled) var menuBarEnabled: Bool = false
    @AppStorage(PreferencesKey.menuBarScope) var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage(PreferencesKey.menuBarStyle) var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage(PreferencesKey.stripShowResetTime) var stripShowResetTime: Bool = false
    @AppStorage(PreferencesKey.stripMonochromeMeters) var stripMonochromeGlobal: Bool = false
    @AppStorage(PreferencesKey.usageDisplayMode) var usageDisplayModeRaw: String = UsageDisplayMode.left.rawValue
    @AppStorage(PreferencesKey.hideZeroMessageSessions) var hideZeroMessageSessionsPref: Bool = true
    @AppStorage(PreferencesKey.hideLowMessageSessions) var hideLowMessageSessionsPref: Bool = true
    // Per-agent polling intervals
    @AppStorage(PreferencesKey.codexPollingInterval) var codexPollingInterval: Int = 300   // 1/5/15 min options, default 5m
    @AppStorage(PreferencesKey.claudePollingInterval) var claudePollingInterval: Int = 900 // 3/15/30 min options, default 15m
    // Star / Pin behavior
    @AppStorage(PreferencesKey.Archives.starPinsSessions) var starPinsSessions: Bool = true
    @AppStorage(PreferencesKey.Archives.stopSyncAfterInactivityMinutes) var stopSyncAfterInactivityMinutes: Int = 30
    @AppStorage(PreferencesKey.Archives.unstarRemovesArchive) var unstarRemovesArchive: Bool = false

    init(initialTab: PreferencesTab = .general) {
        self.initialTabArg = initialTab
        _selectedTab = State(initialValue: initialTab)
    }

    // General tab state
    @State var modifiedDisplay: SessionIndexer.ModifiedDisplay = .relative

    // Codex CLI tab state
    @State var codexPath: String = ""
    @State var codexPathValid: Bool = true
    @State var codexBinaryOverride: String = ""
    @State var codexBinaryValid: Bool = true
    @State var defaultResumeDirectory: String = ""
    @State var defaultResumeDirectoryValid: Bool = true
    @State var preferredLaunchMode: CodexLaunchMode = .terminal
    @State var probeState: ProbeState = .idle
    @State var probeVersion: CodexVersion? = nil
    @State var resolvedCodexPath: String? = nil
    @State var codexPathDebounce: DispatchWorkItem? = nil
    @State var codexProbeDebounce: DispatchWorkItem? = nil

    // Claude CLI probe state (for Resume tab)
    @State var claudeProbeState: ProbeState = .idle
    @State var claudeVersionString: String? = nil
    @State var claudeResolvedPath: String? = nil
    @State var claudeProbeDebounce: DispatchWorkItem? = nil
    @State var showClaudeExperimentalWarning: Bool = false
    // Claude Sessions directory override
    @State var claudePath: String = ""
    @State var claudePathValid: Bool = true
    @State var claudePathDebounce: DispatchWorkItem? = nil

    // Gemini CLI probe state
    @State var geminiProbeState: ProbeState = .idle
    @State var geminiVersionString: String? = nil
    @State var geminiResolvedPath: String? = nil
    @State var geminiProbeDebounce: DispatchWorkItem? = nil
    // Gemini Sessions directory override
    @AppStorage("GeminiSessionsRootOverride") var geminiSessionsPath: String = ""
    @State var geminiSessionsPathValid: Bool = true
    @State var geminiSessionsPathDebounce: DispatchWorkItem? = nil

    // OpenCode probe state
    @ObservedObject var opencodeSettings = OpenCodeSettings.shared
    @State var opencodeProbeState: ProbeState = .idle
    @State var opencodeVersionString: String? = nil
    @State var opencodeResolvedPath: String? = nil
    @State var opencodeProbeDebounce: DispatchWorkItem? = nil
    // OpenCode Sessions directory override
    @AppStorage("OpenCodeSessionsRootOverride") var opencodeSessionsPath: String = ""
    @State var opencodeSessionsPathValid: Bool = true
    @State var opencodeSessionsPathDebounce: DispatchWorkItem? = nil

    // Copilot probe state
    @State var copilotProbeState: ProbeState = .idle
    @State var copilotVersionString: String? = nil
    @State var copilotResolvedPath: String? = nil
    @State var copilotProbeDebounce: DispatchWorkItem? = nil
    // Copilot sessions directory override
    @AppStorage(PreferencesKey.Paths.copilotSessionsRootOverride) var copilotSessionsPath: String = ""
    @State var copilotSessionsPathValid: Bool = true
    @State var copilotSessionsPathDebounce: DispatchWorkItem? = nil

    // Droid probe state
    @ObservedObject var droidSettings = DroidSettings.shared
    @State var droidProbeState: ProbeState = .idle
    @State var droidVersionString: String? = nil
    @State var droidResolvedPath: String? = nil
    @State var droidProbeDebounce: DispatchWorkItem? = nil

    // Droid sessions/projects roots
    @AppStorage(PreferencesKey.Paths.droidSessionsRootOverride) var droidSessionsPath: String = ""
    @State var droidSessionsPathValid: Bool = true
    @State var droidSessionsPathDebounce: DispatchWorkItem? = nil
    @AppStorage(PreferencesKey.Paths.droidProjectsRootOverride) var droidProjectsPath: String = ""
    @State var droidProjectsPathValid: Bool = true
    @State var droidProjectsPathDebounce: DispatchWorkItem? = nil

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selectedTab) {
                ForEach(visibleTabs.filter { $0 != .about && $0 != .codexCLI && $0 != .claudeResume && $0 != .opencode && $0 != .geminiCLI && $0 != .copilotCLI && $0 != .droidCLI }, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.iconName)
                        .tag(tab)
                }
                Divider()
                ForEach([PreferencesTab.codexCLI, .claudeResume, .opencode, .geminiCLI, .copilotCLI, .droidCLI], id: \.self) { tab in
                    Label(tab.title, systemImage: tab.iconName)
                        .tag(tab)
                }
                Divider()
                Label(PreferencesTab.about.title, systemImage: PreferencesTab.about.iconName)
                    .tag(PreferencesTab.about)
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
        // Keep Codex strip visibility consistent with tracking master toggle.
        .onChange(of: codexUsageEnabled) { _, newValue in
            let d = UserDefaults.standard
            if newValue {
                d.set(true, forKey: PreferencesKey.Unified.showCodexStrip)
            } else {
                d.set(false, forKey: PreferencesKey.Unified.showCodexStrip)
            }
        }
        // Keep Claude strip visibility consistent with tracking master toggle.
        // When tracking is turned OFF, immediately hide the strip(s).
        // When tracking is turned ON again, turn the strip(s) back ON for visibility.
        .onChange(of: claudeUsageEnabled) { _, newValue in
            let d = UserDefaults.standard
            if newValue {
                d.set(true, forKey: PreferencesKey.Unified.showClaudeStrip)
                d.set(true, forKey: PreferencesKey.showClaudeUsageStrip)
            } else {
                d.set(false, forKey: PreferencesKey.Unified.showClaudeStrip)
                d.set(false, forKey: PreferencesKey.showClaudeUsageStrip)
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            guard let t = newValue else { return }
            lastSelectedTabRaw = t.rawValue
            maybeProbe(for: t)
        }
        .alert("Claude Usage Tracking (Experimental)", isPresented: $showClaudeExperimentalWarning) {
            Button("Cancel", role: .cancel) { }
                .help("Keep Claude usage tracking disabled")
            Button("Enable Anyway") {
                UserDefaults.standard.set(true, forKey: PreferencesKey.showClaudeUsageStrip)
                ClaudeUsageModel.shared.setEnabled(true)
            }
            .help("Enable the experimental Claude usage tracker despite the warning")
        } message: {
            Text("""
            This feature runs Claude Code headlessly via tmux to fetch `/usage` data (default: every 15 minutes).

            Requirements: Claude CLI + tmux installed and authenticated

            Install tmux (via Homebrew):
              brew install tmux

            ⚠️ Warnings:
            - Experimental - may fail or cause slowdowns
            - Probing may count toward Claude Code usage limits
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
            case .advanced:
                advancedTab
            case .codexCLI:
                codexCLITab
            case .claudeResume:
                claudeResumeTab
            case .opencode:
                openCodeTab
            case .geminiCLI:
                geminiCLITab
            case .copilotCLI:
                copilotCLITab
            case .droidCLI:
                droidCLITab
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





    // New Usage Tracking pane (combines usage strips and menu bar configuration)


    // New separate pane for terminal probes and cleanup








    // MARK: - Cleanup flash helpers
    func showCleanupFlash(_ text: String, color: Color) {
        cleanupFlashText = text
        cleanupFlashColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            withAnimation { cleanupFlashText = nil }
        }
    }
    func handleCleanupResult(_ res: ClaudeProbeProject.ResultStatus, manual: Bool) {
        // Immediate feedback is now handled by a result dialog fed from the notification listener.
        // Keep a subtle flash for non-modal cases (e.g., auto mode), but avoid double messaging.
        if !manual {
            switch res {
            case .success: showCleanupFlash("Deleted Claude probe project.", color: .green)
            case .notFound: showCleanupFlash("No Claude probe project to delete.", color: .secondary)
            case .unsafe: showCleanupFlash("Skipped: project contained non-probe sessions.", color: .orange)
            case .ioError: showCleanupFlash("Failed to delete probe project.", color: .red)
            case .disabled: break
            }
        }
    }
    func handleCodexCleanupResult(_ res: CodexProbeCleanup.ResultStatus) {
        // Manual deletion shows a modal dialog via the notification handler.
        // Avoid duplicating feedback in-pane here.
    }





    // MARK: Actions

    func loadCurrentSettings() {
        codexPath = indexer.sessionsRootOverride
        validateCodexPath()
        // Load Claude sessions override from defaults
        let cp = UserDefaults.standard.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride) ?? ""
        claudePath = cp
        validateClaudePath()
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

    func validateCodexPath() {
        guard !codexPath.isEmpty else {
            codexPathValid = true
            return
        }
        var isDir: ObjCBool = false
        codexPathValid = FileManager.default.fileExists(atPath: codexPath, isDirectory: &isDir) && isDir.boolValue
    }

    func commitCodexPathIfValid() {
        guard codexPathValid else { return }
        // Persist and refresh index once
        if indexer.sessionsRootOverride != codexPath {
            indexer.sessionsRootOverride = codexPath
            indexer.refresh()
        }
    }

    func pickCodexFolder() {
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

    func validateClaudePath() {
        guard !claudePath.isEmpty else {
            claudePathValid = true
            return
        }
        var isDir: ObjCBool = false
        claudePathValid = FileManager.default.fileExists(atPath: claudePath, isDirectory: &isDir) && isDir.boolValue
    }

    func commitClaudePathIfValid() {
        guard claudePathValid else { return }
        let current = UserDefaults.standard.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride) ?? ""
        if current != claudePath {
            UserDefaults.standard.set(claudePath, forKey: PreferencesKey.Paths.claudeSessionsRootOverride)
            // ClaudeSessionIndexer listens to UserDefaults changes and triggers its own refresh
        }
    }

    func pickClaudeFolder() {
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

    func validateBinaryOverride() {
        guard !codexBinaryOverride.isEmpty else {
            codexBinaryValid = true
            return
        }
        let expanded = (codexBinaryOverride as NSString).expandingTildeInPath
        codexBinaryValid = FileManager.default.isExecutableFile(atPath: expanded)
    }

    func commitCodexBinaryIfValid() {
        if codexBinaryOverride.isEmpty {
            // handled by Clear path
            return
        }
        if codexBinaryValid {
            resumeSettings.setBinaryOverride(codexBinaryOverride)
            scheduleCodexProbe()
        }
    }

    func pickCodexBinary() {
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

    func pickClaudeBinary() {
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

    func pickGeminiBinary() {
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

    func validateDefaultDirectory() {
        guard !defaultResumeDirectory.isEmpty else {
            defaultResumeDirectoryValid = true
            return
        }
        var isDir: ObjCBool = false
        defaultResumeDirectoryValid = FileManager.default.fileExists(atPath: defaultResumeDirectory, isDirectory: &isDir) && isDir.boolValue
    }

    func pickDefaultDirectory() {
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

    func resetToDefaults() {
        codexPath = ""
        indexer.sessionsRootOverride = ""
        validateCodexPath()

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
        copilotSettings.setBinaryPath("")
        droidSettings.setBinaryPath("")

        // Reset agent storage overrides
        copilotSessionsPath = ""
        droidSessionsPath = ""
        droidProjectsPath = ""
        validateDroidSessionsPath()
        validateDroidProjectsPath()

        // Reset usage strip preferences
        UserDefaults.standard.set(false, forKey: PreferencesKey.showClaudeUsageStrip)
        ClaudeUsageModel.shared.setEnabled(false)

        // Re-probe after reset
        scheduleCodexProbe()
        scheduleClaudeProbe()
        scheduleGeminiProbe()
        scheduleCopilotProbe()
        scheduleDroidProbe()
    }

    func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

}

// MARK: - Tabs

enum PreferencesTab: String, CaseIterable, Identifiable {
    case general
    case usageTracking
    case usageProbes
    case menuBar
    case unified
    case advanced
    case codexCLI
    case claudeResume
    case opencode
    case geminiCLI
    case copilotCLI
    case droidCLI
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .usageTracking: return "Usage Tracking"
        case .usageProbes: return "Usage Probes"
        case .menuBar: return "Menu Bar"
        case .unified: return "Unified Window"
        case .advanced: return "Advanced"
        case .codexCLI: return "Codex CLI"
        case .claudeResume: return "Claude Code"
        case .opencode: return "OpenCode"
        case .geminiCLI: return "Gemini CLI"
        case .copilotCLI: return "GitHub Copilot CLI"
        case .droidCLI: return "Droid"
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
        case .advanced: return "gearshape.2"
        case .codexCLI: return "terminal"
        case .claudeResume: return "c.square"
        case .opencode: return "chevron.left.slash.chevron.right"
        case .geminiCLI: return "g.circle"
        case .copilotCLI: return "bolt.horizontal.circle"
        case .droidCLI: return "d.circle"
        case .about: return "info.circle"
        }
    }
}

private extension PreferencesView {
    // Sidebar order: General → Unified Window → Usage Tracking → Usage Probes → Menu Bar → [4 Agents] → About
    var visibleTabs: [PreferencesTab] { [.general, .unified, .usageTracking, .usageProbes, .menuBar, .advanced, .codexCLI, .claudeResume, .opencode, .geminiCLI, .copilotCLI, .droidCLI, .about] }
}

// MARK: - Probe helpers

extension PreferencesView {
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
                    self.codexCLIAvailable = true
                case .failure:
                    self.probeVersion = nil
                    self.resolvedCodexPath = nil
                    self.probeState = .failure
                    self.codexCLIAvailable = false
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
                    self.claudeCLIAvailable = true
                case .failure:
                    self.claudeVersionString = nil
                    self.claudeResolvedPath = nil
                    self.claudeProbeState = .failure
                    self.claudeCLIAvailable = false
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
                    self.geminiCLIAvailable = true
                case .failure:
                    self.geminiVersionString = nil
                    self.geminiResolvedPath = nil
                    self.geminiProbeState = .failure
                    self.geminiCLIAvailable = false
                }
            }
        }
    }

    func probeDroid() {
        if droidProbeState == .probing { return }
        droidProbeState = .probing
        droidVersionString = nil
        droidResolvedPath = nil
        let override = droidSettings.binaryPath.isEmpty ? nil : droidSettings.binaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let env = DroidCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.droidVersionString = res.versionString
                    self.droidResolvedPath = res.binaryURL.path
                    self.droidProbeState = .success
                    self.droidCLIAvailable = true
                case .failure:
                    self.droidVersionString = nil
                    self.droidResolvedPath = nil
                    self.droidProbeState = .failure
                    self.droidCLIAvailable = false
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
        case .opencode:
            if opencodeVersionString == nil && opencodeProbeState != .probing { probeOpenCode() }
        case .geminiCLI:
            if geminiVersionString == nil && geminiProbeState != .probing { probeGemini() }
        case .copilotCLI:
            if copilotVersionString == nil && copilotProbeState != .probing { probeCopilot() }
        case .droidCLI:
            if droidVersionString == nil && droidProbeState != .probing { probeDroid() }
        case .menuBar, .usageProbes, .general, .unified, .advanced, .about:
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

    func scheduleCopilotProbe() {
        copilotProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeCopilot() }
        copilotProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func scheduleDroidProbe() {
        droidProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeDroid() }
        droidProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

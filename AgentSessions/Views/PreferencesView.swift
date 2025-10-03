import SwiftUI
import AppKit

private let labelColumnWidth: CGFloat = 170

struct PreferencesView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @State private var selectedTab: PreferencesTab?
    @ObservedObject private var resumeSettings = CodexResumeSettings.shared
    @ObservedObject private var claudeSettings = ClaudeResumeSettings.shared
    @State private var showingResetConfirm: Bool = false
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    // Menu bar prefs
    @AppStorage("MenuBarEnabled") private var menuBarEnabled: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("StripShowResetTime") private var stripShowResetTime: Bool = false

    private let initialResumeSelection: String?

    init(initialTab: PreferencesTab = .general, initialResumeSelection: String? = nil) {
        self.initialResumeSelection = initialResumeSelection
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                tabBody
            }
            Divider()
            footer
        }
        .frame(width: 740, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadCurrentSettings)
    }

    // MARK: Layout chrome

    private var sidebar: some View {
        List(visibleTabs, selection: $selectedTab) { tab in
            Label(tab.title, systemImage: tab.iconName)
                .tag(tab)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, maxWidth: 220)
    }

    private var tabBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch selectedTab ?? .general {
                case .general:
                    generalTab
                case .menuBar:
                    menuBarTab
                case .codexCLI:
                    codexCLITab
                case .codexCLIResume:
                    codexCLIResumeTab
                case .claudeResume:
                    claudeResumeTab
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Reset to Defaults") { showingResetConfirm = true }
                .buttonStyle(.bordered)
            Button("Close", action: closeWindow)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .alert("Reset All Preferences?", isPresented: $showingResetConfirm) {
            Button("Reset", role: .destructive) { resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset General, Sessions, Resume (Codex & Claude), Usage, and Menu Bar settings.")
        }
    }

    // MARK: Tabs

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("General")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Appearance")
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Theme") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearance) { _, newValue in
                        indexer.setAppearance(newValue)
                    }
                }

                Divider()

                labeledRow("Modified Date") {
                    Picker("Modified Display", selection: $modifiedDisplay) {
                        ForEach(SessionIndexer.ModifiedDisplay.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: modifiedDisplay) { _, newValue in
                        indexer.setModifiedDisplay(newValue)
                    }
                }
            }

            sectionHeader("Sessions Sidebar")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    Toggle("Session titles", isOn: $indexer.showTitleColumn)
                    Toggle("Project names", isOn: $indexer.showProjectColumn)
                }
                HStack(spacing: 24) {
                    Toggle("Message counts", isOn: $indexer.showMsgsColumn)
                    Toggle("Modified date", isOn: $indexer.showModifiedColumn)
                }
            }

            sectionHeader("Unified Window")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show source column", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "UnifiedShowSourceColumn") },
                    set: { UserDefaults.standard.set($0, forKey: "UnifiedShowSourceColumn") }
                ))
                labeledRow("Source color") {
                    Picker("Source color", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "UnifiedSourceColorStyle") ?? "none" },
                        set: { UserDefaults.standard.set($0, forKey: "UnifiedSourceColorStyle") }
                    )) {
                        Text("None").tag("none")
                        Text("Text").tag("text")
                        Text("Background").tag("background")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
                Text("Choose whether to display a source column and optional color coding by source. Colors are subtle and accessibility-friendly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var menuBarTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Menu Bar")
                .font(.title2)
                .fontWeight(.semibold)

            // Status item settings (no extra section header per request)
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show menu bar usage", isOn: $menuBarEnabled)

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
                }

                Text("Source: Codex, Claude, or Both. Style: Bars or numbers. Scope: 5h, weekly, or both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Codex CLI")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Detected version:").font(.caption)
                    Text(probeVersion?.description ?? "unknown").font(.caption).monospaced()
                }
                if let path = resolvedCodexPath {
                    Text(path).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Re-probe") { probeCodex() }.buttonStyle(.bordered)
                    Button("Open Codex CLI Preferences…") { selectedTab = .codexCLI }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var codexCLITab: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Codex CLI")
                .font(.title2)
                .fontWeight(.semibold)

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

                    Button(action: pickCodexFolder) {
                        Label("Choose…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: probeCodex) {
                        switch probeState {
                        case .probing:
                            ProgressView()
                        case .success:
                            Text("Check Version")
                        case .idle:
                            Text("Check Version")
                        case .failure:
                            Text("Codex not found").foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Run codex --version")

                    if let version = probeVersion, let resolved = resolvedCodexPath {
                        Text("Codex \(version.description)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(resolved)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if probeState == .failure {
                        Text("Codex not found")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    TextField("/path/to/codex", text: $codexBinaryOverride)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit {
                            validateBinaryOverride()
                            commitCodexBinaryIfValid()
                        }
                        .onChange(of: codexBinaryOverride) { _, _ in
                            validateBinaryOverride()
                            commitCodexBinaryIfValid()
                        }
                    Button(action: pickCodexBinary) {
                        Label("Browse…", systemImage: "square.and.arrow.down.on.square")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    Button("Clear") {
                        codexBinaryOverride = ""
                        validateBinaryOverride()
                        resumeSettings.setBinaryOverride("")
                        scheduleCodexProbe()
                    }
                    .buttonStyle(.bordered)
                }

                if !codexBinaryValid {
                    Label("Must be an executable file", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Leave empty to auto-detect from PATH.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            sectionHeader("Usage Tracking")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show usage strip", isOn: $showUsageStrip)
                toggleRow("Show reset times", isOn: $stripShowResetTime)
                toggleRow("Monochrome meters", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "StripMonochromeMeters") },
                    set: { UserDefaults.standard.set($0, forKey: "StripMonochromeMeters") }
                ))
                HStack(spacing: 12) {
                    Button("Refresh Now") {
                        CodexUsageModel.shared.refreshNow()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!showUsageStrip)
                }
                Text("Parses recent Codex session logs for rate limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Resume-specific defaults now live in Codex CLI Resume tab.
        }
    }

    private var codexCLIResumeTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Codex CLI Resume")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Configure how Agent Sessions resumes saved Codex sessions and run diagnostics.")
                .font(.caption)
                .foregroundStyle(.secondary)

            CodexResumeSheet(initialSelection: initialResumeSelection, context: .preferences)
                .environmentObject(indexer)
                .padding(.top, 4)
            // Status row (mirrors header footer inside sheet, but visible here too)
            if let v = probeVersion, let path = resolvedCodexPath {
                Text("Detected Codex \(v.description) \(path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if probeState == .failure {
                Text("Codex is not found")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var claudeResumeTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Claude Code")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Resume")
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Terminal App") {
                    Picker("Terminal App", selection: Binding(get: { claudeSettings.preferITerm ? 1 : 0 }, set: { claudeSettings.setPreferITerm($0 == 1) })) {
                        Text("Terminal").tag(0)
                        Text("iTerm2").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }

                HStack(spacing: 8) {
                    Button(action: probeClaude) {
                        switch claudeProbeState {
                        case .probing:
                            ProgressView()
                        case .success:
                            Text("Check Version")
                        case .idle:
                            Text("Check Version")
                        case .failure:
                            Text("Claude is not found").foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Run claude --version to confirm availability")
                    if let path = claudeResolvedPath, let ver = claudeVersionString {
                        Text("Claude Code \(ver)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            sectionHeader("Binary Override")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("/path/to/claude", text: Binding(get: { claudeSettings.binaryPath }, set: { claudeSettings.setBinaryPath($0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit { scheduleClaudeProbe() }
                        .onChange(of: claudeSettings.binaryPath) { _, _ in scheduleClaudeProbe() }
                    Button(action: pickClaudeBinary) {
                        Label("Browse…", systemImage: "square.and.arrow.down.on.square")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    Button("Clear") { claudeSettings.setBinaryPath("") }
                        .buttonStyle(.bordered)
                }
                Text("Leave empty to auto-detect from PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Usage Tracking")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show usage strip", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "ShowClaudeUsageStrip") },
                    set: {
                        UserDefaults.standard.set($0, forKey: "ShowClaudeUsageStrip")
                        ClaudeUsageModel.shared.setEnabled($0)
                    }
                ))

                VStack(alignment: .leading, spacing: 6) {
                    Label("First use will request file access permission", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Requires tmux. Launches Claude CLI headlessly to fetch /usage data. macOS will prompt for file access on first run (one-time only).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Refresh Now") {
                        ClaudeUsageModel.shared.refreshNow()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!UserDefaults.standard.bool(forKey: "ShowClaudeUsageStrip"))
                }
            }
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
        // kick off a probe so users see current version/path
        probeState = .idle
        probeVersion = nil
        resolvedCodexPath = nil
        probeCodex()
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

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .frame(width: labelColumnWidth, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(label))
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
    case codexCLI
    case codexCLIResume
    case claudeResume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .codexCLI: return "Codex CLI"
        case .codexCLIResume: return "Codex CLI Resume"
        case .claudeResume: return "Claude Code"
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .codexCLI: return "terminal"
        case .codexCLIResume: return "terminal.fill"
        case .claudeResume: return "chevron.left.slash.chevron.right"
        }
    }
}

private extension PreferencesView {
    var visibleTabs: [PreferencesTab] { [.general, .menuBar, .codexCLI, .codexCLIResume, .claudeResume] }
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

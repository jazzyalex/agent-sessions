import SwiftUI
import AppKit

private let labelColumnWidth: CGFloat = 170

struct PreferencesView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @State private var selectedTab: PreferencesTab?
    @ObservedObject private var resumeSettings = CodexResumeSettings.shared
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
                case .codexCLI:
                    codexCLITab
                case .codexCLIResume:
                    codexCLIResumeTab
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
            Button("Reset to Defaults", action: resetToDefaults)
                .buttonStyle(.bordered)
            Button("Apply", action: applySettings)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                }

                Divider()

                labeledRow("Modified Date") {
                    Picker("Modified Display", selection: $modifiedDisplay) {
                        ForEach(SessionIndexer.ModifiedDisplay.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            sectionHeader("Sessions Sidebar")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Session titles", isOn: $indexer.showTitleColumn)
                Divider()
                toggleRow("Project names", isOn: $indexer.showProjectColumn)
                Divider()
                toggleRow("Message counts", isOn: $indexer.showMsgsColumn)
                Divider()
                toggleRow("Modified timestamps", isOn: $indexer.showModifiedColumn)
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
                        .onChange(of: codexPath) { _, _ in validateCodexPath() }

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

            sectionHeader("Codex Binary")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: probeCodex) {
                        switch probeState {
                        case .probing:
                            ProgressView()
                        case .success:
                            if let version = probeVersion { Text("Codex \(version.description)") } else { Text("Check Version") }
                        case .idle:
                            Text("Check Version")
                        case .failure:
                            Text("Codex is not found").foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Run codex --version and resolve path")

                    if let resolved = resolvedCodexPath {
                        Text(resolved)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if probeState == .failure {
                        Text("Codex is not found")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Override path (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        TextField("/path/to/codex", text: $codexBinaryOverride)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .onChange(of: codexBinaryOverride) { _, _ in validateBinaryOverride() }
                        Button(action: pickCodexBinary) {
                            Label("Browse…", systemImage: "square.and.arrow.down.on.square")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        Button("Clear") {
                            codexBinaryOverride = ""
                            validateBinaryOverride()
                        }
                        .buttonStyle(.bordered)
                    }

                    if !codexBinaryValid {
                        Label("Must be an executable file", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            sectionHeader("Usage Strip")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show in-app Codex usage strip", isOn: $showUsageStrip)
                toggleRow("Show Reset Time in Usage Strip", isOn: $stripShowResetTime)
                HStack(spacing: 12) {
                    Button("Refresh Probe") {
                        CodexUsageModel.shared.refreshNow()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!showUsageStrip)
                    Text("Parses recent Codex session logs for rate limits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            sectionHeader("Menu Bar")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show menu bar usage", isOn: $menuBarEnabled)
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
                Text("Bars: 5h ▰▱▱▱▱ 17%  Wk ▰▰▱▱▱ 28%. Numbers only: 5h 17%  Wk 28%.")
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

    private func pickCodexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                codexPath = url.path
                validateCodexPath()
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

    private func pickCodexBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                codexBinaryOverride = url.path
                validateBinaryOverride()
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
    }

    private func applySettings() {
        indexer.sessionsRootOverride = codexPath
        indexer.setAppearance(appearance)
        indexer.setModifiedDisplay(modifiedDisplay)
        indexer.refresh()

        if codexBinaryValid {
            resumeSettings.setBinaryOverride(codexBinaryOverride)
        }
        if defaultResumeDirectoryValid {
            resumeSettings.setDefaultWorkingDirectory(defaultResumeDirectory)
        }
        resumeSettings.setLaunchMode(preferredLaunchMode)
        probeCodex()
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
    case codexCLI
    case codexCLIResume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .codexCLI: return "Codex CLI"
        case .codexCLIResume: return "Codex CLI Resume"
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .codexCLI: return "terminal"
        case .codexCLIResume: return "terminal.fill"
        }
    }
}

private extension PreferencesView {
    var visibleTabs: [PreferencesTab] { [.general, .codexCLI, .codexCLIResume] }
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
}

// MARK: - Supporting Views

// Old PreferenceCard removed in favor of flat, sectioned layout.

import SwiftUI
import AppKit

private let labelColumnWidth: CGFloat = 170

struct PreferencesView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @State private var selectedTab: PreferencesTab?
    @ObservedObject private var resumeSettings = CodexResumeSettings.shared

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

            sectionHeader("Codex Executable")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Binary override (optional)", text: $codexBinaryOverride)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onChange(of: codexBinaryOverride) { _, _ in validateBinaryOverride() }
                    Button(action: pickCodexBinary) {
                        Label("Choose…", systemImage: "square.and.arrow.down.on.square")
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

            sectionHeader("Resume Defaults")
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Default working directory") {
                    HStack(spacing: 12) {
                        TextField("Optional", text: $defaultResumeDirectory)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: defaultResumeDirectory) { _, _ in validateDefaultDirectory() }
                        Button(action: pickDefaultDirectory) {
                            Label("Choose…", systemImage: "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        Button("Clear") {
                            defaultResumeDirectory = ""
                            validateDefaultDirectory()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !defaultResumeDirectoryValid {
                    Label("Directory must exist and be accessible", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                labeledRow("Preferred launch mode") {
                    Picker("Launch Mode", selection: $preferredLaunchMode) {
                        ForEach(CodexLaunchMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Text("Controls the default mode when resuming a session. You can still change it below if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

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

// MARK: - Supporting Views

// Old PreferenceCard removed in favor of flat, sectioned layout.

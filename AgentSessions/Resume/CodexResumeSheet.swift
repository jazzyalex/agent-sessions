import SwiftUI
import AppKit

struct CodexResumeSheet: View {
    @EnvironmentObject private var indexer: SessionIndexer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = CodexResumeSettings.shared
    @StateObject private var launcher = CodexResumeLauncher()

    let initialSelection: String?
    let context: Context

    @State private var searchText: String = ""
    @State private var selectedSessionID: String? = nil
    @State private var probeState: ProbeState = .idle
    @State private var probeError: String? = nil
    @State private var probeVersion: CodexVersion? = nil
    @State private var codexBinary: URL? = nil
    @State private var useFallback: Bool = false
    @State private var workingDirectoryField: String = ""
    @State private var sizeWarning: String? = nil
    @State private var fileMissing: Bool = false
    @State private var showingHealthOutput: Bool = false
    @State private var healthOutput: String = ""
    @State private var initialSelectionApplied: Bool = false

    private let commandBuilder = CodexResumeCommandBuilder()

    init(initialSelection: String?, context: Context = .sheet) {
        self.initialSelection = initialSelection
        self.context = context
    }

    enum Context {
        case sheet
        case preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if context == .sheet {
                header
                Divider()
            }
            content
            if context == .sheet {
                Divider()
                footer
            }
        }
        .padding(context == .sheet ? 20 : 0)
        .frame(width: context == .sheet ? 780 : nil,
               height: context == .sheet ? 520 : nil,
               alignment: .topLeading)
        .onAppear {
            if !initialSelectionApplied {
                selectedSessionID = initialSelection ?? selectedSessionID
                initialSelectionApplied = true
            }
            refreshSelectionState()
            Task { await probeCodexVersion() }
        }
        .onChange(of: selectedSessionID) { _, _ in refreshSelectionState() }
        .onChange(of: searchText) { _, _ in } // trigger view update
        .onChange(of: settings.binaryOverride) { _, _ in Task { await probeCodexVersion() } }
        .onChange(of: settings.launchMode) { _, _ in } // persist via settings already
        .onChange(of: settings.defaultWorkingDirectory) { _, _ in refreshSelectionState() }
        .onChange(of: indexer.sessions) { _, _ in
            // Apply the initial selection from the main window once when data is available
            if initialSelectionApplied, selectedSessionID == nil {
                if let target = initialSelection, indexer.allSessions.contains(where: { $0.id == target }) {
                    selectedSessionID = target
                } else {
                    selectedSessionID = availableSessions.first?.id
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading) {
                Text("Resume in Codex")
                    .font(.title2).bold()
                Text("Pick a session to reopen in Codex CLI")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { Task { await probeCodexVersion(force: true) } }) {
                switch probeState {
                case .probing:
                    ProgressView()
                case .success:
                    if let version = probeVersion {
                        Text("Codex \(version.description)")
                    } else {
                        Text("Check Version")
                    }
                case .idle:
                    Text("Check Version")
                case .failure:
                    Text("Codex is not found").foregroundStyle(.red)
                }
            }
            .buttonStyle(.bordered)
            .help("Run codex --version to confirm resume support")
            Button("Resume Log") { Task { await runHealthCheck() } }
                .buttonStyle(.bordered)
                .help("Show resume diagnostics for this session")
        }
    }

    private var content: some View {
        Group {
            if context == .sheet {
                HStack(alignment: .top, spacing: 18) {
                    sessionList
                    detailsPanel
                }
            } else {
                detailsPanel
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchField(text: $searchText, prompt: "Search sessions")
            List(selection: $selectedSessionID) {
                ForEach(filteredSessions, id: \Session.id) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.codexDisplayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(session.modifiedRelative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let repo = session.repoName {
                                Text(repo)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let preview = session.firstUserPreview {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(session.id)
                }
            }
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Preferences header: keep only Resume Log in this tab
            if context == .preferences {
                HStack(spacing: 8) {
                    Button("Resume Log") { Task { await runHealthCheck() } }
                        .buttonStyle(.bordered)
                        .help("Show resume diagnostics for this session")
                    Spacer()
                }
            }

            // In sheet context show summary; in preferences show only options/console
            if context == .sheet, let session = selectedSession {
                sessionSummary(for: session)
            }

            if let session = selectedSession {
                launchOptions(for: session)
                embeddedConsole
            } else {
                ContentUnavailableView {
                    Label("Select a session", systemImage: "person.crop.circle")
                } description: {
                    Text("Choose a session to resume in Codex")
                }
            }
        }
        .frame(minWidth: context == .sheet ? 360 : nil,
               maxWidth: .infinity,
               maxHeight: .infinity,
               alignment: .top)
        .sheet(isPresented: $showingHealthOutput) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Resume Health Check")
                    .font(.title3).bold()
                ScrollView {
                    Text(healthOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(healthOutput, forType: .string)
                    }
                    Spacer()
                    Button("Close") { showingHealthOutput = false }
                }
            }
            .padding(16)
            .frame(width: 720, height: 420)
        }
    }

    private func sessionSummary(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.codexDisplayTitle)
                    .font(.headline)
                Spacer()
                Text(session.shortID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Codex session ID")
            }
            if let probeError {
                Label(probeError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if let version = probeVersion {
                if !version.supportsResumeByID {
                    Label("Codex \(version.description) does not fully support resume by ID. Enable the fallback launch option below.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if fileMissing {
                Label("Session file no longer exists.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            if let sizeWarning {
                Label(sizeWarning, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    private var sessionSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session")
                .fontWeight(.semibold)
            Menu {
                ForEach(availableSessions, id: \Session.id) { session in
                    Button(action: { selectedSessionID = session.id }) {
                        Text(menuTitle(for: session))
                    }
                }
            } label: {
                HStack {
                    if let session = selectedSession {
                        Text(menuTitle(for: session))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("Choose a session")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .disabled(availableSessions.isEmpty)

            if availableSessions.isEmpty {
                Text("No Codex sessions available. Refresh the index in the main window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func launchOptions(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Preferences variant: show Codex path instead of Launch button
            // Path/override now live under Preferences → Codex CLI

            VStack(alignment: .leading, spacing: 6) {
                Picker("Launch Mode", selection: Binding(get: { settings.launchMode }, set: { settings.setLaunchMode($0) })) {
                    ForEach(visibleLaunchModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.launchMode.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if canOfferFallback {
                Toggle(isOn: $useFallback) {
                    Text("Use experimental resume flag")
                }
                .toggleStyle(.switch)
                .help("Launch Codex with -c experimental_resume=<path> instead of resume <id>.")
            } else if requiresFallback {
                Label("Falling back to experimental resume flag", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var embeddedConsole: some View {
        Group {
            if false { // Embedded disabled in UI
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(launcher.consoleLines) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.kind == .stderr ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let error = launcher.lastError {
                            Text(error)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.red)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(.background.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let version = probeVersion {
                Text("Detected Codex \(version.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") {
                dismiss()
            }
        }
    }

    private var visibleLaunchModes: [CodexLaunchMode] {
        // Embedded mode disabled to simplify UX
        return [.terminal, .iterm]
    }

    @MainActor
    private func launch(session: Session) {
        guard let package = buildCommand(session: session) else { return }

        switch settings.launchMode {
        case .embedded, .terminal:
            do {
                try launcher.launchInTerminal(package)
            } catch {
                launcher.lastError = error.localizedDescription
            }
        case .iterm:
            do {
                try launcher.launchInITerm(package)
            } catch {
                launcher.lastError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func buildCommand(session: Session) -> CodexResumeCommandBuilder.CommandPackage? {
        guard let binary = codexBinary else {
            probeError = "Codex binary not found"
            return nil
        }
        guard !fileMissing else { return nil }
        do {
            let fallbackURL: URL?
            if FileManager.default.fileExists(atPath: session.filePath) {
                fallbackURL = URL(fileURLWithPath: session.filePath)
            } else {
                fallbackURL = nil
            }

            let attemptResumeFirst = !shouldUseFallback

            return try commandBuilder.makeCommand(for: session,
                                                  settings: settings,
                                                  binaryURL: binary,
                                                  fallbackPath: fallbackURL,
                                                  attemptResumeFirst: attemptResumeFirst)
        } catch {
            probeError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    private func canLaunch(session: Session) -> Bool {
        if fileMissing { return false }
        if codexBinary == nil { return false }
        if shouldUseFallback { return true }
        return probeVersion?.supportsResumeByID ?? false
    }

    @MainActor
    private var shouldUseFallback: Bool {
        requiresFallback || (canOfferFallback && useFallback)
    }

    @MainActor
    private var canOfferFallback: Bool {
        guard let version = probeVersion else { return false }
        return version.supportsResumeByID
    }

    @MainActor
    private var requiresFallback: Bool {
        guard let version = probeVersion else { return false }
        return !version.supportsResumeByID
    }

    @MainActor
    private var selectedSession: Session? {
        guard let selectedSessionID else { return nil }
        return indexer.allSessions.first(where: { $0.id == selectedSessionID })
    }

    @MainActor
    private var availableSessions: [Session] {
        indexer.allSessions.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private var filteredSessions: [Session] {
        let base = availableSessions
        guard !searchText.isEmpty else { return base }
        let lower = searchText.lowercased()
        return base.filter { session in
            session.codexDisplayTitle.lowercased().contains(lower) ||
            session.shortID.lowercased().contains(lower) ||
            session.repoDisplay.lowercased().contains(lower)
        }
    }

    @MainActor
    private func refreshSelectionState() {
        // Do not override selection in preferences; preserve external selection
        guard let session = selectedSession else {
            workingDirectoryField = ""
            sizeWarning = nil
            fileMissing = false
            return
        }
        workingDirectoryField = settings.workingDirectory(for: session.id) ?? session.cwd ?? settings.defaultWorkingDirectory
        updateFileSizeWarning(for: session)
        fileMissing = !FileManager.default.fileExists(atPath: session.filePath)
    }

    private func menuTitle(for session: Session) -> String {
        let title = session.codexDisplayTitle
        let trimmed = title.count > 60 ? String(title.prefix(57)) + "…" : title
        return "\(session.shortID) • \(trimmed)"
    }

    @MainActor
    private func updateFileSizeWarning(for session: Session) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: session.filePath)
            if let size = attrs[.size] as? NSNumber {
                let bytes = size.int64Value
                if bytes > 100 * 1024 * 1024 {
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useMB, .useGB]
                    formatter.countStyle = .file
                    let display = formatter.string(fromByteCount: bytes)
                    sizeWarning = "Large session (\(display)). Codex may compact early turns."
                } else {
                    sizeWarning = nil
                }
            }
        } catch {
            sizeWarning = nil
        }
    }

    @MainActor
    private func chooseDirectory(for session: Session) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                workingDirectoryField = url.path
                settings.setWorkingDirectory(url.path, for: session.id)
            }
        }
    }

    @MainActor
    private func probeCodexVersion(force: Bool = false) async {
        if probeState == .probing && !force { return }
        probeState = .probing
        probeError = nil
        let env = CodexCLIEnvironment()
        let overridePath = settings.binaryOverride
        let resolved = await Task.detached { env.resolveBinary(customPath: overridePath) }.value
        codexBinary = resolved

        guard resolved != nil else {
            probeState = .failure
            probeError = "Codex CLI not found in PATH or override."
            probeVersion = nil
            return
        }

        let result = await Task.detached { env.probeVersion(customPath: overridePath) }.value
        switch result {
        case let .success(data):
            probeVersion = data.version
            codexBinary = data.binaryURL
            probeState = .success
            useFallback = !data.version.supportsResumeByID
        case let .failure(error):
            probeVersion = nil
            probeState = .failure
            probeError = error.localizedDescription
        }
    }

    enum ProbeState {
        case idle
        case probing
        case success
        case failure
    }

    private func runHealthCheck() async {
        guard let session = selectedSession else { return }
        let bin = codexBinary
        let (code, output) = await ResumeHealthCheck.run(sessionPath: session.filePath,
                                                         workingDirectory: workingDirectoryField.isEmpty ? nil : workingDirectoryField,
                                                         codexBinary: bin,
                                                         timeoutSeconds: 6)
        await MainActor.run {
            healthOutput = output
            showingHealthOutput = true
        }
    }
}

// MARK: - Helpers (Preferences: override picker)

private extension CodexResumeSheet {
    func isExecutable(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: expanded)
    }

    func pickCodexBinaryOverride() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.setBinaryOverride(url.path)
            }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.roundedBorder)
            .overlay(alignment: .trailing) {
                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                }
            }
    }
}

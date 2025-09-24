import SwiftUI
import AppKit

struct CodexResumeSheet: View {
    @EnvironmentObject private var indexer: SessionIndexer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = CodexResumeSettings.shared
    @StateObject private var launcher = CodexResumeLauncher()

    let initialSelection: String?

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

    private let commandBuilder = CodexResumeCommandBuilder()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 780, height: 520)
        .onAppear {
            selectedSessionID = initialSelection ?? indexer.sessions.first?.id
            refreshSelectionState()
            Task { await probeCodexVersion() }
        }
        .onChange(of: selectedSessionID) { _, _ in refreshSelectionState() }
        .onChange(of: searchText) { _, _ in } // trigger view update
        .onChange(of: settings.binaryOverride) { _, _ in Task { await probeCodexVersion() } }
        .onChange(of: settings.launchMode) { _, _ in } // persist via settings already
        .onChange(of: settings.defaultWorkingDirectory) { _, _ in refreshSelectionState() }
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
                case .idle, .failure:
                    Text("Check Version")
                }
            }
            .buttonStyle(.bordered)
            .help("Run codex --version to confirm resume support")
            Button("Health Check") { Task { await runHealthCheck() } }
                .buttonStyle(.bordered)
                .help("Validate JSONL and try both resume paths")
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 18) {
            sessionList
            detailsPanel
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
            if let session = selectedSession {
                sessionSummary(for: session)
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
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingHealthOutput) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Resume Health Check")
                    .font(.title3).bold()
                ScrollView {
                    Text(healthOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Close") { showingHealthOutput = false } }
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

    private func launchOptions(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Working Directory")
                    .fontWeight(.semibold)
                HStack(spacing: 8) {
                    TextField("Optional", text: $workingDirectoryField)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260)
                        .onChange(of: workingDirectoryField) { _, newValue in
                            settings.setWorkingDirectory(newValue, for: session.id)
                        }
                    Button("Choose…") { chooseDirectory(for: session) }
                        .buttonStyle(.bordered)
                    Button("Clear") {
                        workingDirectoryField = ""
                        settings.setWorkingDirectory(nil, for: session.id)
                    }
                    .buttonStyle(.bordered)
                }
                if let sessionCwd = session.cwd, sessionCwd != workingDirectoryField {
                    Button {
                        workingDirectoryField = sessionCwd
                        settings.setWorkingDirectory(sessionCwd, for: session.id)
                    } label: {
                        Text("Use session directory: \(sessionCwd)")
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .buttonStyle(.link)
                    .help(sessionCwd)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Launch Mode")
                    .fontWeight(.semibold)
                Picker("Launch Mode", selection: Binding(get: { settings.launchMode }, set: { settings.setLaunchMode($0) })) {
                    ForEach(CodexLaunchMode.allCases) { mode in
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

            HStack {
                Button(action: { launch(session: session) }) {
                    if launcher.isRunningEmbedded && settings.launchMode == .embedded {
                        ProgressView()
                    } else {
                        Text("Launch")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canLaunch(session: session))

                if settings.launchMode == .embedded && launcher.isRunningEmbedded {
                    Button("Stop", action: launcher.stopEmbedded)
                        .buttonStyle(.bordered)
                }

                Spacer()
                if let binary = codexBinary {
                    Text(binary.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var embeddedConsole: some View {
        Group {
            if settings.launchMode == .embedded {
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

    @MainActor
    private func launch(session: Session) {
        guard let package = buildCommand(session: session) else { return }

        switch settings.launchMode {
        case .embedded:
            launcher.launchEmbedded(package)
        case .terminal:
            do {
                try launcher.launchInTerminal(package)
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
    private var filteredSessions: [Session] {
        let base = indexer.allSessions.sorted { $0.modifiedAt > $1.modifiedAt }
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
                                                         codexBinary: bin)
        await MainActor.run {
            healthOutput = output
            showingHealthOutput = true
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

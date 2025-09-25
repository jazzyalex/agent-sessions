import SwiftUI
import AppKit

@main
struct AgentSessionsApp: App {
    @StateObject private var indexer = SessionIndexer()
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("LayoutMode") private var layoutModeRaw: String = LayoutMode.vertical.rawValue
    @State private var selectedSessionID: String?
    @State private var selectedEventID: String?
    @State private var focusSearchToggle: Bool = false
    @State private var showingFirstRunPrompt: Bool = false

    var body: some Scene {
        WindowGroup("Agent Sessions") {
            ContentView(layoutMode: LayoutMode(rawValue: layoutModeRaw) ?? .vertical,
                        onToggleLayout: {
                            let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                            layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
                        })
                .environmentObject(indexer)
                .onAppear {
                    // First run check: if directory is unreadable prompt user
                    if !indexer.canAccessRootDirectory {
                        showingFirstRunPrompt = true
                    }
                    indexer.refresh()
                }
                .sheet(isPresented: $showingFirstRunPrompt) {
                    FirstRunPrompt(showing: $showingFirstRunPrompt)
                        .environmentObject(indexer)
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { indexer.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Copy Transcript") { indexer.requestCopyPlain.toggle() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Find in Transcript") { indexer.requestTranscriptFindFocus.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { PreferencesWindowController.shared.show(indexer: indexer) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
private struct ContentView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @State private var selection: String?
    @State private var selectedEvent: String?
    @State private var showingResumeSheet: Bool = false
    @State private var resumeInitialSelection: String? = nil
    @State private var resumeAlert: ResumeAlert?
    let layoutMode: LayoutMode
    let onToggleLayout: () -> Void

    var body: some View {
        Group {
            if layoutMode == .vertical {
                HSplitView {
                    SessionsListView(selection: $selection,
                                     onLaunchTerminal: handleQuickLaunch,
                                     onOpenWorkingDirectory: handleOpenWorkingDirectory)
                        .frame(minWidth: 320, idealWidth: 600, maxWidth: 1200)
                    TranscriptPlainView(sessionID: selection)
                        .frame(minWidth: 450)
                }
            } else {
                VSplitView {
                    SessionsListView(selection: $selection,
                                     onLaunchTerminal: handleQuickLaunch,
                                     onOpenWorkingDirectory: handleOpenWorkingDirectory)
                        .frame(minHeight: 180)
                    TranscriptPlainView(sessionID: selection)
                        .frame(minHeight: 240)
                }
            }
        }
        .preferredColorScheme(indexer.appAppearance.colorScheme)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SearchFiltersView()
            }
            ToolbarItem(placement: .automatic) {
                Button("Copy Session ID") {
                    if let sid = selectedSession?.codexFilenameUUID {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sid, forType: .string)
                    }
                }
                .disabled(selectedSession?.codexFilenameUUID == nil)
                .help("Copy Codex session ID to clipboard")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    guard let session = selectedSession else {
                        resumeAlert = ResumeAlert(title: "No Session Selected",
                                                  message: "Select a session first to launch in Codex.",
                                                  kind: .failure)
                        return
                    }
                    handleQuickLaunch(session)
                }) {
                    Label("Launch in Terminal", systemImage: "terminal")
                }
                .help("Launch Codex in Terminal for the selected session")
                .disabled(selectedSession == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    if let session = selectedSession {
                        handleOpenWorkingDirectory(session)
                    }
                }) {
                    Label("Open Working Directory", systemImage: "folder")
                }
                .help("Reveal the session's working directory in Finder")
                .disabled(selectedSession == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    resumeInitialSelection = selection
                    showingResumeSheet = true
                }) {
                    Label("Resume Options", systemImage: "list.bullet.rectangle")
                }
                .help("Open resume options and embedded console")
            }
            // Match Codex toggle temporarily removed while we align title logic
            ToolbarItem(placement: .automatic) {
                Button(action: { indexer.refresh() }) {
                    if indexer.isIndexing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh index")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { onToggleLayout() }) {
                    Image(systemName: layoutMode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                }
                .help(layoutMode == .vertical ? "Switch to Horizontal Split" : "Switch to Vertical Split")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { PreferencesWindowController.shared.show(indexer: indexer) }) {
                    Image(systemName: "gear")
                }
                .help("Preferences")
            }
        }
        .onChange(of: indexer.sessions) { _, sessions in
            // Maintain a valid selection whenever new sessions arrive
            guard !sessions.isEmpty else {
                selection = nil
                return
            }

            if let current = selection, sessions.contains(where: { $0.id == current }) {
                return
            }

            selection = sessions.first?.id
        }
        .onChange(of: selection) { _, _ in
            // Reset per-session context when switching selections
            selectedEvent = nil
        }
        .sheet(isPresented: $showingResumeSheet) {
            CodexResumeSheet(initialSelection: resumeInitialSelection)
                .environmentObject(indexer)
        }
        .alert(item: $resumeAlert) { alert in
            switch alert.kind {
            case .failure:
                return Alert(title: Text(alert.title),
                             message: Text(alert.message),
                             dismissButton: .default(Text("OK")))
            case let .needsConfiguration(sessionID):
                return Alert(title: Text(alert.title),
                             message: Text(alert.message),
                             primaryButton: .default(Text("Open Resume Dialog")) {
                                 resumeInitialSelection = sessionID
                                 showingResumeSheet = true
                             },
                             secondaryButton: .cancel())
            }
        }
        // recomputeNow() is called inline in the toggle's setter
    }

    // Rely on system-provided sidebar toggle in the titlebar.
    private func handleQuickLaunch(_ session: Session) {
        Task { @MainActor in
            let result = await CodexResumeCoordinator.shared.quickLaunchInTerminal(session: session)
            switch result {
            case .launched:
                break
            case .needsConfiguration(let message):
                resumeAlert = ResumeAlert(title: "Resume Requires Configuration",
                                          message: message,
                                          kind: .needsConfiguration(sessionID: session.id))
            case .failure(let message):
                resumeAlert = ResumeAlert(title: "Unable to Launch Codex",
                                          message: message,
                                          kind: .failure)
            }
        }
    }

    private func handleOpenWorkingDirectory(_ session: Session) {
        guard let path = codexWorkingDirectory(for: session) else {
            resumeAlert = ResumeAlert(title: "Working Directory Unavailable",
                                      message: "No working directory is associated with this session.",
                                      kind: .failure)
            return
        }

        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            resumeAlert = ResumeAlert(title: "Directory Not Found",
                                      message: "The working directory \(path) does not exist.",
                                      kind: .failure)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func codexWorkingDirectory(for session: Session) -> String? {
        if let override = CodexResumeSettings.shared.workingDirectory(for: session.id), !override.isEmpty {
            return override
        }
        if let sessionCwd = session.cwd, !sessionCwd.isEmpty {
            return sessionCwd
        }
        let defaultDir = CodexResumeSettings.shared.defaultWorkingDirectory
        return defaultDir.isEmpty ? nil : defaultDir
    }

    private var selectedSession: Session? {
        guard let selection else { return nil }
        return indexer.sessions.first(where: { $0.id == selection }) ?? indexer.allSessions.first(where: { $0.id == selection })
    }

    private struct ResumeAlert: Identifiable {
        enum Kind { case failure, needsConfiguration(sessionID: String) }
        let id = UUID()
        let title: String
        let message: String
        let kind: Kind
    }
}

private struct FirstRunPrompt: View {
    @EnvironmentObject var indexer: SessionIndexer
    @Binding var showing: Bool
    @State private var presentingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Codex sessions directory")
                .font(.title2).bold()
            Text(
                "Agent Sessions could not read the default sessions folder. " +
                "Pick a custom path or set the CODEX_HOME environment variable."
            )
                .foregroundStyle(.secondary)
            HStack {
                Button("Pick Folder…") { pickFolder() }
                Button("Use Default") {
                    indexer.sessionsRootOverride = ""
                    indexer.refresh()
                    showing = false
                }
                Spacer()
                Button("Close") { showing = false }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                indexer.sessionsRootOverride = url.path
                indexer.refresh()
                showing = false
            }
        }
    }
}

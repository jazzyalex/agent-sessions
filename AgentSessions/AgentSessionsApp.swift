import SwiftUI
import AppKit

@main
struct AgentSessionsApp: App {
    @StateObject private var indexer = SessionIndexer()
    @StateObject private var claudeIndexer = ClaudeSessionIndexer()
    @StateObject private var codexUsageModel = CodexUsageModel.shared
    @StateObject private var claudeUsageModel = ClaudeUsageModel.shared
    @StateObject private var unifiedIndexerHolder = _UnifiedHolder()
    @AppStorage("MenuBarEnabled") private var menuBarEnabled: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("LayoutMode") private var layoutModeRaw: String = LayoutMode.vertical.rawValue
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    @AppStorage("ShowClaudeUsageStrip") private var showClaudeUsageStrip: Bool = false
    @AppStorage("UnifiedLegacyNoticeShown") private var unifiedNoticeShown: Bool = false
    @State private var selectedSessionID: String?
    @State private var selectedEventID: String?
    @State private var focusSearchToggle: Bool = false
    @State private var showingFirstRunPrompt: Bool = false

    var body: some Scene {
        // Default unified window
        WindowGroup("Agent Sessions") {
            UnifiedSessionsView(unified: unifiedIndexerHolder.makeUnified(codexIndexer: indexer, claudeIndexer: claudeIndexer),
                                codexIndexer: indexer,
                                claudeIndexer: claudeIndexer,
                                layoutMode: LayoutMode(rawValue: layoutModeRaw) ?? .vertical,
                                onToggleLayout: {
                                    let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                                    layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
                                })
                .environmentObject(codexUsageModel)
                .environmentObject(claudeUsageModel)
                .onAppear {
                    indexer.refresh(); claudeIndexer.refresh()
                    codexUsageModel.setEnabled(showUsageStrip)
                    claudeUsageModel.setEnabled(showUsageStrip)
                }
                .onChange(of: showUsageStrip) { _, newValue in
                    codexUsageModel.setEnabled(newValue)
                    claudeUsageModel.setEnabled(newValue)
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { unifiedIndexerHolder.unified?.refresh() }.keyboardShortcut("r", modifiers: .command)
                Button("Find in Transcript") { /* unified find focuses handled in view */ }.keyboardShortcut("f", modifiers: .command).disabled(true)
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { PreferencesWindowController.shared.show(indexer: indexer) }.keyboardShortcut(",", modifiers: .command) }
            CommandGroup(after: .windowArrangement) {
                if FeatureFlags.legacyWindows {
                    Button("New Codex Window") { openWindowCodex() }.keyboardShortcut("1", modifiers: [.command, .shift])
                    Button("New Claude Window") { openWindowClaude() }.keyboardShortcut("2", modifiers: [.command, .shift])
                } else {
                    Button("Codex Only (Unified)") { focusUnified(preset: .codexOnly) }
                        .keyboardShortcut("1", modifiers: [.command, .shift])
                    Button("Claude Only (Unified)") { focusUnified(preset: .claudeOnly) }
                        .keyboardShortcut("2", modifiers: [.command, .shift])
                }
            }
        }

        // Codex-only window (legacy)
        WindowGroup("Agent Sessions (Codex)") {
            ContentView(layoutMode: LayoutMode(rawValue: layoutModeRaw) ?? .vertical,
                        onToggleLayout: {
                            let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                            layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
                        })
                .environmentObject(indexer)
                .environmentObject(codexUsageModel)
                .onAppear {
                    // First run check: if directory is unreadable prompt user
                    if !indexer.canAccessRootDirectory {
                        showingFirstRunPrompt = true
                    }
                    indexer.refresh()
                    codexUsageModel.setEnabled(showUsageStrip)
                }
                .onChange(of: showUsageStrip) { _, newValue in
                    codexUsageModel.setEnabled(newValue)
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

        // Claude-only window (legacy)
        WindowGroup("Agent Sessions (Claude Code)") {
            ClaudeSessionsView(
                indexer: claudeIndexer,
                codexIndexer: indexer,
                layoutMode: LayoutMode(rawValue: layoutModeRaw) ?? .vertical,
                onToggleLayout: {
                    let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                    layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
                })
                .environmentObject(claudeUsageModel)
                .onAppear {
                    claudeIndexer.refresh()
                    claudeUsageModel.setEnabled(showClaudeUsageStrip)
                }
                .onChange(of: showClaudeUsageStrip) { _, newValue in
                    claudeUsageModel.setEnabled(newValue)
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { claudeIndexer.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { PreferencesWindowController.shared.show(indexer: indexer) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        // Menu bar extra for limits (configurable)
        MenuBarExtra(isInserted: $menuBarEnabled) {
            UsageMenuBarMenuContent()
                .environmentObject(indexer)
                .environmentObject(codexUsageModel)
                .environmentObject(claudeUsageModel)
        } label: {
            UsageMenuBarLabel()
                .environmentObject(codexUsageModel)
                .environmentObject(claudeUsageModel)
        }
    }
}

// Helper to hold and lazily build unified indexer once
final class _UnifiedHolder: ObservableObject {
    @Published var unified: UnifiedSessionIndexer? = nil
    func makeUnified(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer) -> UnifiedSessionIndexer {
        if let u = unified { return u }
        let u = UnifiedSessionIndexer(codexIndexer: codexIndexer, claudeIndexer: claudeIndexer)
        unified = u
        return u
    }
}

// Window helpers
extension AgentSessionsApp {
    private func openWindowCodex() { NSApp.activate(ignoringOtherApps: true) }
    private func openWindowClaude() { NSApp.activate(ignoringOtherApps: true) }

    enum UnifiedPreset { case codexOnly, claudeOnly, both }
    private func focusUnified(preset: UnifiedPreset) {
        // Ensure Unified indexer exists and set source filters
        let unified = unifiedIndexerHolder.makeUnified(codexIndexer: indexer, claudeIndexer: claudeIndexer)
        switch preset {
        case .codexOnly:
            unified.includeCodex = true; unified.includeClaude = false
        case .claudeOnly:
            unified.includeCodex = false; unified.includeClaude = true
        case .both:
            unified.includeCodex = true; unified.includeClaude = true
        }
        unified.recomputeNow()

        // Bring Unified window to front (create if none by activating the app)
        NSApp.activate(ignoringOtherApps: true)

        // One-time notice replacing legacy windows
        if !unifiedNoticeShown && !FeatureFlags.legacyWindows {
            unifiedNoticeShown = true
            let alert = NSAlert()
            alert.messageText = "Unified Window"
            alert.informativeText = "Legacy Codex/Claude windows have been replaced by the Unified window. Use Shift+Cmd+1 for Codex only, Shift+Cmd+2 for Claude only."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            alert.runModal()
        }
    }
}
private struct ContentView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @EnvironmentObject var codexUsageModel: CodexUsageModel
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    @State private var selection: String?
    @State private var selectedEvent: String?
    @State private var resumeAlert: ResumeAlert?
    let layoutMode: LayoutMode
    let onToggleLayout: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
            if showUsageStrip {
                UsageStripView(codexStatus: codexUsageModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(indexer.appAppearance.colorScheme)
        .onChange(of: selection) { _, newID in
            // Lazy load: if user selects a lightweight session, trigger full parse
            if let id = newID, let session = indexer.allSessions.first(where: { $0.id == id }),
               session.events.isEmpty {
                indexer.reloadSession(id: id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SearchFiltersView()
            }
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    guard let session = selectedSession else {
                        resumeAlert = ResumeAlert(title: "No Session Selected",
                                                  message: "Select a session first to resume in Codex.",
                                                  kind: .failure)
                        return
                    }
                    handleQuickLaunch(session)
                }) {
                    Label("Resume in Codex", systemImage: "play.circle")
                }
                .help("Resume the selected session in Codex")
                .disabled(selectedSession == nil)
                .keyboardShortcut("r", modifiers: [.command, .control])
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
            // Visual separator between refresh and layout controls
            ToolbarItem(placement: .automatic) {
                Divider()
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { onToggleLayout() }) {
                    Image(systemName: layoutMode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                }
                .help(layoutMode == .vertical ? "Switch to Horizontal Split" : "Switch to Vertical Split")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    PreferencesWindowController.shared.show(indexer: indexer, initialTab: .general)
                }) {
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
        .alert(item: $resumeAlert) { alert in
            switch alert.kind {
            case .failure:
                return Alert(title: Text(alert.title),
                             message: Text(alert.message),
                             dismissButton: .default(Text("OK")))
            case let .needsConfiguration(sessionID):
                return Alert(title: Text(alert.title),
                             message: Text(alert.message),
                             primaryButton: .default(Text("Open Preferences")) {
                                 PreferencesWindowController.shared.show(indexer: indexer,
                                                                          initialTab: .codexCLI)
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

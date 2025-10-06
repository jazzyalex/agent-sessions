import SwiftUI
import AppKit

struct ClaudeSessionsView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    @ObservedObject var codexIndexer: SessionIndexer
    @EnvironmentObject var claudeUsageModel: ClaudeUsageModel
    let layoutMode: LayoutMode
    let onToggleLayout: () -> Void

    @State private var selection: String?
    @State private var directoryAlert: DirectoryAlert?
    @State private var resumeAlert: DirectoryAlert?
    @StateObject private var claudeResumeSettings = ClaudeResumeSettings.shared
    @AppStorage("ShowClaudeUsageStrip") private var showUsageStrip: Bool = false
    @AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = SessionIndexer.ModifiedDisplay.relative.rawValue

    private struct DirectoryAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            if layoutMode == .vertical {
                HSplitView {
                    ClaudeSessionsListView(indexer: indexer, selection: $selection, isResumeEnabled: isClaudeResumeEnabled, onResume: { session in
                        handleResume(session)
                    })
                        .frame(minWidth: 320, idealWidth: 600, maxWidth: 1200)
                    ClaudeTranscriptView(indexer: indexer, sessionID: selection)
                        .frame(minWidth: 450)
                }
            } else {
                VSplitView {
                    ClaudeSessionsListView(indexer: indexer, selection: $selection, isResumeEnabled: isClaudeResumeEnabled, onResume: { session in
                        handleResume(session)
                    })
                        .frame(minHeight: 180)
                    ClaudeTranscriptView(indexer: indexer, sessionID: selection)
                        .frame(minHeight: 240)
                }
            }
            if showUsageStrip {
                ClaudeUsageStripView(status: claudeUsageModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(indexer.appAppearance.colorScheme)
        .onChange(of: selection) { _, newID in
            // Lazy load if needed
            if let id = newID, let session = indexer.allSessions.first(where: { $0.id == id }),
               session.events.isEmpty {
                indexer.reloadSession(id: id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ClaudeSearchFiltersView(indexer: indexer)
            }
            // Resume in Claude (feature-flagged)
            ToolbarItem(placement: .automatic) {
                if isClaudeResumeEnabled {
                    Button(action: {
                        if let session = selectedSession {
                            handleResume(session)
                        }
                    }) {
                        Label("Resume in Claude", systemImage: "play.circle")
                    }
                    .help("Open Terminal and resume this Claude session")
                    .disabled(selectedSession == nil)
                    .keyboardShortcut("r", modifiers: [.command, .control])
                }
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
                    PreferencesWindowController.shared.show(indexer: codexIndexer, initialTab: .general)
                }) {
                    Image(systemName: "gear")
                }
                .help("Preferences")
            }
        }
        .onChange(of: indexer.sessions) { _, sessions in
            guard !sessions.isEmpty else {
                selection = nil
                return
            }

            if let current = selection, sessions.contains(where: { $0.id == current }) {
                return
            }

            selection = sessions.first?.id
        }
        .alert(item: $directoryAlert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
        .alert(item: $resumeAlert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    private var selectedSession: Session? {
        guard let selection else { return nil }
        return indexer.sessions.first(where: { $0.id == selection }) ?? indexer.allSessions.first(where: { $0.id == selection })
    }

    private func handleOpenWorkingDirectory(_ session: Session) {
        guard let path = session.cwd, !path.isEmpty else {
            directoryAlert = DirectoryAlert(title: "Working Directory Unavailable",
                                           message: "No working directory is associated with this session.")
            return
        }

        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            directoryAlert = DirectoryAlert(title: "Directory Not Found",
                                           message: "The working directory \(path) does not exist.")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleResume(_ session: Session) {
        Task { @MainActor in
            let launcher: ClaudeTerminalLaunching = claudeResumeSettings.preferITerm ? ClaudeITermLauncher() : ClaudeTerminalLauncher()
            let coordinator = ClaudeResumeCoordinator(env: ClaudeCLIEnvironment(),
                                                      builder: ClaudeResumeCommandBuilder(),
                                                      launcher: launcher)

            let sid = deriveClaudeSessionID(from: session)
            let wd = claudeResumeSettings.effectiveWorkingDirectory(for: session)
            let bin = claudeResumeSettings.binaryPath.isEmpty ? nil : claudeResumeSettings.binaryPath
            let input = ClaudeResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin)
            let policy = claudeResumeSettings.fallbackPolicy
            let result = await coordinator.resumeInTerminal(input: input, policy: policy, dryRun: false)

            if !result.launched {
                var msg = result.error ?? "Launch failed."
                if let cmd = result.command { msg += "\n\nCommand:\n" + cmd }
                resumeAlert = DirectoryAlert(title: "Resume Failed", message: msg)
            }
        }
    }

    private func deriveClaudeSessionID(from session: Session) -> String? {
        // Try to recover from filename: ~/.claude/projects/.../<UUID>.jsonl
        let url = URL(fileURLWithPath: session.filePath)
        let base = url.deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        // As a last resort, scan head events for a sessionId field
        let limit = min(session.events.count, 2000)
        for e in session.events.prefix(limit) {
            let raw = e.rawJSON
            if let data = Data(base64Encoded: raw),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["sessionId"] as? String, !sid.isEmpty {
                return sid
            }
        }
        return nil
    }

    private var isClaudeResumeEnabled: Bool {
        let def = UserDefaults.standard.bool(forKey: ClaudeFeatureFlag.terminalResumeKey)
        if def { return true }
        if let env = ProcessInfo.processInfo.environment["AGENTSESSIONS_FEATURES"], env.contains("claudeResumeTerminal") { return true }
        return false
    }
}

// Wrapper for SessionsListView that bridges ClaudeSessionIndexer
private struct ClaudeSessionsListView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    @Binding var selection: String?
    let isResumeEnabled: Bool
    let onResume: ((Session) -> Void)?
    @AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = SessionIndexer.ModifiedDisplay.relative.rawValue

    init(indexer: ClaudeSessionIndexer,
         selection: Binding<String?>,
         isResumeEnabled: Bool = false,
         onResume: ((Session) -> Void)? = nil) {
        self.indexer = indexer
        self._selection = selection
        self.isResumeEnabled = isResumeEnabled
        self.onResume = onResume
    }
    @State private var tableSelection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<Session>] = []
    @State private var cachedRows: [Session] = []

    private var rows: [Session] { cachedRows }

    var body: some View {
        Table(rows, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("Session", value: \Session.title) { s in
                Text(s.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 160, ideal: 320, max: 2000)

            TableColumn("Date", value: \Session.modifiedAt) { s in
                let display = SessionIndexer.ModifiedDisplay(rawValue: modifiedDisplayRaw) ?? .relative
                let primary = (display == .relative) ? s.modifiedRelative : absoluteTimeClaude(s.modifiedAt)
                let helpText = (display == .relative) ? absoluteTimeClaude(s.modifiedAt) : s.modifiedRelative
                Text(primary)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(helpText)
            }
            .width(min: 120, ideal: 120, max: 140)

            TableColumn("Project", value: \Session.repoDisplay) { s in
                Text(s.repoDisplay)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) {
                        if let name = s.repoName {
                            indexer.projectFilter = name
                            indexer.recomputeNow()
                        }
                    }
            }
            .width(min: 120, ideal: 160, max: 240)

            TableColumn("Msgs", value: \Session.messageCount) { s in
                Text("\(s.messageCount)")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
            }
            .width(min: 64, ideal: 64, max: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .environment(\.defaultMinListRowHeight, 22)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenuContent(for: ids)
        }
        .navigationTitle("Claude Code Sessions")
        .onChange(of: sortOrder) { _, _ in
            updateCachedRows()
        }
        .onChange(of: tableSelection) { oldSel, newSel in
            // Force single selection
            if newSel.count > 1 {
                // Keep only the newly selected item
                let newlySelected = newSel.subtracting(oldSel)
                if let newItem = newlySelected.first {
                    DispatchQueue.main.async {
                        tableSelection = [newItem]
                        selection = newItem
                    }
                } else if let first = newSel.first {
                    DispatchQueue.main.async {
                        tableSelection = [first]
                        selection = first
                    }
                }
                return
            }
            selection = newSel.first
        }
        .onChange(of: indexer.sessions) { _, _ in
            updateCachedRows()
        }
        .onChange(of: selection) { _, newValue in
            let desired: Set<String> = newValue.map { [$0] } ?? []
            if tableSelection != desired {
                tableSelection = desired
            }
        }
        .onAppear {
            if let sel = selection { tableSelection = [sel] }
            if sortOrder.isEmpty {
                sortOrder = [KeyPathComparator(\Session.modifiedAt, order: .reverse)]
            }
            updateCachedRows()
        }
    }

    private func updateCachedRows() {
        cachedRows = indexer.sessions.sorted(using: sortOrder)
    }

    // Match time formatter used elsewhere so absolute-time mode looks consistent
    private func absoluteTimeClaude(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = false
        return f.string(from: date)
    }

    private func session(for id: String) -> Session? {
        rows.first(where: { $0.id == id }) ?? indexer.sessions.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func contextMenuContent(for selectedIDs: Set<String>) -> some View {
        if selectedIDs.count == 1,
           let id = selectedIDs.first,
           let session = session(for: id) {
            if isResumeEnabled {
                Button("Resume in Claude") { onResume?(session) }
                Divider()
            }
            Button("Open Working Directory") {
                openWorkingDirectory(session)
            }
            .disabled(session.cwd == nil || session.cwd?.isEmpty == true)

            if let name = session.repoName, !name.isEmpty {
                Divider()
                Button("Filter by Project: \(name)") {
                    indexer.projectFilter = name
                    indexer.recomputeNow()
                }
            } else {
                Divider()
                Button("Filter by Project") {}.disabled(true)
            }
        } else {
            Button("Open Working Directory") {}.disabled(true)
            Button("Filter by Project") {}.disabled(true)
        }
    }

    private func openWorkingDirectory(_ session: Session) {
        guard let path = session.cwd, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// Wrapper for transcript view using SessionTranscriptBuilder for consistent formatting
struct ClaudeTranscriptView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: claudeSessionID,
            sessionIDLabel: "Claude",
            enableCaching: false
        )
    }

    private func claudeSessionID(for session: Session) -> String? {
        // Prefer filename UUID: ~/.claude/projects/.../<UUID>.jsonl
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        // Fallback: scan events for sessionId field
        let limit = min(session.events.count, 2000)
        for e in session.events.prefix(limit) {
            let raw = e.rawJSON
            if let data = Data(base64Encoded: raw),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["sessionId"] as? String, !sid.isEmpty {
                return sid
            }
        }
        return nil
    }
}

// MARK: - Search Filters for Claude Sessions
private struct ClaudeSearchFiltersView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search", text: $indexer.queryDraft)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 160)
                    .focused($isSearchFocused)
                    .onSubmit { indexer.applySearch() }

                Button(action: { indexer.applySearch() }) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Search transcripts")

                if !indexer.queryDraft.isEmpty {
                    Button(action: {
                        indexer.queryDraft = ""
                        indexer.query = ""
                        indexer.recomputeNow()
                    }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))

            // Show active project filter with clear button
            if let projectFilter = indexer.projectFilter, !projectFilter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(projectFilter)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Button(action: {
                        indexer.projectFilter = nil
                        indexer.recomputeNow()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear project filter")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3)))
            }

            Spacer(minLength: 0)
        }
    }
}

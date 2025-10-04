import SwiftUI
import AppKit

struct UnifiedSessionsView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @ObservedObject var codexIndexer: SessionIndexer
    @ObservedObject var claudeIndexer: ClaudeSessionIndexer
    @EnvironmentObject var codexUsageModel: CodexUsageModel
    @EnvironmentObject var claudeUsageModel: ClaudeUsageModel

    let layoutMode: LayoutMode
    let onToggleLayout: () -> Void

    @State private var selection: String?
    @State private var tableSelection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<Session>] = []
    @AppStorage("UnifiedShowSourceColumn") private var showSourceColumn: Bool = true
    @AppStorage("UnifiedShowCodexStrip") private var showCodexStrip: Bool = false
    @AppStorage("UnifiedShowClaudeStrip") private var showClaudeStrip: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = SessionIndexer.ModifiedDisplay.relative.rawValue
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    private enum SourceColorStyle: String, CaseIterable { case none, text, background } // deprecated

    private var rows: [Session] { unified.sessions }

    var body: some View {
        VStack(spacing: 0) {
            if layoutMode == .vertical {
                HSplitView {
                    listPane
                        .frame(minWidth: 320, idealWidth: 600, maxWidth: 1200)
                    transcriptPane
                        .frame(minWidth: 450)
                }
            } else {
                VSplitView {
                    listPane
                        .frame(minHeight: 180)
                    transcriptPane
                        .frame(minHeight: 240)
                }
            }

            // Usage strips
            if showCodexStrip || showClaudeStrip {
                VStack(spacing: 0) {
                    if showCodexStrip {
                        UsageStripView(codexStatus: codexUsageModel,
                                       label: "Codex",
                                       brandColor: .blue,
                                       verticalPadding: 4,
                                       drawBackground: false,
                                       collapseTop: false,
                                       collapseBottom: showClaudeStrip)
                    }
                    if showClaudeStrip && UserDefaults.standard.bool(forKey: "ShowClaudeUsageStrip") {
                        ClaudeUsageStripView(status: claudeUsageModel,
                                             label: "Claude",
                                             brandColor: Color(red: 204/255, green: 121/255, blue: 90/255),
                                             verticalPadding: 4,
                                             drawBackground: false,
                                             collapseTop: showCodexStrip,
                                             collapseBottom: false)
                    }
                }
                .background(.thickMaterial)
            }
        }
        // Honor app-wide theme selection from Preferences → General
        .preferredColorScheme((AppAppearance(rawValue: appAppearanceRaw) ?? .system).colorScheme)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 2) {
                    Toggle(isOn: $unified.includeCodex) {
                        Text("Codex").foregroundStyle(stripMonochrome ? .primary : (unified.includeCodex ? Color.blue : .primary))
                    }
                    .toggleStyle(.button)
                    Toggle(isOn: $unified.includeClaude) {
                        Text("Claude").foregroundStyle(stripMonochrome ? .primary : (unified.includeClaude ? Color(red: 204/255, green: 121/255, blue: 90/255) : .primary))
                    }
                    .toggleStyle(.button)
                }
            }
            ToolbarItem(placement: .automatic) { UnifiedSearchFiltersView(unified: unified) }
            ToolbarItem(placement: .automatic) {
                Button(action: { if let s = selectedSession { resume(s) } }) {
                    Label("Resume", systemImage: "play.circle")
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(selectedSession == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { if let s = selectedSession { openDir(s) } }) { Label("Open Working Directory", systemImage: "folder") }
                    .disabled(selectedSession == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { unified.refresh() }) {
                    if unified.isIndexing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                    .help("Refresh index")
            }
            ToolbarItem(placement: .automatic) { Divider() }
            ToolbarItem(placement: .automatic) {
                Button(action: { onToggleLayout() }) { Image(systemName: layoutMode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1") }
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { PreferencesWindowController.shared.show(indexer: codexIndexer, initialTab: .general) }) { Image(systemName: "gear") }
                    .help("Preferences")
            }
        }
        .onAppear {
            if sortOrder.isEmpty { sortOrder = [ KeyPathComparator(\Session.modifiedAt, order: .reverse) ] }
        }
        .onChange(of: selection) { _, id in
            guard let id, let s = rows.first(where: { $0.id == id }) else { return }
            // Lazy load full session per source
            if s.source == .codex, let exist = codexIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
                codexIndexer.reloadSession(id: id)
            } else if s.source == .claude, let exist = claudeIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
                claudeIndexer.reloadSession(id: id)
            }
        }
    }

    private var listPane: some View {
        Table(rows, selection: $tableSelection, sortOrder: $sortOrder) {
            // Always include CLI Agent column; collapse width when hidden to avoid type-check complexity
            TableColumn("CLI Agent", value: \Session.sourceKey) { s in
                Text(s.source == .codex ? "Codex" : "Claude")
                    .font(.system(size: 12))
                    .foregroundStyle(!stripMonochrome ? sourceAccent(s) : .secondary)
            }
            .width(min: showSourceColumn ? 90 : 0, ideal: showSourceColumn ? 100 : 0, max: showSourceColumn ? 120 : 0)

            TableColumn("Session", value: \Session.title) { s in
                Text(s.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .background(Color.clear)
            }
            .width(min: 160, ideal: 320, max: 2000)

            TableColumn("Date", value: \Session.modifiedAt) { s in
                let display = SessionIndexer.ModifiedDisplay(rawValue: modifiedDisplayRaw) ?? .relative
                let primary = (display == .relative) ? s.modifiedRelative : absoluteTimeUnified(s.modifiedAt)
                let helpText = (display == .relative) ? absoluteTimeUnified(s.modifiedAt) : s.modifiedRelative
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
                        if let name = s.repoName { unified.projectFilter = name; unified.recomputeNow() }
                    }
            }
            .width(min: 120, ideal: 160, max: 240)

            TableColumn("Msgs", value: \Session.messageCount) { s in
                Text(unifiedMessageDisplay(for: s))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
            }
            .width(min: 64, ideal: 64, max: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .environment(\.defaultMinListRowHeight, 22)
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let s = rows.first(where: { $0.id == id }) {
                Button("Open Working Directory") { openDir(s) }
                if let name = s.repoName, !name.isEmpty {
                    Divider(); Button("Filter by Project: \(name)") { unified.projectFilter = name; unified.recomputeNow() }
                }
            } else {
                Button("Open Working Directory") {}.disabled(true)
                Button("Filter by Project") {}.disabled(true)
            }
        }
        .onChange(of: sortOrder) { _, newValue in
            if let first = newValue.first {
                let key: UnifiedSessionIndexer.SessionSortDescriptor.Key
                if first.keyPath == \Session.modifiedAt { key = .modified }
                else if first.keyPath == \Session.messageCount { key = .msgs }
                else if first.keyPath == \Session.repoDisplay { key = .repo }
                else if first.keyPath == \Session.source { key = .agent }
                else if first.keyPath == \Session.title { key = .title }
                else { key = .title }
                unified.sortDescriptor = .init(key: key, ascending: first.order == .forward)
                unified.recomputeNow()
            }
            updateSelectionBridge()
        }
        .onChange(of: tableSelection) { _, newSel in selection = newSel.first }
        .onChange(of: unified.sessions) { _, _ in updateSelectionBridge() }
    }

    private var transcriptPane: some View {
        Group {
            if let s = selectedSession {
                if s.source == .codex {
                    TranscriptPlainView(sessionID: selection)
                        .environmentObject(codexIndexer)
                } else {
                    ClaudeTranscriptView(indexer: claudeIndexer, sessionID: selection)
                }
            } else {
                Text("Select a session to view transcript").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectedSession: Session? { selection.flatMap { id in rows.first(where: { $0.id == id }) } }

    // Local helper mirrors SessionsListView absolute time formatting
    private func absoluteTimeUnified(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = false
        return f.string(from: date)
    }

    private func updateSelectionBridge() {
        // Keep single-selection Set in sync with selection id
        let desired: Set<String> = selection.map { [$0] } ?? []
        if tableSelection != desired { tableSelection = desired }
    }

    private func openDir(_ s: Session) {
        guard let path = s.cwd, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func resume(_ s: Session) {
        if s.source == .codex {
            Task { @MainActor in
                _ = await CodexResumeCoordinator.shared.quickLaunchInTerminal(session: s)
            }
        } else {
            let settings = ClaudeResumeSettings.shared
            let sid = deriveClaudeSessionID(from: s)
            let wd = settings.effectiveWorkingDirectory(for: s)
            let bin = settings.binaryPath.isEmpty ? nil : settings.binaryPath
            let input = ClaudeResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin)
            Task { @MainActor in
                let launcher: ClaudeTerminalLaunching = settings.preferITerm ? ClaudeITermLauncher() : ClaudeTerminalLauncher()
                let coord = ClaudeResumeCoordinator(env: ClaudeCLIEnvironment(), builder: ClaudeResumeCommandBuilder(), launcher: launcher)
                _ = await coord.resumeInTerminal(input: input, policy: settings.fallbackPolicy, dryRun: false)
            }
        }
    }

    private func deriveClaudeSessionID(from session: Session) -> String? {
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        let limit = min(session.events.count, 2000)
        for e in session.events.prefix(limit) {
            let raw = e.rawJSON
            if let data = Data(base64Encoded: raw), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let sid = json["sessionId"] as? String, !sid.isEmpty {
                return sid
            }
        }
        return nil
    }

    // Match Codex window message display policy
    private func unifiedMessageDisplay(for s: Session) -> String {
        let count = s.messageCount
        if s.events.isEmpty {
            // Lightweight session: show estimate
            return count >= 1000 ? "Many" : "~\(count)"
        } else {
            return String(format: "%3d", count)
        }
    }

    private func sourceAccent(_ s: Session) -> Color {
        return s.source == .codex ? Color.blue : Color(red: 204/255, green: 121/255, blue: 90/255)
    }
}

private struct UnifiedSearchFiltersView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search", text: $unified.queryDraft)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 160)
                    .focused($focused)
                    .onSubmit { unified.applySearch() }
                Button(action: { unified.applySearch() }) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Search transcripts")
                if !unified.queryDraft.isEmpty {
                    Button(action: { unified.queryDraft = ""; unified.query = ""; unified.recomputeNow() }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))

            // Active project filter badge (Codex parity)
            if let projectFilter = unified.projectFilter, !projectFilter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(projectFilter)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Button(action: { unified.projectFilter = nil; unified.recomputeNow() }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear project filter")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3)))
            }
        }
    }
}

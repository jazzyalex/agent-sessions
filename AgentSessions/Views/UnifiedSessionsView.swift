import SwiftUI
import AppKit

private extension Notification.Name {
    static let collapseInlineSearchIfEmpty = Notification.Name("UnifiedSessionsCollapseInlineSearchIfEmpty")
}

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
    @State private var autoSelectEnabled: Bool = true
    @State private var programmaticSelectionUpdate: Bool = false

    private enum SourceColorStyle: String, CaseIterable { case none, text, background } // deprecated

    @StateObject private var searchCoordinator: SearchCoordinator
    private var rows: [Session] { (searchCoordinator.isRunning || !searchCoordinator.results.isEmpty) ? searchCoordinator.results : unified.sessions }

    init(unified: UnifiedSessionIndexer, codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, layoutMode: LayoutMode, onToggleLayout: @escaping () -> Void) {
        self.unified = unified
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.layoutMode = layoutMode
        self.onToggleLayout = onToggleLayout
        _searchCoordinator = StateObject(wrappedValue: SearchCoordinator(codexIndexer: codexIndexer))
    }

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
                    .help("Show or hide Codex sessions in the list")
                    Toggle(isOn: $unified.includeClaude) {
                        Text("Claude").foregroundStyle(stripMonochrome ? .primary : (unified.includeClaude ? Color(red: 204/255, green: 121/255, blue: 90/255) : .primary))
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Claude sessions in the list")
                }
            }
            ToolbarItem(placement: .automatic) { UnifiedSearchFiltersView(unified: unified, search: searchCoordinator) }
            ToolbarItem(placement: .automatic) {
                Button(action: { if let s = selectedSession { resume(s) } }) {
                    Label("Resume", systemImage: "play.circle")
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(selectedSession == nil)
                .help("Attempt to resume the selected session in its original CLI. Some sessions cannot be relaunched.")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { if let s = selectedSession { openDir(s) } }) { Label("Open Working Directory", systemImage: "folder") }
                    .disabled(selectedSession == nil)
                    .help("Reveal the selected session's working directory in Finder")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { unified.refresh() }) {
                    if unified.isIndexing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                    .help("Re-run the session indexer to discover new logs")
            }
            ToolbarItem(placement: .automatic) { Divider() }
            ToolbarItem(placement: .automatic) {
                Button(action: { onToggleLayout() }) { Image(systemName: layoutMode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1") }
                    .help("Toggle between vertical and horizontal layout modes")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { PreferencesWindowController.shared.show(indexer: codexIndexer, initialTab: .general) }) { Image(systemName: "gear") }
                    .help("Open preferences for appearance, indexing, and agents")
            }
        }
        .onAppear {
            if sortOrder.isEmpty { sortOrder = [ KeyPathComparator(\Session.modifiedAt, order: .reverse) ] }
        }
        .onChange(of: selection) { _, id in
            guard let id, let s = rows.first(where: { $0.id == id }) else { return }
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
            // If a large, unparsed session is clicked during an active search, promote it in the coordinator.
            let sizeBytes = s.fileSizeBytes ?? 0
            if searchCoordinator.isRunning, s.events.isEmpty, sizeBytes >= 10 * 1024 * 1024 {
                searchCoordinator.promote(id: s.id)
            }
            // Lazy load full session per source
            if s.source == .codex, let exist = codexIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
                codexIndexer.reloadSession(id: id)
            } else if s.source == .claude, let exist = claudeIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
                claudeIndexer.reloadSession(id: id)
            }
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
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
        .simultaneousGesture(TapGesture().onEnded {
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
        })
        if searchCoordinator.isRunning {
            let p = searchCoordinator.progress
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progressLineText(p))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay(Divider(), alignment: .top)
        }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let s = rows.first(where: { $0.id == id }) {
                Button("Open Working Directory") { openDir(s) }
                    .help("Reveal the working directory for \(s.title) in Finder")
                Button("Open Session in Folder") { revealSessionFile(s) }
                    .help("Show the raw session log in Finder")
                if let name = s.repoName, !name.isEmpty {
                    Divider()
                    Button("Filter by Project: \(name)") { unified.projectFilter = name; unified.recomputeNow() }
                        .help("Filter to sessions from \(name)")
                }
            } else {
                Button("Open Working Directory") {}
                    .disabled(true)
                    .help("Select a single session with a known working directory")
                Button("Open Session in Folder") {}
                    .disabled(true)
                    .help("Select one session to reveal its log in Finder")
                Button("Filter by Project") {}
                    .disabled(true)
                    .help("Select one session that has project metadata to filter by")
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
        .onChange(of: tableSelection) { _, newSel in
            selection = newSel.first
            if !programmaticSelectionUpdate {
                // User interacted with the table; stop auto-selection
                autoSelectEnabled = false
            }
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
        }
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
        .simultaneousGesture(TapGesture().onEnded {
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
        })
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
        // If auto-selection is enabled, keep the selection pinned to the first row
        if autoSelectEnabled, let first = rows.first { selection = first.id }
        // Keep single-selection Set in sync with selection id
        let desired: Set<String> = selection.map { [$0] } ?? []
        if tableSelection != desired {
            programmaticSelectionUpdate = true
            tableSelection = desired
            DispatchQueue.main.async { programmaticSelectionUpdate = false }
        }
    }

    private func openDir(_ s: Session) {
        guard let path = s.cwd, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func revealSessionFile(_ s: Session) {
        let url = URL(fileURLWithPath: s.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
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
            if let bytes = s.fileSizeBytes {
                return formattedSize(bytes)
            }
            return fallbackEstimate(count)
        } else {
            return String(format: "%3d", count)
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 10 {
            return "\(Int(round(mb)))MB"
        } else if mb >= 1 {
            return String(format: "%.1fMB", mb)
        }
        let kb = max(1, Int(round(Double(bytes) / 1024.0)))
        return "\(kb)KB"
    }

    private func fallbackEstimate(_ count: Int) -> String {
        if count >= 1000 { return "1000+" }
        return "~\(count)"
    }

    private func sourceAccent(_ s: Session) -> Color {
        return s.source == .codex ? Color.blue : Color(red: 204/255, green: 121/255, blue: 90/255)
    }

    private func progressLineText(_ p: SearchCoordinator.Progress) -> String {
        switch p.phase {
        case .idle:
            return ""
        case .small:
            return "Scanning small… \(p.scannedSmall)/\(p.totalSmall)"
        case .large:
            return "Scanning large… \(p.scannedLarge)/\(p.totalLarge)"
        }
    }
}

private struct UnifiedSearchFiltersView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @ObservedObject var search: SearchCoordinator
    @FocusState private var focused: Bool
    @FocusState private var searchFocus: SearchFocusTarget?
    @State private var showInlineSearch: Bool = false
    private enum SearchFocusTarget: Hashable { case field, clear }
    @State private var eventMonitor: Any?
    var body: some View {
        HStack(spacing: 8) {
            if showInlineSearch || !unified.queryDraft.isEmpty || search.isRunning {
                // Inline search field within the toolbar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                    TextField("Search", text: $unified.queryDraft)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .focused($searchFocus, equals: .field)
                        .onSubmit { startSearch() }
                        .frame(minWidth: 220)
                    if !unified.queryDraft.isEmpty {
                        Button(action: { unified.queryDraft = ""; unified.query = ""; unified.recomputeNow(); search.cancel(); showInlineSearch = false; focused = false; searchFocus = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                        }
                        .focused($searchFocus, equals: .clear)
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(focused ? Color.yellow : Color.gray.opacity(0.28), lineWidth: focused ? 2 : 1)
                )
                .onAppear { DispatchQueue.main.async { focused = true; searchFocus = .field } }
                .keyboardShortcut("f", modifiers: [.command, .option])
                // If focus leaves the search controls and query is empty, collapse
                .onChange(of: searchFocus) { _, target in
                    if target == nil && unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !search.isRunning {
                        showInlineSearch = false
                        focused = false
                    }
                }
                .onChange(of: unified.queryDraft) { _, newValue in
                    let q = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if q.isEmpty {
                        search.cancel()
                    } else {
                        startSearch()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .collapseInlineSearchIfEmpty)) { _ in
                    if unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !search.isRunning {
                        showInlineSearch = false
                        focused = false
                        searchFocus = nil
                    }
                }
                .onChange(of: showInlineSearch) { _, shown in
                    if shown {
                        // Ensure programmatic focus after the field becomes visible
                        DispatchQueue.main.async {
                            focused = true
                            searchFocus = .field
                        }
                    }
                }
            } else {
                // Compact loop button without border; inline search replaces it when active
                Button(action: { showInlineSearch = true; DispatchQueue.main.async { focused = true; searchFocus = .field } }) {
                    Image(systemName: "magnifyingglass")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                        .font(.system(size: 14, weight: .regular))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [.command, .option])
                .focusable(false)
                .help("Search sessions (⌥⌘F)")
            }

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
                    .help("Remove the project filter and show all sessions")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3)))
            }
        }
        .onAppear {
            // Global event monitor to collapse empty inline search on click/tab outside
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { ev in
                if (ev.type == .keyDown && ev.keyCode == 48) || ev.type == .leftMouseDown || ev.type == .rightMouseDown { // Tab or click
                    if showInlineSearch,
                       unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !search.isRunning,
                       !focused && searchFocus == nil {
                        showInlineSearch = false
                    }
                }
                return ev
            }
        }
        .onDisappear {
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        }
    }

    private func startSearch() {
        let q = unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { search.cancel(); return }
        let filters = Filters(query: q,
                              dateFrom: unified.dateFrom,
                              dateTo: unified.dateTo,
                              model: unified.selectedModel,
                              kinds: unified.selectedKinds,
                              repoName: unified.projectFilter,
                              pathContains: nil)
        search.start(query: q,
                     filters: filters,
                     includeCodex: unified.includeCodex,
                     includeClaude: unified.includeClaude,
                     all: unified.allSessions)
    }
}

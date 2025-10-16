import SwiftUI
import AppKit

private extension Notification.Name {
    static let collapseInlineSearchIfEmpty = Notification.Name("UnifiedSessionsCollapseInlineSearchIfEmpty")
}

struct UnifiedSessionsView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @ObservedObject var codexIndexer: SessionIndexer
    @ObservedObject var claudeIndexer: ClaudeSessionIndexer
    @ObservedObject var geminiIndexer: GeminiSessionIndexer
    @EnvironmentObject var codexUsageModel: CodexUsageModel
    @EnvironmentObject var claudeUsageModel: ClaudeUsageModel
    @EnvironmentObject var updaterController: UpdaterController

    let layoutMode: LayoutMode
    let onToggleLayout: () -> Void

    @State private var selection: String?
    @State private var tableSelection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<Session>] = []
    @State private var cachedRows: [Session] = []
    @AppStorage("UnifiedShowSourceColumn") private var showSourceColumn: Bool = true
    @AppStorage("UnifiedShowStarColumn") private var showStarColumn: Bool = true
    @AppStorage("UnifiedShowCodexStrip") private var showCodexStrip: Bool = false
    @AppStorage("UnifiedShowClaudeStrip") private var showClaudeStrip: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = SessionIndexer.ModifiedDisplay.relative.rawValue
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @State private var autoSelectEnabled: Bool = true
    @State private var programmaticSelectionUpdate: Bool = false
    @State private var isAutoSelectingFromSearch: Bool = false

    private enum SourceColorStyle: String, CaseIterable { case none, text, background } // deprecated

    @StateObject private var searchCoordinator: SearchCoordinator
    @StateObject private var focusCoordinator = WindowFocusCoordinator()
    private var rows: [Session] {
        if searchCoordinator.isRunning || !searchCoordinator.results.isEmpty {
            // Apply current UI filters and sort to search results
            return unified.applyFiltersAndSort(to: searchCoordinator.results)
        } else {
            return unified.sessions
        }
    }

    init(unified: UnifiedSessionIndexer, codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, geminiIndexer: GeminiSessionIndexer, layoutMode: LayoutMode, onToggleLayout: @escaping () -> Void) {
        self.unified = unified
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.geminiIndexer = geminiIndexer
        self.layoutMode = layoutMode
        self.onToggleLayout = onToggleLayout
        _searchCoordinator = StateObject(wrappedValue: SearchCoordinator(codexIndexer: codexIndexer, claudeIndexer: claudeIndexer, geminiIndexer: geminiIndexer))
    }

    var body: some View {
        VStack(spacing: 0) {
            if layoutMode == .vertical {
                HSplitView {
                    listPane
                        .frame(minWidth: 320, maxWidth: 1200)
                    transcriptPane
                        .frame(minWidth: 450)
                }
                .background(SplitViewAutosave(key: "UnifiedSplit-H"))
                .transaction { $0.animation = nil }
            } else {
                VSplitView {
                    listPane
                        .frame(minHeight: 180)
                    transcriptPane
                        .frame(minHeight: 240)
                }
                .background(SplitViewAutosave(key: "UnifiedSplit-V"))
                .transaction { $0.animation = nil }
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
                        Text("Codex")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeCodex ? Color.blue : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Codex sessions in the list (⌘1)")
                    .keyboardShortcut("1", modifiers: .command)

                    Toggle(isOn: $unified.includeClaude) {
                        Text("Claude")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeClaude ? Color(red: 204/255, green: 121/255, blue: 90/255) : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Claude sessions in the list (⌘2)")
                    .keyboardShortcut("2", modifiers: .command)

                    Toggle(isOn: $unified.includeGemini) {
                        Text("Gemini")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeGemini ? Color.teal : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Gemini sessions in the list (⌘3)")
                    .keyboardShortcut("3", modifiers: .command)
                }
            }
            ToolbarItem(placement: .automatic) {
                UnifiedSearchFiltersView(unified: unified, search: searchCoordinator, focus: focusCoordinator)
            }
            // Compact Favorites filter toggle
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $unified.showFavoritesOnly) {
                    Label("Favorites", systemImage: unified.showFavoritesOnly ? "star.fill" : "star")
                }
                .toggleStyle(.button)
                .disabled(!showStarColumn)
                .help(showStarColumn ? "Show only favorited sessions" : "Enable star column in Preferences to use favorites")
                .accessibilityLabel("Favorites Only")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { if let s = selectedSession { resume(s) } }) {
                    Label("Resume", systemImage: "play.circle")
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(selectedSession == nil || selectedSession?.source == .gemini)
                .help("Resume the selected session in its original CLI (⌃⌘R)")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { if let s = selectedSession { openDir(s) } }) { Label("Open Working Directory", systemImage: "folder") }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(selectedSession == nil)
                    .help("Reveal the selected session's working directory in Finder (⌘⇧O)")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    // Don't clear selection - let the transcript view show loading animation
                    unified.refresh()
                }) {
                    if unified.isIndexing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Re-run the session indexer to discover new logs (⌘R)")
            }
            ToolbarItem(placement: .automatic) { Divider() }
            ToolbarItem(placement: .automatic) {
                Button(action: { onToggleLayout() }) { Image(systemName: layoutMode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1") }
                    .keyboardShortcut("l", modifiers: .command)
                    .help("Toggle between vertical and horizontal layout modes (⌘L)")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { PreferencesWindowController.shared.show(indexer: codexIndexer, updaterController: updaterController, initialTab: .general) }) { Image(systemName: "gear") }
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Open preferences for appearance, indexing, and agents (⌘,)")
            }
        }
        .onAppear {
            if sortOrder.isEmpty { sortOrder = [ KeyPathComparator(\Session.modifiedAt, order: .reverse) ] }
            updateCachedRows()
        }
        .onChange(of: selection) { _, id in
            guard let id, let s = cachedRows.first(where: { $0.id == id }) else { return }
            // When selection is changed due to search auto-selection, do not steal focus or collapse inline search
            if !isAutoSelectingFromSearch {
                // CRITICAL: Selecting session FORCES cleanup of all search UI (Apple Notes behavior)
                focusCoordinator.perform(.selectSession(id: id))
                NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
            }
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
            } else if s.source == .gemini, let exist = geminiIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
                geminiIndexer.reloadSession(id: id)
            }
        }
        .onAppear {
            if sortOrder.isEmpty { sortOrder = [ KeyPathComparator(\Session.modifiedAt, order: .reverse) ] }
        }
        .onChange(of: unified.includeCodex) { _, _ in restartSearchIfRunning() }
        .onChange(of: unified.includeClaude) { _, _ in restartSearchIfRunning() }
        .onChange(of: unified.includeGemini) { _, _ in restartSearchIfRunning() }
    }

    private var listPane: some View {
        ZStack(alignment: .bottom) {
        Table(cachedRows, selection: $tableSelection, sortOrder: $sortOrder) {
            // Always include CLI Agent column; collapse width when hidden to avoid type-check complexity
            TableColumn("CLI Agent", value: \Session.sourceKey) { s in
                let label: String = {
                    switch s.source {
                    case .codex: return "Codex"
                    case .claude: return "Claude"
                    case .gemini: return "Gemini"
                    }
                }()
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(!stripMonochrome ? sourceAccent(s) : .secondary)
                    Spacer(minLength: 4)
                    if showStarColumn {
                        Button(action: { unified.toggleFavorite(s.id) }) {
                            Image(systemName: s.isFavorite ? "star.fill" : "star")
                                .imageScale(.medium)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .help(s.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        .accessibilityLabel(s.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    }
                }
            }
            .width(min: showSourceColumn ? 90 : 0, ideal: showSourceColumn ? 100 : 0, max: showSourceColumn ? 120 : 0)

            TableColumn("Session", value: \Session.title) { s in
                SessionTitleCell(session: s, geminiIndexer: geminiIndexer)
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
                let display: String = {
                    if s.source == .gemini {
                        if let name = s.repoName, !name.isEmpty { return name }
                        return "—"
                    } else {
                        return s.repoDisplay
                    }
                }()
                ProjectCellView(id: s.id, display: display)
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

            // Removed separate Refresh column to avoid churn
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .environment(\.defaultMinListRowHeight, 22)
        .simultaneousGesture(TapGesture().onEnded {
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
        })
        }
        // Bottom overlay to avoid changing intrinsic size of the list pane
        .overlay(alignment: .bottom) {
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
                .allowsHitTesting(false)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let s = cachedRows.first(where: { $0.id == id }) {
                Button(s.isFavorite ? "Remove from Favorites" : "Add to Favorites") { unified.toggleFavorite(id) }
                Divider()
                if s.source != .gemini {
                    Button("Resume in \(s.source == .codex ? "Codex CLI" : "Claude Code")") { resume(s) }
                        .keyboardShortcut("r", modifiers: [.command, .control])
                        .help("Resume the selected session in its original CLI (⌃⌘R)")
                    Divider()
                }
                Button("Open Working Directory") { openDir(s) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .help("Reveal working directory in Finder (⌘⇧O)")
                Button("Reveal Session Log") { revealSessionFile(s) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .help("Show session log file in Finder (⌥⌘L)")
                if let name = s.repoName, !name.isEmpty {
                    Divider()
                    Button("Filter by Project: \(name)") { unified.projectFilter = name; unified.recomputeNow() }
                        .keyboardShortcut("p", modifiers: [.command, .option])
                        .help("Show only sessions from \(name) (⌥⌘P)")
                }
            } else {
                Button("Resume") {}
                    .disabled(true)
                Button("Open Working Directory") {}
                    .disabled(true)
                    .help("Select a session to open its working directory")
                Button("Reveal Session Log") {}
                    .disabled(true)
                    .help("Select a session to reveal its log file")
                Button("Filter by Project") {}
                    .disabled(true)
                    .help("Select a session with project metadata to filter")
            }
        }
        .onChange(of: sortOrder) { _, newValue in
            if let first = newValue.first {
                let key: UnifiedSessionIndexer.SessionSortDescriptor.Key
                if first.keyPath == \Session.modifiedAt { key = .modified }
                else if first.keyPath == \Session.messageCount { key = .msgs }
                else if first.keyPath == \Session.repoDisplay { key = .repo }
                else if first.keyPath == \Session.sourceKey { key = .agent }
                else if first.keyPath == \Session.title { key = .title }
                else { key = .title }
                unified.sortDescriptor = .init(key: key, ascending: first.order == .forward)
                unified.recomputeNow()
            }
            updateSelectionBridge()
            updateCachedRows()
        }
        .onChange(of: tableSelection) { _, newSel in
            // Prevent clearing the current selection by clicking empty table space (HIG: avoid accidental context loss)
            if newSel.isEmpty, let current = selection {
                if tableSelection != [current] {
                    programmaticSelectionUpdate = true
                    tableSelection = [current]
                    DispatchQueue.main.async { programmaticSelectionUpdate = false }
                }
                return
            }
            selection = newSel.first
            if !programmaticSelectionUpdate {
                // User interacted with the table; stop auto-selection
                autoSelectEnabled = false
            }
            if !programmaticSelectionUpdate {
                NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
            }
        }
        .onChange(of: unified.sessions) { _, _ in
            updateSelectionBridge()
            updateCachedRows()
        }
        .onChange(of: searchCoordinator.results) { _, _ in
            updateCachedRows()
            // If we have search results but no valid selection (none selected or selected not in results),
            // auto-select the first match without stealing focus
            if selectedSession == nil, let first = cachedRows.first {
                isAutoSelectingFromSearch = true
                selection = first.id
                let desired: Set<String> = [first.id]
                if tableSelection != desired {
                    programmaticSelectionUpdate = true
                    tableSelection = desired
                    DispatchQueue.main.async { programmaticSelectionUpdate = false }
                }
                // Reset the flag on the next runloop to ensure onChange handlers have observed it
                DispatchQueue.main.async { isAutoSelectingFromSearch = false }
            }
        }
    }

    private var transcriptPane: some View {
        ZStack {
            // Base host is always mounted to keep a stable split subview identity
            TranscriptHostView(kind: selectedSession?.source ?? .codex,
                               selection: selection,
                               codexIndexer: codexIndexer,
                               claudeIndexer: claudeIndexer,
                               geminiIndexer: geminiIndexer)
                .environmentObject(focusCoordinator)
                .id("transcript-host")

            // Overlays for error/empty/loading states to avoid replacing the base view
            if let s = selectedSession {
                if !FileManager.default.fileExists(atPath: s.filePath) {
                    let providerName: String = (s.source == .codex ? "Codex" : (s.source == .claude ? "Claude" : "Gemini"))
                    let accent: Color = sourceAccent(s)
                    VStack(spacing: 12) {
                        Label("Session file not found", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(accent)
                        Text("This \(providerName) session was removed by the system or CLI.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Remove") { if let id = selection { unified.removeSession(id: id) } }
                                .buttonStyle(.borderedProminent)
                            Button("Re-scan") { unified.refresh() }
                                .buttonStyle(.bordered)
                            Button("Locate…") { revealParentOfMissing(s) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                } else if s.source == .gemini, geminiIndexer.unreadableSessionIDs.contains(s.id) {
                    VStack(spacing: 12) {
                        Label("Could not open session", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(sourceAccent(s))
                        Text("This Gemini session could not be parsed. It may be truncated or corrupted.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Open in Finder") { revealSessionFile(s) }
                                .buttonStyle(.borderedProminent)
                            Button("Re-scan") { unified.refresh() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            } else {
                if unified.isIndexing {
                    LoadingAnimationView(
                        codexColor: .blue,
                        claudeColor: Color(red: 204/255, green: 121/255, blue: 90/255)
                    )
                } else {
                    Text("Select a session to view transcript")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
        })
    }

    private var selectedSession: Session? { selection.flatMap { id in cachedRows.first(where: { $0.id == id }) } }

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
        if autoSelectEnabled, let first = cachedRows.first { selection = first.id }
        // Keep single-selection Set in sync with selection id
        let desired: Set<String> = selection.map { [$0] } ?? []
        if tableSelection != desired {
            programmaticSelectionUpdate = true
            tableSelection = desired
            DispatchQueue.main.async { programmaticSelectionUpdate = false }
        }
    }

    private func updateCachedRows() {
        if FeatureFlags.coalesceListResort {
            // unified.sessions is already sorted by the view model's descriptor
            cachedRows = rows
        } else {
            cachedRows = rows.sorted(using: sortOrder)
        }
        if let sel = selection, !cachedRows.contains(where: { $0.id == sel }) {
            selection = cachedRows.first?.id
            tableSelection = selection.map { [$0] } ?? []
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

    private func revealParentOfMissing(_ s: Session) {
        let url = URL(fileURLWithPath: s.filePath)
        let dir = url.deletingLastPathComponent()
        NSWorkspace.shared.open(dir)
    }

    private func resume(_ s: Session) {
        if s.source == .gemini { return } // No resume support for Gemini
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
    
    private func restartSearchIfRunning() {
        guard searchCoordinator.isRunning else { return }
        let filters = Filters(query: unified.query,
                              dateFrom: unified.dateFrom,
                              dateTo: unified.dateTo,
                              model: unified.selectedModel,
                              kinds: unified.selectedKinds,
                              repoName: unified.projectFilter,
                              pathContains: nil)
        searchCoordinator.start(query: unified.query,
                                filters: filters,
                                includeCodex: unified.includeCodex,
                                includeClaude: unified.includeClaude,
                                includeGemini: unified.includeGemini,
                                all: unified.allSessions)
    }

    private func sourceAccent(_ s: Session) -> Color {
        switch s.source {
        case .codex: return Color.blue
        case .claude: return Color(red: 204/255, green: 121/255, blue: 90/255)
        case .gemini: return Color.teal
        }
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

// Stable transcript host that preserves layout identity across provider switches
private struct TranscriptHostView: View {
    let kind: SessionSource
    let selection: String?
    @ObservedObject var codexIndexer: SessionIndexer
    @ObservedObject var claudeIndexer: ClaudeSessionIndexer
    @ObservedObject var geminiIndexer: GeminiSessionIndexer

    var body: some View {
        ZStack { // keep one stable container to avoid split reset
            TranscriptPlainView(sessionID: selection)
                .environmentObject(codexIndexer)
                .opacity(kind == .codex ? 1 : 0)
            ClaudeTranscriptView(indexer: claudeIndexer, sessionID: selection)
                .opacity(kind == .claude ? 1 : 0)
            GeminiTranscriptView(indexer: geminiIndexer, sessionID: selection)
                .opacity(kind == .gemini ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// Session title cell with inline Gemini refresh affordance (hover-only)
private struct SessionTitleCell: View {
    let session: Session
    @ObservedObject var geminiIndexer: GeminiSessionIndexer
    @State private var hover: Bool = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(session.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .background(Color.clear)
            if session.source == .gemini, geminiIndexer.isPreviewStale(id: session.id) {
                Button(action: { geminiIndexer.refreshPreview(id: session.id) }) {
                    Text("Refresh")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.teal)
                .opacity(hover ? 1 : 0)
                .help("Update this session's preview to reflect the latest file contents")
            }
        }
        .onHover { hover = $0 }
    }
}

// Stable, equatable cell to prevent Table reuse glitches in Project column
private struct ProjectCellView: View, Equatable {
    let id: String
    let display: String
    static func == (lhs: ProjectCellView, rhs: ProjectCellView) -> Bool {
        lhs.id == rhs.id && lhs.display == rhs.display
    }
    var body: some View {
        Text(display)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.tail)
            .id("project-cell-\(id)")
    }
}

private struct UnifiedSearchFiltersView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @ObservedObject var search: SearchCoordinator
    @ObservedObject var focus: WindowFocusCoordinator
    @FocusState private var searchFocus: SearchFocusTarget?
    @State private var showInlineSearch: Bool = false
    @State private var searchDebouncer: DispatchWorkItem? = nil
    private enum SearchFocusTarget: Hashable { case field, clear }
    var body: some View {
        HStack(spacing: 8) {
            if showInlineSearch || !unified.queryDraft.isEmpty || search.isRunning {
                // Inline search field within the toolbar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                    // Use an AppKit-backed text field to ensure focus works inside a toolbar
                    ToolbarSearchTextField(text: $unified.queryDraft,
                                           placeholder: "Search",
                                           isFirstResponder: Binding(get: { searchFocus == .field },
                                                                     set: { want in
                                                                         if want { searchFocus = .field }
                                                                         else if searchFocus == .field { searchFocus = nil }
                                                                     }),
                                           onCommit: { startSearchImmediate() })
                        .frame(minWidth: 220)
                    if !unified.queryDraft.isEmpty {
                        Button(action: { unified.queryDraft = ""; unified.query = ""; unified.recomputeNow(); search.cancel(); showInlineSearch = false; searchFocus = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                        }
                        .focused($searchFocus, equals: .clear)
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape)
                        .help("Clear search (⎋)")
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
                        .stroke(searchFocus == .field ? Color.yellow : Color.gray.opacity(0.28), lineWidth: searchFocus == .field ? 2 : 1)
                )
                // If focus leaves the search controls and query is empty, collapse
                .onChange(of: searchFocus) { _, target in
                    if target == nil && unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !search.isRunning {
                        showInlineSearch = false
                    }
                }
                .onChange(of: unified.queryDraft) { _, newValue in
                    TypingActivity.shared.bump()
                    let q = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if q.isEmpty {
                        search.cancel()
                    } else {
                        if FeatureFlags.increaseDeepSearchDebounce {
                            scheduleSearch()
                        } else {
                            startSearch()
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .collapseInlineSearchIfEmpty)) { _ in
                    if unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !search.isRunning {
                        showInlineSearch = false
                        searchFocus = nil
                    }
                }
                .onAppear {
                    searchFocus = .field
                }
                .onChange(of: showInlineSearch) { _, shown in
                    if shown {
                        // Multiple attempts at different timings to ensure focus sticks
                        searchFocus = .field
                        DispatchQueue.main.async {
                            searchFocus = .field
                        }
                    }
                }
            } else {
                // Compact loop button without border; inline search replaces it when active
                Button(action: {
                    focus.perform(.openSessionSearch)
                }) {
                    Image(systemName: "magnifyingglass")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                        .font(.system(size: 14, weight: .regular))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [.command, .option])
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
        .onChange(of: focus.activeFocus) { _, newFocus in
            if newFocus == .sessionSearch {
                showInlineSearch = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    searchFocus = .field
                }
            } else if newFocus == .none || newFocus == .transcriptFind {
                if unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !search.isRunning {
                    showInlineSearch = false
                    searchFocus = nil
                }
            }
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
                     includeGemini: unified.includeGemini,
                     all: unified.allSessions)
    }

    private func startSearchImmediate() {
        searchDebouncer?.cancel(); searchDebouncer = nil
        startSearch()
    }

    private func scheduleSearch() {
        searchDebouncer?.cancel()
        let work = DispatchWorkItem { [weak unified, weak search] in
            guard let unified = unified, let search = search else { return }
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
                         includeGemini: unified.includeGemini,
                         all: unified.allSessions)
        }
        searchDebouncer = work
        let delay: TimeInterval = FeatureFlags.increaseDeepSearchDebounce ? 0.28 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - AppKit-backed text field for reliable toolbar focus
private struct ToolbarSearchTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFirstResponder: Bool
    var onCommit: () -> Void

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ToolbarSearchTextField
        init(parent: ToolbarSearchTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            if parent.text != tf.stringValue { parent.text = tf.stringValue }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFirstResponder = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFirstResponder = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.placeholderString = placeholder
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tf.delegate = context.coordinator
        tf.lineBreakMode = .byTruncatingTail
        // Force focus after the view is in the window
        DispatchQueue.main.async { [weak tf] in
            guard let tf, let window = tf.window else { return }
            _ = window.makeFirstResponder(tf)
        }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        if tf.placeholderString != placeholder { tf.placeholderString = placeholder }
        // Don't rely on isFirstResponder binding - already set in makeNSView
    }
}

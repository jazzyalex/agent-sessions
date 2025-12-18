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
    @ObservedObject var opencodeIndexer: OpenCodeSessionIndexer
    @EnvironmentObject var codexUsageModel: CodexUsageModel
    @EnvironmentObject var claudeUsageModel: ClaudeUsageModel
    @EnvironmentObject var updaterController: UpdaterController
    @EnvironmentObject var columnVisibility: ColumnVisibilityStore

    let layoutMode: LayoutMode
    let analyticsReady: Bool
    let onToggleLayout: () -> Void

    @State private var selection: String?
    @State private var tableSelection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<Session>] = []
    @State private var cachedRows: [Session] = []
    @State private var columnLayoutID: UUID = UUID()
    @AppStorage("UnifiedShowSourceColumn") private var showSourceColumn: Bool = true
    @AppStorage("UnifiedShowStarColumn") private var showStarColumn: Bool = true
    @AppStorage("UnifiedShowSizeColumn") private var showSizeColumn: Bool = true
    @AppStorage("UnifiedShowCodexStrip") private var showCodexStrip: Bool = false
    @AppStorage("UnifiedShowClaudeStrip") private var showClaudeStrip: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = SessionIndexer.ModifiedDisplay.relative.rawValue
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.geminiEnabled) private var geminiAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
    @State private var autoSelectEnabled: Bool = true
    @State private var programmaticSelectionUpdate: Bool = false
    @State private var isAutoSelectingFromSearch: Bool = false
    @State private var hasEverHadSessions: Bool = false
    @State private var hasUserManuallySelected: Bool = false
    @State private var showAnalyticsWarmupNotice: Bool = false
    @State private var showAgentEnablementNotice: Bool = false

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

    init(unified: UnifiedSessionIndexer,
         codexIndexer: SessionIndexer,
         claudeIndexer: ClaudeSessionIndexer,
         geminiIndexer: GeminiSessionIndexer,
         opencodeIndexer: OpenCodeSessionIndexer,
         analyticsReady: Bool,
         layoutMode: LayoutMode,
         onToggleLayout: @escaping () -> Void) {
        self.unified = unified
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.geminiIndexer = geminiIndexer
        self.opencodeIndexer = opencodeIndexer
        self.analyticsReady = analyticsReady
        self.layoutMode = layoutMode
        self.onToggleLayout = onToggleLayout
        _searchCoordinator = StateObject(wrappedValue: SearchCoordinator(codexIndexer: codexIndexer,
                                                                         claudeIndexer: claudeIndexer,
                                                                         geminiIndexer: geminiIndexer,
                                                                         opencodeIndexer: opencodeIndexer))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Cap ETA banner disabled (calculations retained; UI disabled)
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
            let shouldShowCodexStrip = codexAgentEnabled && showCodexStrip
            let shouldShowClaudeStrip = claudeAgentEnabled && showClaudeStrip && UserDefaults.standard.bool(forKey: "ShowClaudeUsageStrip")
            if shouldShowCodexStrip || shouldShowClaudeStrip {
                VStack(spacing: 0) {
                    if shouldShowCodexStrip {
                        UsageStripView(codexStatus: codexUsageModel,
                                       label: "Codex",
                                       brandColor: .blue,
                                       verticalPadding: 4,
                                       drawBackground: false,
                                       collapseTop: false,
                                       collapseBottom: shouldShowClaudeStrip)
                    }
                    if shouldShowClaudeStrip {
                        ClaudeUsageStripView(status: claudeUsageModel,
                                             label: "Claude",
                                             brandColor: Color(red: 204/255, green: 121/255, blue: 90/255),
                                             verticalPadding: 4,
                                             drawBackground: false,
                                             collapseTop: shouldShowCodexStrip,
                                             collapseBottom: false)
                    }
                }
                .background(.thickMaterial)
            }
        }
        // Honor app-wide theme selection from Preferences → General.
        // Apply preferredColorScheme only for explicit Light/Dark; omit for System to inherit.
        .applyIf((AppAppearance(rawValue: appAppearanceRaw) ?? .system) == .light) { $0.preferredColorScheme(.light) }
        .applyIf((AppAppearance(rawValue: appAppearanceRaw) ?? .system) == .dark) { $0.preferredColorScheme(.dark) }
        .toolbar { toolbarContent }
        .overlay(alignment: .topTrailing) {
            if showAnalyticsWarmupNotice {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analytics is warming up… try again in ~1–2 minutes")
                        .font(.footnote)
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 8)
                .padding(.trailing, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if showAgentEnablementNotice {
                Text("Showing active agents only")
                    .font(.footnote)
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            if sortOrder.isEmpty { sortOrder = [ KeyPathComparator(\Session.modifiedAt, order: .reverse) ] }
            updateCachedRows()
        }
        .onChange(of: analyticsReady) { _, ready in
            if ready {
                withAnimation { showAnalyticsWarmupNotice = false }
            }
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
            } else if s.source == .opencode, let exist = opencodeIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
                opencodeIndexer.reloadSession(id: id)
            }
        }
        .onAppear {
            if sortOrder.isEmpty { sortOrder = [ KeyPathComparator(\Session.modifiedAt, order: .reverse) ] }
        }
        .onChange(of: unified.includeCodex) { _, _ in restartSearchIfRunning() }
        .onChange(of: unified.includeClaude) { _, _ in restartSearchIfRunning() }
        .onChange(of: unified.includeGemini) { _, _ in restartSearchIfRunning() }
        .onChange(of: unified.includeOpenCode) { _, _ in restartSearchIfRunning() }
        .onChange(of: codexAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
        .onChange(of: claudeAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
        .onChange(of: geminiAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
        .onChange(of: openCodeAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
        .onReceive(unified.$sessions) { sessions in
            if !sessions.isEmpty {
                hasEverHadSessions = true
            }
        }
    }

    private var listPane: some View {
        let showTitle = columnVisibility.showTitleColumn
        let showModified = columnVisibility.showModifiedColumn
        let showProject = columnVisibility.showProjectColumn
        let showMsgs = columnVisibility.showMsgsColumn
        return ZStack(alignment: .bottom) {
        Table(cachedRows, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("★") { cellFavorite(for: $0) }
                .width(min: showStarColumn ? 36 : 0,
                       ideal: showStarColumn ? 40 : 0,
                       max: showStarColumn ? 44 : 0)

            TableColumn("CLI Agent", value: \Session.sourceKey) { cellSource(for: $0) }
                .width(min: showSourceColumn ? 90 : 0,
                       ideal: showSourceColumn ? 100 : 0,
                       max: showSourceColumn ? 120 : 0)

            TableColumn("Session", value: \Session.title) { s in
                SessionTitleCell(session: s, geminiIndexer: geminiIndexer)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Explicitly select the tapped row to avoid relying solely on Table's mouse handling.
                        selection = s.id
                        let desired: Set<String> = [s.id]
                        if tableSelection != desired {
                            programmaticSelectionUpdate = true
                            tableSelection = desired
                            DispatchQueue.main.async { programmaticSelectionUpdate = false }
                        }
                        hasUserManuallySelected = true
                        autoSelectEnabled = false
                        NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
                    }
            }
            .width(min: showTitle ? 160 : 0,
                   ideal: showTitle ? 320 : 0,
                   max: showTitle ? 2000 : 0)

            TableColumn("Date", value: \Session.modifiedAt) { s in
                let display = SessionIndexer.ModifiedDisplay(rawValue: modifiedDisplayRaw) ?? .relative
                let primary = (display == .relative) ? s.modifiedRelative : absoluteTimeUnified(s.modifiedAt)
                let helpText = (display == .relative) ? absoluteTimeUnified(s.modifiedAt) : s.modifiedRelative
                Text(primary)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(helpText)
            }
            .width(min: showModified ? 120 : 0,
                   ideal: showModified ? 120 : 0,
                   max: showModified ? 140 : 0)

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
            .width(min: showProject ? 120 : 0,
                   ideal: showProject ? 160 : 0,
                   max: showProject ? 240 : 0)

            TableColumn("Msgs", value: \Session.messageCount) { s in
                Text(String(s.messageCount))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
            }
            .width(min: showMsgs ? 64 : 0,
                   ideal: showMsgs ? 64 : 0,
                   max: showMsgs ? 80 : 0)

            // File size column
            TableColumn("Size") { s in
                let display: String = {
                    if let b = s.fileSizeBytes { return formattedSize(b) }
                    return "—"
                }()
                Text(display)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: showSizeColumn ? 72 : 0, ideal: showSizeColumn ? 80 : 0, max: showSizeColumn ? 100 : 0)

            // Removed separate Refresh column to avoid churn
        }
        .id(columnLayoutID)
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
                if s.source == .codex || s.source == .claude {
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
                // Git Context Inspector (Codex + Claude; feature-flagged)
                if isGitInspectorEnabled, (s.source == .codex || s.source == .claude) {
                    Divider()
                    Button("Show Git Context") { showGitInspector(s) }
                        .help("Show historical and current git context with safety analysis")
                }
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
            // Allow empty selection when user clicks whitespace; do not force reselection.
            selection = newSel.first
            if !programmaticSelectionUpdate {
                // User interacted with the table; mark as manually selected
                hasUserManuallySelected = true
                autoSelectEnabled = false
            }
            if !programmaticSelectionUpdate {
                NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
            }
        }
        .onChange(of: unified.sessions) { _, _ in
            // Update cached rows first, then reconcile selection so auto-select uses fresh data.
            updateCachedRows()
            updateSelectionBridge()
        }
        .onChange(of: columnVisibility.changeToken) { _, _ in refreshColumnLayout() }
        .onChange(of: showSourceColumn) { _, _ in refreshColumnLayout() }
        .onChange(of: showSizeColumn) { _, _ in refreshColumnLayout() }
        .onChange(of: showStarColumn) { _, _ in refreshColumnLayout() }
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

    // MARK: - Git Inspector Integration (Unified View)
    private var isGitInspectorEnabled: Bool {
        let flagEnabled = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableGitInspector)
        if flagEnabled { return true }
        if let env = ProcessInfo.processInfo.environment["AGENTSESSIONS_FEATURES"], env.contains("gitInspector") { return true }
        return false
    }

    private func showGitInspector(_ session: Session) {
        GitInspectorWindowController.shared.show(for: session) { resumed in
            // Reuse existing resume pipeline for Codex/Claude as appropriate
            self.resume(resumed)
        }
    }

    private var transcriptPane: some View {
        ZStack {
            // Base host is always mounted to keep a stable split subview identity
            TranscriptHostView(kind: selectedSession?.source ?? .codex,
                               selection: selection,
                               codexIndexer: codexIndexer,
                               claudeIndexer: claudeIndexer,
                               geminiIndexer: geminiIndexer,
                               opencodeIndexer: opencodeIndexer)
                .environmentObject(focusCoordinator)
                .id("transcript-host")

            if shouldShowLaunchOverlay {
                launchBlockingTranscriptOverlay()
            } else if let s = selectedSession {
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
                Text("Select a session to view transcript")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
        })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 2) {
                if codexAgentEnabled {
                    Toggle(isOn: $unified.includeCodex) {
                        Text("Codex")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeCodex ? Color.blue : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Codex sessions in the list (⌘1)")
                    .keyboardShortcut("1", modifiers: .command)
                }

                if claudeAgentEnabled {
                    Toggle(isOn: $unified.includeClaude) {
                        Text("Claude")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeClaude ? Color(red: 204/255, green: 121/255, blue: 90/255) : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Claude sessions in the list (⌘2)")
                    .keyboardShortcut("2", modifiers: .command)
                }

                if geminiAgentEnabled {
                    Toggle(isOn: $unified.includeGemini) {
                        Text("Gemini")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeGemini ? Color.teal : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Gemini sessions in the list (⌘3)")
                    .keyboardShortcut("3", modifiers: .command)
                }

                if openCodeAgentEnabled {
                    Toggle(isOn: $unified.includeOpenCode) {
                        Text("OpenCode")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeOpenCode ? Color.purple : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide OpenCode sessions in the list (⌘4)")
                    .keyboardShortcut("4", modifiers: .command)
                }
            }
        }
        ToolbarItem(placement: .automatic) {
            UnifiedSearchFiltersView(unified: unified, search: searchCoordinator, focus: focusCoordinator)
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $unified.showFavoritesOnly) {
                Label("Favorites", systemImage: unified.showFavoritesOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .disabled(!showStarColumn)
            .help(showStarColumn ? "Show only favorited sessions" : "Enable star column in Preferences to use favorites")
        }
        ToolbarItem(placement: .automatic) {
            AnalyticsButtonView(
                isReady: analyticsReady,
                disabledReason: analyticsDisabledReason,
                onWarmupTap: handleAnalyticsWarmupTap
            )
        }
        ToolbarItemGroup(placement: .automatic) {
            Button(action: { if let s = selectedSession { resume(s) } }) {
                Label("Resume", systemImage: "play.circle")
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(selectedSession == nil || !(selectedSession?.source == .codex || selectedSession?.source == .claude))
            .help("Resume the selected Codex or Claude session in its original CLI (⌃⌘R). Gemini and OpenCode sessions are read-only.")

            Button(action: { if let s = selectedSession { openDir(s) } }) { Label("Open Working Directory", systemImage: "folder") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(selectedSession == nil)
                .help("Reveal the selected session's working directory in Finder (⌘⇧O)")

            if isGitInspectorEnabled {
                Button(action: { if let s = selectedSession { showGitInspector(s) } }) { Label("Git Context", systemImage: "clock.arrow.circlepath") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(selectedSession == nil)
                    .help("Show historical and current git context with safety analysis (⌘⇧G)")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { unified.refresh() }) {
                if unified.isIndexing || unified.isProcessingTranscripts {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
                .keyboardShortcut("r", modifiers: .command)
                .help("Re-run the session indexer to discover new logs (⌘R)")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { onToggleLayout() }) {
                Image(systemName: layoutMode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
            }
            .keyboardShortcut("l", modifiers: .command)
            .help("Toggle between vertical and horizontal layout modes (⌘L)")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { PreferencesWindowController.shared.show(indexer: codexIndexer, updaterController: updaterController) }) {
                Image(systemName: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Open preferences for appearance, indexing, and agents (⌘,)")
        }
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
        // Auto-select first row when sessions become available and user hasn't manually selected
        if !hasUserManuallySelected, let first = cachedRows.first, selection == nil {
            selection = first.id
        }
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
        // If current selection disappeared from list, auto-select first row
        if let sel = selection, !cachedRows.contains(where: { $0.id == sel }) {
            selection = cachedRows.first?.id
            tableSelection = selection.map { [$0] } ?? []
        }
    }

    private func refreshColumnLayout() {
        columnLayoutID = UUID()
        updateCachedRows()
        updateSelectionBridge()
    }

    private func handleAnalyticsWarmupTap() {
        if showAnalyticsWarmupNotice { return }
        withAnimation { showAnalyticsWarmupNotice = true }
        // Auto-dismiss after a short delay so the notice stays lightweight.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { showAnalyticsWarmupNotice = false }
        }
    }

    private var analyticsDisabledReason: String? {
        if !analyticsReady {
            return "Analytics warming up…"
        }
        return nil
    }

    @ViewBuilder
    private func launchBlockingTranscriptOverlay() -> some View {
        launchAnimationView
            .allowsHitTesting(false)
    }

    private var shouldShowLaunchOverlay: Bool {
        unified.sessions.isEmpty && !hasEverHadSessions
    }

    private var launchAnimationView: some View {
        LoadingAnimationView(
            codexColor: Color.agentColor(for: .codex, monochrome: stripMonochrome),
            claudeColor: Color.agentColor(for: .claude, monochrome: stripMonochrome)
        )
    }

    @ViewBuilder
    private func cellFavorite(for session: Session) -> some View {
        if showStarColumn {
            Button(action: { unified.toggleFavorite(session.id) }) {
                Image(systemName: session.isFavorite ? "star.fill" : "star")
                    .imageScale(.medium)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help(session.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(session.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        } else {
            EmptyView()
        }
    }

    private func cellSource(for session: Session) -> some View {
        let label: String
        switch session.source {
        case .codex: label = "Codex"
        case .claude: label = "Claude"
        case .gemini: label = "Gemini"
        case .opencode: label = "OpenCode"
        }
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(!stripMonochrome ? sourceAccent(session) : .secondary)
            Spacer(minLength: 4)
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
                                includeCodex: unified.includeCodex && codexAgentEnabled,
                                includeClaude: unified.includeClaude && claudeAgentEnabled,
                                includeGemini: unified.includeGemini && geminiAgentEnabled,
                                includeOpenCode: unified.includeOpenCode && openCodeAgentEnabled,
                                all: unified.allSessions)
    }

    private func flashAgentEnablementNoticeIfNeeded() {
        let anyDisabled = !(codexAgentEnabled && claudeAgentEnabled && geminiAgentEnabled && openCodeAgentEnabled)
        guard anyDisabled else {
            withAnimation { showAgentEnablementNotice = false }
            return
        }

        withAnimation { showAgentEnablementNotice = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { showAgentEnablementNotice = false }
        }
    }

    private func sourceAccent(_ s: Session) -> Color {
        switch s.source {
        case .codex: return Color.blue
        case .claude: return Color(red: 204/255, green: 121/255, blue: 90/255)
        case .gemini: return Color.teal
        case .opencode: return Color.purple
        }
    }

    private func progressLineText(_ p: SearchCoordinator.Progress) -> String {
        switch p.phase {
        case .idle:
            return "Searching…"
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
    @ObservedObject var opencodeIndexer: OpenCodeSessionIndexer

    var body: some View {
        ZStack { // keep one stable container to avoid split reset
            TranscriptPlainView(sessionID: selection)
                .environmentObject(codexIndexer)
                .opacity(kind == .codex ? 1 : 0)
            ClaudeTranscriptView(indexer: claudeIndexer, sessionID: selection)
                .opacity(kind == .claude ? 1 : 0)
            GeminiTranscriptView(indexer: geminiIndexer, sessionID: selection)
                .opacity(kind == .gemini ? 1 : 0)
            OpenCodeTranscriptView(indexer: opencodeIndexer, sessionID: selection)
                .opacity(kind == .opencode ? 1 : 0)
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
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
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
                .background((stripMonochrome ? Color.secondary : Color.blue).opacity(0.1))
                .background(RoundedRectangle(cornerRadius: 6).stroke((stripMonochrome ? Color.secondary : Color.blue).opacity(0.3)))
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
                     includeOpenCode: unified.includeOpenCode,
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
                         includeOpenCode: unified.includeOpenCode,
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

// MARK: - Analytics Button

private struct AnalyticsButtonView: View {
    let isReady: Bool
    let disabledReason: String?
    let onWarmupTap: () -> Void

    // Access via app-level notification instead of environment
    var body: some View {
        Button(action: {
            if isReady {
                NotificationCenter.default.post(name: .toggleAnalytics, object: nil)
            } else {
                onWarmupTap()
            }
        }) {
            HStack(spacing: 6) {
                if !isReady {
                    ProgressView()
                        .controlSize(.mini)
                }
                Label("Analytics", systemImage: "chart.bar.xaxis")
            }
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("k", modifiers: .command)
        // Keep pressable; communicate readiness instead of disabling.
        .help(helpText)
    }

    private var helpText: String {
        if isReady { return "View usage analytics (⌘K)" }
        return disabledReason ?? "Analytics warming up – results will appear once indexing finishes."
    }
}

// Notification for Analytics toggle
private extension Notification.Name {
    static let toggleAnalytics = Notification.Name("ToggleAnalyticsWindow")
}

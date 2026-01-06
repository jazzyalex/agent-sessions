import SwiftUI
import AppKit

private extension Notification.Name {
    static let collapseInlineSearchIfEmpty = Notification.Name("UnifiedSessionsCollapseInlineSearchIfEmpty")
}

private enum UnifiedSessionsStyle {
    static let selectionAccent = Color(hex: "007acc")
    static let timestampColor = Color(hex: "8E8E93")
}

struct UnifiedSessionsView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @ObservedObject var codexIndexer: SessionIndexer
    @ObservedObject var claudeIndexer: ClaudeSessionIndexer
    @ObservedObject var geminiIndexer: GeminiSessionIndexer
    @ObservedObject var opencodeIndexer: OpenCodeSessionIndexer
    @ObservedObject var copilotIndexer: CopilotSessionIndexer
    @ObservedObject var droidIndexer: DroidSessionIndexer
    @EnvironmentObject var codexUsageModel: CodexUsageModel
    @EnvironmentObject var claudeUsageModel: ClaudeUsageModel
    @EnvironmentObject var updaterController: UpdaterController
    @EnvironmentObject var columnVisibility: ColumnVisibilityStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme

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
	@AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
	@AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = SessionIndexer.ModifiedDisplay.relative.rawValue
	@AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
	@AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled: Bool = false
	@AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled: Bool = false
	@AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.geminiEnabled) private var geminiAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.copilotEnabled) private var copilotAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.droidEnabled) private var droidAgentEnabled: Bool = true
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
        let q = unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty || searchCoordinator.isRunning {
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
         copilotIndexer: CopilotSessionIndexer,
         droidIndexer: DroidSessionIndexer,
         analyticsReady: Bool,
         layoutMode: LayoutMode,
         onToggleLayout: @escaping () -> Void) {
        self.unified = unified
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.geminiIndexer = geminiIndexer
        self.opencodeIndexer = opencodeIndexer
        self.copilotIndexer = copilotIndexer
        self.droidIndexer = droidIndexer
        self.analyticsReady = analyticsReady
        self.layoutMode = layoutMode
        self.onToggleLayout = onToggleLayout
        let store = SearchSessionStore(adapters: [
            .codex: .init(
                transcriptCache: codexIndexer.searchTranscriptCache,
                update: { codexIndexer.updateSession($0) },
                parseFull: { url, forcedID in codexIndexer.parseFileFull(at: url, forcedID: forcedID) }
            ),
            .claude: .init(
                transcriptCache: claudeIndexer.searchTranscriptCache,
                update: { claudeIndexer.updateSession($0) },
                parseFull: { url, forcedID in ClaudeSessionParser.parseFileFull(at: url, forcedID: forcedID) }
            ),
            .gemini: .init(
                transcriptCache: geminiIndexer.searchTranscriptCache,
                update: { geminiIndexer.updateSession($0) },
                parseFull: { url, forcedID in GeminiSessionParser.parseFileFull(at: url, forcedID: forcedID) }
            ),
            .opencode: .init(
                transcriptCache: opencodeIndexer.searchTranscriptCache,
                update: { opencodeIndexer.updateSession($0) },
                parseFull: { url, _ in OpenCodeSessionParser.parseFileFull(at: url) }
            ),
            .copilot: .init(
                transcriptCache: copilotIndexer.searchTranscriptCache,
                update: { copilotIndexer.updateSession($0) },
                parseFull: { url, forcedID in CopilotSessionParser.parseFileFull(at: url, forcedID: forcedID) }
            ),
            .droid: .init(
                transcriptCache: droidIndexer.searchTranscriptCache,
                update: { droidIndexer.updateSession($0) },
                parseFull: { url, forcedID in DroidSessionParser.parseFileFull(at: url, forcedID: forcedID) }
            ),
        ])
        _searchCoordinator = StateObject(wrappedValue: SearchCoordinator(store: store))
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppAppearance(rawValue: appAppearanceRaw) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

	var body: some View {
		let base = AnyView(
			rootContent
				.preferredColorScheme(preferredColorScheme)
				.toolbar { toolbarContent }
				.overlay(alignment: .topTrailing) { topTrailingNotices }
		)

		let lifecycle = AnyView(
			base
				.onAppear {
					updateFooterUsageVisibility()
					if sortOrder.isEmpty { sortOrder = [KeyPathComparator(\Session.modifiedAt, order: .reverse)] }
					updateCachedRows()
					updateSelectionBridge()
				}
				.onDisappear {
					codexUsageModel.setStripVisible(false)
					claudeUsageModel.setStripVisible(false)
				}
		)

		return AnyView(
			lifecycle
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
					} else if s.source == .copilot, let exist = copilotIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
						copilotIndexer.reloadSession(id: id)
					} else if s.source == .droid, let exist = droidIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
						droidIndexer.reloadSession(id: id)
					}
				}
				.onChange(of: unified.includeCodex) { _, _ in restartSearchIfRunning() }
				.onChange(of: unified.includeClaude) { _, _ in restartSearchIfRunning() }
				.onChange(of: unified.includeGemini) { _, _ in restartSearchIfRunning() }
				.onChange(of: unified.includeOpenCode) { _, _ in restartSearchIfRunning() }
				.onChange(of: unified.includeCopilot) { _, _ in restartSearchIfRunning() }
				.onChange(of: unified.includeDroid) { _, _ in restartSearchIfRunning() }
				.onChange(of: codexUsageEnabled) { _, _ in updateFooterUsageVisibility() }
				.onChange(of: claudeUsageEnabled) { _, _ in updateFooterUsageVisibility() }
				.onChange(of: codexAgentEnabled) { _, _ in
					flashAgentEnablementNoticeIfNeeded()
					updateFooterUsageVisibility()
				}
				.onChange(of: claudeAgentEnabled) { _, _ in
					flashAgentEnablementNoticeIfNeeded()
					updateFooterUsageVisibility()
				}
				.onChange(of: geminiAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
				.onChange(of: openCodeAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
				.onChange(of: copilotAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
				.onReceive(unified.$sessions) { sessions in
					if !sessions.isEmpty {
						hasEverHadSessions = true
					}
				}
					.onReceive(NotificationCenter.default.publisher(for: .openSessionsSearchFromMenu)) { _ in
						// Force a focus transition even if Search is already active so the menu action
						// reliably focuses the search field.
						focusCoordinator.perform(.closeAllSearch)
						focusCoordinator.perform(.openSessionSearch)
					}
				.onReceive(NotificationCenter.default.publisher(for: .openTranscriptFindFromMenu)) { _ in
					focusCoordinator.perform(.openTranscriptFind)
				}
		)
	}

	private var topTrailingNotices: some View {
		VStack(alignment: .trailing, spacing: 8) {
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
				.transition(.move(edge: .top).combined(with: .opacity))
			}
			if showAgentEnablementNotice {
				Text("Showing active agents only")
					.font(.footnote)
					.padding(10)
					.background(.regularMaterial)
					.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
					.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.padding(.top, 8)
		.padding(.trailing, 8)
	}

	    private var rootContent: some View {
	        VStack(spacing: 0) {
	            // Cap ETA banner disabled (calculations retained; UI disabled)
	            mainSplitView
	            cockpitFooter
	        }
	    }

	    @ViewBuilder
	    private var mainSplitView: some View {
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
	    }

	    private var cockpitFooter: some View {
	        CockpitFooterView(
	            isBusy: footerIsBusy,
	            statusText: footerStatusText,
	            quotas: footerQuotas,
	            sessionCountText: footerSessionCountText,
	            freshnessText: footerFreshnessText
	        )
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
                    .foregroundStyle(UnifiedSessionsStyle.timestampColor)
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
                    .foregroundStyle(.secondary)
            }
            .width(min: showMsgs ? 64 : 0,
                   ideal: showMsgs ? 64 : 0,
                   max: showMsgs ? 80 : 0)

            // File size column
            TableColumn("Size", value: \Session.fileSizeSortKey) { s in
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
            .tint(UnifiedSessionsStyle.selectionAccent)
	        .environment(\.defaultMinListRowHeight, 26)
		        .simultaneousGesture(TapGesture().onEnded {
		            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
		        })
		        }
		        .contextMenu(forSelectionType: String.self) { ids in
		            if ids.count == 1, let id = ids.first, let s = cachedRows.first(where: { $0.id == id }) {
		                Button(s.isFavorite ? "Remove from Saved" : "Save") { unified.toggleFavorite(s) }
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
                else if first.keyPath == \Session.fileSizeSortKey { key = .size }
                else if first.keyPath == \Session.sourceKey { key = .agent }
                else if first.keyPath == \Session.title { key = .title }
                else { key = .title }
                unified.sortDescriptor = .init(key: key, ascending: first.order == .forward)
                unified.recomputeNow()
            }
            updateSelectionBridge()
            updateCachedRows()
        }
        .onChange(of: tableSelection) { oldSel, newSel in
            // Allow empty selection when user clicks whitespace; do not force reselection.
            selection = newSel.first

            if programmaticSelectionUpdate { return }

            // SwiftUI Table sometimes emits an initial "empty selection" change during mount.
            // Do not treat that as user interaction or it disables initial auto-select.
            if oldSel.isEmpty, newSel.isEmpty { return }

            // User interacted with the table; mark as manually selected
            hasUserManuallySelected = true
            autoSelectEnabled = false
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
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

	    private var footerIsBusy: Bool {
	        unified.isIndexing
	        || unified.isProcessingTranscripts
	        || searchCoordinator.isRunning
	        || unified.launchState.overallPhase < .ready
	    }

	    private var footerStatusText: String {
	        if unified.launchState.overallPhase < .ready {
	            return unified.launchState.overallPhase.statusDescription
	        }
	        if unified.isIndexing || unified.isProcessingTranscripts {
	            return unified.isProcessingTranscripts ? "Processing sessions…" : "Indexing sessions…"
	        }
	        if searchCoordinator.isRunning {
	            return "Searching…"
	        }
	        return ""
	    }

	    private var footerSessionCountText: String {
	        let visible = cachedRows.count
	        let total = unified.sessions.count
	        if visible != total {
	            return "\(visible) / \(total) Sessions"
	        }
	        return "\(total) Sessions"
	    }

	    private var footerFreshnessText: String? {
	        let date = unified.sessions.map(\.modifiedAt).max() ?? cachedRows.map(\.modifiedAt).max()
	        guard let date else { return nil }
	        return "Last: \(timeAgoShort(date))"
	    }

	    private func timeAgoShort(_ date: Date, now: Date = Date()) -> String {
	        let seconds = max(0, now.timeIntervalSince(date))
	        if seconds < 60 { return "<1m ago" }
	        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
	        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
	        return "\(Int(seconds / 86400))d ago"
	    }

	    private var footerQuotas: [QuotaData] {
	        var out: [QuotaData] = []
	        if codexAgentEnabled && codexUsageEnabled {
	            out.append(.codex(from: codexUsageModel))
	        }
	        if claudeAgentEnabled && claudeUsageEnabled {
	            out.append(.claude(from: claudeUsageModel))
	        }
	        return out
	    }

	    @MainActor
	    private func updateFooterUsageVisibility() {
	        codexUsageModel.setStripVisible(codexAgentEnabled && codexUsageEnabled)
	        claudeUsageModel.setStripVisible(claudeAgentEnabled && claudeUsageEnabled)
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
                               opencodeIndexer: opencodeIndexer,
                               copilotIndexer: copilotIndexer,
                               droidIndexer: droidIndexer)
                .environmentObject(focusCoordinator)
                .id("transcript-host")

            if shouldShowLaunchOverlay {
                launchBlockingTranscriptOverlay()
            } else if let s = selectedSession {
                if !FileManager.default.fileExists(atPath: s.filePath) {
                    let providerName: String = {
                        switch s.source {
                        case .codex: return "Codex"
                        case .claude: return "Claude"
                        case .gemini: return "Gemini"
                        case .opencode: return "OpenCode"
                        case .copilot: return "Copilot"
                        case .droid: return "Droid"
                        }
                    }()
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
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeCodex ? Color.agentCodex : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Codex sessions in the list (⌘1)")
                    .keyboardShortcut("1", modifiers: .command)
                }

                if claudeAgentEnabled {
                    Toggle(isOn: $unified.includeClaude) {
                        Text("Claude")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeClaude ? Color.agentClaude : .primary))
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

                if copilotAgentEnabled {
                    Toggle(isOn: $unified.includeCopilot) {
                        Text("Copilot")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeCopilot ? Color.agentCopilot : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Copilot sessions in the list (⌘5)")
                    .keyboardShortcut("5", modifiers: .command)
                }

                if droidAgentEnabled {
                    Toggle(isOn: $unified.includeDroid) {
                        Text("Droid")
                            .foregroundStyle(stripMonochrome ? .primary : (unified.includeDroid ? Color.agentDroid : .primary))
                            .fixedSize()
                    }
                    .toggleStyle(.button)
                    .help("Show or hide Droid sessions in the list (⌘6)")
                    .keyboardShortcut("6", modifiers: .command)
                }
            }
            .tint(UnifiedSessionsStyle.selectionAccent)
        }
        ToolbarItem(placement: .automatic) {
            UnifiedSearchFiltersView(unified: unified, search: searchCoordinator, focus: focusCoordinator)
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $unified.showFavoritesOnly) {
                Label("Saved", systemImage: unified.showFavoritesOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .disabled(!showStarColumn)
            .help(showStarColumn ? "Show only saved sessions" : "Enable the Save column in Preferences to use saved sessions")
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
            .help("Resume the selected Codex or Claude session in its original CLI (⌃⌘R). Gemini, OpenCode, and Copilot sessions are read-only.")

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
            let current = AppAppearance(rawValue: appAppearanceRaw) ?? .system
            let effective = current.effectiveColorScheme(systemScheme: systemColorScheme)
            let next = current.toggledDarkLight(systemScheme: systemColorScheme)
            Button(action: { codexIndexer.setAppearance(next) }) {
                Label("Toggle Dark/Light", systemImage: (effective == .dark) ? "sun.max" : "moon")
                    .labelStyle(.iconOnly)
            }
            .help((effective == .dark) ? "Switch to Light Mode" : "Switch to Dark Mode")
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
        return AppDateFormatting.dateTimeShort(date)
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
            let desired: Set<String> = selection.map { [$0] } ?? []
            if tableSelection != desired {
                programmaticSelectionUpdate = true
                tableSelection = desired
                DispatchQueue.main.async { programmaticSelectionUpdate = false }
            }
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
            Button(action: { unified.toggleFavorite(session) }) {
                Image(systemName: session.isFavorite ? "star.fill" : "star")
                    .imageScale(.medium)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help(starHelpText(isStarred: session.isFavorite))
            .accessibilityLabel(session.isFavorite ? "Remove from Saved" : "Save")
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
        case .copilot: label = "Copilot"
        case .droid: label = "Droid"
        }
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
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
        let q = unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchCoordinator.cancel(); return }
        let filters = Filters(query: q,
                              dateFrom: unified.dateFrom,
                              dateTo: unified.dateTo,
                              model: unified.selectedModel,
                              kinds: unified.selectedKinds,
                              repoName: unified.projectFilter,
                              pathContains: nil)
        searchCoordinator.start(query: q,
                                filters: filters,
                                includeCodex: unified.includeCodex && codexAgentEnabled,
                                includeClaude: unified.includeClaude && claudeAgentEnabled,
                                includeGemini: unified.includeGemini && geminiAgentEnabled,
                                includeOpenCode: unified.includeOpenCode && openCodeAgentEnabled,
                                includeCopilot: unified.includeCopilot && copilotAgentEnabled,
                                includeDroid: unified.includeDroid && droidAgentEnabled,
                                all: unified.allSessions)
    }

    private func flashAgentEnablementNoticeIfNeeded() {
        let anyDisabled = !(codexAgentEnabled && claudeAgentEnabled && geminiAgentEnabled && openCodeAgentEnabled && copilotAgentEnabled && droidAgentEnabled)
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
        case .codex: return Color.agentCodex
        case .claude: return Color.agentClaude
        case .gemini: return Color.teal
        case .opencode: return Color.purple
        case .copilot: return Color.agentCopilot
        case .droid: return Color.agentDroid
        }
    }

	    private func progressLineText(_ p: SearchCoordinator.Progress) -> String {
	        switch p.phase {
	        case .idle:
	            return "Searching…"
	        case .indexed:
	            return "Searching indexed text…"
	        case .legacySmall:
	            return "Scanning sessions… \(p.scannedSmall)/\(p.totalSmall)"
	        case .legacyLarge:
	            return "Scanning sessions (large)… \(p.scannedLarge)/\(p.totalLarge)"
	        case .unindexedSmall:
	            return "Searching sessions not indexed yet… \(p.scannedSmall)/\(p.totalSmall)"
	        case .unindexedLarge:
	            return "Searching sessions not indexed yet (large)… \(p.scannedLarge)/\(p.totalLarge)"
	        case .toolOutputsSmall:
	            return "Searching full tool outputs… \(p.scannedSmall)/\(p.totalSmall)"
	        case .toolOutputsLarge:
	            return "Searching large tool outputs… \(p.scannedLarge)/\(p.totalLarge)"
	        }
	    }

    private func starHelpText(isStarred: Bool) -> String {
        let pins = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
        let unstarRemoves = UserDefaults.standard.bool(forKey: PreferencesKey.Archives.unstarRemovesArchive)
        if isStarred {
            if pins && unstarRemoves { return "Remove from Saved (deletes local copy)" }
            if pins { return "Remove from Saved (keeps local copy)" }
            return "Remove from Saved"
        } else {
            return pins ? "Save (keeps locally)" : "Save"
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
    @ObservedObject var copilotIndexer: CopilotSessionIndexer
    @ObservedObject var droidIndexer: DroidSessionIndexer

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
            CopilotTranscriptView(indexer: copilotIndexer, sessionID: selection)
                .opacity(kind == .copilot ? 1 : 0)
            DroidTranscriptView(indexer: droidIndexer, sessionID: selection)
                .opacity(kind == .droid ? 1 : 0)
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
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .background(Color.clear)
            if session.source == .gemini, geminiIndexer.isPreviewStale(id: session.id) {
                Button(action: { geminiIndexer.refreshPreview(id: session.id) }) {
                    Text("Refresh")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
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

// Stable cell to prevent Table reuse glitches in Project column
private struct ProjectCellView: View {
    let id: String
    let display: String
    var body: some View {
        Text(display)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
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
    @State private var searchDebouncer: DispatchWorkItem? = nil
    @State private var focusRequestToken: Int = 0
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    private enum SearchFocusTarget: Hashable { case field, clear }
    var body: some View {
        HStack(spacing: 8) {
            // Inline search field (always visible to keep global search front-and-center)
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
                                       focusRequestToken: focusRequestToken,
                                       onCommit: { startSearchImmediate() })
                    .frame(minWidth: 220)

                if unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("⌥⌘F")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Button(action: {
                        unified.queryDraft = ""
                        unified.query = ""
                        unified.recomputeNow()
                        search.cancel()
                        searchFocus = nil
                    }) {
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
            .help("Search sessions (⌥⌘F)")
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
            .onChange(of: focus.activeFocus) { _, newFocus in
                if newFocus == .sessionSearch {
                    requestSearchFocus()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSessionsSearchFromMenu)) { _ in
                requestSearchFocus()
            }

            // Preserve the keyboard shortcut binding even though the search box is always visible.
            Button(action: {
                focus.perform(.closeAllSearch)
                focus.perform(.openSessionSearch)
                requestSearchFocus()
            }) { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0.001)
                .frame(width: 1, height: 1)

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
                .background((stripMonochrome ? Color.secondary : UnifiedSessionsStyle.selectionAccent).opacity(0.1))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke((stripMonochrome ? Color.secondary : UnifiedSessionsStyle.selectionAccent).opacity(0.3))
                )
            }
        }
    }

    private func requestSearchFocus() {
        focusRequestToken &+= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            searchFocus = .field
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
                     includeCopilot: unified.includeCopilot,
                     includeDroid: unified.includeDroid,
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
                         includeCopilot: unified.includeCopilot,
                         includeDroid: unified.includeDroid,
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
    var focusRequestToken: Int
    var onCommit: () -> Void

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ToolbarSearchTextField
        var didRequestFocus: Bool = false
        var lastFocusRequestToken: Int = 0
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
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        if tf.placeholderString != placeholder { tf.placeholderString = placeholder }
        if focusRequestToken != context.coordinator.lastFocusRequestToken {
            context.coordinator.lastFocusRequestToken = focusRequestToken
            context.coordinator.didRequestFocus = false
            requestFocus(tf, coordinator: context.coordinator)
        } else if isFirstResponder {
            // `NSTextField` becomes first responder via a field editor, so we can't reliably compare
            // against `window.firstResponder`. Instead, request focus once when asked.
            if !context.coordinator.didRequestFocus {
                requestFocus(tf, coordinator: context.coordinator)
            }
        } else {
            context.coordinator.didRequestFocus = false
        }
    }

    private func requestFocus(_ tf: NSTextField, coordinator: Coordinator) {
        coordinator.didRequestFocus = true
        DispatchQueue.main.async { [weak tf] in
            guard let tf, let window = tf.window else { return }
            _ = window.makeFirstResponder(tf)
        }
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

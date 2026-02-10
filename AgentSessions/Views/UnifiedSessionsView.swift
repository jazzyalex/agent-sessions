import SwiftUI
import AppKit

private extension Notification.Name {
    static let collapseInlineSearchIfEmpty = Notification.Name("UnifiedSessionsCollapseInlineSearchIfEmpty")
}

private enum UnifiedSessionsStyle {
    static let selectionAccent = Color(hex: "007acc")
    static let timestampColor = Color(hex: "8E8E93")
    static let agentPillFill = Color(nsColor: .controlBackgroundColor)
    static let agentPillStroke = Color(nsColor: .separatorColor).opacity(0.35)
    static let agentTabFont = Font.system(size: 12, weight: .medium)
    static let agentDotSize: CGFloat = 8
    static let toolbarGroupSpacing: CGFloat = 12
    static let toolbarItemSpacing: CGFloat = 4
    static let toolbarButtonSize: CGFloat = 32
    static let toolbarIconSize: CGFloat = 16
    static let toolbarButtonCornerRadius: CGFloat = 8
    static let toolbarHoverOpacity: Double = 0.06
    static let toolbarIconFont = Font.system(size: 16, weight: .semibold)
    static let toolbarFocusRingColor = Color(nsColor: .keyboardFocusIndicatorColor)
}

struct UnifiedSessionsView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @ObservedObject var codexIndexer: SessionIndexer
    @ObservedObject var claudeIndexer: ClaudeSessionIndexer
    @ObservedObject var geminiIndexer: GeminiSessionIndexer
    @ObservedObject var opencodeIndexer: OpenCodeSessionIndexer
    @ObservedObject var copilotIndexer: CopilotSessionIndexer
    @ObservedObject var droidIndexer: DroidSessionIndexer
    @ObservedObject var openclawIndexer: OpenClawSessionIndexer
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
    @AppStorage(PreferencesKey.Agents.openClawEnabled) private var openClawAgentEnabled: Bool = AgentEnablement.isAvailable(.openclaw)
    @State private var autoSelectEnabled: Bool = true
    @State private var programmaticSelectionUpdate: Bool = false
    @State private var isAutoSelectingFromSearch: Bool = false
    @State private var hasEverHadSessions: Bool = false
    @State private var hasUserManuallySelected: Bool = false
    @State private var showAnalyticsWarmupNotice: Bool = false
    @State private var showAgentEnablementNotice: Bool = false

    private enum SourceColorStyle: String, CaseIterable { case none, text, background } // deprecated
    private enum SelectionChangeSource { case mouse }

    @StateObject private var searchCoordinator: SearchCoordinator
    @StateObject private var focusCoordinator = WindowFocusCoordinator()
    @StateObject private var searchState = UnifiedSearchState()
    @State private var selectionChangeSource: SelectionChangeSource? = nil
    @State private var autoJumpWorkItem: DispatchWorkItem? = nil
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
         openclawIndexer: OpenClawSessionIndexer,
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
        self.openclawIndexer = openclawIndexer
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
            .openclaw: .init(
                transcriptCache: openclawIndexer.searchTranscriptCache,
                update: { openclawIndexer.updateSession($0) },
                parseFull: { url, forcedID in OpenClawSessionParser.parseFileFull(at: url, forcedID: forcedID) }
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

    private var effectiveColorScheme: ColorScheme {
        let current = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        return current.effectiveColorScheme(systemScheme: systemColorScheme)
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
                    unified.setAppActive(NSApp.isActive)
                    unified.setFocusedSession(selectedSession)
                    searchCoordinator.setAppActive(NSApp.isActive)
                }
                .onDisappear {
                    unified.setFocusedSession(nil)
                    unified.setAppActive(false)
                    codexUsageModel.setStripVisible(false)
                    claudeUsageModel.setStripVisible(false)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    unified.setAppActive(true)
                    searchCoordinator.setAppActive(true)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    unified.setAppActive(false)
                    searchCoordinator.setAppActive(false)
                }
		)

		let afterAnalytics = lifecycle
			.onChange(of: analyticsReady) { _, ready in
				if ready {
					withAnimation { showAnalyticsWarmupNotice = false }
				}
			}

		let afterSelection = afterAnalytics
			.onChange(of: selection) { _, id in
				handleSelectionChange(id)
			}

		let afterCodex = afterSelection
			.onChange(of: unified.includeCodex) { _, _ in restartSearchIfRunning() }
		let afterClaude = afterCodex
			.onChange(of: unified.includeClaude) { _, _ in restartSearchIfRunning() }
		let afterGemini = afterClaude
			.onChange(of: unified.includeGemini) { _, _ in restartSearchIfRunning() }
		let afterOpenCode = afterGemini
			.onChange(of: unified.includeOpenCode) { _, _ in restartSearchIfRunning() }
		let afterCopilot = afterOpenCode
			.onChange(of: unified.includeCopilot) { _, _ in restartSearchIfRunning() }
		let afterDroid = afterCopilot
			.onChange(of: unified.includeDroid) { _, _ in restartSearchIfRunning() }

		let afterOpenClaw = afterDroid
			.onChange(of: unified.includeOpenClaw) { _, _ in restartSearchIfRunning() }

		let afterUsage = afterOpenClaw
			.onChange(of: codexUsageEnabled) { _, _ in updateFooterUsageVisibility() }
			.onChange(of: claudeUsageEnabled) { _, _ in updateFooterUsageVisibility() }
			.onChange(of: searchState.query) { _, newValue in
				if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					cancelAutoJump()
				}
			}

		let afterAgents = afterUsage
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

		let afterSessions = afterAgents
			.onReceive(unified.$sessions) { sessions in
				if !sessions.isEmpty {
					hasEverHadSessions = true
				}
			}

		let afterSessionSearch = afterSessions
			.onReceive(NotificationCenter.default.publisher(for: .openSessionsSearchFromMenu)) { _ in
				// Force a focus transition even if Search is already active so the menu action
				// reliably focuses the search field.
				focusCoordinator.perform(.closeAllSearch)
				focusCoordinator.perform(.openSessionSearch)
			}

			let afterTranscriptFind = afterSessionSearch
				.onReceive(NotificationCenter.default.publisher(for: .openTranscriptFindFromMenu)) { _ in
					focusCoordinator.perform(.openTranscriptFind)
				}

		let afterNavigateFromImages = afterTranscriptFind
				.onReceive(NotificationCenter.default.publisher(for: .navigateToSessionFromImages)) { n in
					guard let id = n.object as? String else { return }
					let eventID = n.userInfo?["eventID"] as? String
					let userPromptIndex = n.userInfo?["userPromptIndex"] as? Int
					selection = id
					let desired: Set<String> = [id]
					if tableSelection != desired {
						programmaticSelectionUpdate = true
						tableSelection = desired
						DispatchQueue.main.async { programmaticSelectionUpdate = false }
					}
					CodexImagesWindowController.shared.sendToBack()
					NSApp.activate(ignoringOtherApps: true)
					if let main = NSApp.windows.first(where: { $0.isVisible && $0.title == "Agent Sessions" }) ?? NSApp.mainWindow {
						main.makeKeyAndOrderFront(nil)
					}
					DispatchQueue.main.async {
						var payload: [AnyHashable: Any] = [:]
						if let eventID, !eventID.isEmpty {
							payload["eventID"] = eventID
						} else if let userPromptIndex {
							payload["userPromptIndex"] = userPromptIndex
						} else {
							return
						}
						NotificationCenter.default.post(
							name: .navigateToSessionEventFromImages,
							object: id,
							userInfo: payload
						)
					}
				}

				let afterShowImages = afterNavigateFromImages
					.onReceive(NotificationCenter.default.publisher(for: .showImagesFromMenu)) { _ in
						showImagesForSelectedSession(showNoSelectionAlert: true)
					}

				let afterShowImagesForInlineImage = afterShowImages
					.onReceive(NotificationCenter.default.publisher(for: .showImagesForInlineImage)) { n in
							guard let id = n.object as? String else { return }
							let requestedItemID = n.userInfo?["selectedItemID"] as? String

							selection = id
							let desired: Set<String> = [id]
							if tableSelection != desired {
								programmaticSelectionUpdate = true
								tableSelection = desired
								DispatchQueue.main.async { programmaticSelectionUpdate = false }
							}

							guard let session = selectedSession else {
								NSSound.beep()
								return
							}
							let allSessions: [Session]
							allSessions = unified.allSessions
							CodexImagesWindowController.shared.show(session: session, allSessions: allSessions)

							guard let requestedItemID else { return }
							DispatchQueue.main.async {
								NotificationCenter.default.post(
									name: .selectImagesBrowserItem,
									object: id,
									userInfo: ["selectedItemID": requestedItemID, "forceScope": CodexImagesScope.singleSession.rawValue]
								)
							}
						}

				return AnyView(afterShowImagesForInlineImage)
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
                        selectionChangeSource = .mouse
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
	        .environment(\.defaultMinListRowHeight, 28)
		        .simultaneousGesture(TapGesture().onEnded {
		            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
		        })
		        }
		        .contextMenu(forSelectionType: String.self) { ids in
		            if ids.count == 1, let id = ids.first, let s = cachedRows.first(where: { $0.id == id }) {
		                Button(s.isFavorite ? "Remove from Saved" : "Save") { unified.toggleFavorite(s) }
		                Divider()
                if s.source == .codex || s.source == .claude {
                    Button("Resume in \(s.source == .codex ? "Codex CLI" : "Claude Code") (\(CodexLaunchMode.selectedResumeTerminalTitle()))") { resume(s) }
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
                Button("Copy Session ID") { copySessionID(id) }
                    .help("Copy the session ID to the clipboard")
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
                Button("Copy Session ID") {}
                    .disabled(true)
                    .help("Select exactly one session to copy its ID")
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
            unified.setFocusedSession(selectedSession)
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

    private func copySessionID(_ id: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(id, forType: .string)
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
                               droidIndexer: droidIndexer,
                               openclawIndexer: openclawIndexer)
                .environmentObject(focusCoordinator)
                .environmentObject(searchState)
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
                        case .openclaw: return "OpenClaw"
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
            HStack(spacing: 12) {
                if codexAgentEnabled {
                    AgentTabToggle(title: "Codex", color: Color.agentCodex, isMonochrome: stripMonochrome, isOn: $unified.includeCodex)
                        .help("Show or hide Codex sessions in the list (⌘1)")
                        .keyboardShortcut("1", modifiers: .command)
                }

                if claudeAgentEnabled {
                    AgentTabToggle(title: "Claude", color: Color.agentClaude, isMonochrome: stripMonochrome, isOn: $unified.includeClaude)
                        .help("Show or hide Claude sessions in the list (⌘2)")
                        .keyboardShortcut("2", modifiers: .command)
                }

                if geminiAgentEnabled {
                    AgentTabToggle(title: "Gemini", color: Color.teal, isMonochrome: stripMonochrome, isOn: $unified.includeGemini)
                        .help("Show or hide Gemini sessions in the list (⌘3)")
                        .keyboardShortcut("3", modifiers: .command)
                }

                if openCodeAgentEnabled {
                    AgentTabToggle(title: "OpenCode", color: Color.purple, isMonochrome: stripMonochrome, isOn: $unified.includeOpenCode)
                        .help("Show or hide OpenCode sessions in the list (⌘4)")
                        .keyboardShortcut("4", modifiers: .command)
                }

                if copilotAgentEnabled {
                    AgentTabToggle(title: "Copilot", color: Color.agentCopilot, isMonochrome: stripMonochrome, isOn: $unified.includeCopilot)
                        .help("Show or hide Copilot sessions in the list (⌘5)")
                        .keyboardShortcut("5", modifiers: .command)
                }

                if droidAgentEnabled {
                    AgentTabToggle(title: "Droid", color: Color.agentDroid, isMonochrome: stripMonochrome, isOn: $unified.includeDroid)
                        .help("Show or hide Droid sessions in the list (⌘6)")
                        .keyboardShortcut("6", modifiers: .command)
                }

                if openClawAgentEnabled {
                    AgentTabToggle(title: "OpenClaw", color: Color.agentOpenClaw, isMonochrome: stripMonochrome, isOn: $unified.includeOpenClaw)
                        .help("Show or hide OpenClaw sessions in the list (⌘7)")
                        .keyboardShortcut("7", modifiers: .command)
                }
            }
            .controlSize(.small)
            .tint(UnifiedSessionsStyle.selectionAccent)
        }
        ToolbarItem(placement: .automatic) {
            UnifiedSearchFiltersView(unified: unified, search: searchCoordinator, focus: focusCoordinator, searchState: searchState)
                .frame(maxWidth: 520)
        }
        if let projectFilter = unified.projectFilter, !projectFilter.isEmpty {
            ToolbarItem(placement: .automatic) {
                UnifiedProjectFilterBadgeView(unified: unified)
            }
        }
        ToolbarItemGroup(placement: .automatic) {
            ToolbarIconToggle(
                isOn: $unified.showFavoritesOnly,
                onSymbol: "star.fill",
                offSymbol: "star",
                help: showStarColumn ? "Show only saved sessions" : "Enable the Save column in Preferences to use saved sessions",
                activeColor: .primary
            )
            .disabled(!showStarColumn)

            AnalyticsButtonView(
                isReady: analyticsReady,
                disabledReason: analyticsDisabledReason,
                onWarmupTap: handleAnalyticsWarmupTap
            )

            ToolbarGroupDivider()

            ToolbarIconButton(help: "Resume the selected Codex or Claude session in its original CLI (⌃⌘R). Gemini, OpenCode, and Copilot sessions are read-only.") { _ in
                ToolbarIcon(systemName: "terminal")
            } action: {
                if let s = selectedSession { resume(s) }
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(selectedSession == nil || !(selectedSession?.source == .codex || selectedSession?.source == .claude))
            .accessibilityLabel(Text("Resume"))

            ToolbarIconButton(help: "Reveal the selected session's working directory in Finder (⌘⇧O)") { _ in
                ToolbarIcon(systemName: "folder")
            } action: {
                if let s = selectedSession { openDir(s) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(selectedSession == nil)
            .accessibilityLabel(Text("Open Working Directory"))

            ToolbarIconButton(help: "Re-run the session indexer to discover new logs (⌘R)") { _ in
                ZStack {
                    ToolbarIcon(systemName: "arrow.clockwise")
                        .opacity(unified.isIndexing || unified.isProcessingTranscripts ? 0.35 : 1)
                    if unified.isIndexing || unified.isProcessingTranscripts {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } action: {
                unified.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(Text("Refresh"))

            ToolbarIconButton(help: imagesToolbarHelpText) { _ in
                ToolbarIcon(systemName: "photo.on.rectangle")
            } action: {
                showImagesForSelectedSession(showNoSelectionAlert: true)
            }
            .disabled(selectedSession == nil)
            .accessibilityLabel(Text("Image Browser"))

            if isGitInspectorEnabled {
                ToolbarIconButton(help: "Show historical and current git context with safety analysis (⌘⇧G)") { _ in
                    ToolbarIcon(systemName: "clock.arrow.circlepath")
                } action: {
                    if let s = selectedSession { showGitInspector(s) }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(selectedSession == nil)
                .accessibilityLabel(Text("Git Context"))
            }

            ToolbarGroupDivider()

            LayoutToggleButton(layoutMode: layoutMode, onToggleLayout: onToggleLayout)

            ToolbarIconButton(help: effectiveColorScheme == .dark ? "Switch to Light Mode" : "Switch to Dark Mode") { _ in
                ToolbarIcon(systemName: effectiveColorScheme == .dark ? "sun.max" : "moon")
            } action: {
                codexIndexer.toggleDarkLight(systemScheme: systemColorScheme)
            }
            .accessibilityLabel(Text("Toggle Dark/Light"))

            ToolbarIconButton(help: "Open preferences for appearance, indexing, and agents (⌘,)") { isHovering in
                ToolbarIcon(systemName: "gearshape", opacity: isHovering ? 1 : 0.4)
            } action: {
                PreferencesWindowController.shared.show(indexer: codexIndexer, updaterController: updaterController)
            }
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel(Text("Settings"))
        }
    }

    private var selectedSession: Session? { selection.flatMap { id in cachedRows.first(where: { $0.id == id }) } }

    private var imagesToolbarHelpText: String {
        return "Show images for the selected session"
    }

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

    private func showImagesForSelectedSession(showNoSelectionAlert: Bool) {
        guard let session = selectedSession else {
            if showNoSelectionAlert {
                showImagesAlert(message: "Select a session to view images.")
            }
            return
        }
        CodexImagesWindowController.shared.show(session: session, allSessions: unified.allSessions)
    }

    private func showImagesAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func handleSelectionChange(_ id: String?) {
        guard let id, let s = cachedRows.first(where: { $0.id == id }) else {
            cancelAutoJump()
            unified.setFocusedSession(nil)
            return
        }
        if !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let immediate = consumeImmediateSelectionJump()
            scheduleAutoJump(for: id, immediate: immediate)
        } else {
            cancelAutoJump()
        }
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
        } else if s.source == .openclaw, let exist = openclawIndexer.allSessions.first(where: { $0.id == id }), exist.events.isEmpty {
            openclawIndexer.reloadSession(id: id)
        }

        searchCoordinator.prewarmTranscriptIfNeeded(for: s)
        unified.setFocusedSession(s)
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

    private func scheduleAutoJump(for sessionID: String, immediate: Bool) {
        cancelAutoJump()
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let work = DispatchWorkItem { searchState.requestAutoJump(sessionID: sessionID) }
        if immediate {
            work.perform()
        } else {
            autoJumpWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private func cancelAutoJump() {
        autoJumpWorkItem?.cancel()
        autoJumpWorkItem = nil
    }

    private func consumeImmediateSelectionJump() -> Bool {
        if selectionChangeSource == .mouse {
            selectionChangeSource = nil
            return true
        }
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return true
        default:
            return false
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
        case .openclaw: label = "OpenClaw"
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
	                                includeOpenClaw: unified.includeOpenClaw && openClawAgentEnabled,
	                                enableDeepScan: searchCoordinator.deepScanEnabled,
	                                all: unified.allSessions)
	    }

    private func flashAgentEnablementNoticeIfNeeded() {
        let anyDisabled = !(codexAgentEnabled && claudeAgentEnabled && geminiAgentEnabled && openCodeAgentEnabled && copilotAgentEnabled && droidAgentEnabled && openClawAgentEnabled)
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
        case .openclaw: return Color.agentOpenClaw
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

private struct AgentTabToggle: View {
    let title: String
    let color: Color
    let isMonochrome: Bool
    @Binding var isOn: Bool

    private var activeColor: Color { isMonochrome ? .primary : color }
    private var dotColor: Color { isOn ? activeColor : activeColor.opacity(0.35) }
    private var textColor: Color { isOn ? activeColor : .primary }

    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: UnifiedSessionsStyle.agentDotSize, height: UnifiedSessionsStyle.agentDotSize)
                Text(title)
            }
            .font(UnifiedSessionsStyle.agentTabFont)
            .foregroundStyle(textColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(UnifiedSessionsStyle.agentPillFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(UnifiedSessionsStyle.agentPillStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

private struct ToolbarIcon: View {
    let systemName: String
    var isActive: Bool = false
    var activeColor: Color = UnifiedSessionsStyle.selectionAccent
    var opacity: Double? = nil
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemName)
            .font(UnifiedSessionsStyle.toolbarIconFont)
            .frame(width: UnifiedSessionsStyle.toolbarIconSize, height: UnifiedSessionsStyle.toolbarIconSize)
            .foregroundStyle(isActive ? activeColor : .primary)
            .opacity((opacity ?? 1) * (isEnabled ? 1 : 0.4))
    }
}

private struct ToolbarIconButton<Label: View>: View {
    let help: String
    let label: (Bool) -> Label
    let action: () -> Void
    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            label(isHovering)
                .frame(width: UnifiedSessionsStyle.toolbarButtonSize, height: UnifiedSessionsStyle.toolbarButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: UnifiedSessionsStyle.toolbarButtonCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(isHovering ? UnifiedSessionsStyle.toolbarHoverOpacity : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: UnifiedSessionsStyle.toolbarButtonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in isHovering = hovering }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

private struct ToolbarIconToggle: View {
    @Binding var isOn: Bool
    let onSymbol: String
    let offSymbol: String
    let help: String
    var activeColor: Color = UnifiedSessionsStyle.selectionAccent

    var body: some View {
        ToolbarIconButton(help: help) { _ in
            ToolbarIcon(systemName: isOn ? onSymbol : offSymbol,
                        isActive: isOn,
                        activeColor: activeColor)
        } action: {
            isOn.toggle()
        }
        .accessibilityLabel(Text("Saved"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

private struct ToolbarGroupDivider: View {
    var body: some View {
        Divider()
            .frame(height: 18)
    }
}

private struct LayoutToggleButton: View {
    let layoutMode: LayoutMode
    let onToggleLayout: () -> Void

    private var targetMode: LayoutMode {
        layoutMode == .vertical ? .horizontal : .vertical
    }

    private var iconName: String {
        targetMode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1"
    }

    private var helpText: String {
        targetMode == .vertical ? "Switch to vertical split layout" : "Switch to horizontal split layout"
    }

    var body: some View {
        ToolbarIconButton(help: helpText) { _ in
            ToolbarIcon(systemName: iconName)
        } action: {
            onToggleLayout()
        }
        .accessibilityLabel(Text("Toggle Layout"))
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
    @ObservedObject var openclawIndexer: OpenClawSessionIndexer

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
            OpenClawTranscriptView(indexer: openclawIndexer, sessionID: selection)
                .opacity(kind == .openclaw ? 1 : 0)
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
    @ObservedObject var searchState: UnifiedSearchState
    @FocusState private var searchFocus: SearchFocusTarget?
    @State private var searchDebouncer: DispatchWorkItem? = nil
    @State private var focusRequestToken: Int = 0
    private enum SearchFocusTarget: Hashable { case field, clear }
    var body: some View {
        HStack(spacing: 8) {
            // Inline search field (always visible to keep global search front-and-center)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

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
                    .help("Search sessions (⌥⌘F). Filters: repo:NAME, path:PATH. Use quotes for phrases; escape \\\" and \\\\. Press Return for full deep scan.")

                if unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("⌥⌘F")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
                            .font(.system(size: 13, weight: .semibold))
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
                    .stroke(searchFocus == .field ? UnifiedSessionsStyle.toolbarFocusRingColor : Color(nsColor: .separatorColor).opacity(0.6),
                            lineWidth: searchFocus == .field ? 2 : 1)
            )
            .help("Search sessions (⌥⌘F). Filters: repo:NAME, path:PATH. Use quotes for phrases; escape \\\" and \\\\. Press Return for full deep scan.")
            .onAppear {
                if searchState.query != unified.queryDraft {
                    searchState.query = unified.queryDraft
                }
            }
            .onChange(of: unified.queryDraft) { _, newValue in
                TypingActivity.shared.bump()
                if searchState.query != newValue {
                    searchState.query = newValue
                }
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
            .onChange(of: searchState.query) { _, newValue in
                if unified.queryDraft != newValue {
                    unified.queryDraft = newValue
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
        }
    }

    private func requestSearchFocus() {
        focusRequestToken &+= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            searchFocus = .field
        }
    }

    private func startSearch(deepScan: Bool = false) {
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
                     includeOpenClaw: unified.includeOpenClaw,
                     enableDeepScan: deepScan,
                     all: unified.allSessions)
    }

    private func startSearchImmediate() {
        searchDebouncer?.cancel(); searchDebouncer = nil
        startSearch(deepScan: true)
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
                         includeOpenClaw: unified.includeOpenClaw,
                         enableDeepScan: false,
                         all: unified.allSessions)
        }
        searchDebouncer = work
        let delay: TimeInterval = FeatureFlags.increaseDeepSearchDebounce ? 0.28 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

private struct UnifiedProjectFilterBadgeView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false

    var body: some View {
        let accent = stripMonochrome ? Color.secondary : UnifiedSessionsStyle.selectionAccent
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            if let projectFilter = unified.projectFilter {
                Text(projectFilter)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            Button(action: {
                unified.projectFilter = nil
                unified.recomputeNow()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove the project filter and show all sessions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accent.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(accent.opacity(0.3))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: true, vertical: false)
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
        tf.font = NSFont.systemFont(ofSize: 12, weight: .medium)
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
        ToolbarIconButton(help: helpText) { _ in
            ZStack {
                ToolbarIcon(systemName: "chart.bar.xaxis")
                    .opacity(isReady ? 1 : 0.35)
                if !isReady {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        } action: {
            if isReady {
                NotificationCenter.default.post(name: .toggleAnalytics, object: nil)
            } else {
                onWarmupTap()
            }
        }
        .keyboardShortcut("k", modifiers: .command)
        .accessibilityLabel(Text("Analytics"))
        // Keep pressable; communicate readiness instead of disabling.
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

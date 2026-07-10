import SwiftUI
import AppKit

/// Display mapping for subagent-type badges. Keeps long internal type names
/// (e.g. "workflow-subagent") short in the session list.
enum WorkflowSubagentBadge {
    static func displayLabel(for agentType: String) -> String {
        agentType == Session.claudeWorkflowSubagentType ? "workflow" : agentType
    }
}

enum UnifiedTableSelectionPolicy {
    static func shouldClearCanonicalSelectionOnTableDeselection(
        isDatasetChurning: Bool,
        currentSelectionID: String?,
        visibleRowIDs: Set<String>
    ) -> Bool {
        guard !isDatasetChurning else { return false }
        guard let currentSelectionID else { return false }
        return visibleRowIDs.contains(currentSelectionID)
    }

    /// The Table should mirror the canonical `selection` whenever that id is
    /// actually present in the rows currently on screen. Busy/churn state must
    /// NOT hide a selection that is genuinely still there — doing so caused the
    /// native highlight to flicker off and on during every live-session
    /// republish. Only hide it when the id is genuinely absent from the row
    /// set (e.g. mid hierarchy-rebuild before `cachedRows` catches up), which
    /// is what originally motivated this gate: avoid the Table trying to
    /// scroll/highlight a row that doesn't exist yet.
    static func shouldExposeCanonicalSelectionToTable(
        selectionPresentInRows: Bool
    ) -> Bool {
        selectionPresentInRows
    }

    static func shouldReplaceMissingSelection(
        hierarchyBrowsing: Bool,
        refreshBusy: Bool,
        hasUserManuallySelected: Bool,
        datasetChurning: Bool
    ) -> Bool {
        guard !datasetChurning else { return false }
        return !(hierarchyBrowsing && refreshBusy && hasUserManuallySelected)
    }
}

enum UnifiedRowsStabilityPolicy {
    static func shouldHoldRowsDuringRunningSearch(
        isSearchRunning: Bool,
        nextRowsEmpty: Bool,
        showActiveSessionsOnly: Bool,
        cachedRowsEmpty: Bool
    ) -> Bool {
        guard isSearchRunning else { return false }
        guard nextRowsEmpty else { return false }
        guard !showActiveSessionsOnly else { return false }
        guard !cachedRowsEmpty else { return false }
        return true
    }

    static func shouldHoldRowsDuringTransientEmptyRefresh(
        query: String,
        isSearchRunning: Bool,
        isDatasetChurning: Bool,
        isIndexing: Bool,
        nextRowsEmpty: Bool,
        showActiveSessionsOnly: Bool,
        cachedRowsEmpty: Bool,
        hasSelection: Bool
    ) -> Bool {
        guard query.isEmpty else { return false }
        guard !isSearchRunning else { return false }
        guard nextRowsEmpty else { return false }
        guard !showActiveSessionsOnly else { return false }
        guard !cachedRowsEmpty else { return false }
        guard hasSelection else { return false }
        return isDatasetChurning || isIndexing
    }
}

enum UnifiedTableIdentityPolicy {
    static func tableIdentity(columnLayoutID: UUID, reorderGeneration: Int) -> String {
        "unified-table-\(columnLayoutID.uuidString)-\(reorderGeneration)"
    }

    /// Above this many moved rows, force an O(n) Table rebuild rather than let SwiftUI
    /// diff the reorder. Measured: a full ~3,300-row re-sort (moved≈n) diffs in ~6.5s.
    /// Even under a pessimistic O(moved·n) cost model this bounds the diff-path worst case
    /// to roughly a few-hundred ms for a sub-threshold (moved<128) reorder on a 3,300-row
    /// list — a brief hitch, not a beachball — while preserving scroll position for those
    /// small/incidental reorders. A genuine column-header sort re-keys ~all rows
    /// (moved≈n ≫ 128), so it always takes the rebuild path.
    static let reorderRebuildThreshold = 128

    /// A *large* reorder = same membership, and enough rows moved that SwiftUI's move-diff
    /// (O(n^2)) would beachball. Only then is a full Table rebuild (new .id(), O(n)) worth
    /// its cost (loses scroll position). Small reorders (a few rows, or an incidental
    /// hierarchy regroup) and membership changes fall through to SwiftUI's cheap diff, which
    /// preserves scroll. The expensive Set-equality membership check runs only once the
    /// move count already crossed the threshold, so normal/idle updates pay just an O(n)
    /// scan with no allocation.
    static func isLargeReorder(old: [Session], new: [Session]) -> Bool {
        guard old.count == new.count, old.count > 1 else { return false }
        var moved = 0
        for i in 0..<old.count where old[i].id != new[i].id { moved += 1 }
        guard moved >= reorderRebuildThreshold else { return false }
        return Set(old.lazy.map(\.id)) == Set(new.lazy.map(\.id))
    }
}

enum UnifiedHierarchyCommandPolicy {
    static func collapsedParentsAfterCollapseAll(
        existing: Set<String>,
        visibleParentIDs: Set<String>
    ) -> Set<String> {
        existing.union(visibleParentIDs)
    }

    static func collapsedParentsAfterExpandAll(
        existing: Set<String>,
        visibleParentIDs: Set<String>
    ) -> Set<String> {
        existing.subtracting(visibleParentIDs)
    }

    static func parentIDForSelectedHierarchyChild(
        rowIDs: [String],
        rowMeta: [String: SubagentRowMeta],
        selectedID: String?
    ) -> String? {
        guard let selectedID,
              let selectedIndex = rowIDs.firstIndex(of: selectedID),
              selectedIndex > 0,
              rowMeta[selectedID]?.depth ?? 0 > 0 else {
            return nil
        }

        for index in stride(from: selectedIndex - 1, through: 0, by: -1) {
            let candidateID = rowIDs[index]
            let metadata = rowMeta[candidateID]
            if metadata?.depth == 0, metadata?.hasChildren == true {
                return candidateID
            }
        }
        return nil
    }
}

private extension Notification.Name {
    static let collapseInlineSearchIfEmpty = Notification.Name("UnifiedSessionsCollapseInlineSearchIfEmpty")
}

private enum CockpitNavigationUserInfoKey {
    static let source = "source"
    static let runtimeSessionID = "runtimeSessionID"
    static let logPath = "logPath"
    static let workingDirectory = "workingDirectory"
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

private struct WindowKeyObserver: NSViewRepresentable {
    var onBecameKey: ((NSWindow) -> Void)?
    var onResignedKey: ((NSWindow) -> Void)?
    var onWillClose: ((NSWindow) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onBecameKey: onBecameKey,
            onResignedKey: onResignedKey,
            onWillClose: onWillClose
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            context.coordinator.attach(to: view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateCallbacks(
            onBecameKey: onBecameKey,
            onResignedKey: onResignedKey,
            onWillClose: onWillClose
        )
        DispatchQueue.main.async { [weak nsView] in
            context.coordinator.attach(to: nsView?.window)
        }
    }

    final class Coordinator {
        private var onBecameKey: ((NSWindow) -> Void)?
        private var onResignedKey: ((NSWindow) -> Void)?
        private var onWillClose: ((NSWindow) -> Void)?
        private var window: NSWindow?
        private var becameKeyObserver: NSObjectProtocol?
        private var resignedKeyObserver: NSObjectProtocol?
        private var willCloseObserver: NSObjectProtocol?

        init(
            onBecameKey: ((NSWindow) -> Void)?,
            onResignedKey: ((NSWindow) -> Void)?,
            onWillClose: ((NSWindow) -> Void)?
        ) {
            self.onBecameKey = onBecameKey
            self.onResignedKey = onResignedKey
            self.onWillClose = onWillClose
        }

        deinit {
            detach()
        }

        func updateCallbacks(
            onBecameKey: ((NSWindow) -> Void)?,
            onResignedKey: ((NSWindow) -> Void)?,
            onWillClose: ((NSWindow) -> Void)?
        ) {
            self.onBecameKey = onBecameKey
            self.onResignedKey = onResignedKey
            self.onWillClose = onWillClose
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else { return }
            if window === newWindow { return }

            detach()
            window = newWindow

            becameKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.onBecameKey?(window)
            }

            resignedKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.onResignedKey?(window)
            }

            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.onWillClose?(window)
                self.detach()
            }

            if newWindow.isKeyWindow {
                DispatchQueue.main.async { [weak self, weak newWindow] in
                    guard let self, let window = newWindow else { return }
                    self.onBecameKey?(window)
                }
            }
        }

        private func detach() {
            if let observer = becameKeyObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = resignedKeyObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = willCloseObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            becameKeyObserver = nil
            resignedKeyObserver = nil
            willCloseObserver = nil
            window = nil
        }
    }
}

struct UnifiedSessionsView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    let codexIndexer: SessionIndexer
    let claudeIndexer: ClaudeSessionIndexer
    @ObservedObject var antigravityIndexer: AntigravitySessionIndexer
    let opencodeIndexer: OpenCodeSessionIndexer
    let hermesIndexer: HermesSessionIndexer
    let copilotIndexer: CopilotSessionIndexer
    let droidIndexer: DroidSessionIndexer
    let openclawIndexer: OpenClawSessionIndexer
    let cursorIndexer: CursorSessionIndexer
    let piIndexer: PiSessionIndexer
    @EnvironmentObject var codexUsageModel: CodexUsageModel
    @EnvironmentObject var claudeUsageModel: ClaudeUsageModel
    @Environment(CodexActiveSessionsModel.self) var activeCodexSessions
    @EnvironmentObject var updaterController: UpdaterController
    @EnvironmentObject var columnVisibility: ColumnVisibilityStore
    @EnvironmentObject var onboardingCoordinator: OnboardingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.openWindow) private var openWindow

    let layoutMode: LayoutMode
    let analyticsReady: Bool
    let analyticsPhase: AnalyticsIndexPhase
    let analyticsIsStale: Bool
    let onToggleLayout: () -> Void

    @State private var selection: String?
    // Advances only when the 150ms selectionPropagationTask fires (or on
    // first population) — the transcript pane renders from THIS, not the raw
    // `selection`, so key-repeat scrubbing never re-renders/rebuilds the pane.
    // Row highlighting stays bound to `selection` directly (instant).
    @State private var settledSelection: String?
    @State private var selectionSource: SessionSource? = nil
    @State private var lastSelectedSource: SessionSource = .codex
		@State private var sortOrder: [KeyPathComparator<Session>] = []
		@State private var cachedRows: [Session] = []
        @State private var cachedRowIDs: [String] = []
        @State private var cachedVisibleRowIDs: Set<String> = []
        @State private var cachedTotalSessionCount: Int = 0
        @State private var cachedLatestModifiedAt: Date? = nil
	    @State private var collapsedParents: Set<String> = []
	    @State private var hasLoadedPersistedCollapsedParents: Bool = false
        @State private var hierarchyRowMeta: [String: SubagentRowMeta] = [:]
        @State private var sideChatParentContextByID: [String: String] = [:]
        @State private var cachedExpandableParentIDs: Set<String> = []
        // O(1) id -> row lookup, rebuilt alongside cachedRows in the same apply
        // step. Lets per-click paths (handleSelectionChange, selectedSession)
        // avoid an O(n) `cachedRows.first(where:)` scan.
        @State private var cachedRowByID: [String: Session] = [:]
        // Precomputed `staticSurfacePills(for:)` per row, rebuilt alongside
        // cachedRows (SessionRowsBuilder.build already iterates every session).
        // `cellSource(for:)` reads this instead of calling `surfacePills`
        // per row-body call (W7 Task 1 -- see SessionRowsBuilder.RowsOutput).
        @State private var cachedSurfacePillsBySessionID: [String: [CodexSurfacePill]] = [:]
        // Bumped on every updateCachedRows() trigger (both the synchronous and
        // the off-main async paths) BEFORE any async work starts. The async
        // path's apply step checks its captured generation against the current
        // value; a mismatch means a newer trigger has since started/finished and
        // this stale result must be dropped (superseded, never interleaved).
        @State private var rowsRebuildGeneration: Int = 0
	@State private var columnLayoutID: UUID = UUID()
	// Bumped whenever cachedRows is reassigned as a *wholesale reorder* (same id-set,
	// different order — i.e. a sort). Feeding this into the Table's .id() forces SwiftUI
	// to REBUILD the table (O(n)) instead of DIFFING the reorder, whose move-computation
	// (AppKitOutlineTableCoordinator -> remove(atOffsets:)/move(fromOffsets:toOffset:))
	// is O(n^2) and beachballs for multiple seconds at ~3,300 rows. See docs/perf-master-plan.md W4.
	@State private var tableReorderGeneration: Int = 0
	@AppStorage("UnifiedShowSourceColumn") private var showSourceColumn: Bool = true
	@AppStorage("UnifiedShowStarColumn") private var showStarColumn: Bool = true
	@AppStorage("UnifiedShowSizeColumn") private var showSizeColumn: Bool = true
    @AppStorage("UnifiedShowActiveSessionsOnly") private var showActiveSessionsOnly: Bool = false
    @AppStorage(PreferencesKey.Unified.showSubagentHierarchy) private var showSubagentHierarchy: Bool = true
    @AppStorage(PreferencesKey.Unified.showTranscriptWindow) private var showTranscriptWindow: Bool = true
    @AppStorage(PreferencesKey.Unified.collapsedHierarchyParents) private var collapsedHierarchyParentsRaw: String = ""
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var liveSessionsFeatureEnabled: Bool = true
	@AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
	@AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = SessionIndexer.ModifiedDisplay.relative.rawValue
	@AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
	@AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled: Bool = false
	@AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled: Bool = false
	@AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.antigravityEnabled) private var antigravityAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.hermesEnabled) private var hermesAgentEnabled: Bool = true
	@AppStorage(PreferencesKey.Agents.copilotEnabled) private var copilotAgentEnabled: Bool = true
	    @AppStorage(PreferencesKey.Agents.droidEnabled) private var droidAgentEnabled: Bool = true
	    @AppStorage(PreferencesKey.Agents.openClawEnabled) private var openClawAgentEnabled: Bool = false
	    @AppStorage(PreferencesKey.Agents.cursorEnabled) private var cursorAgentEnabled: Bool = true
	    @AppStorage(PreferencesKey.Agents.piEnabled) private var piAgentEnabled: Bool = AgentEnablement.isEnabled(.pi)
	    @State private var autoSelectEnabled: Bool = true
	    @State private var isDatasetChurning: Bool = false
	    // Set by updateCachedRows() exactly when the canonical selection id was
	    // missing from the fresh rows AND UnifiedTableSelectionPolicy suppressed
	    // replacement solely because isDatasetChurning was true at that moment.
	    // Consulted by the post-churn onChange(of: unified.sessions) pass to know
	    // whether a second updateCachedRows() call is actually needed (see there).
	    @State private var selectionReplacementDeferredDuringChurn: Bool = false
	    @State private var isAutoSelectingFromSearch: Bool = false
    @State private var hasEverHadSessions: Bool = false
    @State private var hasUserManuallySelected: Bool = false
    @State private var showAgentEnablementNotice: Bool = false
    @State private var isWindowKey: Bool = false
    @State private var activeConsumerID = UUID()
    @State private var cachedFallbackPresenceBySessionKey: [String: CodexActivePresence] = [:]
#if DEBUG
    @State private var debugActiveOnlyUpdateRowsCount: UInt64 = 0
    @State private var debugActiveOnlyUpdateRowsTotalMs: Double = 0
    @State private var debugActiveOnlyUpdateRowsMaxMs: Double = 0
    @State private var debugActiveOnlyLastReportAt: Date = .distantPast
#endif

    private enum SourceColorStyle: String, CaseIterable { case none, text, background } // deprecated

    @StateObject private var searchCoordinator: SearchCoordinator
    @StateObject private var focusCoordinator = WindowFocusCoordinator()
    @StateObject private var searchState = UnifiedSearchState()
    // Debounced selection-propagation task (see handleSelectionChange). Key-repeat
    // scrubbing fires selection changes every ~30-90ms; without this, each one used
    // to schedule transcript teardown/reload on the next runloop turn, which always
    // lands between key-repeat events — every scrubbed row did full propagation work.
    @State private var selectionPropagationTask: Task<Void, Never>? = nil
    @State private var restoreCandidate: Session? = nil
    @State private var showRestoredRelaunch = false
    private var rows: [Session] {
        let baseRows: [Session]
        let q = unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty || searchCoordinator.isRunning {
            // Apply current UI filters and sort to search results
            baseRows = unified.applyFiltersAndSort(to: searchCoordinator.results)
        } else {
            baseRows = unified.sessions
        }

        guard showActiveSessionsOnly else { return baseRows }
        return baseRows.filter { isSessionLive($0) }
    }

    init(unified: UnifiedSessionIndexer,
         codexIndexer: SessionIndexer,
         claudeIndexer: ClaudeSessionIndexer,
         antigravityIndexer: AntigravitySessionIndexer,
         opencodeIndexer: OpenCodeSessionIndexer,
         hermesIndexer: HermesSessionIndexer,
         copilotIndexer: CopilotSessionIndexer,
         droidIndexer: DroidSessionIndexer,
         openclawIndexer: OpenClawSessionIndexer,
         cursorIndexer: CursorSessionIndexer,
         piIndexer: PiSessionIndexer,
         analyticsReady: Bool,
         analyticsPhase: AnalyticsIndexPhase,
         analyticsIsStale: Bool,
         layoutMode: LayoutMode,
         onToggleLayout: @escaping () -> Void) {
        self.unified = unified
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.antigravityIndexer = antigravityIndexer
        self.opencodeIndexer = opencodeIndexer
        self.hermesIndexer = hermesIndexer
        self.copilotIndexer = copilotIndexer
        self.droidIndexer = droidIndexer
        self.openclawIndexer = openclawIndexer
        self.cursorIndexer = cursorIndexer
        self.piIndexer = piIndexer
        self.analyticsReady = analyticsReady
        self.analyticsPhase = analyticsPhase
        self.analyticsIsStale = analyticsIsStale
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
            .antigravity: .init(
                transcriptCache: antigravityIndexer.searchTranscriptCache,
                update: { antigravityIndexer.updateSession($0) },
                parseFull: { url, forcedID in AntigravitySessionParser.parseFileFull(at: url, forcedID: forcedID) }
            ),
            .opencode: .init(
                transcriptCache: opencodeIndexer.searchTranscriptCache,
                update: { opencodeIndexer.updateSession($0) },
                parseFull: { [opencodeIndexer] url, forcedID in
                    if url.lastPathComponent == "opencode.db", !forcedID.isEmpty {
                        let customRoot = opencodeIndexer.sessionsRootOverride.isEmpty ? nil : opencodeIndexer.sessionsRootOverride
                        return OpenCodeSqliteReader.loadFullSession(customRoot: customRoot, sessionID: forcedID)
                    }
                    return OpenCodeSessionParser.parseFileFull(at: url)
                }
            ),
            .hermes: .init(
                transcriptCache: hermesIndexer.searchTranscriptCache,
                update: { hermesIndexer.updateSession($0) },
                parseFull: { url, forcedID in
                    if url.pathExtension.lowercased() == "db", !forcedID.isEmpty {
                        return HermesStateDBReader.loadFullSession(dbURL: url, sessionID: forcedID)
                    }
                    return HermesSessionParser.parseFileFull(at: url)
                }
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
            .cursor: .init(
                transcriptCache: cursorIndexer.searchTranscriptCache,
                update: { cursorIndexer.updateSession($0) },
                parseFull: { url, forcedID in CursorSessionParser.parseFileFull(at: url, forcedID: forcedID) }
            ),
            .pi: .init(
                transcriptCache: piIndexer.searchTranscriptCache,
                update: { piIndexer.updateSession($0) },
                parseFull: { url, _ in PiSessionParser.parseFileFull(at: url, allowLargeFile: true) }
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
				.background(
					WindowKeyObserver(
						onBecameKey: { _ in
							handleWindowDidBecomeKey()
						},
						onResignedKey: { _ in
							handleWindowDidResignKey()
						},
						onWillClose: { _ in
							handleWindowWillClose()
						}
					)
				)
		)

			let lifecycle = AnyView(
				base
				                .onAppear {
				                    activeCodexSessions.setUnifiedConsumerVisible(true, consumerID: activeConsumerID)
				                    updateFooterUsageVisibility()
				                    if sortOrder.isEmpty { sortOrder = [KeyPathComparator(\Session.modifiedAt, order: .reverse)] }
				                    if !liveSessionsFeatureEnabled { showActiveSessionsOnly = false }
                                    loadPersistedCollapsedParentsIfNeeded()
				                    updateCachedRows()
				                    ensureDefaultSelectionIfNeeded()
				                    if settledSelection == nil, let selection { settledSelection = selection }
				                    unified.setAppActive(NSApp.isActive)
			                    updateFocusedSessionIfNeeded(selectedSession)
			                    refreshSelectionSourceFromCachedRows()
                                tryHandlePendingCockpitNavigationIfNeeded()
		                    searchCoordinator.setAppActive(NSApp.isActive)
			                }
			                .onDisappear {
			                    activeCodexSessions.setUnifiedConsumerVisible(false, consumerID: activeConsumerID)
			                    codexUsageModel.setStripVisible(false)
			                    claudeUsageModel.setStripVisible(false)
			                    selectionPropagationTask?.cancel()
			                    selectionPropagationTask = nil
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

		let afterSelection = lifecycle
			.onChange(of: selection) { _, id in
				handleSelectionChange(id)
			}

        let afterCodex = afterSelection
            .onChange(of: unified.includeCodex) { _, _ in restartSearchIfRunning() }
        let afterArchived = afterCodex
            .onChange(of: unified.showArchivedCodexDesktopOnly) { _, _ in restartSearchForActiveQuery() }
            .onChange(of: unified.showArchivedClaudeDesktopOnly) { _, _ in restartSearchForActiveQuery() }
        let afterClaude = afterArchived
            .onChange(of: unified.includeClaude) { _, _ in restartSearchIfRunning() }
		let afterAntigravity = afterClaude
			.onChange(of: unified.includeAntigravity) { _, _ in restartSearchIfRunning() }
		let afterOpenCode = afterAntigravity
			.onChange(of: unified.includeOpenCode) { _, _ in restartSearchIfRunning() }
		let afterCopilot = afterOpenCode
			.onChange(of: unified.includeCopilot) { _, _ in restartSearchIfRunning() }
		let afterDroid = afterCopilot
			.onChange(of: unified.includeDroid) { _, _ in restartSearchIfRunning() }

		let afterOpenClaw = afterDroid
			.onChange(of: unified.includeOpenClaw) { _, _ in restartSearchIfRunning() }

		let afterCursor = afterOpenClaw
			.onChange(of: unified.includeCursor) { _, _ in restartSearchIfRunning() }

        let afterPi = afterCursor
            .onChange(of: unified.includePi) { _, _ in restartSearchIfRunning() }

        let afterActiveOnly = afterPi
            .onChange(of: showActiveSessionsOnly) { _, _ in
                if !liveSessionsFeatureEnabled {
                    showActiveSessionsOnly = false
                }
                updateCachedRows()
                ensureDefaultSelectionIfNeeded()
                refreshSelectionSourceFromCachedRows()
                updateFocusedSessionIfNeeded(selectedSession)
            }

        let afterLiveFeature = afterActiveOnly
            .onChange(of: liveSessionsFeatureEnabled) { _, enabled in
                if !enabled { showActiveSessionsOnly = false }
                updateCachedRows()
                ensureDefaultSelectionIfNeeded()
                refreshSelectionSourceFromCachedRows()
                updateFocusedSessionIfNeeded(selectedSession)
            }
            .onChange(of: showSubagentHierarchy) { _, newValue in
                if !newValue { persistCollapsedParents() }
                updateCachedRows()
            }
            .onChange(of: collapsedParents) { _, _ in
                persistCollapsedParents()
                updateCachedRows()
            }

			let afterUsage = afterLiveFeature
				.onChange(of: codexUsageEnabled) { _, _ in updateFooterUsageVisibility() }
				.onChange(of: claudeUsageEnabled) { _, _ in updateFooterUsageVisibility() }
					.onChange(of: searchState.query) { _, newValue in
						if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
							cancelAutoJump()
	                        updateCachedRows()
	                        ensureDefaultSelectionIfNeeded()
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
			.onChange(of: antigravityAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
			.onChange(of: openCodeAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }
			.onChange(of: copilotAgentEnabled) { _, _ in flashAgentEnablementNoticeIfNeeded() }

		let afterSessions = afterAgents
			.onReceive(unified.$sessions) { sessions in
				if !sessions.isEmpty {
					hasEverHadSessions = true
				}
                tryHandlePendingCockpitNavigationIfNeeded()
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
						let source = cachedRows.first(where: { $0.id == id })?.source
						setActiveSelection(id, source: source, userInitiated: true)
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

				let afterNavigateFromCockpit = afterNavigateFromImages
					.onReceive(NotificationCenter.default.publisher(for: .navigateToSessionFromCockpit)) { n in
						handleNavigateToSessionFromCockpit(n)
					}

					let afterShowImages = afterNavigateFromCockpit
						.onReceive(NotificationCenter.default.publisher(for: .showImagesFromMenu)) { _ in
							showImagesForSelectedSession(showNoSelectionAlert: true)
						}

                    let afterCollapseAllGroups = afterShowImages
                        .onReceive(NotificationCenter.default.publisher(for: .collapseAllUnifiedSessionGroupsFromMenu)) { _ in
                            collapseAllHierarchyParents()
                        }

                    let afterExpandAllGroups = afterCollapseAllGroups
                        .onReceive(NotificationCenter.default.publisher(for: .expandAllUnifiedSessionGroupsFromMenu)) { _ in
                            expandAllHierarchyParents()
                        }

					let afterShowImagesForInlineImage = afterExpandAllGroups
							.onReceive(NotificationCenter.default.publisher(for: .showImagesForInlineImage)) { n in
								guard let id = n.object as? String else { return }
							let requestedItemID = n.userInfo?["selectedItemID"] as? String

							let source = cachedRows.first(where: { $0.id == id })?.source
							setActiveSelection(id, source: source, userInitiated: true)

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
                    .onReceive(activeCodexSessions.membershipTicks) { _ in
                        // A live-presence bump changes Agent live-state dots (active/open),
                        // never the underlying session list — the visible row SET comes from
                        // unified.sessions, not the presence poll. So when Active-only filtering
                        // is OFF, the full updateCachedRows() rebuild (hierarchy + side-chat +
                        // derived-state + cachedRows reassignment, ~5-6 O(n) passes over 3,300
                        // rows) cannot change anything the user sees and is the dominant W1
                        // beachball contributor. Take a cheap path that only refreshes the
                        // fallback-presence map; direct dots refresh because this onReceive
                        // firing re-diffs the body, and each source-cell's .id(...) is keyed on
                        // that row's own (liveState, lastSeenAt) signature (see
                        // livePresenceSignature) so only rows whose visible dot actually changed
                        // get a new cell identity — not every row on every tick. Cross-workspace
                        // fallback dots read cachedFallbackPresenceBySessionKey (rebuilt here).
                        // NOTE: reverted "C5" skipped this fallback rebuild too and broke
                        // fallback dots — we must keep it.
#if DEBUG
                        let _memSpan = Perf.begin("membershipTick", thresholdMs: 8,
                                                  showActiveSessionsOnly ? "activeOnly-full" : "cheap-dotsOnly")
                        defer { Perf.end(_memSpan) }
#endif
                        if showActiveSessionsOnly {
                            // Active-only: the visible SET depends on live membership, so a
                            // structural rebuild is genuinely required. This fires on the
                            // same live-poll cadence as the unified.sessions republish, so
                            // it gets the same off-main treatment (Task 2) — a user with
                            // Active-only enabled shouldn't pay ~110ms on main every tick.
                            updateCachedRowsAsync { _, applied in
                                guard applied else { return }
                                ensureDefaultSelectionIfNeeded()
                                refreshSelectionSourceFromCachedRows()
                                updateFocusedSessionIfNeeded(selectedSession)
                            }
                        } else {
                            // Cheap path: SET + order unchanged, only dots move.
                            rebuildCachedFallbackPresences()
                            updateFocusedSessionIfNeeded(selectedSession)
                        }
                    }

				return AnyView(afterShowImagesForInlineImage)
			}

	private var topTrailingNotices: some View {
		VStack(alignment: .trailing, spacing: 8) {
			if showAgentEnablementNotice {
				Text("Showing active agents only")
					.font(.footnote)
					.padding(10)
					.background(.regularMaterial)
					.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
					.transition(.move(edge: .top).combined(with: .opacity))
			}
			ForEach(Array(unified.newlyAvailableProviders.enumerated()), id: \.element) { index, source in
				newProviderBanner(for: source)
					.transition(.move(edge: .top).combined(with: .opacity))
					.animation(
						.easeOut(duration: 0.3).delay(Double(index) * 0.3),
						value: unified.newlyAvailableProviders
					)
			}
		}
		.padding(.top, 8)
		.padding(.trailing, 8)
	}

	private func newProviderBanner(for source: SessionSource) -> some View {
		HStack(spacing: 10) {
			Image(systemName: source.iconName)
				.font(.title3)
			Text("\(source.displayName) sessions found")
				.font(.footnote.weight(.medium))
			Spacer(minLength: 8)
			Button("Enable") {
				withAnimation(.easeInOut(duration: 0.3)) {
					unified.dismissNewProviderBanner(for: source, enable: true)
				}
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.small)
			.accessibilityLabel("Enable \(source.displayName)")
			Button("Dismiss") {
				withAnimation(.easeInOut(duration: 0.3)) {
					unified.dismissNewProviderBanner(for: source, enable: false)
				}
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
			.accessibilityLabel("Dismiss \(source.displayName) notification")
		}
		.padding(10)
		.background(.regularMaterial)
		.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		.accessibilityElement(children: .contain)
	}

	    private var rootContent: some View {
	        VStack(spacing: 0) {
	            // Cap ETA banner disabled (calculations retained; UI disabled)
	            mainSplitView
	            cockpitFooter
	        }
	    }

	    /// Session-list pane with the onboarding top-card slot (What's New / feedback)
	    /// mounted above the table. Renders nothing extra when there's nothing to show.
	    private var listPaneWithTopSlot: some View {
	        VStack(spacing: 0) {
	            OnboardingListTopSlot(coordinator: onboardingCoordinator)
	            listPane
	        }
	        .onboardingSheets(coordinator: onboardingCoordinator)
	    }

	    @ViewBuilder
	    private var mainSplitView: some View {
	        if !showTranscriptWindow {
	            listPaneWithTopSlot
	                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
	                .transaction { $0.animation = nil }
	        } else if layoutMode == .vertical {
	            HSplitView {
	                // Native macOS split idiom: panes read as distinct via a one-step
	                // background value difference (list on window gray, transcript on
	                // the brighter text background) + a single crisp hairline. Each
	                // pane is inset by `paneGutter` so neither the list content nor the
	                // transcript stripes butt against the line — equal margin both sides.
	                listPaneWithTopSlot
	                    .frame(minWidth: 320, maxWidth: 1200)
	                    .padding(.trailing, Self.paneGutter)
	                    .background(Self.listPaneBackground)
	                    .overlay(alignment: .trailing) { paneHairline(.vertical) }
	                transcriptPane
	                    .frame(minWidth: 450)
	                    .padding(.leading, Self.paneGutter)
	                    .background(Color(nsColor: .textBackgroundColor))
	            }
	            .background(SplitViewAutosave(key: "UnifiedSplit-H"))
	            .transaction { $0.animation = nil }
	        } else {
	            VSplitView {
	                listPaneWithTopSlot
	                    .frame(minHeight: 180)
	                    .padding(.bottom, Self.paneGutter)
	                    .background(Self.listPaneBackground)
	                    .overlay(alignment: .bottom) { paneHairline(.horizontal) }
	                transcriptPane
	                    .frame(minHeight: 240)
	                    .padding(.top, Self.paneGutter)
	                    .background(Color(nsColor: .textBackgroundColor))
	            }
	            .background(SplitViewAutosave(key: "UnifiedSplit-V"))
	            .transaction { $0.animation = nil }
	        }
	    }

	    /// Content inset from the list/transcript hairline so neither pane's content
	    /// touches the separator. Each pane's own background fills the inset up to
	    /// the line, so the two panes read as distinct panels (AgentsView-style).
	    private static let paneGutter: CGFloat = LayoutTokens.sm

	    /// Flat "sidebar" tone for the Session-list pane — the standard window/chrome
	    /// gray, one value step off the transcript's brighter text background, so the
	    /// panes read as distinct without depending on column widths.
	    private static let listPaneBackground = Color(nsColor: .windowBackgroundColor)

	    /// A single 1px hairline at the list/transcript boundary, in the system
	    /// `separatorColor` so it matches every other divider in the window and
	    /// adapts to light/dark. Pane value contrast (see `mainSplitView`) does the
	    /// heavy lifting; this just crisps the seam.
	    @ViewBuilder
	    private func paneHairline(_ axis: Axis) -> some View {
	        let line = Color(nsColor: .separatorColor)
	        switch axis {
	        case .vertical:
	            line.frame(width: 1).frame(maxHeight: .infinity)
	        case .horizontal:
	            line.frame(height: 1).frame(maxWidth: .infinity)
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
		        Table(cachedRows, selection: tableSingleSelection, sortOrder: $sortOrder) {
            TableColumn("★") { cellFavorite(for: $0) }
                .width(min: showStarColumn ? 36 : 0,
                       ideal: showStarColumn ? 40 : 0,
                       max: showStarColumn ? 44 : 0)

            TableColumn("Agent", value: \Session.sourceKey) { s in
                cellSource(for: s)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        setActiveSelection(s.id, source: s.source, userInitiated: true)
                        autoSelectEnabled = false
                        focusActiveTerminal(for: s)
                    }
            }
                .width(min: showSourceColumn ? 90 : 0,
                       ideal: showSourceColumn ? 100 : 0,
                       max: showSourceColumn ? 120 : 0)

            TableColumn("Session", value: \Session.listTitle) { s in
                SessionTitleCell(
                    session: s,
                    displayTitleOverride: unified.claudeDesktopTitle(for: s),
                    antigravityIndexer: antigravityIndexer,
                    rowMeta: hierarchyRowMeta[s.id],
                    sideChatParentContext: sideChatParentContextByID[s.id],
                    isExpanded: !collapsedParents.contains(s.id),
                    onToggleExpand: { id in
                            if collapsedParents.contains(id) {
                                collapsedParents.remove(id)
                            } else {
                                collapsedParents.insert(id)
                            }
                        }
                    )
	                    .contentShape(Rectangle())
	                    .onTapGesture {
	                        // Explicitly select the tapped row to avoid relying solely on Table's mouse handling.
	                        setActiveSelection(s.id, source: s.source, userInitiated: true)
	                        autoSelectEnabled = false
	                        NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
	                    }
            }
            .width(min: showTitle ? 160 : 0,
                   ideal: showTitle ? 320 : 0,
                   max: showTitle ? 2000 : 0)

            TableColumn("Date", value: \Session.modifiedAt) { s in
                // Both variants are still computed every body call (`.help` takes an
                // eager String, not a lazily-evaluated closure, so the untaken branch's
                // string can't be skipped) -- but `s.modifiedRelative` now reads a
                // shared, lock-guarded RelativeDateTimeFormatter (Session.swift) instead
                // of allocating a fresh one per call, which was the fingerprinted cost.
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

            TableColumn("Project", value: \Session.rowRepoDisplay) { s in
                let display: String = {
                    if s.source == .antigravity {
                        if let name = s.rowRepoName, !name.isEmpty { return name }
                        return "—"
                    } else {
                        return s.rowRepoDisplay
                    }
                }()
                let isNestedHierarchyRow = showSubagentHierarchy
                    && searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (hierarchyRowMeta[s.id]?.depth ?? 0) > 0
                ProjectCellView(
                    id: s.id,
                    display: display,
                    worktree: isNestedHierarchyRow ? nil : s.rowProjectWorktreeDisplayName
                )
                    .onTapGesture(count: 2) {
                        if let name = s.rowRepoName { unified.projectFilter = name; unified.recomputeNow() }
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
	        .id(UnifiedTableIdentityPolicy.tableIdentity(columnLayoutID: columnLayoutID, reorderGeneration: tableReorderGeneration))
	        .tableStyle(.inset(alternatesRowBackgrounds: false))
            // Transparent table so the flat "sidebar" pane background shows through;
            // system white zebra is dropped (see listPaneBackground).
            .scrollContentBackground(.hidden)
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
	                // Derive Antigravity conversation ID once to avoid repeated disk reads
	                let antigravityCLISessionID = (s.source == .antigravity) ? AntigravitySessionIDHelper.deriveSessionID(from: s) : nil
	                if canResumeSession(s, antigravityCLISessionID: antigravityCLISessionID) {
	                    Button("Resume in \(resumeAgentLabel(s.source)) (\(CodexLaunchMode.selectedResumeTerminalTitle()))") { resume(s) }
	                        .keyboardShortcut("r", modifiers: [.command, .control])
	                        .help("Resume the selected session in its original CLI (⌃⌘R)")
	                    Divider()
	                }
                    if activeCodexSessions.supportsLiveSessions(for: s.source) {
                        let availability = terminalFocusAvailability(for: s)
                        Button("Focus in iTerm2") {
                            focusActiveTerminal(for: s)
                        }
                        .disabled(!availability.canFocus)
                        .help(availability.helpText)
                        Divider()
                    }
	                Button("Open Working Directory") { openDir(s) }
	                    .keyboardShortcut("o", modifiers: [.command, .shift])
	                    .help("Reveal working directory in Finder (⌘⇧O)")
	                Button("Reveal Session Log") { revealSessionFile(s) }
	                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .help("Show session log file in Finder (⌥⌘L)")
                if let copyID = copyableSessionID(for: s) {
                    Button("Copy Session ID") { copySessionID(copyID) }
                        .help(s.isSideChat ? "Copy the parent session ID to the clipboard" : "Copy the session ID to the clipboard")
                } else {
                    Button("Copy Session ID") {}
                        .disabled(true)
                        .help("No parent session ID is available for this side chat")
                }
                Button("Copy Resume Command") { copyResumeCommand(s, antigravityCLISessionID: antigravityCLISessionID) }
                    .disabled(!canCopyResumeCommand(s, antigravityCLISessionID: antigravityCLISessionID))
                    .help("Copy a terminal-agnostic resume command to the clipboard")
                if let name = s.rowRepoName, !name.isEmpty {
                    Divider()
                    Button("Filter by Project: \(name)") { unified.projectFilter = name; unified.recomputeNow() }
                        .keyboardShortcut("p", modifiers: [.command, .option])
                        .help("Show only sessions from \(name) (⌥⌘P)")
                }
                if unified.isArchivedClaudeDesktop(s) {
                    let canRestore = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.allowClaudeArchiveRestore)
                    Button("Restore from Archive") { restoreCandidate = s }
                        .disabled(!canRestore)
                        .help(canRestore
                              ? "Set this Claude session back to active in Claude Desktop"
                              : "Enable 'Allow restoring archived Claude sessions' in Preferences -> Advanced")
                    Divider()
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
                Button("Copy Resume Command") {}
                    .disabled(true)
                    .help("Select exactly one session to copy its resume command")
                Button("Filter by Project") {}
                    .disabled(true)
                    .help("Select a session with project metadata to filter")
            }
        }
        .confirmationDialog(
            "Restore from Archive?",
            isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }),
            presenting: restoreCandidate
        ) { session in
            // Defer so the dialog dismisses before the relaunch alert presents.
            Button("Restore") { restoreCandidate = nil; DispatchQueue.main.async { restoreFromArchive(session) } }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: { _ in
            Text("Relaunch Claude Desktop afterward to see this session. Your transcript isn’t changed.")
        }
        .alert("Restored", isPresented: $showRestoredRelaunch) {
            Button("OK") {}
        } message: {
            Text("Relaunch Claude Desktop to see it.")
        }
        .onChange(of: sortOrder) { _, newValue in
            if let first = newValue.first {
                let key: UnifiedSessionIndexer.SessionSortDescriptor.Key
                if first.keyPath == \Session.modifiedAt { key = .modified }
                else if first.keyPath == \Session.messageCount { key = .msgs }
                else if first.keyPath == \Session.rowRepoDisplay { key = .repo }
                else if first.keyPath == \Session.fileSizeSortKey { key = .size }
                else if first.keyPath == \Session.sourceKey { key = .agent }
                else if first.keyPath == \Session.listTitle { key = .title }
                else { key = .title }
                // Setting sortDescriptor drives the sort-only Combine fast path
                // (re-sorts the already-filtered set off-main). Do NOT also call
                // recomputeNow() here — a full filter+sort pass would run ~150ms
                // later and overwrite the fast-path result, negating the optimization.
                unified.sortDescriptor = .init(key: key, ascending: first.order == .forward)
            }
            // No immediate updateCachedRows() here: the sortDescriptor fast path
            // re-sorts off-main and republishes unified.sessions, whose onChange
            // rebuilds rows + reconciles selection. An immediate rebuild here ran
            // against the pre-sort array — pure waste (~115 ms) plus a Table diff.
        }
#if DEBUG
				.onReceive(NotificationCenter.default.publisher(for: PerfBench.toggleSortNotification)) { _ in
					// Perf harness (AS_PERF_BENCH=sort): toggle the sort key to exercise the full
					// real sort path — onChange(of: sortOrder) -> updateCachedRows -> Table reorder.
					if sortOrder.first?.keyPath == \Session.messageCount {
						sortOrder = [KeyPathComparator(\Session.modifiedAt, order: .reverse)]
					} else {
						sortOrder = [KeyPathComparator(\Session.messageCount, order: .reverse)]
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: PerfBench.selectWalkNotification)) { _ in
					// Perf harness (AS_PERF_BENCH=select): advance selection to the next row via
					// the real setActiveSelection(...) path — exercises handleSelectionChange's
					// full pipeline (debounce window, focus, reload, prewarm), not a bypass, so
					// captures show whether key-repeat-rate selection changes coalesce as intended.
					guard !cachedRows.isEmpty else { return }
					let stride = PerfBench.selectWalkStride
					let nextIndex: Int
					if let current = selection, let idx = cachedRows.firstIndex(where: { $0.id == current }) {
						nextIndex = (idx + stride) % cachedRows.count
					} else {
						nextIndex = 0
					}
					let next = cachedRows[nextIndex]
					Perf.event("selectWalkStep", "index=\(nextIndex) stride=\(stride) id=\(next.id.prefix(8))")
					setActiveSelection(next.id, source: next.source, userInitiated: true)
				}
#endif
				.onChange(of: unified.isIndexing) { wasIndexing, isIndexing in
					// When indexing finishes, reconcile selection in case a deferred
					// clear was skipped (the guard in updateCachedRows).
					if wasIndexing, !isIndexing {
						updateCachedRows()
						ensureDefaultSelectionIfNeeded()
						refreshSelectionSourceFromCachedRows()
					}
				}
				.onChange(of: unified.sessions) { _, _ in
					// Update cached rows first, then reconcile canonical selection with fresh data.
					// The heavy hierarchy/derived-state computation runs off-main
					// (SessionRowsBuilder via updateCachedRowsAsync) so this republish
					// — which fires on the live ~2s poll cadence, not just user
					// actions — never blocks the main thread for the full rebuild
					// cost. The apply (and everything below that reads fresh
					// cachedRows) runs in the completion, on main, in one turn.
					selectionTrace("sessions changed begin selection=\(selection ?? "nil") cachedRows=\(cachedRows.count)")
                    restartSearchForSideChatDatasetChangeIfNeeded()
					isDatasetChurning = true
					updateCachedRowsAsync { heldRows, applied in
						guard applied else {
							// Superseded by a newer trigger; that trigger's own
							// completion carries the churn-flag reset and any
							// needed second pass. Nothing to do here.
							return
						}
						let deferredReplacement = selectionReplacementDeferredDuringChurn
						ensureDefaultSelectionIfNeeded()
						refreshSelectionSourceFromCachedRows()
						updateFocusedSessionIfNeeded(selectedSession)
						DispatchQueue.main.async {
							isDatasetChurning = false
							// Correctness: shouldReplaceMissingSelection() defers a
							// missing-selection replacement while isDatasetChurning is true
							// (Fix 2), so a genuinely-deleted session's selection can only be
							// cleaned up once churn drops. Cost: re-running updateCachedRows()
							// unconditionally on every republish reintroduced the double-call
							// class Task 5 eliminated (~115ms at 3.3k rows on the ~2s live
							// cadence). Only pay for the second pass when it can actually
							// matter: rows were held stale, or this pass is the one that will
							// finally apply a deferred selection replacement.
							if heldRows || deferredReplacement {
								updateCachedRows()
								ensureDefaultSelectionIfNeeded()
								refreshSelectionSourceFromCachedRows()
								updateFocusedSessionIfNeeded(selectedSession)
							}
							selectionTrace("sessions changed end selection=\(selection ?? "nil") cachedRows=\(cachedRows.count)")
						}
					}
				}
        .onChange(of: columnVisibility.changeToken) { _, _ in refreshColumnLayout() }
        .onChange(of: showSourceColumn) { _, _ in refreshColumnLayout() }
        .onChange(of: showSizeColumn) { _, _ in refreshColumnLayout() }
        .onChange(of: showStarColumn) { _, _ in refreshColumnLayout() }
        .onChange(of: searchCoordinator.isRunning) { _, _ in
            updateCachedRows()
            let q = unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                ensureDefaultSelectionIfNeeded()
                refreshSelectionSourceFromCachedRows()
            }
        }
        .onChange(of: searchCoordinator.results) { _, _ in
            updateCachedRows()
            // If we have search results but no valid selection (none selected or selected not in results),
            // auto-select the first match without stealing focus
            if selection == nil, let first = cachedRows.first {
                isAutoSelectingFromSearch = true
                setActiveSelection(first.id, source: first.source, userInitiated: false)
                // Reset the flag on the next runloop to ensure onChange handlers have observed it
                DispatchQueue.main.async { isAutoSelectingFromSearch = false }
            }
            refreshSelectionSourceFromCachedRows()
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
	        if unified.coreIndexingDisplayMode == .syncing {
	            let progress = unified.coreIndexingProgress
	            if progress.total > 0, let percent = progress.percent {
	                return "Syncing updates \(progress.processed)/\(progress.total) (\(percent)%)…"
	            }
	            if progress.processed > 0 {
	                return "Syncing updates (\(progress.processed))…"
	            }
	            return "Syncing updates…"
	        }
	        if unified.coreIndexingDisplayMode == .indexing || unified.isIndexing {
	            let progress = unified.coreIndexingProgress
	            if progress.total > 0 {
	                if let percent = progress.percent {
	                    return "Indexing \(progress.processed)/\(progress.total) sessions (\(percent)%)…"
	                }
	                return "Indexing \(progress.processed)/\(progress.total) sessions…"
	            }
	            if progress.processed > 0 {
	                return "Indexing \(progress.processed) sessions…"
	            }
	            return "Indexing sessions…"
	        }
	        if unified.isProcessingTranscripts {
	            return "Processing transcripts (core index)…"
	        }
	        if searchCoordinator.isRunning {
	            return "Searching…"
	        }
	        return ""
	    }

	    private var footerSessionCountText: String {
	        let visible = cachedRows.count
	        let total = cachedTotalSessionCount
	        let countText = visible != total
	            ? "\(visible) / \(total) Sessions"
	            : "\(total) Sessions"
	        if unified.showFavoritesOnly {
	            return "\(countText) | Saved only"
	        }
	        return countText
	    }

	    private var footerFreshnessText: String? {
	        guard let date = cachedLatestModifiedAt else { return nil }
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

    private func restoreFromArchive(_ session: Session) {
        guard let path = unified.claudeArchiveSidecarPath(for: session) else { return }
        do {
            try ClaudeArchiveRestore.restore(sidecarPath: path) // reads the gate via isEnabled
            showRestoredRelaunch = true
            // Optimistic overlay mutation: clear the archived flag in place.
            if let key = session.claudeArchiveJoinKey, var rec = unified.claudeArchive[key] {
                rec = ClaudeDesktopSidecarRecord(cliSessionID: rec.cliSessionID, title: rec.title,
                                                 isArchived: false, autoArchiveExempt: true,
                                                 sidecarPath: rec.sidecarPath, modifiedAt: rec.modifiedAt)
                unified.applyOptimisticClaudeArchive(rec, for: key)
            }
        } catch {
            NSLog("Claude archive restore failed: \(error)")
        }
    }

    private func copySessionID(_ id: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(id, forType: .string)
    }

    private func copyableSessionID(for session: Session) -> String? {
        if session.isSideChat {
            return nonEmptySessionID(session.parentSessionID)
        }
        if session.source == .antigravity {
            return AntigravitySessionIDHelper.deriveSessionID(from: session)
        }
        return nonEmptySessionID(session.id)
    }

    private func nonEmptySessionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func canCopyResumeCommand(_ session: Session, antigravityCLISessionID: String? = nil) -> Bool {
        switch session.source {
        case .claude:
            return true // falls back to --continue
        case .codex:
            return canResumeCodexInCLI(session)
                && (session.codexInternalSessionID != nil || session.codexFilenameUUID != nil)
        case .opencode:
            return true // session.id is the SQLite session ID; falls back to --continue
        case .hermes:
            return true
        case .copilot:
            return true // session.id from session.start; falls back to --continue
        case .cursor:
            return true // session.id from transcript UUID; falls back to --continue
        case .pi:
            return true // session file path or id; falls back to --continue
        case .antigravity:
            return (antigravityCLISessionID ?? AntigravitySessionIDHelper.deriveSessionID(from: session)) != nil
        default:
            return false
        }
    }

    private func copyResumeCommand(_ session: Session, antigravityCLISessionID: String? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch session.source {
        case .claude:
            let settings = ClaudeResumeSettings.shared
            let sid = ClaudeSessionIDHelper.deriveSessionID(from: session)
            let wd = ClaudeSessionIDHelper.projectRoot(for: session)
            let binary = settings.binaryPath.isEmpty ? "claude" : settings.binaryPath
            let builder = ClaudeResumeCommandBuilder()
            let core: String
            if let id = sid, !id.isEmpty {
                core = "\(builder.shellQuoteIfNeeded(binary)) --resume \(builder.shellQuoteIfNeeded(id))"
            } else {
                core = "\(builder.shellQuoteIfNeeded(binary)) --continue"
            }
            let command = wd.map { "cd \(builder.shellQuoteIfNeeded($0.path)) && \(core)" } ?? core
            pb.setString(command, forType: .string)

        case .codex:
            let settings = CodexResumeSettings.shared
            guard let sid = session.codexInternalSessionID ?? session.codexFilenameUUID else { return }
            let wd = settings.effectiveWorkingDirectory(for: session)
            let binary = settings.binaryOverride.isEmpty ? "codex" : settings.binaryOverride
            let builder = CodexResumeCommandBuilder()
            let core = "\(builder.shellQuoteIfNeeded(binary)) resume \(builder.shellQuoteIfNeeded(sid))"
            let command = wd.map { "cd \(builder.shellQuoteIfNeeded($0)) && \(core)" } ?? core
            pb.setString(command, forType: .string)

        case .opencode:
            let settings = OpenCodeSettings.shared
            let sid = session.id
            let wd = settings.effectiveWorkingDirectory(for: session)
            let binary = settings.binaryPath.isEmpty ? "opencode" : settings.binaryPath
            let builder = OpenCodeResumeCommandBuilder()
            let core: String
            if !sid.isEmpty {
                core = "\(builder.shellQuoteIfNeeded(binary)) --session \(builder.shellQuoteIfNeeded(sid))"
            } else {
                core = "\(builder.shellQuoteIfNeeded(binary)) --continue"
            }
            let command = wd.map { "cd \(builder.shellQuoteIfNeeded($0.path)) && \(core)" } ?? core
            pb.setString(command, forType: .string)

        case .hermes:
            let settings = HermesSettings.shared
            let sid = session.id
            let wd = effectiveWorkingDirectoryURL(for: session)
            let binary = settings.binaryPath.isEmpty ? "hermes" : settings.binaryPath
            let builder = HermesResumeCommandBuilder()
            let core = !sid.isEmpty
                ? "\(builder.shellQuoteIfNeeded(binary)) --resume \(builder.shellQuoteIfNeeded(sid))"
                : "\(builder.shellQuoteIfNeeded(binary)) --continue"
            let command = wd.map { "cd \(builder.shellQuoteIfNeeded($0.path)) && \(core)" } ?? core
            pb.setString(command, forType: .string)

        case .copilot:
            let settings = CopilotSettings.shared
            let sid = session.id
            let wd = settings.effectiveWorkingDirectory(for: session)
            let binary = settings.binaryPath.isEmpty ? "copilot" : settings.binaryPath
            let builder = CopilotResumeCommandBuilder()
            let core: String
            if !sid.isEmpty {
                core = "\(builder.shellQuoteIfNeeded(binary)) --resume=\(builder.shellQuoteIfNeeded(sid))"
            } else {
                core = "\(builder.shellQuoteIfNeeded(binary)) --continue"
            }
            let command = wd.map { "cd \(builder.shellQuoteIfNeeded($0.path)) && \(core)" } ?? core
            pb.setString(command, forType: .string)

        case .cursor:
            let settings = CursorSettings.shared
            let sid = session.id
            let wd = settings.effectiveWorkingDirectory(for: session)
            let plan = settings.copyCommandPlan(sessionID: sid)
            let builder = CursorResumeCommandBuilder()
            guard let core = try? builder.makeCoreCommand(strategy: plan.strategy, binaryCommand: plan.binary) else { return }
            let command = wd.map { "cd \(builder.shellQuoteIfNeeded($0.path)) && \(core)" } ?? core
            pb.setString(command, forType: .string)

        case .pi:
            let settings = PiSettings.shared
            let sid = session.id
            let wd = settings.effectiveWorkingDirectory(for: session)
            guard let plan = settings.copyCommandPlan(sessionID: sid) else { return }
            let builder = PiResumeCommandBuilder()
            guard let core = try? builder.makeCoreCommand(strategy: plan.strategy,
                                                          binaryCommand: plan.binary,
                                                          sessionDirectory: plan.sessionDirectory?.path) else { return }
            let command = wd.map { "cd \(builder.shellQuoteIfNeeded($0.path)) && \(core)" } ?? core
            pb.setString(command, forType: .string)

        case .antigravity:
            let settings = AntigravityCLISettings.shared
            guard let sid = antigravityCLISessionID ?? AntigravitySessionIDHelper.deriveSessionID(from: session) else { return }
            let wd = settings.effectiveWorkingDirectory(for: session)
            let binary = settings.binaryOverride.isEmpty ? "agy" : settings.binaryOverride
            let builder = AntigravityResumeCommandBuilder()
            let core = "\(builder.shellQuoteIfNeeded(binary)) --conversation \(builder.shellQuoteIfNeeded(sid))"
            let command = wd.map { "cd \(builder.shellQuoteIfNeeded($0.path)) && \(core)" } ?? core
            pb.setString(command, forType: .string)

        default:
            break
        }
    }

	    private var transcriptPane: some View {
	        ZStack {
	            // Base host is always mounted to keep a stable split subview identity
	            TranscriptHostView(kind: selectionSource ?? lastSelectedSource,
	                               selection: settledSelection,
	                               codexIndexer: codexIndexer,
                               claudeIndexer: claudeIndexer,
                               antigravityIndexer: antigravityIndexer,
                               opencodeIndexer: opencodeIndexer,
                               hermesIndexer: hermesIndexer,
                               copilotIndexer: copilotIndexer,
                               droidIndexer: droidIndexer,
                               openclawIndexer: openclawIndexer,
                               cursorIndexer: cursorIndexer,
                               piIndexer: piIndexer)
                .environmentObject(focusCoordinator)
                .environmentObject(searchState)
                .id("transcript-host")
                .transaction { txn in txn.disablesAnimations = true }

            if shouldShowLaunchOverlay {
                launchBlockingTranscriptOverlay()
            } else if let s = selectedSession {
                if !s.isSideChat && !FileManager.default.fileExists(atPath: s.filePath) {
                    let providerName: String = {
                        switch s.source {
                        case .codex: return "Codex"
                        case .claude: return "Claude"
                        case .antigravity: return "Antigravity"
                        case .opencode: return "OpenCode"
                        case .hermes: return "Hermes"
                        case .copilot: return "Copilot"
                        case .droid: return "Droid"
                        case .openclaw: return "OpenClaw"
                        case .cursor: return "Cursor"
                        case .pi: return "Pi"
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
                } else if s.source == .antigravity, antigravityIndexer.unreadableSessionIDs.contains(s.id) {
                    VStack(spacing: 12) {
                        Label("Could not open session", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(sourceAccent(s))
                        Text("This Antigravity session could not be parsed. It may be truncated or corrupted.")
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
            } else if selection == nil {
                Text("Select a session to view transcript")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transaction { txn in txn.disablesAnimations = true }
        .simultaneousGesture(TapGesture().onEnded {
            NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
        })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 12) {
                ActiveSessionsOnlyToggle(isOn: $showActiveSessionsOnly)
                    .disabled(!liveSessionsFeatureEnabled)
                    .help(
                        liveSessionsFeatureEnabled
                            ? "Show only live sessions in the list (Codex, Claude)"
                            : "Enable Live sessions + Cockpit (Beta) in Settings → Agent Cockpit."
                    )

                Button(action: { showSubagentHierarchy.toggle() }) {
                    Image(systemName: showSubagentHierarchy ? "list.bullet.indent" : "list.bullet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(showSubagentHierarchy ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showSubagentHierarchy ? "Flat session list (⇧⌘H)" : "Show subagent hierarchy (⇧⌘H)")
                .keyboardShortcut("h", modifiers: [.command, .shift])

                // Collapse/Expand-all only apply while browsing the subagent
                // hierarchy, so keep them out of the toolbar entirely in the
                // common flat-list mode rather than showing them disabled.
                if isHierarchyBrowsing {
                    ToolbarIconButton(help: "Collapse all visible parent sessions") { isHovering in
                        ToolbarIcon(systemName: "arrow.down.right.and.arrow.up.left", opacity: isHovering ? 1 : 0.55)
                    } action: {
                        collapseAllHierarchyParents()
                    }
                    .disabled(currentExpandableParentIDs.isEmpty)

                    ToolbarIconButton(help: "Expand all visible parent sessions") { isHovering in
                        ToolbarIcon(systemName: "arrow.up.left.and.arrow.down.right", opacity: isHovering ? 1 : 0.55)
                    } action: {
                        expandAllHierarchyParents()
                    }
                    .disabled(collapsedParents.isEmpty)
                }

                if codexAgentEnabled {
                    Button("") { unified.includeCodex.toggle() }
                        .keyboardShortcut("1", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)

                    CodexSegmentedPill(
                        isCodexOn: $unified.includeCodex,
                        isArchivedOn: $unified.showArchivedCodexDesktopOnly,
                        isMonochrome: stripMonochrome
                    )
                    .help("Show or hide Codex sessions (⌘1). Archive icon: narrow Codex results to archived sessions; other enabled agents remain visible.")
                }

                if claudeAgentEnabled {
                    Button("") { unified.includeClaude.toggle() }
                        .keyboardShortcut("2", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)

                    ClaudeSegmentedPill(
                        isClaudeOn: $unified.includeClaude,
                        isArchivedOn: $unified.showArchivedClaudeDesktopOnly,
                        isMonochrome: stripMonochrome
                    )
                    .help("Show or hide Claude sessions (⌘2). Archive icon: narrow Claude results to archived Desktop sessions; other enabled agents remain visible.")
                }

                // Codex + Claude stay as pills; the remaining enabled agents show
                // as pills while the toolbar is uncrowded, and collapse into a
                // filter menu once more than four agents are enabled (⌘ shortcuts
                // are preserved either way).
                agentToggleControls()
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
                help: "Show only saved sessions",
                activeColor: .primary,
                accessibilityLabel: "Saved"
            )

            AnalyticsButtonView(
                isReady: analyticsReady,
                phase: analyticsPhase,
                isStale: analyticsIsStale
            )

            ToolbarGroupDivider()

            ToolbarIconButton(help: "Resume the selected session in its original CLI (⌃⌘R).") { _ in
                ToolbarIcon(systemName: "terminal")
            } action: {
                if let s = selectedSession { resume(s) }
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(!canResumeSelectedSession)
            .accessibilityLabel(Text("Resume"))

            ToolbarIconButton(help: "Reveal the selected session's working directory in Finder (⌘⇧O)") { _ in
                ToolbarIcon(systemName: "folder")
            } action: {
                if let s = selectedSession { openDir(s) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(selectedSession == nil)
            .accessibilityLabel(Text("Open Working Directory"))

            ToolbarIconButton(help: "Refresh sessions list/index (core indexing, not Analytics) (⌘R)") { _ in
                ZStack {
                    ToolbarIcon(systemName: "arrow.clockwise")
                        .opacity(unified.isIndexing || unified.isProcessingTranscripts ? 0.35 : 1)
                    if unified.isIndexing || unified.isProcessingTranscripts {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 7, height: 7)
                            .offset(x: 8, y: -8)
                    }
                }
            } action: {
                activeCodexSessions.refreshNow()
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

            ToolbarIconButton(
                help: liveSessionsFeatureEnabled
                    ? "Open Agent Cockpit."
                    : "Enable Live sessions + Cockpit (Beta) in Settings → Agent Cockpit."
            ) { _ in
                ToolbarIcon(systemName: "rectangle.3.group")
            } action: {
                openWindow(id: "AgentCockpit")
            }
            .disabled(!liveSessionsFeatureEnabled)
            .accessibilityLabel(Text("Agent Cockpit"))

            ToolbarGroupDivider()

            ToolbarIconToggle(
                isOn: $showTranscriptWindow,
                onSymbol: "sidebar.right",
                offSymbol: "sidebar.right",
                help: showTranscriptWindow ? "Hide Transcript window" : "Show Transcript window",
                activeColor: .primary,
                accessibilityLabel: "Transcript Window"
            )

            LayoutToggleButton(layoutMode: layoutMode, onToggleLayout: onToggleLayout)

            ToolbarIconButton(help: effectiveColorScheme == .dark ? "Switch to Light Mode" : "Switch to Dark Mode") { _ in
                ToolbarIcon(systemName: effectiveColorScheme == .dark ? "sun.max" : "moon")
            } action: {
                codexIndexer.toggleDarkLight(systemScheme: systemColorScheme)
            }
            .accessibilityLabel(Text("Toggle Dark/Light"))

            ToolbarIconButton(help: "Open settings for appearance, indexing, and agents (⌘,)") { isHovering in
                ToolbarIcon(systemName: "gearshape", opacity: isHovering ? 1 : 0.4)
            } action: {
                PreferencesWindowController.shared.show(indexer: codexIndexer, updaterController: updaterController)
            }
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel(Text("Settings"))
        }
    }

    /// Enabled agents other than Codex/Claude (which always render as segmented
    /// pills), in the fixed order they've historically appeared in the toolbar.
    private var enabledOtherAgentSpecs: [AgentToolbarSpec] {
        var specs: [AgentToolbarSpec] = []
        if antigravityAgentEnabled {
            specs.append(.init(id: "antigravity", title: "Antigravity", color: .teal, isOn: $unified.includeAntigravity, shortcut: "3"))
        }
        if openCodeAgentEnabled {
            specs.append(.init(id: "opencode", title: "OpenCode", color: .purple, isOn: $unified.includeOpenCode, shortcut: "4"))
        }
        if hermesAgentEnabled {
            specs.append(.init(id: "hermes", title: "Hermes", color: TranscriptColorSystem.agentBrandAccent(source: .hermes), isOn: $unified.includeHermes, shortcut: nil))
        }
        if copilotAgentEnabled {
            specs.append(.init(id: "copilot", title: "Copilot", color: Color.agentCopilot, isOn: $unified.includeCopilot, shortcut: "5"))
        }
        if droidAgentEnabled {
            specs.append(.init(id: "droid", title: "Droid", color: Color.agentDroid, isOn: $unified.includeDroid, shortcut: "6"))
        }
        if openClawAgentEnabled {
            specs.append(.init(id: "openclaw", title: "OpenClaw", color: Color.agentOpenClaw, isOn: $unified.includeOpenClaw, shortcut: "7"))
        }
        if cursorAgentEnabled {
            specs.append(.init(id: "cursor", title: "Cursor", color: Color.agentCursor, isOn: $unified.includeCursor, shortcut: "8"))
        }
        if piAgentEnabled {
            specs.append(.init(id: "pi", title: "Pi", color: Color.agentPi, isOn: $unified.includePi, shortcut: "9"))
        }
        return specs
    }

    /// Total enabled agents including Codex/Claude — drives when the other agents
    /// collapse into the overflow menu.
    private var enabledAgentCount: Int {
        (codexAgentEnabled ? 1 : 0) + (claudeAgentEnabled ? 1 : 0) + enabledOtherAgentSpecs.count
    }

    @ViewBuilder
    private func agentToggleControls() -> some View {
        let specs = enabledOtherAgentSpecs
        if enabledAgentCount > 4 {
            AgentOverflowMenu(specs: specs)
            // Keep ⌘3–9 working while the pills are collapsed into the menu.
            ForEach(specs) { spec in
                if let sc = spec.shortcut {
                    Button("") { spec.isOn.wrappedValue.toggle() }
                        .keyboardShortcut(sc, modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                }
            }
        } else {
            ForEach(specs) { spec in
                agentPill(spec)
            }
        }
    }

    @ViewBuilder
    private func agentPill(_ spec: AgentToolbarSpec) -> some View {
        let pill = AgentTabToggle(title: spec.title, color: spec.color, isMonochrome: stripMonochrome, isOn: spec.isOn)
            .help("Show or hide \(spec.title) sessions in the list")
        if let sc = spec.shortcut {
            pill.keyboardShortcut(sc, modifiers: .command)
        } else {
            pill
        }
    }

            private var selectedSession: Session? { selection.flatMap { id in cachedRowByID[id] } }

            static func sideChatParentContexts(for rows: [Session],
                                                       allSessions: [Session]) -> [String: String] {
                let candidates = rows + allSessions
                var titleByParentKey: [String: String] = [:]
                titleByParentKey.reserveCapacity(candidates.count * 2)
                for session in candidates where !session.isSideChat {
                    let title = session.listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    titleByParentKey[session.id] = title
                    if let internalID = session.codexInternalSessionIDHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !internalID.isEmpty {
                        titleByParentKey[internalID] = title
                    }
                }

                var contexts: [String: String] = [:]
                for session in rows where session.isSideChat {
                    guard let parentID = session.parentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !parentID.isEmpty else {
                        continue
                    }
                    contexts[session.id] = titleByParentKey[parentID] ?? shortenedParentID(parentID)
                }
                return contexts
            }

            private static func shortenedParentID(_ id: String) -> String {
                guard id.count > 12 else { return id }
                return "\(id.prefix(8))…"
            }

            private var currentExpandableParentIDs: Set<String> {
                guard isHierarchyBrowsing else { return [] }
                return cachedExpandableParentIDs
            }

            private var parentIDForSelectedHierarchyChild: String? {
                UnifiedHierarchyCommandPolicy.parentIDForSelectedHierarchyChild(
                    rowIDs: cachedRowIDs,
                    rowMeta: hierarchyRowMeta,
                    selectedID: selection
                )
            }

            private func collapseAllHierarchyParents() {
                let parentIDs = currentExpandableParentIDs
                guard !parentIDs.isEmpty else { return }
                if let parentID = parentIDForSelectedHierarchyChild,
                   let parent = cachedRows.first(where: { $0.id == parentID }) {
                    setActiveSelection(parentID, source: parent.source, userInitiated: false)
                }
                collapsedParents = UnifiedHierarchyCommandPolicy.collapsedParentsAfterCollapseAll(
                    existing: collapsedParents,
                    visibleParentIDs: parentIDs
                )
            }

            private func expandAllHierarchyParents() {
                guard isHierarchyBrowsing else { return }
                guard !collapsedParents.isEmpty else { return }
                collapsedParents = UnifiedHierarchyCommandPolicy.collapsedParentsAfterExpandAll(
                    existing: collapsedParents,
                    visibleParentIDs: currentExpandableParentIDs
                )
            }

            private func loadPersistedCollapsedParentsIfNeeded() {
                guard !hasLoadedPersistedCollapsedParents else { return }
                hasLoadedPersistedCollapsedParents = true
                collapsedParents = Self.decodeCollapsedHierarchyParents(collapsedHierarchyParentsRaw)
            }

            private func persistCollapsedParents() {
                collapsedHierarchyParentsRaw = Self.encodeCollapsedHierarchyParents(collapsedParents)
            }

            private static func encodeCollapsedHierarchyParents(_ ids: Set<String>) -> String {
                ids.sorted().joined(separator: "\n")
            }

            private static func decodeCollapsedHierarchyParents(_ raw: String) -> Set<String> {
                Set(raw.split(separator: "\n").map(String.init))
            }

		    private var tableSingleSelection: Binding<String?> {
	        Binding(
	            get: {
	                guard let id = selection else { return nil }
                    guard UnifiedTableSelectionPolicy.shouldExposeCanonicalSelectionToTable(
                        selectionPresentInRows: cachedVisibleRowIDs.contains(id)
                    ) else {
                        return nil
                    }
	                return id
	            },
	            set: { newID in
	                if let newID {
	                    let source = cachedRows.first(where: { $0.id == newID })?.source
	                    selectionTrace("table set newID=\(newID) source=\(source?.rawValue ?? "nil")")
	                    setActiveSelection(newID, source: source, userInitiated: true)
	                    autoSelectEnabled = false
	                    NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
	                    return
	                }

	                let shouldClearSelection = UnifiedTableSelectionPolicy
	                    .shouldClearCanonicalSelectionOnTableDeselection(
	                        isDatasetChurning: isDatasetChurning,
	                        currentSelectionID: selection,
		                        visibleRowIDs: cachedVisibleRowIDs
		                    )
	                let userInitiated = isLikelyUserInitiatedTableDeselection()
	                selectionTrace(
		                    "table clear-request current=\(selection ?? "nil") shouldClear=\(shouldClearSelection) userInitiated=\(userInitiated) churning=\(isDatasetChurning) visibleCount=\(cachedVisibleRowIDs.count)"
	                )
	                guard userInitiated else { return }
	                guard shouldClearSelection else { return }
	                setActiveSelection(nil, userInitiated: true)
	                autoSelectEnabled = false
	                NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
	            }
	        )
	    }

    private var imagesToolbarHelpText: String {
        return "Show images for the selected session"
    }

    // Local helper for absolute time formatting
    private func absoluteTimeUnified(_ date: Date?) -> String {
        guard let date else { return "" }
        return AppDateFormatting.dateTimeShort(date)
    }

	    @MainActor
	    private func setActiveSelection(_ id: String?, source: SessionSource? = nil, userInitiated: Bool) {
	        selectionTrace("setActiveSelection id=\(id ?? "nil") source=\(source?.rawValue ?? "nil") userInitiated=\(userInitiated)")
	        if userInitiated {
	            hasUserManuallySelected = true
	        }
	        selection = id

	        guard let id else { return }

	        if let source {
	            selectionSource = source
	            lastSelectedSource = source
	            return
	        }

	        if let row = cachedRows.first(where: { $0.id == id }) {
	            selectionSource = row.source
	            lastSelectedSource = row.source
	        }
	    }

	    @MainActor
	    private func ensureDefaultSelectionIfNeeded() {
	        guard selection == nil, !hasUserManuallySelected else { return }
	        guard let first = cachedRows.first else { return }
	        setActiveSelection(first.id, source: first.source, userInitiated: false)
	    }

	    @MainActor
	    private func refreshSelectionSourceFromCachedRows() {
	        guard let id = selection else { return }
	        guard let row = cachedRows.first(where: { $0.id == id }) else { return }
	        selectionSource = row.source
	        lastSelectedSource = row.source
	        selectionTrace("refreshSelectionSource id=\(id) source=\(row.source.rawValue)")
	    }

	    private func isLikelyUserInitiatedTableDeselection() -> Bool {
	        guard let event = NSApp.currentEvent else { return false }
	        switch event.type {
	        case .leftMouseDown, .leftMouseUp,
	             .rightMouseDown, .rightMouseUp,
	             .otherMouseDown, .otherMouseUp,
	             .keyDown:
	            return true
	        default:
	            return false
	        }
	    }

	    private var selectionTraceEnabled: Bool {
	        ProcessInfo.processInfo.environment["AGENTSESSIONS_TRACE_SELECTION"] == "1"
	            || UserDefaults.standard.bool(forKey: "DebugTraceSelection")
	    }

	    private func selectionTrace(_ message: @autoclosure () -> String) {
	        #if DEBUG
	        guard selectionTraceEnabled else { return }
	        print("🧭[Selection] \(message())")
	        #endif
	    }

    private func showImagesForSelectedSession(showNoSelectionAlert: Bool) {
        guard let session = selectedSession else {
            if showNoSelectionAlert {
                showActionAlert(message: "Select a session to view images.")
            }
            return
        }
        CodexImagesWindowController.shared.show(session: session, allSessions: unified.allSessions)
    }

    private func showActionAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

	    private func handleSelectionChange(_ id: String?) {
	        guard let id, let s = cachedRowByID[id] else {
	            cancelAutoJump()
	            selectionPropagationTask?.cancel()
	            selectionPropagationTask = nil
	            settledSelection = nil
	            updateFocusedSessionIfNeeded(nil)
	            return
	        }
	        ListScrubSignal.shared.noteSelectionChange()
        // Only the cheap, selection-visual-relevant work runs synchronously in
        // this SwiftUI update turn: the row lookup and presence-probe deferral.
        // This is what lets the native selection highlight paint on the NEXT
        // runloop turn instead of waiting behind transcript-pane teardown/reload —
        // see the deferred block below. Search auto-jump is requested from inside
        // that deferred block too (once selection settles), not here.
        activeCodexSessions.deferExpensiveProbesForSelectionOpen()
	        selectionSource = s.source
	        lastSelectedSource = s.source

        if searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancelAutoJump()
        }
        // If a large, unparsed session is clicked during an active search, promote it in the coordinator.
        let sizeBytes = s.fileSizeBytes ?? 0
        if searchCoordinator.isRunning, s.events.isEmpty, sizeBytes >= 10 * 1024 * 1024 {
            searchCoordinator.promote(id: s.id)
        }

        // Everything below triggers transcript-pane work (focus transition,
        // per-source reload/parse, transcript prewarm). It waits for a short
        // stability window instead of just the next runloop turn: key-repeat
        // events during list scrubbing arrive every ~30-90ms, and a next-turn
        // defer always lands between two of them, so the staleness guard used
        // to pass for EVERY scrubbed row — each one fired a full transcript
        // teardown+reload (measured 120-290% CPU, ~1s perceived latency,
        // independent of list size). Debouncing to 150ms — comfortably above
        // the key-repeat interval, but still imperceptible for a single
        // click/arrow-key press — coalesces a whole scrub into one propagation
        // for the row the user actually rests on.
        selectionPropagationTask?.cancel()
        // Sample the flag now, synchronously: isAutoSelectingFromSearch is reset by a
        // DispatchQueue.main.async on the very next runloop turn after search auto-selection
        // sets it, which always fires well before this task's 150ms sleep wakes. Re-reading
        // the @State var inside the propagation body would therefore always observe false.
        let wasAutoSelectingFromSearch = isAutoSelectingFromSearch
        selectionPropagationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, selection == id else { return }
            Perf.event("selectionPropagate", "id=\(id.prefix(8))")
            settledSelection = id
            // Count a session-open for the feedback-ask trigger (debounced settle
            // fires once per rested selection, not per key-repeat scrub).
            onboardingCoordinator.noteSessionOpened()
            // Auto-jump to the first search-term occurrence in the transcript, but only once
            // the transcript pane's own selection (settledSelection) is about to match this id —
            // TranscriptPlainView gates its match on searchState.autoJumpSessionID == session.id,
            // where session.id tracks settledSelection, not the raw (possibly still-scrubbing)
            // selection. Requesting the jump here (instead of eagerly in the raw-selection
            // branch above) keeps the two in lockstep so manual clicks/arrows land the same
            // instant auto-jump the first search-selected result already gets.
            scheduleAutoJump(for: id)
            // When selection is changed due to search auto-selection, do not steal focus or collapse inline search
            if !wasAutoSelectingFromSearch {
                // CRITICAL: Selecting session FORCES cleanup of all search UI (Apple Notes behavior)
                focusCoordinator.perform(.selectSession(id: id))
                NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
            }
            // Lazy load full session per source. Parse + model build run off-main and the
            // windowed build paints only the tail window, so hydration always proceeds
            // immediately on selection (no manual "Show full transcript" gate).
            let requestedSelectionReload = reloadSessionForSource(s)
            searchCoordinator.prewarmTranscriptIfNeeded(for: s, allowParsingLightweight: !requestedSelectionReload)
            updateFocusedSessionIfNeeded(s)
        }
    }

    private struct CockpitNavigationTarget {
        let unifiedSessionID: String
        let source: SessionSource?
        let runtimeSessionID: String?
        let logPath: String?
        let workingDirectory: String?
    }

    private func handleNavigateToSessionFromCockpit(_ notification: Notification) {
        guard let unifiedSessionID = notification.object as? String else { return }
        let sourceRaw = notification.userInfo?[CockpitNavigationUserInfoKey.source] as? String
        let source = sourceRaw.flatMap(SessionSource.init(rawValue:))
        let target = CockpitNavigationTarget(
            unifiedSessionID: unifiedSessionID,
            source: source,
            runtimeSessionID: notification.userInfo?[CockpitNavigationUserInfoKey.runtimeSessionID] as? String,
            logPath: notification.userInfo?[CockpitNavigationUserInfoKey.logPath] as? String,
            workingDirectory: notification.userInfo?[CockpitNavigationUserInfoKey.workingDirectory] as? String
        )
        _ = handleCockpitNavigation(target, emitBeepOnFailure: false)
    }

    @discardableResult
    private func handleCockpitNavigation(_ target: CockpitNavigationTarget, emitBeepOnFailure: Bool) -> Bool {
        guard let session = resolveCockpitNavigationTarget(target) else {
            if emitBeepOnFailure {
                NSSound.beep()
            }
            return false
        }

        let wasVisible = cachedRows.contains(where: { $0.id == session.id })
        if !wasVisible {
            applyAutoRevealFiltersForCockpitNavigation(session)
            _ = updateCachedRows()
        }

        guard cachedRows.contains(where: { $0.id == session.id }) else {
            if emitBeepOnFailure {
                NSSound.beep()
            }
            return false
        }

        let selectedSource = cachedRows.first(where: { $0.id == session.id })?.source ?? session.source
        setActiveSelection(session.id, source: selectedSource, userInitiated: true)
        focusCoordinator.perform(.selectSession(id: session.id))
        NotificationCenter.default.post(name: .collapseInlineSearchIfEmpty, object: nil)
        updateFocusedSessionIfNeeded(session)
        CockpitNavigationBridge.clearIfMatching(unifiedSessionID: target.unifiedSessionID)

        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.title == "Agent Sessions" }) ?? NSApp.mainWindow {
            main.makeKeyAndOrderFront(nil)
        }
        return true
    }

    private func tryHandlePendingCockpitNavigationIfNeeded() {
        guard let pending = CockpitNavigationBridge.load() else { return }
        if Date().timeIntervalSince(pending.createdAt) > 45 {
            CockpitNavigationBridge.clear()
            return
        }

        let source = pending.sourceRawValue.flatMap(SessionSource.init(rawValue:))
        let target = CockpitNavigationTarget(
            unifiedSessionID: pending.unifiedSessionID,
            source: source,
            runtimeSessionID: pending.runtimeSessionID,
            logPath: pending.logPath,
            workingDirectory: pending.workingDirectory
        )
        _ = handleCockpitNavigation(target, emitBeepOnFailure: false)
    }

    private func resolveCockpitNavigationTarget(_ target: CockpitNavigationTarget) -> Session? {
        let scoped = unified.allSessions.filter { session in
            guard let source = target.source else { return true }
            return session.source == source
        }

        if let direct = scoped.first(where: { $0.id == target.unifiedSessionID }) {
            return direct
        }

        if let logPath = target.logPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !logPath.isEmpty {
            let normalized = CodexActiveSessionsModel.normalizePath(logPath)
            if let match = scoped.first(where: {
                CodexActiveSessionsModel.normalizePath($0.filePath) == normalized
            }) {
                return match
            }
        }

        if let runtimeSessionID = target.runtimeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimeSessionID.isEmpty {
            if let match = scoped.first(where: {
                CodexActiveSessionsModel.liveSessionIDCandidates(for: $0).contains(runtimeSessionID)
            }) {
                return match
            }
        }

        // cwd-only fallback intentionally omitted — prefer "no navigation"
        // over navigating to a potentially wrong session from the same directory.
        return nil
    }

    private func applyAutoRevealFiltersForCockpitNavigation(_ session: Session) {
        ensureSourceIncludedForCockpitNavigation(session.source)

        if showActiveSessionsOnly, !isSessionLive(session) {
            showActiveSessionsOnly = false
        }
        if unified.showFavoritesOnly {
            unified.showFavoritesOnly = false
        }
        if unified.showArchivedCodexDesktopOnly, session.source == .codex, !session.isArchivedCodexDesktopSession {
            unified.showArchivedCodexDesktopOnly = false
        }

        if !unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !unified.query.isEmpty {
            unified.queryDraft = ""
            unified.query = ""
            searchCoordinator.cancel()
        }

        if unified.projectFilter != nil { unified.projectFilter = nil }
        if unified.dateFrom != nil { unified.dateFrom = nil }
        if unified.dateTo != nil { unified.dateTo = nil }
        if unified.selectedModel != nil { unified.selectedModel = nil }
        let allKinds = Set(SessionEventKind.allCases)
        if unified.selectedKinds != allKinds {
            unified.selectedKinds = allKinds
        }
        unified.recomputeNow()
    }

    private func ensureSourceIncludedForCockpitNavigation(_ source: SessionSource) {
        switch source {
        case .codex:
            if !unified.includeCodex { unified.includeCodex = true }
        case .claude:
            if !unified.includeClaude { unified.includeClaude = true }
        case .antigravity:
            if !unified.includeAntigravity { unified.includeAntigravity = true }
        case .opencode:
            if !unified.includeOpenCode { unified.includeOpenCode = true }
        case .hermes:
            if !unified.includeHermes { unified.includeHermes = true }
        case .copilot:
            if !unified.includeCopilot { unified.includeCopilot = true }
        case .droid:
            if !unified.includeDroid { unified.includeDroid = true }
        case .openclaw:
            if !unified.includeOpenClaw { unified.includeOpenClaw = true }
        case .cursor:
            if !unified.includeCursor { unified.includeCursor = true }
        case .pi:
            if !unified.includePi { unified.includePi = true }
        }
    }

    private func handleWindowDidBecomeKey() {
        isWindowKey = true
        updateFocusedSessionIfNeeded(selectedSession)
    }

    private func handleWindowDidResignKey() {
        isWindowKey = false
    }

    private func handleWindowWillClose() {
        isWindowKey = false
        unified.setFocusedSession(nil)
    }

    private func updateFocusedSessionIfNeeded(_ session: Session?) {
        guard isWindowKey else { return }
        unified.setFocusedSession(session)
    }

    /// Per-source lazy reload of a session's full content. Returns true if a reload was started.
    @discardableResult
    private func reloadSessionForSource(_ s: Session) -> Bool {
        let id = s.id
        // Mirror the agent-enabled guards on the canonical focused-reload dispatch
        // (UnifiedSessionIndexer.focusedMonitorCapabilityBySource): don't reload a
        // source the user has disabled.
        switch s.source {
        case .codex:
            // isPartiallyHydrated (Task 9e stage 0 tail-first paint) must not look
            // "already loaded" here — otherwise a second selection-change on the
            // same still-hydrating session (re-fired list selection, etc.) would
            // skip re-dispatching reloadSession. reloadSession's own
            // reloadingSessionIDs guard already de-dupes a genuinely in-flight
            // parse, so this is a safety net, not the primary de-dupe.
            if unified.codexAgentEnabled, let e = codexIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty || e.isPartiallyHydrated { codexIndexer.reloadSession(id: id); return true }
        case .claude:
            if unified.claudeAgentEnabled, let e = claudeIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty { claudeIndexer.reloadSession(id: id); return true }
        case .antigravity:
            if unified.antigravityAgentEnabled, let e = antigravityIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty { antigravityIndexer.reloadSession(id: id); return true }
        case .opencode:
            if unified.openCodeAgentEnabled, let e = opencodeIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty { opencodeIndexer.reloadSession(id: id); return true }
        case .hermes:
            if unified.hermesAgentEnabled, let e = hermesIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty { hermesIndexer.reloadSession(id: id); return true }
        case .copilot:
            if unified.copilotAgentEnabled, let e = copilotIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty { copilotIndexer.reloadSession(id: id); return true }
        case .droid:
            if unified.droidAgentEnabled, let e = droidIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty { droidIndexer.reloadSession(id: id); return true }
        case .openclaw:
            if unified.openClawAgentEnabled, let e = openclawIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty { openclawIndexer.reloadSession(id: id); return true }
        case .cursor:
            if unified.cursorAgentEnabled, let e = cursorIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty, !CursorSessionIndexer.isDBOnlySession(e) { cursorIndexer.reloadSession(id: id); return true }
        case .pi:
            if unified.piAgentEnabled, let e = piIndexer.allSessions.first(where: { $0.id == id }), e.events.isEmpty { piIndexer.reloadSession(id: id); return true }
        }
        return false
    }

        /// Phases 0-3 of a rows rebuild: cheap main-actor bookkeeping (fallback
        /// presences, `nextRows` filter/sort, hold-rows-during-churn checks). Shared
        /// by both the synchronous path (`updateCachedRows()`) and the off-main
        /// path (`updateCachedRowsAsync()`) so the two never diverge on what
        /// counts as "hold" vs "rebuild".
        ///
        /// Returns nil when the rebuild should be held (rows left exactly as-is);
        /// otherwise the `SessionRowsBuilder.RowsInput` snapshot for the heavy
        /// phase, ready to run sync or via `Task.detached`.
        private func prepareRowsRebuild() -> SessionRowsBuilder.RowsInput? {
            selectionReplacementDeferredDuringChurn = false
            // Cheap main-actor step only: the direct-join lookup itself must run
            // here (CodexActiveSessionsModel.presence(for:) reads main-actor-only
            // lookup caches), but the heavy fallback-presence grouping/sorting
            // moves into SessionRowsBuilder.build, off-main (W7 Task 1 Step 6c;
            // was `rebuildCachedFallbackPresences()`, computed unconditionally on
            // main under the "fallbackPresences" span every rebuild).
            let allSessionsForFallback = unified.allSessions
            let presencesForFallback = activeCodexSessions.presences
            let directJoinFallbackKeys = directJoinFallbackKeys(for: allSessionsForFallback)
            let nextRows: [Session]
            if FeatureFlags.coalesceListResort {
                // unified.sessions is already sorted by the view model's descriptor
                nextRows = rows
            } else {
                nextRows = rows.sorted(using: sortOrder)
            }
            cachedTotalSessionCount = unified.sessions.count
            cachedLatestModifiedAt = latestModifiedAt(in: unified.sessions) ?? latestModifiedAt(in: nextRows)

            let query = unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldHoldRowsDuringRunningSearch = UnifiedRowsStabilityPolicy.shouldHoldRowsDuringRunningSearch(
                isSearchRunning: searchCoordinator.isRunning,
                nextRowsEmpty: nextRows.isEmpty,
                showActiveSessionsOnly: showActiveSessionsOnly,
                cachedRowsEmpty: cachedRows.isEmpty
            )
            let shouldHoldRowsDuringTransientEmptyRefresh = UnifiedRowsStabilityPolicy.shouldHoldRowsDuringTransientEmptyRefresh(
                query: query,
                isSearchRunning: searchCoordinator.isRunning,
                isDatasetChurning: isDatasetChurning,
                isIndexing: unified.isIndexing,
                nextRowsEmpty: nextRows.isEmpty,
                showActiveSessionsOnly: showActiveSessionsOnly,
                cachedRowsEmpty: cachedRows.isEmpty,
                hasSelection: selection != nil
            )
            guard !(shouldHoldRowsDuringRunningSearch || shouldHoldRowsDuringTransientEmptyRefresh) else {
                return nil
            }

            return SessionRowsBuilder.RowsInput(
                nextRows: nextRows,
                allSessions: allSessionsForFallback,
                previousCachedRows: cachedRows,
                collapsedParents: collapsedParents,
                showSubagentHierarchy: showSubagentHierarchy,
                searchActive: !query.isEmpty,
                isHierarchyBrowsing: isHierarchyBrowsing,
                presences: presencesForFallback,
                directJoinFallbackKeys: directJoinFallbackKeys
            )
        }

        /// Apply a `SessionRowsBuilder` result on the main actor: assign
        /// cachedRows/hierarchy/derived state, bump `tableReorderGeneration` for a
        /// large reorder, then run the UNCHANGED selection-reconciliation block.
        /// `heldRows` reflects whether `prepareRowsRebuild()` held rows for this
        /// trigger (output is nil in that case — nothing to assign).
        @MainActor
        private func applyRowsOutput(_ output: SessionRowsBuilder.RowsOutput?) {
            if let output {
                if output.isLargeReorder {
                    tableReorderGeneration &+= 1
#if DEBUG
                    Perf.event("reorderRebuild", "rows=\(output.cachedRows.count) gen=\(tableReorderGeneration)")
#endif
                }
                cachedRows = output.cachedRows
                hierarchyRowMeta = output.hierarchyRowMeta
                sideChatParentContextByID = output.sideChatParentContextByID
                cachedRowIDs = output.cachedRowIDs
                cachedVisibleRowIDs = output.cachedVisibleRowIDs
                cachedExpandableParentIDs = output.cachedExpandableParentIDs
                cachedRowByID = output.cachedRowByID
                cachedSurfacePillsBySessionID = output.surfacePillsBySessionID
                cachedFallbackPresenceBySessionKey = output.fallbackPresenceBySessionKey
            }

            if let selectedID = selection,
               !cachedRows.contains(where: { $0.id == selectedID }) {
                if UnifiedTableSelectionPolicy.shouldReplaceMissingSelection(
                    hierarchyBrowsing: isHierarchyBrowsing,
                    refreshBusy: isRefreshBusyForSelection,
                    hasUserManuallySelected: hasUserManuallySelected,
                    datasetChurning: isDatasetChurning
                ) {
                    if let first = cachedRows.first {
                        setActiveSelection(first.id, source: first.source, userInitiated: false)
                    } else {
                        setActiveSelection(nil, userInitiated: false)
                    }
                } else if isDatasetChurning {
                    // Replacement would have happened but was suppressed solely by the
                    // churn gate — flag it so the post-churn pass knows to retry.
                    selectionReplacementDeferredDuringChurn = true
                }
            }

            ensureDefaultSelectionIfNeeded()
            refreshSelectionSourceFromCachedRows()
        }

        /// Synchronous rows rebuild — used by every call site except the heavy
        /// `unified.sessions` republish path (see `updateCachedRowsAsync()`).
        /// Returns `heldRows` (rows were intentionally left stale this call).
	    @discardableResult
	    private func updateCachedRows() -> Bool {
        rowsRebuildGeneration &+= 1
#if DEBUG
        // Snapshot the row count NOW: Perf detail closures are evaluated lazily in end()
        // (after cachedRows is reassigned below), so capture the pre-update value in a let.
        let _rowsBefore = cachedRows.count
        let _perfSpan = Perf.begin("updateCachedRows", thresholdMs: 8, "n=\(_rowsBefore) activeOnly=\(showActiveSessionsOnly)")
        defer { Perf.end(_perfSpan) }
        let startedAt = Date()
        defer {
            if showActiveSessionsOnly {
                let elapsedMs = Date().timeIntervalSince(startedAt) * 1000.0
                debugActiveOnlyUpdateRowsCount &+= 1
                debugActiveOnlyUpdateRowsTotalMs += elapsedMs
                debugActiveOnlyUpdateRowsMaxMs = max(debugActiveOnlyUpdateRowsMaxMs, elapsedMs)

                if elapsedMs > 25 {
                    print("[UnifiedSessionsView][perf] updateCachedRows active-only took \(String(format: "%.1f", elapsedMs))ms rows=\(cachedRows.count)")
                }

                let now = Date()
                if now.timeIntervalSince(debugActiveOnlyLastReportAt) >= 10, debugActiveOnlyUpdateRowsCount > 0 {
                    let avgMs = debugActiveOnlyUpdateRowsTotalMs / Double(debugActiveOnlyUpdateRowsCount)
                    print(
                        "[UnifiedSessionsView][perf] active-only updateCachedRows " +
                        "count=\(debugActiveOnlyUpdateRowsCount) avgMs=\(String(format: "%.1f", avgMs)) maxMs=\(String(format: "%.1f", debugActiveOnlyUpdateRowsMaxMs))"
                    )
                    debugActiveOnlyUpdateRowsCount = 0
                    debugActiveOnlyUpdateRowsTotalMs = 0
                    debugActiveOnlyUpdateRowsMaxMs = 0
                    debugActiveOnlyLastReportAt = now
                }
            }
        }
#endif
        guard let input = prepareRowsRebuild() else {
            applyRowsOutput(nil)
            return true
        }
#if DEBUG
        let _hbSpan = Perf.begin("hierarchyBuild", thresholdMs: 4, "rows=\(input.nextRows.count)")
#endif
        let output = SessionRowsBuilder.build(input: input)
#if DEBUG
        Perf.end(_hbSpan)
#endif
        applyRowsOutput(output)
        return false
	    }

        /// Off-main rows rebuild for the heavy `unified.sessions` republish path
        /// (Task 2): computes `SessionRowsBuilder.build` on a detached task, then
        /// applies the result on main IF this trigger's generation is still
        /// current — a newer trigger (another republish, or a synchronous
        /// `updateCachedRows()` call from a different onChange firing in between)
        /// supersedes it and this result is dropped, never interleaved.
        ///
        /// The hold/no-hold decision itself is cheap and made on main before the
        /// async hop, so callers needing `heldRows` get it via `completion`
        /// rather than a return value — only the heavy hierarchy/derived-state
        /// computation moves off-main.
        /// - Parameter completion: invoked on the main actor exactly once, either
        ///   synchronously before returning (rows held, nothing to compute) or
        ///   after the off-main compute applies. `heldRows` matches the
        ///   synchronous `updateCachedRows()` return value; `applied` is false
        ///   when a newer trigger superseded this one (the completion still
        ///   fires so callers can run their "did this pass finish" bookkeeping,
        ///   but must not treat a superseded pass as having produced fresh rows).
        private func updateCachedRowsAsync(completion: @escaping (_ heldRows: Bool, _ applied: Bool) -> Void) {
            rowsRebuildGeneration &+= 1
            let generation = rowsRebuildGeneration
#if DEBUG
            let _rowsBefore = cachedRows.count
            let _perfSpan = Perf.begin("updateCachedRows", thresholdMs: 8, "n=\(_rowsBefore) activeOnly=\(showActiveSessionsOnly) async=1")
            defer { Perf.end(_perfSpan) }
#endif
            guard let input = prepareRowsRebuild() else {
                applyRowsOutput(nil)
                completion(true, true)
                return
            }
            Task.detached(priority: .userInitiated) {
#if DEBUG
                let _hbSpan = Perf.begin("hierarchyBuild", thresholdMs: 4, "rows=\(input.nextRows.count) offMain=1")
#endif
                let output = SessionRowsBuilder.build(input: input)
#if DEBUG
                Perf.end(_hbSpan)
#endif
                await MainActor.run { [self] in
                    // Staleness discipline: only apply if no newer trigger has
                    // started since this one (a newer updateCachedRows()/
                    // updateCachedRowsAsync() call bumps rowsRebuildGeneration
                    // before this closure can run). A stale result is dropped
                    // silently — the newer trigger's own apply (sync or async)
                    // is authoritative and already reflects the latest input.
                    guard self.rowsRebuildGeneration == generation else {
#if DEBUG
                        Perf.event("rowsRebuildSuperseded", "gen=\(generation) current=\(self.rowsRebuildGeneration)")
#endif
                        completion(false, false)
                        return
                    }
                    self.applyRowsOutput(output)
                    completion(false, true)
                }
            }
        }

    private func latestModifiedAt(in sessions: [Session]) -> Date? {
        var latest: Date?
        for session in sessions {
            guard let current = latest else {
                latest = session.modifiedAt
                continue
            }
            if session.modifiedAt > current {
                latest = session.modifiedAt
            }
        }
        return latest
    }

    private var isHierarchyBrowsing: Bool {
        showSubagentHierarchy && searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isRefreshBusyForSelection: Bool {
        isDatasetChurning || unified.isIndexing || searchCoordinator.isRunning
    }

    // Called only from within the 150ms-settled selection-propagation task, i.e. once
    // `settledSelection` (and therefore the transcript pane's resolved session.id) is about
    // to match `sessionID`. Firing here — rather than eagerly off the raw selection stream —
    // is what keeps this request in lockstep with TranscriptPlainView's
    // `searchState.autoJumpSessionID == session.id` gate; see the call site for the full
    // rationale.
    private func scheduleAutoJump(for sessionID: String) {
        cancelAutoJump()
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchState.requestAutoJump(sessionID: sessionID)
    }

    private func cancelAutoJump() {
        // Clear any outstanding request so a transcript pane that hasn't caught up yet
        // (e.g. selection was cleared, or search was cleared mid-settle) doesn't apply a
        // stale jump once it does.
        searchState.autoJumpSessionID = nil
    }

	    private func refreshColumnLayout() {
	        columnLayoutID = UUID()
	        updateCachedRows()
	        ensureDefaultSelectionIfNeeded()
	        refreshSelectionSourceFromCachedRows()
	    }


    @ViewBuilder
    private func launchBlockingTranscriptOverlay() -> some View {
        launchAnimationView
            .allowsHitTesting(false)
    }

    private var shouldShowLaunchOverlay: Bool {
        false
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
        let isSelected = selection == session.id
        let presence: CodexActivePresence? = {
            guard activeCodexSessions.supportsLiveSessions(for: session.source) else { return nil }
            return livePresence(for: session)
        }()
        let liveState: CodexLiveState? = {
            guard let presence else { return nil }
            return activeCodexSessions.liveState(for: presence)
        }()
        let rowTextColor: Color = {
            if isSelected { return .white }
            return !stripMonochrome ? sourceAccent(session) : .secondary
        }()
        let rowDotColor: Color = {
            if let liveState {
                switch liveState {
                case .activeWorking:
                    return Color(hex: "30d158")
                case .openIdle:
                    return effectiveColorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
                }
            }
            if isSelected { return .white.opacity(0.95) }
            return !stripMonochrome ? sourceAccent(session) : .primary
        }()
        let liveOpacity: Double = liveState == .openIdle ? 0.60 : 1.0
        // Static part precomputed once per rows rebuild (SessionRowsBuilder.build);
        // only the live Claude Desktop archived bit is patched in here. Falls back
        // to the full per-call computation if the row hasn't been through a rebuild
        // yet (cache miss should not happen in steady state, but must never crash).
        let staticPills = cachedSurfacePillsBySessionID[session.id] ?? Self.staticSurfacePills(for: session)
        let surfacePills = Self.applyingLiveClaudeArchiveState(
            to: staticPills,
            session: session,
            isClaudeArchived: unified.isArchivedClaudeDesktop(session)
        )
        switch session.source {
        case .codex: label = "Codex"
        case .claude: label = "Claude"
        case .antigravity: label = "Antigravity"
        case .opencode: label = "OpenCode"
        case .hermes: label = "Hermes"
        case .copilot: label = "Copilot"
        case .droid: label = "Droid"
        case .openclaw: label = "OpenClaw"
        case .cursor: label = "Cursor"
        case .pi: label = "Pi"
        }
        let isSubagentRow = (hierarchyRowMeta[session.id]?.depth ?? 0) > 0
        return HStack(spacing: 6) {
            if isSubagentRow {
                Spacer().frame(width: 12)
            }
            if let liveState {
                CodexLiveStatusDot(
                    state: liveState,
                    color: rowDotColor,
                    size: 7,
                    lastSeenAt: presence?.lastSeenAt
                )
                    .accessibilityLabel(Text("\(label) \(liveState == .activeWorking ? "active" : "open") session"))
            }
            Text(label)
                .font(.system(size: 12, weight: isSubagentRow ? .light : .regular, design: .monospaced))
                .foregroundStyle(isSubagentRow ? rowTextColor.opacity(0.7) : rowTextColor)
            ForEach(surfacePills, id: \.identity) { surfacePill in
                Text(surfacePill.label)
                    .font(surfacePill.font)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(surfacePill.fill)
                    .foregroundStyle(surfacePill.foreground(isSelected: isSelected))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(surfacePill.stroke(isSelected: isSelected), lineWidth: surfacePill.strokeWidth)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel(surfacePill.accessibilityLabel(agentLabel: label))
            }
            Spacer(minLength: 4)
        }
        .opacity(liveOpacity)
        .id("source-cell-\(session.id)-\(Self.livePresenceSignature(state: liveState, lastSeenAt: presence?.lastSeenAt))")
    }

    /// Compact signature of the row's own visible live-state, used to key the
    /// Agent cell's `.id(...)`. Deliberately narrower than the global
    /// `activeCodexSessions.activeMembershipVersion` counter: that counter
    /// bumps on every live-presence poll tick regardless of whether *this*
    /// row's dot/label actually changed, which was forcing every Agent cell
    /// (and its gesture recognizers) to be torn down and recreated on every
    /// tick — eating in-flight double-clicks. Keying on the row's own derived
    /// (state, lastSeenAt) pair still forces re-identification exactly when
    /// this row's visible presence changes, and leaves untouched rows alone.
    private static func livePresenceSignature(state: CodexLiveState?, lastSeenAt: Date?) -> String {
        let stateToken = state?.rawValue ?? "none"
        let lastSeenToken = lastSeenAt.map { String($0.timeIntervalSince1970) } ?? "none"
        return "\(stateToken)-\(lastSeenToken)"
    }

    /// Surface-pill classification (`staticSurfacePills`, `surfacePills`,
    /// `applyingLiveClaudeArchiveState`, and their private helpers) lives in
    /// `SessionRowsBuilder` (Services) -- it's pure business logic over
    /// `Session` data with no SwiftUI dependency, whereas `CodexSurfacePill`
    /// itself stays here since it carries presentation (`Color`/`Font`)
    /// methods. These are thin forwarders so call sites in this file can keep
    /// using `Self.<name>(...)` (T2).
    static func staticSurfacePills(for session: Session) -> [CodexSurfacePill] {
        SessionRowsBuilder.staticSurfacePills(for: session)
    }

    static func applyingLiveClaudeArchiveState(
        to staticPills: [CodexSurfacePill],
        session: Session,
        isClaudeArchived: Bool
    ) -> [CodexSurfacePill] {
        SessionRowsBuilder.applyingLiveClaudeArchiveState(to: staticPills, session: session, isClaudeArchived: isClaudeArchived)
    }

    static func surfacePills(for session: Session, isClaudeArchived: Bool = false) -> [CodexSurfacePill] {
        SessionRowsBuilder.surfacePills(for: session, isClaudeArchived: isClaudeArchived)
    }

    struct CodexSurfacePill {
        let label: String
        let accessibilityLabel: String
        let usesFullAccessibilityLabel: Bool
        let isArchived: Bool

        var identity: String { "\(label)-\(isArchived ? "archived" : "standard")" }

        static func desktop(isArchived: Bool = false) -> CodexSurfacePill {
            CodexSurfacePill(
                label: "desk",
                accessibilityLabel: isArchived ? "Codex Desktop archived session" : "Desktop app",
                usesFullAccessibilityLabel: isArchived,
                isArchived: isArchived
            )
        }

        static func standard(label: String, accessibilityLabel: String) -> CodexSurfacePill {
            CodexSurfacePill(label: label, accessibilityLabel: accessibilityLabel)
        }

        init(label: String, accessibilityLabel: String, usesFullAccessibilityLabel: Bool = false, isArchived: Bool = false) {
            self.label = label
            self.accessibilityLabel = accessibilityLabel
            self.usesFullAccessibilityLabel = usesFullAccessibilityLabel
            self.isArchived = isArchived
        }

        func accessibilityLabel(agentLabel: String) -> String {
            usesFullAccessibilityLabel ? accessibilityLabel : "\(agentLabel) \(accessibilityLabel)"
        }

        func foreground(isSelected: Bool) -> Color {
            if isArchived {
                return isSelected ? Color.white.opacity(0.95) : UnifiedSessionsStyle.selectionAccent
            }
            return isSelected ? Color.white.opacity(0.85) : Color.secondary
        }

        var fill: Color {
            isArchived ? UnifiedSessionsStyle.selectionAccent.opacity(0.14) : Color.secondary.opacity(0.12)
        }

        func stroke(isSelected: Bool) -> Color {
            guard isArchived else { return .clear }
            return isSelected ? Color.white.opacity(0.50) : UnifiedSessionsStyle.selectionAccent.opacity(0.55)
        }

        var strokeWidth: CGFloat {
            isArchived ? 1 : 0
        }

        var font: Font {
            let base = Font.system(size: 10, weight: .semibold, design: .monospaced)
            return isArchived ? base.italic() : base
        }
    }

    private struct TerminalFocusAvailability {
        let canFocus: Bool
        let helpText: String
    }

    private func terminalFocusAvailability(for session: Session) -> TerminalFocusAvailability {
        guard activeCodexSessions.supportsLiveSessions(for: session.source) else {
            return TerminalFocusAvailability(
                canFocus: false,
                helpText: "This agent does not support live terminal focus."
            )
        }

        let presence = livePresence(for: session)
        let canFocus = CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: presence?.terminal?.itermSessionId,
            tty: presence?.tty,
            termProgram: presence?.terminal?.termProgram
        ) || presence?.revealURL != nil
        let helpText: String = {
            if canFocus { return "Focus the existing iTerm2 tab/window for this session." }
            if isSessionLive(session) { return "Focus is unavailable for this terminal session." }
            return "This session is not currently live."
        }()
        return TerminalFocusAvailability(canFocus: canFocus, helpText: helpText)
    }

    private func focusActiveTerminal(for session: Session) {
        let availability = terminalFocusAvailability(for: session)
        guard availability.canFocus else {
            showActionAlert(message: availability.helpText)
            return
        }

        let presence = livePresence(for: session)
        if CodexActiveSessionsModel.tryFocusITerm2(
            itermSessionId: presence?.terminal?.itermSessionId,
            tty: presence?.tty
        ) {
            return
        }
        if let focusURL = presence?.revealURL, NSWorkspace.shared.open(focusURL) {
            return
        }

        showActionAlert(message: "Unable to focus the terminal for this session.")
    }

    private var canResumeSelectedSession: Bool {
        guard let selectedSession else { return false }
        let antigravityCLISessionID = selectedSession.source == .antigravity
            ? AntigravitySessionIDHelper.deriveSessionID(from: selectedSession)
            : nil
        return canResumeSession(selectedSession, antigravityCLISessionID: antigravityCLISessionID)
    }

    private func effectiveWorkingDirectoryURL(for session: Session) -> URL? {
        switch session.source {
        case .claude:
            return ClaudeSessionIDHelper.projectRoot(for: session)
        case .codex:
            if let wd = CodexResumeSettings.shared.effectiveWorkingDirectory(for: session), !wd.isEmpty {
                return URL(fileURLWithPath: wd)
            }
            return nil
        case .opencode:
            return OpenCodeSettings.shared.effectiveWorkingDirectory(for: session)
        case .hermes:
            return HermesSettings.shared.effectiveWorkingDirectory(for: session)
        case .copilot:
            return CopilotSettings.shared.effectiveWorkingDirectory(for: session)
        case .cursor:
            return CursorSettings.shared.effectiveWorkingDirectory(for: session)
        case .pi:
            return PiSettings.shared.effectiveWorkingDirectory(for: session)
        case .antigravity:
            return AntigravityCLISettings.shared.effectiveWorkingDirectory(for: session)
        default:
            guard let path = session.cwd, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private func openDir(_ s: Session) {
        guard let url = effectiveWorkingDirectoryURL(for: s) else { return }
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

    private func resumeAgentLabel(_ source: SessionSource) -> String {
        switch source {
        case .codex: return "Codex CLI"
        case .opencode: return "OpenCode"
        case .hermes: return "Hermes"
        case .claude: return "Claude Code"
        case .copilot: return "Copilot CLI"
        case .cursor: return "Cursor CLI"
        case .pi: return "Pi CLI"
        case .antigravity: return "Antigravity CLI"
        default: return "CLI"
        }
    }

    private func canResumeSession(_ s: Session, antigravityCLISessionID: String? = nil) -> Bool {
        switch s.source {
        case .codex:
            return canResumeCodexInCLI(s)
        case .claude:
            return !s.isClaudeWorkflowSubagent
        case .opencode, .hermes, .copilot, .cursor, .pi:
            return true
        case .antigravity:
            return (antigravityCLISessionID ?? AntigravitySessionIDHelper.deriveSessionID(from: s)) != nil
        default:
            return false
        }
    }

    private func canResumeCodexInCLI(_ session: Session) -> Bool {
        !session.isSideChat && session.codexSurface != .vscode
    }

    private func resume(_ s: Session) {
        guard !s.isClaudeWorkflowSubagent else { return }
        switch s.source {
        case .codex:
            Task { @MainActor in
                _ = await CodexResumeCoordinator.shared.quickLaunchInTerminal(session: s)
            }
        case .opencode:
            let settings = OpenCodeSettings.shared
            let sid = s.id
            let wd = settings.effectiveWorkingDirectory(for: s)
            let bin = settings.binaryPath.isEmpty ? nil : settings.binaryPath
            let input = OpenCodeResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin)
            Task { @MainActor in
                let launcher: OpenCodeTerminalLaunching = {
                    switch ResumePreferenceHelpers.resolveTerminalKind() {
                    case .iterm2:                  return OpenCodeITermLauncher()
                    case .warp:                    return OpenCodeWarpLauncher()
                    case .warpPreview:             return OpenCodeWarpPreviewLauncher()
                    case .terminalApp, .unknown:   return OpenCodeTerminalLauncher()
                    }
                }()
                let coord = OpenCodeResumeCoordinator(env: OpenCodeCLIEnvironment(), builder: OpenCodeResumeCommandBuilder(), launcher: launcher)
                _ = await coord.resumeInTerminal(input: input, policy: settings.fallbackPolicy, dryRun: false)
            }
        case .hermes:
            let settings = HermesSettings.shared
            let sid = s.id
            let wd = effectiveWorkingDirectoryURL(for: s)
            let bin = settings.binaryPath.isEmpty ? nil : settings.binaryPath
            let input = HermesResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin)
            Task { @MainActor in
                let launcher: HermesTerminalLaunching = {
                    switch ResumePreferenceHelpers.resolveTerminalKind() {
                    case .iterm2:                  return HermesITermLauncher()
                    case .warp:                    return HermesWarpLauncher()
                    case .warpPreview:             return HermesWarpPreviewLauncher()
                    case .terminalApp, .unknown:   return HermesTerminalLauncher()
                    }
                }()
                let coord = HermesResumeCoordinator(env: HermesCLIEnvironment(), builder: HermesResumeCommandBuilder(), launcher: launcher)
                _ = await coord.resumeInTerminal(input: input, policy: settings.fallbackPolicy, dryRun: false)
            }
        case .copilot:
            let settings = CopilotSettings.shared
            let sid = s.id
            let wd = settings.effectiveWorkingDirectory(for: s)
            let bin = settings.binaryPath.isEmpty ? nil : settings.binaryPath
            let input = CopilotResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin)
            Task { @MainActor in
                let launcher: CopilotTerminalLaunching = {
                    switch ResumePreferenceHelpers.resolveTerminalKind() {
                    case .iterm2:                  return CopilotITermLauncher()
                    case .warp:                    return CopilotWarpLauncher()
                    case .warpPreview:             return CopilotWarpPreviewLauncher()
                    case .terminalApp, .unknown:   return CopilotTerminalLauncher()
                    }
                }()
                let coord = CopilotResumeCoordinator(env: CopilotCLIEnvironment(), builder: CopilotResumeCommandBuilder(), launcher: launcher)
                _ = await coord.resumeInTerminal(input: input, policy: settings.fallbackPolicy, dryRun: false)
            }
        case .cursor:
            let settings = CursorSettings.shared
            let sid = s.id
            let wd = settings.effectiveWorkingDirectory(for: s)
            let bin = settings.binaryPath.isEmpty ? nil : settings.binaryPath
            let input = CursorResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin)
            Task { @MainActor in
                let launcher: CursorTerminalLaunching = {
                    switch ResumePreferenceHelpers.resolveTerminalKind() {
                    case .iterm2:                  return CursorITermLauncher()
                    case .warp:                    return CursorWarpLauncher()
                    case .warpPreview:             return CursorWarpPreviewLauncher()
                    case .terminalApp, .unknown:   return CursorTerminalLauncher()
                    }
                }()
                let coord = CursorResumeCoordinator(env: CursorCLIEnvironment(), builder: CursorResumeCommandBuilder(), launcher: launcher)
                _ = await coord.resumeInTerminal(input: input, policy: settings.fallbackPolicy, dryRun: false)
            }
        case .pi:
            let settings = PiSettings.shared
            let sid = s.id
            let wd = settings.effectiveWorkingDirectory(for: s)
            let bin = settings.binaryPath.isEmpty ? nil : settings.binaryPath
            let sessionDirectory = settings.copyCommandPlan(sessionID: sid)?.sessionDirectory
            let input = PiResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin, sessionDirectory: sessionDirectory)
            Task { @MainActor in
                let launcher: PiTerminalLaunching = {
                    switch ResumePreferenceHelpers.resolveTerminalKind() {
                    case .iterm2:                  return PiITermLauncher()
                    case .warp:                    return PiWarpLauncher()
                    case .warpPreview:             return PiWarpPreviewLauncher()
                    case .terminalApp, .unknown:   return PiTerminalLauncher()
                    }
                }()
                let coord = PiResumeCoordinator(env: PiCLIEnvironment(), builder: PiResumeCommandBuilder(), launcher: launcher)
                _ = await coord.resumeInTerminal(input: input, policy: settings.fallbackPolicy, dryRun: false)
            }
        case .antigravity:
            let settings = AntigravityCLISettings.shared
            let sid = AntigravitySessionIDHelper.deriveSessionID(from: s)
            let wd = settings.effectiveWorkingDirectory(for: s)
            let bin = settings.binaryOverride.isEmpty ? nil : settings.binaryOverride
            let input = AntigravityResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin)
            Task { @MainActor in
                let launcher: AntigravityTerminalLaunching = {
                    switch ResumePreferenceHelpers.resolveTerminalKind() {
                    case .iterm2:                  return AntigravityITermLauncher()
                    case .warp:                    return AntigravityWarpLauncher()
                    case .warpPreview:             return AntigravityWarpPreviewLauncher()
                    case .terminalApp, .unknown:   return AntigravityTerminalLauncher()
                    }
                }()
                let coord = AntigravityResumeCoordinator(env: AntigravityCLIEnvironment(), builder: AntigravityResumeCommandBuilder(), launcher: launcher)
                _ = await coord.resumeInTerminal(input: input, dryRun: false)
            }
        case .claude:
            let settings = ClaudeResumeSettings.shared
            let sid = ClaudeSessionIDHelper.deriveSessionID(from: s)
            let wd = ClaudeSessionIDHelper.projectRoot(for: s)
            let bin = settings.binaryPath.isEmpty ? nil : settings.binaryPath
            let input = ClaudeResumeInput(sessionID: sid, workingDirectory: wd, binaryOverride: bin)
            Task { @MainActor in
                let launcher: ClaudeTerminalLaunching = {
                    switch ResumePreferenceHelpers.resolveTerminalKind() {
                    case .iterm2:                  return ClaudeITermLauncher()
                    case .warp:                    return ClaudeWarpLauncher()
                    case .warpPreview:             return ClaudeWarpPreviewLauncher()
                    case .terminalApp, .unknown:   return ClaudeTerminalLauncher()
                    }
                }()
                let coord = ClaudeResumeCoordinator(env: ClaudeCLIEnvironment(), builder: ClaudeResumeCommandBuilder(), launcher: launcher)
                _ = await coord.resumeInTerminal(input: input, policy: settings.fallbackPolicy, dryRun: false)
            }
        default:
            return
        }
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
        restartSearch(onlyIfRunning: true)
    }

    private func restartSearchForActiveQuery() {
        restartSearch(onlyIfRunning: false)
    }

    private func restartSearchForSideChatDatasetChangeIfNeeded() {
        let q = unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard FilterEngine.parseOperators(q).sideChatsOnly else { return }
        restartSearchForActiveQuery()
    }

    private func restartSearch(onlyIfRunning: Bool) {
        guard !onlyIfRunning || searchCoordinator.isRunning else { return }
        let q = unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchCoordinator.cancel(); return }
        let filters = Filters(query: q,
                              dateFrom: unified.dateFrom,
                              dateTo: unified.dateTo,
                              model: unified.selectedModel,
                              kinds: unified.selectedKinds,
                              repoName: unified.projectFilter,
                              pathContains: nil,
                              archivedCodexDesktopOnly: unified.showArchivedCodexDesktopOnly,
                              sideChatsOnly: false)
        searchCoordinator.start(query: q,
                                filters: filters,
                                includeCodex: unified.includeCodex && codexAgentEnabled,
                                includeClaude: unified.includeClaude && claudeAgentEnabled,
                                includeAntigravity: unified.includeAntigravity && antigravityAgentEnabled,
                                includeOpenCode: unified.includeOpenCode && openCodeAgentEnabled,
                                includeHermes: unified.includeHermes && hermesAgentEnabled,
                                includeCopilot: unified.includeCopilot && copilotAgentEnabled,
                                includeDroid: unified.includeDroid && droidAgentEnabled,
                                includeOpenClaw: unified.includeOpenClaw && openClawAgentEnabled,
                                includeCursor: unified.includeCursor && cursorAgentEnabled,
                                includePi: unified.includePi && piAgentEnabled,
                                enableDeepScan: searchCoordinator.deepScanEnabled,
                                all: unified.allSessions)
    }

    private func flashAgentEnablementNoticeIfNeeded() {
        let anyDisabled = !(codexAgentEnabled && claudeAgentEnabled && antigravityAgentEnabled && openCodeAgentEnabled && hermesAgentEnabled && copilotAgentEnabled && droidAgentEnabled && openClawAgentEnabled && cursorAgentEnabled && piAgentEnabled)
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
        case .antigravity: return Color.teal
        case .opencode: return Color.purple
        case .hermes: return TranscriptColorSystem.agentBrandAccent(source: .hermes)
        case .copilot: return Color.agentCopilot
        case .droid: return Color.agentDroid
        case .openclaw: return Color.agentOpenClaw
        case .cursor: return Color.agentCursor
        case .pi: return Color.agentPi
        }
    }

    private func isSessionLive(_ session: Session) -> Bool {
        guard activeCodexSessions.supportsLiveSessions(for: session.source) else { return false }
        return livePresence(for: session) != nil
    }

    private func livePresence(for session: Session) -> CodexActivePresence? {
        if let direct = activeCodexSessions.presence(for: session) {
            return direct
        }
        let fallbackKey = Self.fallbackPresenceKey(source: session.source, sessionID: session.id)
        return cachedFallbackPresenceBySessionKey[fallbackKey]
    }

    /// Sessions eligible for fallback-presence matching whose `activeCodexSessions.presence(for:)`
    /// lookup (main-actor: hits `CodexActiveSessionsModel`'s internal lookup caches,
    /// not just Sendable data) already resolved directly. Computed on main --
    /// this is the one part of the fallback-presence pipeline that genuinely
    /// cannot move off-main (see doc comment on `buildFallbackPresenceMap`) --
    /// but it's the same O(sessions) set of calls this function always made, just
    /// isolated from the heavy grouping/sorting that used to run alongside it.
    /// Delegates to `SessionRowsBuilder.directJoinFallbackKeys` (S2 shared
    /// helper) so this file, `CockpitView`, and `AgentCockpitHUDView` don't
    /// each keep their own copy of the same source-filter loop.
    private func directJoinFallbackKeys(for sessions: [Session]) -> Set<String> {
        SessionRowsBuilder.directJoinFallbackKeys(for: sessions) { session in
            activeCodexSessions.presence(for: session)
        }
    }

    /// Main-actor, standalone fallback-presence refresh for the membership-tick
    /// "cheap path" (dots-only update when Active-only filtering is off, see the
    /// call site's comment: SET+order don't change on a live-presence poll, only
    /// dot state does, so a full rows rebuild would be wasted work). This is
    /// distinct from the rows-rebuild pipeline's fallback-presence computation
    /// (SessionRowsBuilder.build, off-main, W7 Task 1 Step 6c) -- this path must
    /// stay synchronous and main-actor because it runs on every live-poll tick
    /// independent of any rows rebuild.
    private func rebuildCachedFallbackPresences() {
        let sessions = unified.allSessions
        cachedFallbackPresenceBySessionKey = SessionRowsBuilder.buildFallbackPresenceMap(
            sessions: sessions,
            presences: activeCodexSessions.presences,
            directJoinSessionKeys: directJoinFallbackKeys(for: sessions)
        )
    }

    /// Fallback-presence join logic (`buildFallbackPresenceMap` and its
    /// private helpers, plus `fallbackClaimedPresence`/`fallbackEligibleSessions`/
    /// `fallbackSessionSort`/`fallbackPresenceSort`) lives in `SessionRowsBuilder`
    /// (Services) -- pure business logic over `Session`/`CodexActivePresence`
    /// Sendable data, with no View dependency (T2). These are thin forwarders
    /// so call sites in this file can keep using `Self.<name>(...)`.
    static func buildFallbackPresenceMap(sessions: [Session],
                                         presences: [CodexActivePresence],
                                         directJoinSessionKeys: Set<String>) -> [String: CodexActivePresence] {
        SessionRowsBuilder.buildFallbackPresenceMap(
            sessions: sessions,
            presences: presences,
            directJoinSessionKeys: directJoinSessionKeys
        )
    }

    static func fallbackPresenceKey(source: SessionSource, sessionID: String) -> String {
        SessionRowsBuilder.fallbackPresenceKey(source: source, sessionID: sessionID)
    }

    static func fallbackClaimedPresence(for session: Session,
                                        among candidateSessions: [Session],
                                        using fallbackPresences: [CodexActivePresence]) -> CodexActivePresence? {
        SessionRowsBuilder.fallbackClaimedPresence(for: session, among: candidateSessions, using: fallbackPresences)
    }

    static func fallbackEligibleSessions(from candidateSessions: [Session],
                                         hasDirectJoin: (Session) -> Bool) -> [Session] {
        SessionRowsBuilder.fallbackEligibleSessions(from: candidateSessions, hasDirectJoin: hasDirectJoin)
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

/// Describes one non-Codex/Claude agent toggle so it can render either as a
/// toolbar pill or as a row in the overflow filter menu without duplicating the
/// title/color/binding/shortcut in two places.
private struct AgentToolbarSpec: Identifiable {
    let id: String
    let title: String
    let color: Color
    let isOn: Binding<Bool>
    let shortcut: KeyEquivalent?
}

/// Overflow control shown in place of the individual agent pills once the
/// toolbar gets crowded (more than four agents enabled). Styled as a pill
/// identical to `AgentTabToggle` — with a chevron to signal it expands — so it
/// reads as "the other agent pills, collapsed into one." Each menu row toggles
/// that agent's inclusion; the ⌘ shortcuts are handled by hidden buttons.
private struct AgentOverflowMenu: View {
    let specs: [AgentToolbarSpec]

    var body: some View {
        Menu {
            ForEach(specs) { spec in
                Toggle(isOn: spec.isOn) { Text(spec.title) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Agents")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .agentPillSurface()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show or hide agents in the list")
        .accessibilityLabel(Text("Agent filters"))
    }
}

/// The shared capsule surface used by every agent pill (individual toggles and
/// the "Agents" overflow), so they stay pixel-identical.
private struct AgentPillSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(UnifiedSessionsStyle.agentTabFont)
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
}

private extension View {
    func agentPillSurface() -> some View { modifier(AgentPillSurface()) }
}

private struct AgentTabToggle: View {
    let title: String
    let color: Color
    let isMonochrome: Bool
    @Binding var isOn: Bool

    private var activeColor: Color { isMonochrome ? .primary : color }
    private var textColor: Color {
        if isOn { return activeColor }
        return isMonochrome ? .secondary : .primary
    }

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(title)
                .foregroundStyle(textColor)
                .agentPillSurface()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

private struct ActiveSessionsOnlyToggle: View {
    @Binding var isOn: Bool

    private let dotSize: CGFloat = 7.8

    private var dotColor: Color {
        isOn ? UnifiedSessionsStyle.selectionAccent : Color.secondary.opacity(0.5)
    }

    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack(spacing: 0) {
                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)
            }
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
        .accessibilityLabel(Text("Live sessions only"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

private struct ArchivedCodexDesktopIconToggle: View {
    @Binding var isOn: Bool
    @Binding var includeCodex: Bool

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOn ? "archivebox.fill" : "archivebox")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? UnifiedSessionsStyle.selectionAccent : .secondary)
                .frame(minWidth: 14)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(UnifiedSessionsStyle.agentPillFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isOn ? UnifiedSessionsStyle.selectionAccent.opacity(0.55) : UnifiedSessionsStyle.agentPillStroke, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Narrow Codex to archived Desktop sessions"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }

    private func toggle() {
        let nextValue = !isOn
        if nextValue, !includeCodex {
            includeCodex = true
        }
        isOn = nextValue
    }
}

private struct ClaudeSegmentedPill: View {
    @Binding var isClaudeOn: Bool
    @Binding var isArchivedOn: Bool
    let isMonochrome: Bool

    private var claudeAccent: Color { isMonochrome ? .primary : Color.agentClaude }
    private var claudeTextColor: Color {
        if isClaudeOn { return claudeAccent }
        return isMonochrome ? .secondary : .primary
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { isClaudeOn.toggle() }) {
                Text("Claude")
                    .font(UnifiedSessionsStyle.agentTabFont)
                    .foregroundStyle(claudeTextColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Claude"))
            .accessibilityValue(Text(isClaudeOn ? "On" : "Off"))

            Rectangle()
                .fill(UnifiedSessionsStyle.agentPillStroke)
                .frame(width: 1)
                .padding(.vertical, 4)

            Button(action: archiveToggle) {
                Image(systemName: isArchivedOn ? "archivebox.fill" : "archivebox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isArchivedOn ? UnifiedSessionsStyle.selectionAccent : .secondary)
                    .frame(minWidth: 14)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Narrow Claude to archived Desktop sessions"))
            .accessibilityValue(Text(isArchivedOn ? "On" : "Off"))
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule(style: .continuous).fill(UnifiedSessionsStyle.agentPillFill))
        .overlay(Capsule(style: .continuous).stroke(UnifiedSessionsStyle.agentPillStroke, lineWidth: 1))
    }

    private func archiveToggle() {
        let next = !isArchivedOn
        if next, !isClaudeOn { isClaudeOn = true }
        isArchivedOn = next
    }
}

private struct CodexSegmentedPill: View {
    @Binding var isCodexOn: Bool
    @Binding var isArchivedOn: Bool
    let isMonochrome: Bool

    private var codexAccent: Color { isMonochrome ? .primary : Color.agentCodex }
    private var codexTextColor: Color {
        if isCodexOn { return codexAccent }
        return isMonochrome ? .secondary : .primary
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { isCodexOn.toggle() }) {
                Text("Codex")
                    .font(UnifiedSessionsStyle.agentTabFont)
                    .foregroundStyle(codexTextColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Codex"))
            .accessibilityValue(Text(isCodexOn ? "On" : "Off"))

            Rectangle()
                .fill(UnifiedSessionsStyle.agentPillStroke)
                .frame(width: 1)
                .padding(.vertical, 4)

            Button(action: archiveToggle) {
                Image(systemName: isArchivedOn ? "archivebox.fill" : "archivebox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isArchivedOn ? UnifiedSessionsStyle.selectionAccent : .secondary)
                    .frame(minWidth: 14)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Narrow Codex to archived Desktop sessions"))
            .accessibilityValue(Text(isArchivedOn ? "On" : "Off"))
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule(style: .continuous).fill(UnifiedSessionsStyle.agentPillFill))
        .overlay(Capsule(style: .continuous).stroke(UnifiedSessionsStyle.agentPillStroke, lineWidth: 1))
    }

    private func archiveToggle() {
        let next = !isArchivedOn
        if next, !isCodexOn { isCodexOn = true }
        isArchivedOn = next
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
    var accessibilityLabel: String = "Toggle"

    var body: some View {
        ToolbarIconButton(help: help) { _ in
            ToolbarIcon(systemName: isOn ? onSymbol : offSymbol,
                        isActive: isOn,
                        activeColor: activeColor)
        } action: {
            isOn.toggle()
        }
        .accessibilityLabel(Text(accessibilityLabel))
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
    let codexIndexer: SessionIndexer
    let claudeIndexer: ClaudeSessionIndexer
    let antigravityIndexer: AntigravitySessionIndexer
    let opencodeIndexer: OpenCodeSessionIndexer
    let hermesIndexer: HermesSessionIndexer
    let copilotIndexer: CopilotSessionIndexer
    let droidIndexer: DroidSessionIndexer
    let openclawIndexer: OpenClawSessionIndexer
    let cursorIndexer: CursorSessionIndexer
    let piIndexer: PiSessionIndexer

    var body: some View {
        ZStack { // keep one stable container to avoid split reset
            TranscriptPlainView(sessionID: selection)
                .environmentObject(codexIndexer)
                .opacity(kind == .codex ? 1 : 0)
            ClaudeTranscriptView(indexer: claudeIndexer, sessionID: selection)
                .opacity(kind == .claude ? 1 : 0)
            AntigravityTranscriptView(indexer: antigravityIndexer, sessionID: selection)
                .opacity(kind == .antigravity ? 1 : 0)
            OpenCodeTranscriptView(indexer: opencodeIndexer, sessionID: selection)
                .opacity(kind == .opencode ? 1 : 0)
            HermesTranscriptView(indexer: hermesIndexer, sessionID: selection)
                .opacity(kind == .hermes ? 1 : 0)
            CopilotTranscriptView(indexer: copilotIndexer, sessionID: selection)
                .opacity(kind == .copilot ? 1 : 0)
            DroidTranscriptView(indexer: droidIndexer, sessionID: selection)
                .opacity(kind == .droid ? 1 : 0)
            OpenClawTranscriptView(indexer: openclawIndexer, sessionID: selection)
                .opacity(kind == .openclaw ? 1 : 0)
            CursorTranscriptView(indexer: cursorIndexer, sessionID: selection)
                .opacity(kind == .cursor ? 1 : 0)
            UnifiedTranscriptView(
                indexer: piIndexer,
                sessionID: selection,
                sessionIDExtractor: { $0.id.isEmpty ? nil : $0.id },
                sessionIDLabel: "Pi",
                enableCaching: false
            )
            .opacity(kind == .pi ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// Session title cell with inline Antigravity refresh affordance (hover-only)
private struct SessionTitleCell: View {
    let session: Session
    let displayTitleOverride: String?
    @ObservedObject var antigravityIndexer: AntigravitySessionIndexer
    let rowMeta: SubagentRowMeta?
    let sideChatParentContext: String?
    let isExpanded: Bool
    let onToggleExpand: ((String) -> Void)?
    @State private var hover: Bool = false

    var body: some View {
        let isNestedSubagent = (rowMeta?.depth ?? 0) > 0
        let showFlatSubagentMarker = session.isSubagent && !isNestedSubagent
        HStack(spacing: 4) {
            // Disclosure chevron for parents with children
            if let meta = rowMeta, meta.hasChildren {
                Button(action: { onToggleExpand?(session.id) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                }
                .buttonStyle(.plain)
                .frame(width: 16)
                .foregroundStyle(.secondary)
                if meta.hasWorkflowChildren {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("Spawned a workflow · \(meta.childCount) agents")
                        .accessibilityLabel("Spawned a workflow")
                }
                Text("(\(meta.childCount))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if isNestedSubagent {
                // Indent for subagent children
                Spacer().frame(width: 20)
            }

            if showFlatSubagentMarker {
                Text("sub")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel("Subagent")
                    .help(subagentPillHelp)
            }

            if session.isSideChat {
                Text("side")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.18))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel("Side chat")
                    .help("Codex side chat")
            }

            // Subagent type badge (only when hierarchy nesting is active)
            if isNestedSubagent {
                if let agentType = session.subagentType, !agentType.isEmpty {
                    Text(WorkflowSubagentBadge.displayLabel(for: agentType))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help(subagentPillHelp)
                }
                // Model badge
                if let abbreviated = ModelNameAbbreviator.abbreviate(session.model) {
                    Text(abbreviated)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }

            if session.isDeleted {
                Text("deleted")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel("Deleted session")
            }

            HStack(spacing: 6) {
                Text(displayTitleOverride ?? session.listTitle)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if session.isSideChat, let sideChatParentContext {
                    Text("of \(sideChatParentContext)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .background(Color.clear)
            .frame(maxWidth: .infinity, alignment: .leading)

            if session.source == .antigravity, antigravityIndexer.isPreviewStale(id: session.id) {
                Button(action: { antigravityIndexer.refreshPreview(id: session.id) }) {
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

    private var subagentPillHelp: String {
        guard let effort = session.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
              !effort.isEmpty else {
            return "Subagent"
        }
        return "Subagent\nReasoning effort: \(effort)"
    }
}

// Stable cell to prevent Table reuse glitches in Project column
private struct ProjectCellView: View {
    let id: String
    let display: String
    let worktree: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(display)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            if let worktree, !worktree.isEmpty, worktree != display {
                Text(worktree)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .id("project-cell-\(id)")
    }
}

private struct UnifiedSearchFiltersView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @ObservedObject var search: SearchCoordinator
    @ObservedObject var focus: WindowFocusCoordinator
    @ObservedObject var searchState: UnifiedSearchState
    @AppStorage(PreferencesKey.Agents.piEnabled) private var piAgentEnabled: Bool = AgentEnablement.isEnabled(.pi)
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
                                       onCommit: { startSearchImmediate() },
                                       onEscape: { clearSearchFromField() })
                    .frame(minWidth: 220)
                    .help("Search sessions (⌥⌘F). Filters: repo:NAME, path:PATH. Use quotes for phrases; escape \\\" and \\\\. Press Return for full deep scan.")

                if unified.queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("⌥⌘F")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Button(action: {
                        clearSearchFromField()
                        searchFocus = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .focused($searchFocus, equals: .clear)
                    .buttonStyle(.plain)
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
                              pathContains: nil,
                              archivedCodexDesktopOnly: unified.showArchivedCodexDesktopOnly,
                              sideChatsOnly: false)
        search.start(query: q,
                     filters: filters,
                     includeCodex: unified.includeCodex,
                     includeClaude: unified.includeClaude,
                     includeAntigravity: unified.includeAntigravity,
                     includeOpenCode: unified.includeOpenCode,
                     includeHermes: unified.includeHermes,
                     includeCopilot: unified.includeCopilot,
                     includeDroid: unified.includeDroid,
                     includeOpenClaw: unified.includeOpenClaw,
                     includeCursor: unified.includeCursor,
                     includePi: unified.includePi && piAgentEnabled,
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
                                  pathContains: nil,
                                  archivedCodexDesktopOnly: unified.showArchivedCodexDesktopOnly,
                                  sideChatsOnly: false)
            search.start(query: q,
                         filters: filters,
                         includeCodex: unified.includeCodex,
                         includeClaude: unified.includeClaude,
                         includeAntigravity: unified.includeAntigravity,
                         includeOpenCode: unified.includeOpenCode,
                         includeHermes: unified.includeHermes,
                         includeCopilot: unified.includeCopilot,
                         includeDroid: unified.includeDroid,
                         includeOpenClaw: unified.includeOpenClaw,
                         includeCursor: unified.includeCursor,
                         includePi: unified.includePi && piAgentEnabled,
                         enableDeepScan: false,
                         all: unified.allSessions)
        }
        searchDebouncer = work
        let delay: TimeInterval = FeatureFlags.increaseDeepSearchDebounce ? 0.28 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearSearchFromField() {
        unified.queryDraft = ""
        unified.query = ""
        unified.recomputeNow()
        search.cancel()
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
    var onEscape: () -> Void

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
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Clear the field editor directly so Escape visibly empties the field even
                // though it stays first responder (updateNSView won't overwrite an
                // actively-edited field).
                textView.string = ""
                if parent.text != "" { parent.text = "" }
                parent.onEscape()
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
        context.coordinator.parent = self
        // Only push the binding's value into the field when it is NOT being actively
        // edited. While the user types, the NSTextField is authoritative; a lagging
        // SwiftUI binding (`text`) arriving here mid-edit would overwrite the field and
        // erase the characters typed since (the dropped-character bug). Programmatic
        // clears either resign focus (✕ button) or clear the field editor directly
        // (Escape, handled in the coordinator), so they still take effect.
        if tf.currentEditor() == nil, tf.stringValue != text { tf.stringValue = text }
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
    let phase: AnalyticsIndexPhase
    let isStale: Bool

    var body: some View {
        ToolbarIconButton(help: helpText) { _ in
            ZStack {
                ToolbarIcon(systemName: "chart.bar.xaxis")
                    .opacity((isReady || phase == .ready) ? 1 : 0.5)
                if phase == .queued || phase == .building {
                    ProgressView()
                        .controlSize(.mini)
                } else if isStale {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .offset(x: 8, y: -8)
                }
            }
        } action: {
            NotificationCenter.default.post(name: .toggleAnalyticsWindow, object: nil)
        }
        .keyboardShortcut("k", modifiers: .command)
        .accessibilityLabel(Text("Analytics"))
    }

    private var helpText: String {
        switch phase {
        case .queued, .building:
            return "Analytics build in progress (⌘K)"
        case .ready:
            if isStale {
                return "View analytics (stale data, update available) (⌘K)"
            }
            return "View usage analytics (⌘K)"
        case .failed:
            return "View analytics (last build failed, retry available) (⌘K)"
        case .canceled:
            return "View analytics (build canceled, restart available) (⌘K)"
        case .idle:
            if isReady {
                return "View usage analytics (⌘K)"
            }
            return "View analytics (build required) (⌘K)"
        }
    }
}

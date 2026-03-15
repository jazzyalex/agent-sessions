import SwiftUI
import AppKit
import Combine

enum HUDLiveState: Equatable {
    case active
    case idle
}

enum HUDDisplayPriority: Int, Equatable {
    case active = 0
    case waitingFresh = 1
    case waitingStale = 2
}

enum HUDAgentType: Equatable {
    case codex
    case claude
    case opencode
    case shell

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .opencode: return "OpenCode"
        case .shell: return "Shell"
        }
    }

    var standardTextColor: Color {
        switch self {
        case .codex: return .agentCodex
        case .claude: return .agentClaude
        case .opencode: return .agentOpenCode
        case .shell: return .secondary
        }
    }
}

struct HUDRow: Identifiable, Equatable {
    let id: String
    let source: SessionSource
    let agentType: HUDAgentType
    let projectName: String
    let displayName: String
    let liveState: HUDLiveState
    let preview: String
    let elapsed: String
    let lastSeenAt: Date?
    let itermSessionId: String?
    let revealURL: URL?
    let tty: String?
    let termProgram: String?
    let tabTitle: String?
    let cleanedTabTitle: String?
    let resolvedSessionID: String?
    let runtimeSessionID: String?
    let logPath: String?
    let workingDirectory: String?
    let lastActivityAt: Date?
    let lastActivityTooltip: String?

    init(id: String,
         source: SessionSource,
         agentType: HUDAgentType,
         projectName: String,
         displayName: String,
         liveState: HUDLiveState,
         preview: String,
         elapsed: String,
         lastSeenAt: Date?,
         itermSessionId: String?,
         revealURL: URL?,
         tty: String?,
         termProgram: String?,
         tabTitle: String? = nil,
         cleanedTabTitle: String? = nil,
         resolvedSessionID: String? = nil,
         runtimeSessionID: String? = nil,
         logPath: String? = nil,
         workingDirectory: String? = nil,
         lastActivityAt: Date? = nil,
         lastActivityTooltip: String? = nil) {
        self.id = id
        self.source = source
        self.agentType = agentType
        self.projectName = projectName
        self.displayName = displayName
        self.liveState = liveState
        self.preview = preview
        self.elapsed = elapsed
        self.lastSeenAt = lastSeenAt
        self.itermSessionId = itermSessionId
        self.revealURL = revealURL
        self.tty = tty
        self.termProgram = termProgram
        self.tabTitle = tabTitle
        self.cleanedTabTitle = cleanedTabTitle
        self.resolvedSessionID = resolvedSessionID
        self.runtimeSessionID = runtimeSessionID
        self.logPath = logPath
        self.workingDirectory = workingDirectory
        self.lastActivityAt = lastActivityAt
        self.lastActivityTooltip = lastActivityTooltip
    }

    static func == (lhs: HUDRow, rhs: HUDRow) -> Bool {
        lhs.id == rhs.id
            && lhs.source == rhs.source
            && lhs.agentType == rhs.agentType
            && lhs.projectName == rhs.projectName
            && lhs.displayName == rhs.displayName
            && lhs.liveState == rhs.liveState
            && lhs.preview == rhs.preview
            && lhs.lastSeenAt == rhs.lastSeenAt
            && lhs.itermSessionId == rhs.itermSessionId
            && lhs.revealURL == rhs.revealURL
            && lhs.tty == rhs.tty
            && lhs.termProgram == rhs.termProgram
            && lhs.tabTitle == rhs.tabTitle
            && lhs.cleanedTabTitle == rhs.cleanedTabTitle
            && lhs.resolvedSessionID == rhs.resolvedSessionID
            && lhs.runtimeSessionID == rhs.runtimeSessionID
            && lhs.logPath == rhs.logPath
            && lhs.workingDirectory == rhs.workingDirectory
            && lhs.lastActivityAt == rhs.lastActivityAt
            && lhs.elapsed == rhs.elapsed
            && lhs.lastActivityTooltip == rhs.lastActivityTooltip
    }
}

private enum AgentCockpitHUDTheme {
    static let cornerRadius: CGFloat = 12
    static let toolbarButtonCornerRadius: CGFloat = 7
}

enum HUDSessionFilterMode: Equatable {
    case all
    case active
    case idle
}

struct HUDGroup: Identifiable {
    let id: String
    let projectName: String
    let rows: [HUDRow]
    let activeCount: Int
    let idleCount: Int
    let freshIdleCount: Int
    let staleIdleCount: Int

    var hasActive: Bool { activeCount > 0 }
    var hasFreshWaiting: Bool { freshIdleCount > 0 }
    var isStaleOnly: Bool { activeCount == 0 && freshIdleCount == 0 && staleIdleCount > 0 }
    var displayPriority: HUDDisplayPriority {
        if hasActive { return .active }
        if hasFreshWaiting { return .waitingFresh }
        return .waitingStale
    }
    var collapseSyncKey: String { "\(id)|\(isStaleOnly ? 1 : 0)" }

    var summaryText: String {
        if activeCount > 0 && idleCount > 0 {
            return "\(activeCount) active · \(idleCount) waiting"
        }
        if activeCount > 0 {
            return "\(activeCount) active"
        }
        return "\(idleCount) waiting"
    }
}

struct HUDLiveSessionSummary: Equatable {
    let activeCount: Int
    let waitingCount: Int
}

private struct LegacyMappedRow: Identifiable {
    let id: String
    let source: SessionSource
    let title: String
    let liveState: CodexLiveState
    let lastSeenAt: Date?
    let repo: String
    let date: Date?
    let focusURL: URL?
    let itermSessionId: String?
    let tty: String?
    let termProgram: String?
    let tabTitle: String?
    let resolvedSessionID: String?
    let sessionID: String?
    let logPath: String?
    let workingDirectory: String?
    let lastActivityAt: Date?
}

struct SessionLookupIndexes {
    let byLogPath: [String: Session]
    let bySessionID: [String: Session]
    let byWorkspace: [String: Session]
}

private struct HUDRowsSnapshot: Equatable {
    let rows: [HUDRow]
    let activeCount: Int
    let idleCount: Int
}

private struct HUDWaitingCounts {
    let active: Int
    let idle: Int
    let freshIdle: Int
    let staleIdle: Int
}

private struct HUDPresentationInputs: Equatable {
    let canonicalRows: [HUDRow]
    let snapshotTimestamp: Date
    let isCompact: Bool
    let sessionFilterMode: HUDSessionFilterMode
    let filterText: String
    let groupByProject: Bool
    let collapsedProjects: Set<String>
    let orderedRowIDs: [String]
    let isWindowVisibleForOrdering: Bool

    static func == (lhs: HUDPresentationInputs, rhs: HUDPresentationInputs) -> Bool {
        lhs.canonicalRows == rhs.canonicalRows
            && lhs.isCompact == rhs.isCompact
            && lhs.sessionFilterMode == rhs.sessionFilterMode
            && lhs.filterText == rhs.filterText
            && lhs.groupByProject == rhs.groupByProject
            && lhs.collapsedProjects == rhs.collapsedProjects
            && lhs.orderedRowIDs == rhs.orderedRowIDs
            && lhs.isWindowVisibleForOrdering == rhs.isWindowVisibleForOrdering
    }
}

private struct HUDPresentationState {
    let inputs: HUDPresentationInputs
    let rowsForDisplay: [HUDRow]
    let visibleRows: [HUDRow]
    let fullListLayoutSignature: Int
    let shownSessionCount: Int
    let groupedVisibleRows: [HUDGroup]
    let groupedRowsForCollapseSync: [HUDGroup]
    let renderedRows: [HUDRow]
    let shortcutIndexMap: [String: Int]

    static let empty = HUDPresentationState(
        inputs: HUDPresentationInputs(
            canonicalRows: [],
            snapshotTimestamp: .distantPast,
            isCompact: false,
            sessionFilterMode: .all,
            filterText: "",
            groupByProject: false,
            collapsedProjects: [],
            orderedRowIDs: [],
            isWindowVisibleForOrdering: true
        ),
        rowsForDisplay: [],
        visibleRows: [],
        fullListLayoutSignature: 0,
        shownSessionCount: 0,
        groupedVisibleRows: [],
        groupedRowsForCollapseSync: [],
        renderedRows: [],
        shortcutIndexMap: [:]
    )
}

@MainActor
private final class AgentCockpitHUDDerivedStateModel: ObservableObject {
    @Published private(set) var snapshot = HUDRowsSnapshot(rows: [], activeCount: 0, idleCount: 0)
    @Published private(set) var snapshotTimestamp: Date = Date()

    private weak var activeCodex: CodexActiveSessionsModel?
    private var codexSessions: [Session]
    private var claudeSessions: [Session]
    private var opencodeSessions: [Session]
    private var lookupIndexes: SessionLookupIndexes
    private var presences: [CodexActivePresence] = []
    private var isCompact: Bool
    private var cancellables: Set<AnyCancellable> = []
    private var activeCancellable: AnyCancellable?
    private var rebuildScheduled: Bool = false
#if DEBUG
    private struct DebugRebuildState {
        var rebuildCount: UInt64 = 0
        var lookupRebuildCount: UInt64 = 0
    }
    private static let debugRebuildLock = NSLock()
    private static var debugRebuildState = DebugRebuildState()

    static func debugRebuildSnapshot() -> (rebuildCount: UInt64, lookupRebuildCount: UInt64) {
        debugRebuildLock.lock()
        let state = debugRebuildState
        debugRebuildLock.unlock()
        return (
            rebuildCount: state.rebuildCount,
            lookupRebuildCount: state.lookupRebuildCount
        )
    }

    private static func recordDebugRebuild() {
        debugRebuildLock.lock()
        debugRebuildState.rebuildCount &+= 1
        debugRebuildLock.unlock()
    }

    private static func recordDebugLookupRebuild() {
        debugRebuildLock.lock()
        debugRebuildState.lookupRebuildCount &+= 1
        debugRebuildLock.unlock()
    }
#endif

    init(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, opencodeIndexer: OpenCodeSessionIndexer, initialCompact: Bool) {
        codexSessions = codexIndexer.allSessions
        claudeSessions = claudeIndexer.allSessions
        opencodeSessions = opencodeIndexer.allSessions
        lookupIndexes = AgentCockpitHUDView.buildSessionLookupIndexes(
            codexSessions: codexSessions,
            claudeSessions: claudeSessions,
            opencodeSessions: opencodeSessions
        )
        isCompact = initialCompact

        codexIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                codexSessions = sessions
                rebuildLookupIndexes()
                scheduleRebuild()
            }
            .store(in: &cancellables)

        claudeIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                claudeSessions = sessions
                rebuildLookupIndexes()
                scheduleRebuild()
            }
            .store(in: &cancellables)

        opencodeIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                opencodeSessions = sessions
                rebuildLookupIndexes()
                scheduleRebuild()
            }
            .store(in: &cancellables)
    }

    func bind(activeCodex: CodexActiveSessionsModel) {
        self.activeCodex = activeCodex
        presences = activeCodex.presences
        activeCancellable = activeCodex.$presences.sink { [weak self] presences in
            guard let self else { return }
            self.presences = presences
            scheduleRebuild()
        }
        scheduleRebuild()
    }

    func setCompact(_ compact: Bool, activeCodex: CodexActiveSessionsModel) {
        self.activeCodex = activeCodex
        guard isCompact != compact else { return }
        isCompact = compact
        scheduleRebuild()
    }

    private func rebuildLookupIndexes() {
        lookupIndexes = AgentCockpitHUDView.buildSessionLookupIndexes(
            codexSessions: codexSessions,
            claudeSessions: claudeSessions,
            opencodeSessions: opencodeSessions
        )
#if DEBUG
        Self.recordDebugLookupRebuild()
#endif
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuildIfReady()
        }
    }

    private func rebuildIfReady(activeCodex: CodexActiveSessionsModel? = nil) {
        let activeCodex = activeCodex ?? self.activeCodex
        guard let activeCodex else { return }
        let now = Date()
        let nextSnapshot = AgentCockpitHUDView.makeRowsSnapshot(
            codexSessions: codexSessions,
            claudeSessions: claudeSessions,
            opencodeSessions: opencodeSessions,
            presences: presences,
            activeCodex: activeCodex,
            isCompact: isCompact,
            lookupIndexes: lookupIndexes,
            now: now
        )
        if nextSnapshot != snapshot {
            snapshot = nextSnapshot
            snapshotTimestamp = now
        }
#if DEBUG
        Self.recordDebugRebuild()
#endif
    }
}

struct AgentCockpitHUDView: View {
    let codexIndexer: SessionIndexer
    let claudeIndexer: ClaudeSessionIndexer
    let opencodeIndexer: OpenCodeSessionIndexer
    @EnvironmentObject var activeCodex: CodexActiveSessionsModel

    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var activeEnabled: Bool = true
    @AppStorage(PreferencesKey.Cockpit.hudGroupByProject) private var groupByProject: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudCompact) private var isCompact: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudPinned) private var isPinned: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudCompactBaselineRows) private var compactBaselineRows: Int = 4
    @AppStorage(PreferencesKey.Cockpit.hudCompactAutoFitEnabled) private var compactAutoFitEnabled: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudShowLimits) private var showLimits: Bool = true

    @State private var sessionFilterMode: HUDSessionFilterMode = .all
    @State private var filterText: String = ""
    @State private var collapsedProjects: Set<String> = []
    @State private var activeConsumerID = UUID()
    @State private var searchFocusToken: Int = 0
    @State private var orderedRowIDs: [String] = []
    @State private var latestCanonicalRows: [HUDRow] = []
    @State private var latestCanonicalRowsSnapshotAt: Date = Date()
    @State private var presentationClockNow: Date = Date()
    @State private var isWindowVisibleForOrdering: Bool = true
    @State private var wasWindowHiddenSinceLastVisible: Bool = false
    @State private var hiddenMembershipChurnDetected: Bool = false
    @State private var hiddenPriorityChurnDetected: Bool = false
    @State private var highlightedRowIDs: Set<String> = []
    @State private var isCockpitWindowKey: Bool = true
    @State private var isCompactWindowHovered: Bool = false
    @State private var staleAutoCollapsedProjects: Set<String> = []
    @State private var manuallyExpandedStaleProjects: Set<String> = []
    @State private var presentationState: HUDPresentationState = .empty
    @StateObject private var derivedState: AgentCockpitHUDDerivedStateModel
    @FocusState private var isSearchFocused: Bool

    private let fullBodyMinHeight: CGFloat = 170
    private let compactBodyRowHeight: CGFloat = 31
    private let compactBodyMinRowsWhenToolbarHidden: CGFloat = 3
    private let compactBodyMaxRowsWhenToolbarVisible: CGFloat = 10
    private static let staleWaitingThreshold: TimeInterval = 4 * 60 * 60
    private static let presentationClockInterval: TimeInterval = 30
    private let presentationClock = Timer.publish(
        every: AgentCockpitHUDView.presentationClockInterval,
        on: .main,
        in: .common
    ).autoconnect()

    private static let codexRolloutTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    private static let activityTooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private var effectiveCompactBaselineRows: Int {
        min(max(compactBaselineRows, 3), Int(compactBodyMaxRowsWhenToolbarVisible))
    }

    init(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, opencodeIndexer: OpenCodeSessionIndexer) {
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.opencodeIndexer = opencodeIndexer
        _derivedState = StateObject(
            wrappedValue: AgentCockpitHUDDerivedStateModel(
                codexIndexer: codexIndexer,
                claudeIndexer: claudeIndexer,
                opencodeIndexer: opencodeIndexer,
                initialCompact: UserDefaults.standard.object(forKey: PreferencesKey.Cockpit.hudCompact) as? Bool ?? false
            )
        )
    }

    var body: some View {
        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: hudContent.preferredColorScheme(.light)
            case .dark: hudContent.preferredColorScheme(.dark)
            case .system: hudContent
            }
        }
        .onAppear {
            activeCodex.setCockpitConsumerVisible(true, consumerID: activeConsumerID)
            activeCodex.setCockpitWindowVisible(true, consumerID: activeConsumerID)
            UserDefaults.standard.set(true, forKey: PreferencesKey.Cockpit.hudOpen)
            CodexUsageModel.shared.setAppActive(NSApp.isActive)
            CodexUsageModel.shared.setCockpitVisible(true, pinned: isPinned)
            ClaudeUsageModel.shared.setAppActive(NSApp.isActive)
            ClaudeUsageModel.shared.setCockpitVisible(true, pinned: isPinned)
        }
        .onDisappear {
            activeCodex.setCockpitWindowVisible(false, consumerID: activeConsumerID)
            activeCodex.setCockpitConsumerVisible(false, consumerID: activeConsumerID)
            UserDefaults.standard.set(false, forKey: PreferencesKey.Cockpit.hudOpen)
            CodexUsageModel.shared.setCockpitVisible(false, pinned: false)
            ClaudeUsageModel.shared.setCockpitVisible(false, pinned: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            CodexUsageModel.shared.setAppActive(true)
            ClaudeUsageModel.shared.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            CodexUsageModel.shared.setAppActive(false)
            ClaudeUsageModel.shared.setAppActive(false)
        }
        .onChange(of: isPinned) { _, newPinned in
            CodexUsageModel.shared.setCockpitVisible(true, pinned: newPinned)
            ClaudeUsageModel.shared.setCockpitVisible(true, pinned: newPinned)
        }
    }

    private var hudContent: some View {
        let snapshot = derivedState.snapshot
        let snapshotTimestamp = derivedState.snapshotTimestamp
        let presentationTimestamp = max(snapshotTimestamp, presentationClockNow)
        let canonicalRows = activeEnabled ? snapshot.rows : []
        let currentPresentationInputs = HUDPresentationInputs(
            canonicalRows: canonicalRows,
            snapshotTimestamp: presentationTimestamp,
            isCompact: isCompact,
            sessionFilterMode: sessionFilterMode,
            filterText: filterText,
            groupByProject: groupByProject,
            collapsedProjects: collapsedProjects,
            orderedRowIDs: orderedRowIDs,
            isWindowVisibleForOrdering: isWindowVisibleForOrdering
        )
        let displayState = presentationState.inputs == currentPresentationInputs
            ? presentationState
            : Self.makePresentationState(from: currentPresentationInputs)
        let showsCompactToolbar = !isCompact || isPinned || isCockpitWindowKey || isCompactWindowHovered

        return configuredHUDContent(
            snapshot: snapshot,
            displayState: displayState,
            showsCompactToolbar: showsCompactToolbar
        )
        .onAppear {
            derivedState.bind(activeCodex: activeCodex)
            derivedState.setCompact(isCompact, activeCodex: activeCodex)
            presentationClockNow = max(presentationClockNow, snapshotTimestamp)
            presentationState = Self.makePresentationState(from: currentPresentationInputs)
            synchronizeOrderedRows(
                with: canonicalRows,
                previousRows: [],
                previousSnapshotAt: presentationTimestamp,
                incomingSnapshotAt: presentationTimestamp
            )
            latestCanonicalRows = canonicalRows
            latestCanonicalRowsSnapshotAt = presentationTimestamp
            synchronizeCollapsedProjectsForStaleGroups(with: presentationState.groupedRowsForCollapseSync)
        }
        .onChange(of: canonicalRows) { oldRows, rows in
            let presentationTimestamp = max(presentationClockNow, derivedState.snapshotTimestamp)
            synchronizeOrderedRows(
                with: rows,
                previousRows: oldRows,
                previousSnapshotAt: latestCanonicalRowsSnapshotAt,
                incomingSnapshotAt: presentationTimestamp
            )
            latestCanonicalRows = rows
            latestCanonicalRowsSnapshotAt = presentationTimestamp
            refreshPresentationState(
                canonicalRows: rows,
                snapshotTimestamp: presentationTimestamp
            )
            synchronizeCollapsedProjectsForStaleGroups(with: presentationState.groupedRowsForCollapseSync)
        }
        .onChange(of: isWindowVisibleForOrdering) { _, isVisible in
            guard isVisible else { return }
            let now = Date()
            presentationClockNow = now
            refreshPresentationState(canonicalRows: latestCanonicalRows, snapshotTimestamp: now)
            synchronizeOrderedRows(
                with: latestCanonicalRows,
                previousRows: latestCanonicalRows,
                previousSnapshotAt: latestCanonicalRowsSnapshotAt,
                incomingSnapshotAt: now
            )
            latestCanonicalRowsSnapshotAt = now
            synchronizeCollapsedProjectsForStaleGroups(with: presentationState.groupedRowsForCollapseSync)
        }
        .onChange(of: displayState.groupedRowsForCollapseSync.map(\.collapseSyncKey)) { _, _ in
            synchronizeCollapsedProjectsForStaleGroups(with: displayState.groupedRowsForCollapseSync)
        }
        .onChange(of: groupByProject) { _, _ in
            refreshPresentationState(
                canonicalRows: canonicalRows,
                snapshotTimestamp: presentationTimestamp
            )
            synchronizeCollapsedProjectsForStaleGroups(with: presentationState.groupedRowsForCollapseSync)
        }
        .onChange(of: isCompact) { _, _ in
            derivedState.setCompact(isCompact, activeCodex: activeCodex)
            synchronizeCollapsedProjectsForStaleGroups(with: presentationState.groupedRowsForCollapseSync)
        }
        .onChange(of: sessionFilterMode) { _, _ in
            refreshPresentationState(canonicalRows: canonicalRows, snapshotTimestamp: presentationTimestamp)
        }
        .onChange(of: filterText) { _, _ in
            refreshPresentationState(canonicalRows: canonicalRows, snapshotTimestamp: presentationTimestamp)
        }
        .onChange(of: orderedRowIDs) { _, _ in
            refreshPresentationState(canonicalRows: canonicalRows, snapshotTimestamp: presentationTimestamp)
        }
        .onChange(of: collapsedProjects) { _, _ in
            refreshPresentationState(canonicalRows: canonicalRows, snapshotTimestamp: presentationTimestamp)
        }
        .onChange(of: activeEnabled) { _, _ in
            refreshPresentationState(canonicalRows: canonicalRows, snapshotTimestamp: presentationTimestamp)
        }
        .onReceive(presentationClock) { now in
            guard isWindowVisibleForOrdering else { return }
            presentationClockNow = now
            let presentationTimestamp = max(now, derivedState.snapshotTimestamp)
            synchronizeOrderedRows(
                with: latestCanonicalRows,
                previousRows: latestCanonicalRows,
                previousSnapshotAt: latestCanonicalRowsSnapshotAt,
                incomingSnapshotAt: presentationTimestamp
            )
            latestCanonicalRowsSnapshotAt = presentationTimestamp
            refreshPresentationState(canonicalRows: latestCanonicalRows, snapshotTimestamp: presentationTimestamp)
            synchronizeCollapsedProjectsForStaleGroups(with: presentationState.groupedRowsForCollapseSync)
        }
        .onHover { hovering in
            guard isCompact else { return }
            withAnimation(.easeInOut(duration: 0.14)) {
                isCompactWindowHovered = hovering
            }
        }
        .applyIf(isCompact) { view in
            view.ignoresSafeArea(.container, edges: .top)
        }
    }

    private func configuredHUDContent(snapshot: HUDRowsSnapshot,
                                      displayState: HUDPresentationState,
                                      showsCompactToolbar: Bool) -> AnyView {
        AnyView(
            hudStack(
                snapshot: snapshot,
                displayState: displayState,
                showsCompactToolbar: showsCompactToolbar
            )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .background(
            AgentCockpitHUDWindowConfigurator(
                isPinned: isPinned,
                shownSessionCount: displayState.shownSessionCount,
                isCompact: isCompact,
                activeEnabled: activeEnabled,
                compactToolbarVisible: showsCompactToolbar,
                groupByProject: groupByProject,
                compactPreferredRows: effectiveCompactBaselineRows,
                compactAutoFitEnabled: compactAutoFitEnabled
            )
            .allowsHitTesting(false)
        )
        .background(
            CockpitWindowVisibilityObserver { isVisible in
                handleWindowVisibilityChange(isVisible: isVisible)
            } onKeyWindowChanged: { isKey in
                handleWindowKeyChange(isKey: isKey)
            }
            .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.18), value: isCompact)
        )
    }

    @ViewBuilder
    private func hudStack(snapshot: HUDRowsSnapshot,
                          displayState: HUDPresentationState,
                          showsCompactToolbar: Bool) -> some View {
        VStack(spacing: 0) {
            if showsCompactToolbar {
                header(activeCount: snapshot.activeCount, idleCount: snapshot.idleCount)
                    .background(Color.primary.opacity(0.04))
                    .transition(.move(edge: .top).combined(with: .opacity))
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
                    .transition(.opacity)
            }

            if !activeEnabled {
                disabledCallout
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            bodyList(
                visibleRows: displayState.visibleRows,
                groupedRows: displayState.groupedVisibleRows,
                shortcutIndexMap: displayState.shortcutIndexMap,
                totalRowsCount: displayState.rowsForDisplay.count,
                showsCompactToolbar: showsCompactToolbar,
                fullListLayoutSignature: displayState.fullListLayoutSignature
            )
            .background(Color.clear)
            .disabled(!activeEnabled)

            if showLimits {
                HUDLimitsBar()
            }

            hiddenShortcuts(renderedRows: displayState.renderedRows)
        }
    }

    private func refreshPresentationState(canonicalRows: [HUDRow],
                                          snapshotTimestamp: Date) {
        presentationState = Self.makePresentationState(
            from: HUDPresentationInputs(
                canonicalRows: canonicalRows,
                snapshotTimestamp: snapshotTimestamp,
                isCompact: isCompact,
                sessionFilterMode: sessionFilterMode,
                filterText: filterText,
                groupByProject: groupByProject,
                collapsedProjects: collapsedProjects,
                orderedRowIDs: orderedRowIDs,
                isWindowVisibleForOrdering: isWindowVisibleForOrdering
            )
        )
    }

    @ViewBuilder
    private func header(activeCount: Int, idleCount: Int) -> some View {
        VStack(spacing: isCompact ? 0 : 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Button {
                        guard activeEnabled else { return }
                        sessionFilterMode = .all
                    } label: {
                        Text("All \(activeCount + idleCount)")
                    }
                    .buttonStyle(HUDFilterPillStyle(isOn: sessionFilterMode == .all, kind: .all))
                    .help("Show all live sessions.")

                    Button {
                        guard activeEnabled else { return }
                        sessionFilterMode = .active
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: "30d158"))
                                .frame(width: 7, height: 7)
                            Text("\(activeCount)")
                        }
                    }
                    .buttonStyle(HUDFilterPillStyle(isOn: sessionFilterMode == .active, kind: .active))
                    .help("Show active working sessions only.")

                    Button {
                        guard activeEnabled else { return }
                        sessionFilterMode = .idle
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: "ffb340"))
                                .frame(width: 7, height: 7)
                            Text("\(idleCount)")
                        }
                    }
                    .buttonStyle(HUDFilterPillStyle(isOn: sessionFilterMode == .idle, kind: .idle))
                    .help("Show waiting sessions only.")
                }
                .disabled(!activeEnabled)
                .opacity(activeEnabled ? 1 : 0.6)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Button {
                        AppWindowRouter.showAgentSessionsWindow()
                    } label: {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(HUDIconButtonStyle(isOn: false, tint: nil))
                    .help("Open Agent Sessions")

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isCompact.toggle()
                        }
                    } label: {
                        Image(systemName: isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(HUDIconButtonStyle(isOn: isCompact, tint: nil))
                    .help(isCompact ? "Show filter and navigation" : "Compact mode")

                    Button {
                        isPinned.toggle()
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(HUDIconButtonStyle(isOn: isPinned, tint: isPinned ? .orange : nil))
                    .help(isPinned ? "Unpin — stop keeping on top" : "Pin — keep above all windows")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, isCompact ? 10 : 0)

            if !isCompact {
                HStack(spacing: 8) {
                    HUDSearchField(
                        text: $filterText,
                        placeholder: "Filter sessions...",
                        focusToken: searchFocusToken
                    )
                    .disabled(!activeEnabled)
                    .focused($isSearchFocused)
                    .onExitCommand {
                        guard activeEnabled else { return }
                        if !filterText.isEmpty {
                            filterText = ""
                        }
                        isSearchFocused = false
                    }

                    Button {
                        guard activeEnabled else { return }
                        groupByProject.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.grid.2x2")
                            Text("By Project")
                        }
                    }
                    .buttonStyle(HUDIconButtonStyle(isOn: groupByProject, tint: .accentColor))
                    .help("Group sessions by project.")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func bodyList(visibleRows: [HUDRow],
                          groupedRows: [HUDGroup],
                          shortcutIndexMap: [String: Int],
                          totalRowsCount: Int,
                          showsCompactToolbar: Bool,
                          fullListLayoutSignature: Int) -> some View {
        Group {
            if visibleRows.isEmpty {
                emptyState(totalRowsCount: totalRowsCount)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isCompact ? .leading : .center)
                    .padding(.horizontal, isCompact ? 14 : 0)
            } else if shouldCenterCompactRows(visibleRows: visibleRows, showsCompactToolbar: showsCompactToolbar) {
                compactCenteredBodyRows(visibleRows: visibleRows, shortcutIndexMap: shortcutIndexMap)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if groupByProject {
                            ForEach(Array(groupedRows.enumerated()), id: \.element.id) { index, group in
                                if shouldShowStaleGroupsDivider(before: index, in: groupedRows) {
                                    staleGroupsDivider
                                }
                                AgentCockpitHUDGroupHeader(
                                    projectName: group.projectName,
                                    activeCount: group.activeCount,
                                    idleCount: group.idleCount,
                                    isStaleOnly: group.isStaleOnly,
                                    isCollapsed: collapsedProjects.contains(group.id)
                                ) {
                                    toggleCollapsed(projectID: group.id, isStaleOnly: group.isStaleOnly)
                                }

                                if !collapsedProjects.contains(group.id) {
                                    ForEach(group.rows) { row in
                                        AgentCockpitHUDRowView(
                                            row: row,
                                            shortcutIndex: shortcutIndexMap[row.id],
                                            isSelected: false,
                                            filterText: filterText,
                                            isGrouped: true,
                                            isCompact: isCompact,
                                            isNewlyInserted: highlightedRowIDs.contains(row.id)
                                        ) {
                                            focus(row)
                                        }
                                        .contextMenu {
                                            rowContextMenu(row)
                                        }
                                    }
                                }
                            }
                        } else {
                            ForEach(visibleRows) { row in
                                AgentCockpitHUDRowView(
                                    row: row,
                                    shortcutIndex: shortcutIndexMap[row.id],
                                    isSelected: false,
                                    filterText: filterText,
                                    isGrouped: false,
                                    isCompact: isCompact,
                                    isNewlyInserted: highlightedRowIDs.contains(row.id)
                                ) {
                                    focus(row)
                                }
                                .contextMenu {
                                    rowContextMenu(row)
                                }
                            }
                        }
                    }
                    .padding(.vertical, isCompact ? 0 : 2)
                    .id(fullListLayoutSignature)
                }
                .scrollIndicators(.visible)
            }
        }
        .frame(
            minHeight: isCompact
                ? compactBodyMinHeight(
                    visibleRowCount: visibleRows.count,
                    showsCompactToolbar: showsCompactToolbar
                )
                : fullBodyMinHeight,
            maxHeight: .infinity
        )
    }

    private func compactBodyMinHeight(visibleRowCount: Int,
                                      showsCompactToolbar: Bool) -> CGFloat {
        if compactAutoFitEnabled && showsCompactToolbar {
            let rows = min(max(visibleRowCount, 1), Int(compactBodyMaxRowsWhenToolbarVisible))
            return CGFloat(rows) * compactBodyRowHeight
        }
        if showsCompactToolbar {
            return CGFloat(effectiveCompactBaselineRows) * compactBodyRowHeight
        }
        return compactBodyMinRowsWhenToolbarHidden * compactBodyRowHeight
    }

    @ViewBuilder
    private func compactCenteredBodyRows(visibleRows: [HUDRow],
                                         shortcutIndexMap: [String: Int]) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(visibleRows) { row in
                AgentCockpitHUDRowView(
                    row: row,
                    shortcutIndex: shortcutIndexMap[row.id],
                    isSelected: false,
                    filterText: filterText,
                    isGrouped: false,
                    isCompact: isCompact,
                    isNewlyInserted: highlightedRowIDs.contains(row.id)
                ) {
                    focus(row)
                }
                .contextMenu {
                    rowContextMenu(row)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func shouldCenterCompactRows(visibleRows: [HUDRow],
                                         showsCompactToolbar: Bool) -> Bool {
        guard isCompact else { return false }
        guard !showsCompactToolbar else { return false }
        guard !isPinned else { return false }
        guard !groupByProject else { return false }
        return visibleRows.count <= 4
    }

    @ViewBuilder
    private func hiddenShortcuts(renderedRows: [HUDRow]) -> some View {
        VStack(spacing: 0) {
            Button("") {
                guard activeEnabled else { return }
                focusSearchField(selectAll: true)
            }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)

            Button("") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isCompact.toggle()
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)

            ForEach(1...9, id: \.self) { n in
                Button("") {
                    guard activeEnabled else { return }
                    guard renderedRows.indices.contains(n - 1) else { return }
                    let row = renderedRows[n - 1]
                    focus(row)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            }

            Button("") {
                guard activeEnabled else { return }
                guard renderedRows.indices.contains(9) else { return }
                focus(renderedRows[9])
            }
            .keyboardShortcut("0", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    private static func renderedRows(visibleRows: [HUDRow],
                                     groupedRows: [HUDGroup],
                                     groupByProject: Bool,
                                     collapsedProjects: Set<String>) -> [HUDRow] {
        guard groupByProject else { return visibleRows }
        return groupedRows.flatMap { group in
            collapsedProjects.contains(group.id) ? [] : group.rows
        }
    }

    private func toggleCollapsed(projectID: String, isStaleOnly: Bool) {
        if collapsedProjects.contains(projectID) {
            collapsedProjects.remove(projectID)
            staleAutoCollapsedProjects.remove(projectID)
            if isStaleOnly {
                manuallyExpandedStaleProjects.insert(projectID)
            }
        } else {
            collapsedProjects.insert(projectID)
            if isStaleOnly {
                manuallyExpandedStaleProjects.remove(projectID)
            }
        }
    }

    private func filteredRows(from rows: [HUDRow]) -> [HUDRow] {
        Self.filteredRows(rows, mode: sessionFilterMode, query: filterText)
    }

    private func groupedRows(from rows: [HUDRow]) -> [HUDGroup] {
        if isWindowVisibleForOrdering {
            return Self.groupedRowsPreservingOrder(rows)
        }
        return Self.groupedRows(rows)
    }

    @ViewBuilder
    private var staleGroupsDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 0.5)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func emptyState(totalRowsCount: Int) -> some View {
        if isCompact {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text("No sessions")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        } else {
            Text(fullModeEmptyStateLabel(totalRowsCount: totalRowsCount))
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func fullModeEmptyStateLabel(totalRowsCount: Int) -> String {
        let hasQuery = !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasQuery { return "No matching sessions" }

        switch sessionFilterMode {
        case .all:
            return "No active sessions"
        case .active:
            return "No active sessions"
        case .idle:
            return totalRowsCount == 0 ? "No active sessions" : "No waiting sessions"
        }
    }

    private func fullUngroupedLayoutSignature(for rows: [HUDRow]) -> Int {
        guard !isCompact, !groupByProject else { return 0 }
        var hasher = Hasher()
        hasher.combine(rows.count)
        for row in rows {
            hasher.combine(row.id)
            hasher.combine(row.projectName)
            hasher.combine(row.displayName)
            hasher.combine(row.cleanedTabTitle ?? "")
        }
        return hasher.finalize()
    }

    private static func makePresentationState(from inputs: HUDPresentationInputs) -> HUDPresentationState {
        let rowsForDisplay = rowsOrderedForDisplay(
            orderedRowIDs: inputs.orderedRowIDs,
            canonicalRows: inputs.canonicalRows
        )
        let visibleRows = filteredRows(
            rowsForDisplay,
            mode: inputs.sessionFilterMode,
            query: inputs.filterText
        )
        let fullListLayoutSignature = fullUngroupedLayoutSignature(
            rows: visibleRows,
            isCompact: inputs.isCompact,
            groupByProject: inputs.groupByProject
        )
        let groupedVisibleRows = inputs.groupByProject
            ? groupedRowsForPresentation(
                visibleRows,
                now: inputs.snapshotTimestamp,
                isWindowVisibleForOrdering: inputs.isWindowVisibleForOrdering
            )
            : []
        let groupedRowsForCollapseSync = inputs.groupByProject
            ? groupedRowsForPresentation(
                rowsForDisplay,
                now: inputs.snapshotTimestamp,
                isWindowVisibleForOrdering: inputs.isWindowVisibleForOrdering
            )
            : []
        let renderedRows = renderedRows(
            visibleRows: visibleRows,
            groupedRows: groupedVisibleRows,
            groupByProject: inputs.groupByProject,
            collapsedProjects: inputs.collapsedProjects
        )
        let shortcutIndexMap = renderedRows.enumerated().reduce(into: [String: Int]()) { partial, pair in
            let (index, row) = pair
            if partial[row.id] == nil {
                partial[row.id] = index + 1
            }
        }
        return HUDPresentationState(
            inputs: inputs,
            rowsForDisplay: rowsForDisplay,
            visibleRows: visibleRows,
            fullListLayoutSignature: fullListLayoutSignature,
            shownSessionCount: visibleRows.count,
            groupedVisibleRows: groupedVisibleRows,
            groupedRowsForCollapseSync: groupedRowsForCollapseSync,
            renderedRows: renderedRows,
            shortcutIndexMap: shortcutIndexMap
        )
    }

    private static func rowsOrderedForDisplay(orderedRowIDs: [String],
                                              canonicalRows: [HUDRow]) -> [HUDRow] {
        guard !orderedRowIDs.isEmpty else { return canonicalRows }

        let byID = Dictionary(uniqueKeysWithValues: canonicalRows.map { ($0.id, $0) })
        let ordered = orderedRowIDs.compactMap { byID[$0] }
        let orderedSet = Set(ordered.map(\.id))
        if ordered.count == canonicalRows.count {
            return ordered
        }
        let trailing = canonicalRows.filter { !orderedSet.contains($0.id) }
        return ordered + trailing
    }

    private static func fullUngroupedLayoutSignature(rows: [HUDRow],
                                                     isCompact: Bool,
                                                     groupByProject: Bool) -> Int {
        guard !isCompact, !groupByProject else { return 0 }
        var hasher = Hasher()
        hasher.combine(rows.count)
        for row in rows {
            hasher.combine(row.id)
            hasher.combine(row.projectName)
            hasher.combine(row.displayName)
            hasher.combine(row.cleanedTabTitle ?? "")
        }
        return hasher.finalize()
    }

    private static func groupedRowsForPresentation(_ rows: [HUDRow],
                                                   now: Date,
                                                   isWindowVisibleForOrdering: Bool) -> [HUDGroup] {
        if isWindowVisibleForOrdering {
            return groupedRowsPreservingOrder(rows, now: now)
        }
        return groupedRows(rows, now: now)
    }

    private func rowsOrderedForDisplay(from canonicalRows: [HUDRow]) -> [HUDRow] {
        Self.rowsOrderedForDisplay(orderedRowIDs: orderedRowIDs, canonicalRows: canonicalRows)
    }

    private func synchronizeOrderedRows(with canonicalRows: [HUDRow],
                                        previousRows: [HUDRow],
                                        previousSnapshotAt: Date,
                                        incomingSnapshotAt: Date) {
        let incomingIDs = canonicalRows.map(\.id)

        guard !orderedRowIDs.isEmpty else {
            orderedRowIDs = incomingIDs
            return
        }

        if !isWindowVisibleForOrdering {
            wasWindowHiddenSinceLastVisible = true
            if Self.hasMembershipChurn(existing: orderedRowIDs, incoming: incomingIDs) {
                hiddenMembershipChurnDetected = true
            }
            if Self.hasPriorityChurn(existing: previousRows,
                                     existingSnapshotAt: previousSnapshotAt,
                                     incoming: canonicalRows,
                                     incomingSnapshotAt: incomingSnapshotAt) {
                hiddenPriorityChurnDetected = true
            }
            return
        }

        if wasWindowHiddenSinceLastVisible {
            if hiddenMembershipChurnDetected || hiddenPriorityChurnDetected {
                orderedRowIDs = incomingIDs
            } else {
                let merge = Self.stableMergedOrder(existing: orderedRowIDs, incoming: incomingIDs)
                orderedRowIDs = merge.order
                queueInsertionHighlights(for: merge.inserted)
            }
            wasWindowHiddenSinceLastVisible = false
            hiddenMembershipChurnDetected = false
            hiddenPriorityChurnDetected = false
            return
        }

        if Self.hasPriorityChurn(existing: previousRows,
                                 existingSnapshotAt: previousSnapshotAt,
                                 incoming: canonicalRows,
                                 incomingSnapshotAt: incomingSnapshotAt) {
            orderedRowIDs = incomingIDs
            return
        }

        let merge = Self.stableMergedOrder(existing: orderedRowIDs, incoming: incomingIDs)
        orderedRowIDs = merge.order
        queueInsertionHighlights(for: merge.inserted)
    }

    private func synchronizeCollapsedProjectsForStaleGroups(with groups: [HUDGroup]) {
        let synchronized = Self.synchronizeCollapsedProjectsForStaleGroups(
            isCompact: isCompact,
            groupByProject: groupByProject,
            groups: groups,
            collapsedProjects: collapsedProjects,
            staleAutoCollapsedProjects: staleAutoCollapsedProjects,
            manuallyExpandedStaleProjects: manuallyExpandedStaleProjects
        )
        collapsedProjects = synchronized.collapsedProjects
        staleAutoCollapsedProjects = synchronized.staleAutoCollapsedProjects
        manuallyExpandedStaleProjects = synchronized.manuallyExpandedStaleProjects
    }

    static func synchronizeCollapsedProjectsForStaleGroups(
        isCompact: Bool,
        groupByProject: Bool,
        groups: [HUDGroup],
        collapsedProjects: Set<String>,
        staleAutoCollapsedProjects: Set<String>,
        manuallyExpandedStaleProjects: Set<String>
    ) -> (collapsedProjects: Set<String>, staleAutoCollapsedProjects: Set<String>, manuallyExpandedStaleProjects: Set<String>) {
        var collapsedProjects = collapsedProjects
        var staleAutoCollapsedProjects = staleAutoCollapsedProjects
        var manuallyExpandedStaleProjects = manuallyExpandedStaleProjects

        guard isCompact, groupByProject else {
            if !staleAutoCollapsedProjects.isEmpty {
                collapsedProjects.subtract(staleAutoCollapsedProjects)
            }
            staleAutoCollapsedProjects.removeAll(keepingCapacity: false)
            manuallyExpandedStaleProjects.removeAll(keepingCapacity: false)
            return (collapsedProjects, staleAutoCollapsedProjects, manuallyExpandedStaleProjects)
        }

        let staleOnlyIDs = Set(groups.lazy.filter(\.isStaleOnly).map(\.id))
        let noLongerStale = staleAutoCollapsedProjects.subtracting(staleOnlyIDs)
        if !noLongerStale.isEmpty {
            collapsedProjects.subtract(noLongerStale)
            staleAutoCollapsedProjects.subtract(noLongerStale)
        }

        manuallyExpandedStaleProjects.formIntersection(staleOnlyIDs)

        for group in groups where group.isStaleOnly {
            guard !staleAutoCollapsedProjects.contains(group.id),
                  !manuallyExpandedStaleProjects.contains(group.id) else {
                continue
            }
            collapsedProjects.insert(group.id)
            staleAutoCollapsedProjects.insert(group.id)
        }

        staleAutoCollapsedProjects.formIntersection(staleOnlyIDs)
        return (collapsedProjects, staleAutoCollapsedProjects, manuallyExpandedStaleProjects)
    }

    private func shouldShowStaleGroupsDivider(before index: Int, in groups: [HUDGroup]) -> Bool {
        guard isCompact, groupByProject else { return false }
        guard groups.indices.contains(index) else { return false }
        guard groups[index].isStaleOnly else { return false }
        guard groups.contains(where: { !$0.isStaleOnly }) else { return false }
        return index == 0 || !groups[index - 1].isStaleOnly
    }

    private func queueInsertionHighlights(for ids: [String]) {
        let freshIDs = Set(ids)
        guard !freshIDs.isEmpty else { return }
        highlightedRowIDs.formUnion(freshIDs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            withAnimation(.easeOut(duration: 0.20)) {
                highlightedRowIDs.subtract(freshIDs)
            }
        }
    }

    private func handleWindowVisibilityChange(isVisible: Bool) {
        activeCodex.setCockpitWindowVisible(isVisible, consumerID: activeConsumerID)
        guard isWindowVisibleForOrdering != isVisible else { return }
        isWindowVisibleForOrdering = isVisible
        if !isVisible {
            wasWindowHiddenSinceLastVisible = true
        }
    }

    private func handleWindowKeyChange(isKey: Bool) {
        withAnimation(.easeInOut(duration: 0.14)) {
            isCockpitWindowKey = isKey
        }
    }

    private func focusSearchField(selectAll: Bool) {
        isSearchFocused = true
        if selectAll {
            searchFocusToken &+= 1
        }
    }

    private func focus(_ row: HUDRow) {
        guard activeEnabled else { return }
        if CodexActiveSessionsModel.tryFocusITerm2(itermSessionId: row.itermSessionId, tty: row.tty) {
            return
        }
        if let url = row.revealURL {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ row: HUDRow) -> some View {
        Button("Go to Session") {
            goToSession(row)
        }
        .disabled(!activeEnabled || row.resolvedSessionID == nil)
        .help("Select this session in the main Agent Sessions window and open its transcript.")

        Button("Focus in iTerm2") {
            focus(row)
        }
        .disabled(!activeEnabled || !canFocus(row))
        .help("Focus the existing iTerm2 tab/window for this session.")

        Divider()

        Button("Reveal Log") {
            revealLog(row)
        }
        .disabled(!activeEnabled || row.logPath == nil)
        .help("Reveal the session log in Finder.")

        Button("Open Working Directory") {
            openWorkingDirectory(row)
        }
        .disabled(!activeEnabled || row.workingDirectory == nil)
        .help("Open the working directory in Finder.")

        Divider()

        Button("Copy Session ID") {
            copyToPasteboard(row.runtimeSessionID ?? row.resolvedSessionID)
        }
        .disabled((row.runtimeSessionID ?? row.resolvedSessionID) == nil)

        Button("Copy Tab Title") {
            copyToPasteboard(normalizedTabTitle(row))
        }
        .disabled(normalizedTabTitle(row) == nil)

        Button("Copy Working Directory Path") {
            copyToPasteboard(row.workingDirectory)
        }
        .disabled(row.workingDirectory == nil)
    }

    private func canFocus(_ row: HUDRow) -> Bool {
        CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: row.itermSessionId,
            tty: row.tty,
            termProgram: row.termProgram
        ) || row.revealURL != nil
    }

    private func goToSession(_ row: HUDRow) {
        guard activeEnabled else { return }
        guard let resolvedSessionID = row.resolvedSessionID else {
            NSSound.beep()
            return
        }
        let pendingRequest = PendingCockpitNavigationRequest(
            unifiedSessionID: resolvedSessionID,
            sourceRawValue: row.source.rawValue,
            runtimeSessionID: row.runtimeSessionID,
            logPath: row.logPath,
            workingDirectory: row.workingDirectory,
            createdAt: Date()
        )
        CockpitNavigationBridge.store(pendingRequest)

        AppWindowRouter.showAgentSessionsWindow()

        var payload: [AnyHashable: Any] = ["source": row.source.rawValue]
        if let runtimeSessionID = row.runtimeSessionID, !runtimeSessionID.isEmpty {
            payload["runtimeSessionID"] = runtimeSessionID
        }
        if let logPath = row.logPath, !logPath.isEmpty {
            payload["logPath"] = logPath
        }
        if let workingDirectory = row.workingDirectory, !workingDirectory.isEmpty {
            payload["workingDirectory"] = workingDirectory
        }
        postGoToSessionNotification(
            unifiedSessionID: resolvedSessionID,
            payload: payload,
            attempt: 0
        )
    }

    private func postGoToSessionNotification(unifiedSessionID: String,
                                             payload: [AnyHashable: Any],
                                             attempt: Int) {
        NotificationCenter.default.post(
            name: .navigateToSessionFromCockpit,
            object: unifiedSessionID,
            userInfo: payload
        )

        guard attempt < 8 else { return }
        guard CockpitNavigationBridge.hasPending(unifiedSessionID: unifiedSessionID) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            postGoToSessionNotification(
                unifiedSessionID: unifiedSessionID,
                payload: payload,
                attempt: attempt + 1
            )
        }
    }

    private func revealLog(_ row: HUDRow) {
        guard let path = row.logPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func openWorkingDirectory(_ row: HUDRow) {
        guard let path = row.workingDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
    }

    private func normalizedTabTitle(_ row: HUDRow) -> String? {
        row.cleanedTabTitle
    }

    private var disabledCallout: some View {
        PreferenceCallout {
            Text("Live sessions + Cockpit (Beta) is disabled in Settings → Agent Cockpit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func liveSessionSummary(activeCodex: CodexActiveSessionsModel) -> HUDLiveSessionSummary {
        let presences = displayableLiveSummaryPresences(from: activeCodex.presences, lookupIndexes: nil)
        let activeCount = presences.reduce(into: 0) { count, presence in
            if activeCodex.liveState(for: presence) == .activeWorking {
                count += 1
            }
        }
        let waitingCount = max(0, presences.count - activeCount)
        return HUDLiveSessionSummary(activeCount: activeCount, waitingCount: waitingCount)
    }

    static func liveSessionSummary(activeCodex: CodexActiveSessionsModel,
                                   lookupIndexes: SessionLookupIndexes?) -> HUDLiveSessionSummary {
        let presences = displayableLiveSummaryPresences(from: activeCodex.presences, lookupIndexes: lookupIndexes)
        let activeCount = presences.reduce(into: 0) { count, presence in
            if activeCodex.liveState(for: presence) == .activeWorking {
                count += 1
            }
        }
        let waitingCount = max(0, presences.count - activeCount)
        return HUDLiveSessionSummary(activeCount: activeCount, waitingCount: waitingCount)
    }

    static func liveSessionSummary(activeCodex: CodexActiveSessionsModel,
                                   codexIndexer: SessionIndexer,
                                   claudeIndexer: ClaudeSessionIndexer,
                                   opencodeIndexer: OpenCodeSessionIndexer) -> HUDLiveSessionSummary {
        liveSessionSummary(
            activeCodex: activeCodex,
            lookupIndexes: buildSessionLookupIndexes(
                codexSessions: codexIndexer.allSessions,
                claudeSessions: claudeIndexer.allSessions,
                opencodeSessions: opencodeIndexer.allSessions
            )
        )
    }

    private static func displayableLiveSummaryPresences(from presences: [CodexActivePresence],
                                                        lookupIndexes: SessionLookupIndexes?) -> [CodexActivePresence] {
        let supportedSources: Set<SessionSource> = [.codex, .claude, .opencode]
        let filtered = presences.filter { presence in
            guard supportedSources.contains(presence.source) else { return false }
            let hasWorkspaceMatch = hasWorkspaceMatchForSummary(presence, lookupIndexes: lookupIndexes)
            return !Self.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: hasWorkspaceMatch
            )
        }

        let coalesced = CodexActiveSessionsModel.coalescePresencesByTTY(filtered)
        var byKey: [String: CodexActivePresence] = [:]
        byKey.reserveCapacity(coalesced.count)
        for presence in coalesced {
            let key = liveSummaryPresenceKey(for: presence)
            byKey[key] = preferredLiveSummaryPresence(existing: byKey[key], incoming: presence)
        }
        return Array(byKey.values)
    }

    private static func hasWorkspaceMatchForSummary(_ presence: CodexActivePresence,
                                                    lookupIndexes: SessionLookupIndexes?) -> Bool {
        guard let lookupIndexes else { return false }
        return Self.resolveByWorkspace(
            presence.workspaceRoot,
            source: presence.source,
            lookupIndexes: lookupIndexes
        ) != nil
    }

    private static func liveSummaryPresenceKey(for presence: CodexActivePresence) -> String {
        if let sessionID = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            return CodexActiveSessionsModel.sessionLookupKey(source: presence.source, sessionId: sessionID)
        }
        if let logPath = presence.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !logPath.isEmpty {
            return CodexActiveSessionsModel.logLookupKey(
                source: presence.source,
                normalizedPath: CodexActiveSessionsModel.normalizePath(logPath)
            )
        }
        if let tty = normalizeTTY(presence.tty) {
            return "\(presence.source.rawValue)|tty:\(tty)"
        }
        if let workspace = normalizedWorkingDirectory(presence.workspaceRoot), !workspace.isEmpty {
            return workspaceLookupKey(source: presence.source, normalizedPath: workspace)
        }
        if let sourceFilePath = presence.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourceFilePath.isEmpty {
            return "\(presence.source.rawValue)|src:\(CodexActiveSessionsModel.normalizePath(sourceFilePath))"
        }
        if let pid = presence.pid {
            return "\(presence.source.rawValue)|pid:\(pid)"
        }
        return CodexActiveSessionsModel.presenceKey(for: presence)
    }

    private static func preferredLiveSummaryPresence(existing: CodexActivePresence?,
                                                     incoming: CodexActivePresence) -> CodexActivePresence {
        guard let existing else { return incoming }
        let existingSeen = existing.lastSeenAt ?? .distantPast
        let incomingSeen = incoming.lastSeenAt ?? .distantPast
        if incomingSeen != existingSeen {
            return incomingSeen > existingSeen ? incoming : existing
        }
        let existingHasJoin = (existing.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (existing.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let incomingHasJoin = (incoming.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (incoming.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        if existingHasJoin != incomingHasJoin {
            return incomingHasJoin ? incoming : existing
        }
        return existing
    }

    fileprivate static func makeRowsSnapshot(codexSessions: [Session],
                                             claudeSessions: [Session],
                                             opencodeSessions: [Session],
                                             presences: [CodexActivePresence],
                                             activeCodex: CodexActiveSessionsModel,
                                             isCompact: Bool,
                                             lookupIndexes: SessionLookupIndexes,
                                             now: Date = Date()) -> HUDRowsSnapshot {
        let supportedSources: Set<SessionSource> = [.codex, .claude, .opencode]
        let allSessions = codexSessions + claudeSessions + opencodeSessions
        let fallbackBySessionKey = UnifiedSessionsView.buildFallbackPresenceMap(
            sessions: allSessions,
            presences: presences
        ) { candidate in
            activeCodex.presence(for: candidate) != nil
        }

        var fallbackSessionByPresenceKey: [String: Session] = [:]
        fallbackSessionByPresenceKey.reserveCapacity(fallbackBySessionKey.count)

        for session in allSessions {
            let sessionKey = UnifiedSessionsView.fallbackPresenceKey(source: session.source, sessionID: session.id)
            guard let presence = fallbackBySessionKey[sessionKey] else { continue }
            let presenceKey = CodexActiveSessionsModel.presenceKey(for: presence)
            guard presenceKey != "unknown" else { continue }
            fallbackSessionByPresenceKey[presenceKey] = Self.preferredSession(
                existing: fallbackSessionByPresenceKey[presenceKey],
                incoming: session
            )
        }

        let mappedRows: [LegacyMappedRow] = presences.compactMap { presence in
            guard supportedSources.contains(presence.source) else { return nil }
            let logNorm = presence.sessionLogPath.map(CodexActiveSessionsModel.normalizePath)
            let presenceKey = CodexActiveSessionsModel.presenceKey(for: presence)

            let session = logNorm.flatMap { normalized in
                lookupIndexes.byLogPath[CodexActiveSessionsModel.logLookupKey(source: presence.source, normalizedPath: normalized)]
            } ?? Self.resolveBySessionID(presence.sessionId, source: presence.source, lookupIndexes: lookupIndexes)
                ?? Self.resolveByWorkspace(presence.workspaceRoot, source: presence.source, lookupIndexes: lookupIndexes)
                ?? fallbackSessionByPresenceKey[presenceKey]

            if Self.shouldHideUnresolvedPresencePlaceholder(presence, resolvedSession: session, lookupIndexes: lookupIndexes) {
                return nil
            }

            let title = session?.title
                ?? presence.sessionId.map { "Session \($0.prefix(8))" }
                ?? "Active \(presence.source.displayName) session"

            let repo = Self.projectLabel(resolvedSession: session, presence: presence)
            let date = session?.modifiedAt ?? Self.parseSessionTimestamp(from: presence)
            let lastActivityAt = activeCodex.lastActivityAt(for: presence) ?? date
            let liveState = activeCodex.liveState(for: presence)

            let stableID: String =
                "\(presence.source.rawValue)|" + (logNorm
                ?? presence.sessionId
                ?? presence.sourceFilePath
                ?? presence.pid.map { "pid:\($0)" }
                ?? presence.tty
                ?? "\(presence.sessionLogPath ?? "unknown")|\(presence.pid ?? -1)")

            return LegacyMappedRow(
                id: stableID,
                source: presence.source,
                title: title,
                liveState: liveState,
                lastSeenAt: presence.lastSeenAt,
                repo: repo,
                date: date,
                focusURL: presence.revealURL,
                itermSessionId: presence.terminal?.itermSessionId,
                tty: presence.tty,
                termProgram: presence.terminal?.termProgram,
                tabTitle: presence.terminal?.tabTitle,
                resolvedSessionID: session?.id,
                sessionID: Self.authoritativeSessionID(for: presence, resolvedSession: session),
                logPath: presence.sessionLogPath,
                workingDirectory: session?.cwd ?? presence.workspaceRoot,
                lastActivityAt: lastActivityAt
            )
        }

        let deduped = Self.dedupeRowsByResolvedSession(mappedRows)

        let sorted = deduped.sorted { a, b in
            let aState = Self.mapLiveStateForHUD(a.liveState)
            let bState = Self.mapLiveStateForHUD(b.liveState)
            let aPriority = Self.displayPriority(for: aState, lastActivityAt: a.lastActivityAt, now: now)
            let bPriority = Self.displayPriority(for: bState, lastActivityAt: b.lastActivityAt, now: now)
            if aPriority != bPriority {
                return aPriority.rawValue < bPriority.rawValue
            }
            let da = a.lastActivityAt ?? .distantPast
            let db = b.lastActivityAt ?? .distantPast
            if da != db { return da > db }
            if a.repo != b.repo { return a.repo.localizedCaseInsensitiveCompare(b.repo) == .orderedAscending }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        let hudRows = sorted.map { row in
            let hudState = Self.mapLiveStateForHUD(row.liveState)
            let elapsed = isCompact ? "" : Self.elapsedLabel(from: row.lastActivityAt)
            let activityTooltip = row.lastActivityAt.map { Self.activityTooltipFormatter.string(from: $0) }
            let cleanedTabTitle = Self.normalizedCockpitTabTitle(row.tabTitle, source: row.source)
            return HUDRow(
                id: row.id,
                source: row.source,
                agentType: Self.mapAgentType(row.source),
                projectName: row.repo,
                displayName: row.title,
                liveState: hudState,
                preview: row.title,
                elapsed: elapsed,
                lastSeenAt: row.lastSeenAt,
                itermSessionId: row.itermSessionId,
                revealURL: row.focusURL,
                tty: row.tty,
                termProgram: row.termProgram,
                tabTitle: row.tabTitle,
                cleanedTabTitle: cleanedTabTitle,
                resolvedSessionID: row.resolvedSessionID,
                runtimeSessionID: row.sessionID,
                logPath: row.logPath,
                workingDirectory: row.workingDirectory,
                lastActivityAt: row.lastActivityAt,
                lastActivityTooltip: activityTooltip
            )
        }

        let counts = Self.waitingCounts(for: hudRows, now: now)
        return HUDRowsSnapshot(rows: hudRows, activeCount: counts.active, idleCount: counts.idle)
    }

    private static func elapsedLabel(from date: Date?) -> String {
        guard let date else { return "—" }
        let delta = max(Int(Date().timeIntervalSince(date)), 0)
        if delta < 60 { return "\(delta)s" }
        if delta < 3600 { return "\(delta / 60)m" }
        if delta < 86400 { return "\(delta / 3600)h" }
        return "\(delta / 86400)d"
    }

    static func mapLiveStateForHUD(_ liveState: CodexLiveState) -> HUDLiveState {
        liveState == .activeWorking ? .active : .idle
    }

    static func displayPriority(for row: HUDRow, now: Date = Date()) -> HUDDisplayPriority {
        displayPriority(for: row.liveState, lastActivityAt: row.lastActivityAt, now: now)
    }

    static func displayPriority(for liveState: HUDLiveState,
                                lastActivityAt: Date?,
                                now: Date = Date()) -> HUDDisplayPriority {
        switch liveState {
        case .active:
            return .active
        case .idle:
            guard let lastActivityAt else { return .waitingFresh }
            return now.timeIntervalSince(lastActivityAt) >= staleWaitingThreshold ? .waitingStale : .waitingFresh
        }
    }

    static func isStaleWaiting(_ row: HUDRow, now: Date = Date()) -> Bool {
        displayPriority(for: row, now: now) == .waitingStale
    }

    private static let trailingParentheticalRegex: NSRegularExpression = {
        // Optional trailing "(...)" suffix used by iTerm tab defaults, e.g. "(codex*)".
        guard let regex = try? NSRegularExpression(pattern: #"\s*\(([^()]*)\)\s*$"#) else {
            fatalError("Invalid cockpit tab-title suffix regex.")
        }
        return regex
    }()

    private static let defaultTabTokensBySource: [SessionSource: Set<String>] = [
        .codex: ["codex"],
        .claude: ["claude", "claude code"]
    ]

    static func normalizedCockpitTabTitle(_ rawTitle: String?, source: SessionSource) -> String? {
        guard let rawTitle else { return nil }
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let defaultTokens = defaultTabTokensBySource[source, default: []]
        guard !defaultTokens.isEmpty else { return trimmed }

        let normalized = normalizeTabToken(trimmed)
        if defaultTokens.contains(normalized) {
            return nil
        }

        if let stripped = strippingTrailingDefaultSuffix(from: trimmed, defaults: defaultTokens) {
            let normalizedStripped = normalizeTabToken(stripped)
            guard !normalizedStripped.isEmpty, !defaultTokens.contains(normalizedStripped) else {
                return nil
            }
            return stripped
        }

        return trimmed
    }

    private static func strippingTrailingDefaultSuffix(from text: String,
                                                       defaults: Set<String>) -> String? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = trailingParentheticalRegex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        let suffixRange = match.range(at: 1)
        guard suffixRange.location != NSNotFound else { return nil }
        let suffix = nsText.substring(with: suffixRange)
        guard defaults.contains(normalizeTabToken(suffix)) else {
            return nil
        }

        let prefixRange = NSRange(location: 0, length: match.range.location)
        let prefix = nsText.substring(with: prefixRange).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix
    }

    private static func normalizeTabToken(_ text: String) -> String {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return "" }

        var sanitized = String()
        sanitized.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                sanitized.unicodeScalars.append(scalar)
            } else {
                sanitized.append(" ")
            }
        }

        return sanitized
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func counts(for rows: [HUDRow]) -> (active: Int, idle: Int) {
        let active = rows.reduce(into: 0) { partial, row in
            if row.liveState == .active { partial += 1 }
        }
        return (active: active, idle: rows.count - active)
    }

    static func liveSessionSummary(for rows: [HUDRow], now: Date = Date()) -> HUDLiveSessionSummary {
        let counts = waitingCounts(for: rows, now: now)
        return HUDLiveSessionSummary(activeCount: counts.active, waitingCount: counts.idle)
    }

    static func hasPriorityChurn(existing: [HUDRow], incoming: [HUDRow], now: Date = Date()) -> Bool {
        hasPriorityChurn(
            existing: existing,
            existingSnapshotAt: now,
            incoming: incoming,
            incomingSnapshotAt: now
        )
    }

    static func hasPriorityChurn(existing: [HUDRow],
                                 existingSnapshotAt: Date,
                                 incoming: [HUDRow],
                                 incomingSnapshotAt: Date) -> Bool {
        guard !existing.isEmpty, !incoming.isEmpty else { return false }
        let existingIDs = existing.map(\.id)
        let incomingIDs = incoming.map(\.id)
        if Set(existingIDs) == Set(incomingIDs), existingIDs != incomingIDs {
            return true
        }
        let existingPriorities = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, displayPriority(for: $0, now: existingSnapshotAt)) }
        )
        for row in incoming {
            guard let existingPriority = existingPriorities[row.id] else { continue }
            if existingPriority != displayPriority(for: row, now: incomingSnapshotAt) {
                return true
            }
        }
        return false
    }

    static func filteredRows(_ rows: [HUDRow], mode: HUDSessionFilterMode, query: String) -> [HUDRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            let statePass: Bool = {
                switch mode {
                case .all:
                    return true
                case .active:
                    return row.liveState == .active
                case .idle:
                    return row.liveState == .idle
                }
            }()
            guard statePass else { return false }
            guard !trimmed.isEmpty else { return true }
            let lowered = trimmed.lowercased()
            return row.projectName.lowercased().contains(lowered)
                || row.displayName.lowercased().contains(lowered)
                || row.preview.lowercased().contains(lowered)
                || (row.cleanedTabTitle?.lowercased().contains(lowered) ?? false)
        }
    }

    static func stableMergedOrder(existing: [String], incoming: [String]) -> (order: [String], inserted: [String]) {
        let incomingSet = Set(incoming)
        let kept = existing.filter { incomingSet.contains($0) }
        let keptSet = Set(kept)
        let inserted = incoming.filter { !keptSet.contains($0) }
        return (kept + inserted, inserted)
    }

    static func hasMembershipChurn(existing: [String], incoming: [String]) -> Bool {
        Set(existing) != Set(incoming)
    }

    static func groupedRows(_ rows: [HUDRow], now: Date = Date()) -> [HUDGroup] {
        var buckets: [String: [HUDRow]] = [:]
        buckets.reserveCapacity(rows.count)

        for row in rows {
            buckets[row.projectName, default: []].append(row)
        }

        var out: [HUDGroup] = buckets.map { projectName, projectRows in
            let sortedRows = sortRows(projectRows, now: now)
            let counts = waitingCounts(for: sortedRows, now: now)
            return HUDGroup(
                id: projectName,
                projectName: projectName,
                rows: sortedRows,
                activeCount: counts.active,
                idleCount: counts.idle,
                freshIdleCount: counts.freshIdle,
                staleIdleCount: counts.staleIdle
            )
        }

        out.sort { a, b in
            if a.displayPriority != b.displayPriority {
                return a.displayPriority.rawValue < b.displayPriority.rawValue
            }
            return a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
        }

        return out
    }

    static func groupedRowsPreservingOrder(_ rows: [HUDRow], now: Date = Date()) -> [HUDGroup] {
        var buckets: [String: [HUDRow]] = [:]
        var order: [String] = []
        buckets.reserveCapacity(rows.count)
        order.reserveCapacity(rows.count)

        for row in rows {
            if buckets[row.projectName] == nil {
                order.append(row.projectName)
            }
            buckets[row.projectName, default: []].append(row)
        }

        let groups: [HUDGroup] = order.compactMap { projectName -> HUDGroup? in
            guard let projectRows = buckets[projectName] else { return nil }
            let sortedRows = sortRows(projectRows, now: now)
            let counts = waitingCounts(for: sortedRows, now: now)
            return HUDGroup(
                id: projectName,
                projectName: projectName,
                rows: sortedRows,
                activeCount: counts.active,
                idleCount: counts.idle,
                freshIdleCount: counts.freshIdle,
                staleIdleCount: counts.staleIdle
            )
        }

        return groups.sorted { a, b in
            if a.displayPriority != b.displayPriority {
                return a.displayPriority.rawValue < b.displayPriority.rawValue
            }
            guard let aIndex = order.firstIndex(of: a.projectName),
                  let bIndex = order.firstIndex(of: b.projectName) else {
                return a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
            }
            return aIndex < bIndex
        }
    }

    private static func waitingCounts(for rows: [HUDRow], now: Date = Date()) -> HUDWaitingCounts {
        var active = 0
        var idle = 0
        var freshIdle = 0
        var staleIdle = 0

        for row in rows {
            switch displayPriority(for: row, now: now) {
            case .active:
                active += 1
            case .waitingFresh:
                idle += 1
                freshIdle += 1
            case .waitingStale:
                idle += 1
                staleIdle += 1
            }
        }

        return HUDWaitingCounts(active: active, idle: idle, freshIdle: freshIdle, staleIdle: staleIdle)
    }

    private static func sortRows(_ rows: [HUDRow], now: Date = Date()) -> [HUDRow] {
        rows.sorted { a, b in
            let aPriority = displayPriority(for: a, now: now)
            let bPriority = displayPriority(for: b, now: now)
            if aPriority != bPriority {
                return aPriority.rawValue < bPriority.rawValue
            }
            let da = a.lastActivityAt ?? .distantPast
            let db = b.lastActivityAt ?? .distantPast
            if da != db { return da > db }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private static func mapAgentType(_ source: SessionSource) -> HUDAgentType {
        switch source {
        case .codex:
            return .codex
        case .claude:
            return .claude
        case .opencode:
            return .opencode
        default:
            return .shell
        }
    }

    private static func authoritativeSessionID(for presence: CodexActivePresence, resolvedSession: Session?) -> String? {
        if let sessionID = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            return sessionID
        }
        guard let resolvedSession else { return nil }
        return CodexActiveSessionsModel.liveSessionIDCandidates(for: resolvedSession).first
    }

    private static func resolveBySessionID(_ id: String?, source: SessionSource, lookupIndexes: SessionLookupIndexes) -> Session? {
        guard let id, !id.isEmpty else { return nil }
        let key = CodexActiveSessionsModel.sessionLookupKey(source: source, sessionId: id)
        return lookupIndexes.bySessionID[key]
    }

    private static func resolveByWorkspace(_ workspaceRoot: String?,
                                           source: SessionSource,
                                           lookupIndexes: SessionLookupIndexes) -> Session? {
        guard let normalizedWorkspace = normalizedWorkingDirectory(workspaceRoot), !normalizedWorkspace.isEmpty else {
            return nil
        }
        let exactKey = workspaceLookupKey(source: source, normalizedPath: normalizedWorkspace)
        if let session = lookupIndexes.byWorkspace[exactKey] {
            return session
        }

        let sourcePrefix = "\(source.rawValue)|cwd:"
        var best: (session: Session, score: Int)?
        for (key, session) in lookupIndexes.byWorkspace {
            guard key.hasPrefix(sourcePrefix) else { continue }
            let sessionPath = String(key.dropFirst(sourcePrefix.count))
            guard !sessionPath.isEmpty else { continue }
            let hasRelation =
                normalizedWorkspace == sessionPath
                || normalizedWorkspace.hasPrefix(sessionPath + "/")
                || sessionPath.hasPrefix(normalizedWorkspace + "/")
            guard hasRelation else { continue }
            let candidate = (session: session, score: sessionPath.count)
            if let best, best.score >= candidate.score {
                continue
            }
            best = candidate
        }
        return best?.session
    }

    static func projectLabel(resolvedSession: Session?, presence: CodexActivePresence) -> String {
        if let repoName = normalizedProjectLabel(resolvedSession?.repoName) {
            return repoName
        }
        if let inferred = inferredProjectName(fromPath: resolvedSession?.cwd) {
            return inferred
        }
        if let inferred = inferredProjectName(fromPath: presence.workspaceRoot) {
            return inferred
        }
        if let repoDisplay = normalizedProjectLabel(resolvedSession?.repoDisplay), repoDisplay != "—" {
            return repoDisplay
        }
        return "-"
    }

    private static func normalizedProjectLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func inferredProjectName(fromPath rawPath: String?) -> String? {
        guard let rawPath = normalizedProjectLabel(rawPath) else { return nil }
        let normalizedPath = CodexActiveSessionsModel.normalizePath(rawPath)
        guard !normalizedPath.isEmpty else { return nil }
        let genericNames = Set(["documents", "desktop", "downloads", "tmp", "temp", "src", "code"])

        let url = URL(fileURLWithPath: normalizedPath)
        let candidate = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty, candidate != ".", !genericNames.contains(candidate.lowercased()) {
            return candidate
        }

        let parent = url.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parent.isEmpty, parent != ".", !genericNames.contains(parent.lowercased()) else { return nil }
        return parent
    }

    private static func shouldHideUnresolvedPresencePlaceholder(_ presence: CodexActivePresence,
                                                                resolvedSession: Session?,
                                                                lookupIndexes: SessionLookupIndexes) -> Bool {
        let hasWorkspaceMatch = Self.resolveByWorkspace(
            presence.workspaceRoot,
            source: presence.source,
            lookupIndexes: lookupIndexes
        ) != nil
        return Self.shouldHideUnresolvedPresencePlaceholder(
            presence,
            resolvedSession: resolvedSession,
            hasWorkspaceMatch: hasWorkspaceMatch
        )
    }

    static func shouldHideUnresolvedPresencePlaceholder(_ presence: CodexActivePresence,
                                                        resolvedSession: Session?,
                                                        hasWorkspaceMatch: Bool) -> Bool {
        guard resolvedSession == nil else { return false }
        let kind = presence.kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if kind == "subagent" { return true }

        let hasSessionID = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLogPath = presence.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasSessionID || hasLogPath { return false }

        if presence.source == .codex { return !hasWorkspaceMatch }

        let hasRevealURL = presence.revealURL != nil
        let hasITermGuid = CodexActiveSessionsModel.itermSessionGuid(from: presence.terminal?.itermSessionId)?.isEmpty == false
        let termProgram = presence.terminal?.termProgram?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let reportsITermProgram = termProgram.contains("iterm")
        let canFocusFallbackStrict = hasRevealURL || hasITermGuid || reportsITermProgram

        if canFocusFallbackStrict { return false }
        if hasWorkspaceMatch { return false }
        return true
    }

    private static func dedupeRowsByResolvedSession(_ rows: [LegacyMappedRow]) -> [LegacyMappedRow] {
        var byKey: [String: LegacyMappedRow] = [:]
        byKey.reserveCapacity(rows.count)

        for row in rows {
            let key: String = {
                if let id = row.sessionID, !id.isEmpty {
                    return "\(row.source.rawValue)|sid:\(id)"
                }
                if let path = row.logPath {
                    return CodexActiveSessionsModel.logLookupKey(
                        source: row.source,
                        normalizedPath: CodexActiveSessionsModel.normalizePath(path)
                    )
                }
                if let tty = Self.normalizeTTY(row.tty) {
                    return "\(row.source.rawValue)|tty:\(tty)"
                }
                if let workspace = Self.normalizedWorkingDirectory(row.workingDirectory), !workspace.isEmpty {
                    return Self.workspaceLookupKey(source: row.source, normalizedPath: workspace)
                }
                if let itermSessionId = row.itermSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !itermSessionId.isEmpty {
                    return "\(row.source.rawValue)|iterm:\(itermSessionId)"
                }
                return row.id
            }()
            let existing = byKey[key]
            byKey[key] = Self.preferredRow(existing: existing, incoming: row)
        }

        return Array(byKey.values)
    }

    private static func preferredRow(existing: LegacyMappedRow?, incoming: LegacyMappedRow) -> LegacyMappedRow {
        guard let existing else { return incoming }
        let winner: LegacyMappedRow
        let loser: LegacyMappedRow
        let existingHasDate = existing.date != nil
        let incomingHasDate = incoming.date != nil
        if existingHasDate != incomingHasDate {
            winner = incomingHasDate ? incoming : existing
            loser = incomingHasDate ? existing : incoming
            return Self.mergeMetadata(into: winner, from: loser)
        }
        let existingSeen = existing.lastSeenAt ?? .distantPast
        let incomingSeen = incoming.lastSeenAt ?? .distantPast
        if incomingSeen != existingSeen {
            winner = incomingSeen > existingSeen ? incoming : existing
            loser = incomingSeen > existingSeen ? existing : incoming
            return Self.mergeMetadata(into: winner, from: loser)
        }
        let existingHasJoin = (existing.sessionID?.isEmpty == false) || existing.logPath != nil
        let incomingHasJoin = (incoming.sessionID?.isEmpty == false) || incoming.logPath != nil
        if existingHasJoin != incomingHasJoin {
            winner = incomingHasJoin ? incoming : existing
            loser = incomingHasJoin ? existing : incoming
            return Self.mergeMetadata(into: winner, from: loser)
        }
        if existing.liveState != incoming.liveState {
            let existingCanProbe = Self.rowCanTailProbe(existing)
            let incomingCanProbe = Self.rowCanTailProbe(incoming)
            if existingCanProbe != incomingCanProbe {
                winner = incomingCanProbe ? incoming : existing
                loser = incomingCanProbe ? existing : incoming
                return Self.mergeMetadata(into: winner, from: loser)
            }
            if existing.liveState == .activeWorking, incoming.liveState == .openIdle {
                return Self.mergeMetadata(into: incoming, from: existing)
            }
            return Self.mergeMetadata(into: existing, from: incoming)
        }
        if incoming.title.count > existing.title.count {
            return Self.mergeMetadata(into: incoming, from: existing)
        }
        return Self.mergeMetadata(into: existing, from: incoming)
    }

    private static func mergeMetadata(into winner: LegacyMappedRow, from loser: LegacyMappedRow) -> LegacyMappedRow {
        LegacyMappedRow(
            id: winner.id,
            source: winner.source,
            title: winner.title,
            liveState: winner.liveState,
            lastSeenAt: winner.lastSeenAt ?? loser.lastSeenAt,
            repo: winner.repo,
            date: winner.date ?? loser.date,
            focusURL: winner.focusURL ?? loser.focusURL,
            itermSessionId: winner.itermSessionId ?? loser.itermSessionId,
            tty: winner.tty ?? loser.tty,
            termProgram: winner.termProgram ?? loser.termProgram,
            tabTitle: winner.tabTitle ?? loser.tabTitle,
            resolvedSessionID: winner.resolvedSessionID ?? loser.resolvedSessionID,
            sessionID: winner.sessionID ?? loser.sessionID,
            logPath: winner.logPath ?? loser.logPath,
            workingDirectory: winner.workingDirectory ?? loser.workingDirectory,
            lastActivityAt: winner.lastActivityAt ?? loser.lastActivityAt
        )
    }

    private static func rowCanTailProbe(_ row: LegacyMappedRow) -> Bool {
        CodexActiveSessionsModel.canAttemptITerm2TailProbe(
            itermSessionId: row.itermSessionId,
            tty: row.tty,
            termProgram: row.termProgram
        )
    }

    private static func parseSessionTimestamp(from presence: CodexActivePresence) -> Date? {
        guard let path = presence.sessionLogPath else { return nil }
        if presence.source != .codex {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attrs[.modificationDate] as? Date {
                return date
            }
            return nil
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard filename.hasPrefix("rollout-") else { return nil }
        guard let tRange = filename.range(of: #"rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-"#,
                                          options: .regularExpression) else {
            return nil
        }

        let match = String(filename[tRange])
        let ts = match
            .replacingOccurrences(of: "rollout-", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return Self.codexRolloutTimestampFormatter.date(from: ts)
    }

    static func buildSessionLookupIndexes(codexSessions: [Session],
                                          claudeSessions: [Session],
                                          opencodeSessions: [Session] = []) -> SessionLookupIndexes {
        let supportedSources: Set<SessionSource> = [.codex, .claude, .opencode]
        let allSessions = codexSessions + claudeSessions + opencodeSessions

        var byLogPath: [String: Session] = [:]
        var bySessionID: [String: Session] = [:]
        var byWorkspace: [String: Session] = [:]
        byLogPath.reserveCapacity(allSessions.count)
        bySessionID.reserveCapacity(allSessions.count * 2)
        byWorkspace.reserveCapacity(allSessions.count)

        for session in allSessions where supportedSources.contains(session.source) {
            let logKey = CodexActiveSessionsModel.logLookupKey(
                source: session.source,
                normalizedPath: CodexActiveSessionsModel.normalizePath(session.filePath)
            )
            byLogPath[logKey] = Self.preferredSession(existing: byLogPath[logKey], incoming: session)

            for runtimeID in CodexActiveSessionsModel.liveSessionIDCandidates(for: session) {
                let sid = runtimeID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sid.isEmpty else { continue }
                let sessionKey = CodexActiveSessionsModel.sessionLookupKey(source: session.source, sessionId: sid)
                bySessionID[sessionKey] = Self.preferredSession(existing: bySessionID[sessionKey], incoming: session)
            }

            if let cwd = Self.normalizedWorkingDirectory(session.cwd), !cwd.isEmpty {
                let workspaceKey = Self.workspaceLookupKey(source: session.source, normalizedPath: cwd)
                byWorkspace[workspaceKey] = Self.preferredSession(existing: byWorkspace[workspaceKey], incoming: session)
            }
        }

        return SessionLookupIndexes(byLogPath: byLogPath, bySessionID: bySessionID, byWorkspace: byWorkspace)
    }

    private static func preferredSession(existing: Session?, incoming: Session) -> Session {
        guard let existing else { return incoming }
        if incoming.modifiedAt != existing.modifiedAt {
            return incoming.modifiedAt > existing.modifiedAt ? incoming : existing
        }
        let incomingStart = incoming.startTime ?? .distantPast
        let existingStart = existing.startTime ?? .distantPast
        if incomingStart != existingStart {
            return incomingStart > existingStart ? incoming : existing
        }
        if incoming.filePath != existing.filePath {
            return incoming.filePath < existing.filePath ? incoming : existing
        }
        return incoming.id < existing.id ? incoming : existing
    }

    private static func normalizedWorkingDirectory(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = CodexActiveSessionsModel.normalizePath(raw)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeTTY(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/dev/") {
            return trimmed
        }
        return "/dev/\(trimmed)"
    }

    private static func workspaceLookupKey(source: SessionSource, normalizedPath: String) -> String {
        "\(source.rawValue)|cwd:\(normalizedPath)"
    }
}

private struct CockpitWindowVisibilityObserver: NSViewRepresentable {
    let onVisibilityChanged: (Bool) -> Void
    var onKeyWindowChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onVisibilityChanged: onVisibilityChanged,
            onKeyWindowChanged: onKeyWindowChanged
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            context.coordinator.attach(to: view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onVisibilityChanged = onVisibilityChanged
        context.coordinator.onKeyWindowChanged = onKeyWindowChanged
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
#if DEBUG
        private struct DebugAttachmentState {
            var attachedWindowCount: Int = 0
            var activeObserverSetCount: Int = 0
            var maxAttachedWindowCount: Int = 0
            var maxActiveObserverSetCount: Int = 0
        }
        private static let debugAttachmentLock = NSLock()
        private static var debugAttachmentState = DebugAttachmentState()

        static func debugAttachmentSnapshot() -> (attachedWindows: Int, activeObserverSets: Int, maxAttachedWindows: Int, maxActiveObserverSets: Int) {
            debugAttachmentLock.lock()
            let state = debugAttachmentState
            debugAttachmentLock.unlock()
            return (
                attachedWindows: state.attachedWindowCount,
                activeObserverSets: state.activeObserverSetCount,
                maxAttachedWindows: state.maxAttachedWindowCount,
                maxActiveObserverSets: state.maxActiveObserverSetCount
            )
        }

        private static func recordAttach() {
            debugAttachmentLock.lock()
            debugAttachmentState.attachedWindowCount += 1
            debugAttachmentState.activeObserverSetCount += 1
            debugAttachmentState.maxAttachedWindowCount = max(
                debugAttachmentState.maxAttachedWindowCount,
                debugAttachmentState.attachedWindowCount
            )
            debugAttachmentState.maxActiveObserverSetCount = max(
                debugAttachmentState.maxActiveObserverSetCount,
                debugAttachmentState.activeObserverSetCount
            )
            debugAttachmentLock.unlock()
        }

        private static func recordDetach() {
            debugAttachmentLock.lock()
            debugAttachmentState.attachedWindowCount = max(0, debugAttachmentState.attachedWindowCount - 1)
            debugAttachmentState.activeObserverSetCount = max(0, debugAttachmentState.activeObserverSetCount - 1)
            debugAttachmentLock.unlock()
        }
#endif
        var onVisibilityChanged: (Bool) -> Void
        var onKeyWindowChanged: ((Bool) -> Void)?
        private weak var window: NSWindow?
        private var miniObserver: NSObjectProtocol?
        private var deminiObserver: NSObjectProtocol?
        private var occlusionObserver: NSObjectProtocol?
        private var closeObserver: NSObjectProtocol?
        private var becameKeyObserver: NSObjectProtocol?
        private var resignedKeyObserver: NSObjectProtocol?

        init(onVisibilityChanged: @escaping (Bool) -> Void,
             onKeyWindowChanged: ((Bool) -> Void)?) {
            self.onVisibilityChanged = onVisibilityChanged
            self.onKeyWindowChanged = onKeyWindowChanged
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else { return }
            guard window !== newWindow else { return }
            detach()
            window = newWindow
#if DEBUG
            Self.recordAttach()
#endif

            miniObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                self?.emitCurrentVisibility()
            }

            deminiObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                self?.emitCurrentVisibility()
            }

            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                self?.emitCurrentVisibility()
            }

            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                self?.onVisibilityChanged(false)
                self?.onKeyWindowChanged?(false)
                self?.detach()
            }

            becameKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                self?.emitCurrentKeyState()
            }

            resignedKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                self?.emitCurrentKeyState()
            }

            DispatchQueue.main.async { [weak self] in
                self?.emitCurrentVisibility()
                self?.emitCurrentKeyState()
            }
        }

        func detach() {
            if let observer = miniObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = deminiObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = occlusionObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = closeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = becameKeyObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = resignedKeyObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            miniObserver = nil
            deminiObserver = nil
            occlusionObserver = nil
            closeObserver = nil
            becameKeyObserver = nil
            resignedKeyObserver = nil
            if window != nil {
#if DEBUG
                Self.recordDetach()
#endif
            }
            window = nil
        }

        private func emitCurrentVisibility() {
            guard let window else { return }
            let visible = !window.isMiniaturized && window.isVisible
            onVisibilityChanged(visible)
        }

        private func emitCurrentKeyState() {
            guard let window else { return }
            onKeyWindowChanged?(window.isKeyWindow)
        }

        deinit {
            detach()
        }
    }
}

private struct CockpitScrollViewScrollerConfigurator: NSViewRepresentable {
    let alwaysVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attachIfNeeded(to: nsView)
        context.coordinator.apply(alwaysVisible: alwaysVisible)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restoreBaseline()
    }

    final class Coordinator {
        private weak var scrollView: NSScrollView?
        private var baselineAutohides: Bool?
        private var baselineScrollerStyle: NSScroller.Style?

        func attachIfNeeded(to view: NSView?) {
            guard let candidate = enclosingScrollView(from: view) else { return }
            guard scrollView !== candidate else { return }
            scrollView = candidate
            baselineAutohides = candidate.autohidesScrollers
            baselineScrollerStyle = candidate.scrollerStyle
        }

        func apply(alwaysVisible: Bool) {
            guard let scrollView else { return }
            scrollView.hasVerticalScroller = true
            if alwaysVisible {
                scrollView.autohidesScrollers = false
                scrollView.scrollerStyle = .legacy
            } else {
                if let baselineAutohides {
                    scrollView.autohidesScrollers = baselineAutohides
                }
                if let baselineScrollerStyle {
                    scrollView.scrollerStyle = baselineScrollerStyle
                }
            }
        }

        func restoreBaseline() {
            apply(alwaysVisible: false)
            scrollView = nil
            baselineAutohides = nil
            baselineScrollerStyle = nil
        }

        private func enclosingScrollView(from view: NSView?) -> NSScrollView? {
            var current = view
            while let node = current {
                if let scrollView = node as? NSScrollView {
                    return scrollView
                }
                if let enclosing = node.enclosingScrollView {
                    return enclosing
                }
                current = node.superview
            }
            return nil
        }

        deinit {
            restoreBaseline()
        }
    }
}

// MARK: - HUD Limits Bar

private struct HUDLimitsProviderEntry {
    let source: UsageTrackingSource
    let fiveHourLeft: Int
    let weekLeft: Int
    let fiveHourResetText: String
    let weekResetText: String
}

/// An isolated view that observes usage models independently so that
/// polling updates don't cause the entire AgentCockpitHUDView to re-render.
private struct HUDLimitsBar: View {
    @EnvironmentObject private var codexUsageModel: CodexUsageModel
    @EnvironmentObject private var claudeUsageModel: ClaudeUsageModel
    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled = false
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled = true
    @AppStorage(PreferencesKey.usageDisplayMode) private var usageDisplayModeRaw = UsageDisplayMode.left.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: UsageDisplayMode { UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left }

    private var entries: [HUDLimitsProviderEntry] {
        var out: [HUDLimitsProviderEntry] = []
        if codexAgentEnabled && codexUsageEnabled {
            out.append(HUDLimitsProviderEntry(
                source: .codex,
                fiveHourLeft: codexUsageModel.fiveHourRemainingPercent,
                weekLeft: codexUsageModel.weekRemainingPercent,
                fiveHourResetText: codexUsageModel.fiveHourResetText,
                weekResetText: codexUsageModel.weekResetText
            ))
        }
        if claudeAgentEnabled && claudeUsageEnabled {
            out.append(HUDLimitsProviderEntry(
                source: .claude,
                fiveHourLeft: claudeUsageModel.sessionRemainingPercent,
                weekLeft: claudeUsageModel.weekAllModelsRemainingPercent,
                fiveHourResetText: claudeUsageModel.sessionResetText,
                weekResetText: claudeUsageModel.weekAllModelsResetText
            ))
        }
        return out
    }

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
                HUDLimitsBarContent(entries: entries, mode: mode, reduceMotion: reduceMotion)
                    .frame(height: 22)
                    .clipped()
            }
        }
    }
}

private struct HUDLimitsBarContent: View {
    let entries: [HUDLimitsProviderEntry]
    let mode: UsageDisplayMode
    let reduceMotion: Bool

    var body: some View {
        HUDLimitsMarquee(reduceMotion: reduceMotion) {
            HStack(spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 {
                        Text("|")
                            .foregroundStyle(Color.primary.opacity(0.25))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    HUDLimitsProviderText(entry: entry, mode: mode)
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
        }
    }
}

private struct HUDLimitsProviderText: View {
    let entry: HUDLimitsProviderEntry
    let mode: UsageDisplayMode
    @Environment(\.colorScheme) private var colorScheme

    private func pct(_ left: Int) -> Int { mode.numericPercent(fromLeft: left) }

    private func pctColor(_ left: Int) -> Color {
        if left <= 10 { return .red }
        if left < 30 { return Color.orange }
        return .primary
    }

    private func fiveHourResetLabel() -> String? {
        guard entry.fiveHourLeft < 30 else { return nil }
        let date = UsageResetText.resetDate(kind: "5h", source: entry.source, raw: entry.fiveHourResetText)
        return formatRelativeTimeUntil(date)
    }

    private func weekResetLabel() -> String? {
        guard entry.weekLeft < 30 else { return nil }
        let date = UsageResetText.resetDate(kind: "Wk", source: entry.source, raw: entry.weekResetText)
        return formatWeeklyReset(date)
    }

    // Matches CockpitFooterView.QuotaWidget.formatRelativeTimeUntil exactly
    private func formatRelativeTimeUntil(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let interval = max(0, date.timeIntervalSince(now))
        if interval == 0 { return nil }
        if interval < 60 { return "<1m" }
        let totalMinutes = Int(ceil(interval / 60.0))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours <= 0 { return "\(minutes)m" }
        if minutes <= 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    // Matches CockpitFooterView.QuotaWidget.formatWeeklyReset exactly
    private func formatWeeklyReset(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        if interval < 24 * 60 * 60 {
            return hudWeeklyResetFormatter.string(from: date)
        }
        return AppDateFormatting.weekdayAbbrev(date)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Provider icon — matches CockpitFooterView ProviderIcon exactly
            if entry.source == .claude {
                Image("FooterIconClaude")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                Image("FooterIconCodex")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            }

            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    HStack(spacing: 0) {
                        Text("5h: ")
                        Text("\(pct(entry.fiveHourLeft))%")
                            .foregroundStyle(pctColor(entry.fiveHourLeft))
                    }
                    if let r = fiveHourResetLabel() {
                        Text("↻ \(r)")
                    }
                }
                Text("|").foregroundStyle(Color.primary.opacity(0.25))
                HStack(spacing: 4) {
                    HStack(spacing: 0) {
                        Text("Wk: ")
                        Text("\(pct(entry.weekLeft))%")
                            .foregroundStyle(pctColor(entry.weekLeft))
                    }
                    if let r = weekResetLabel() {
                        Text("↻ \(r)")
                    }
                }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.primary)
        }
    }
}

private let hudWeeklyResetFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = .current
    f.timeZone = .autoupdatingCurrent
    f.dateFormat = "HH:mm"
    return f
}()

// MARK: - Marquee

private struct HUDLimitsMarquee<Content: View>: View {
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let speed: CGFloat = 25  // pt per second
    private let gap: CGFloat = 60    // gap before loop repeats

    private var needsScroll: Bool {
        !reduceMotion && contentWidth > 0 && containerWidth > 0 && contentWidth > containerWidth
    }
    private var loopWidth: CGFloat { contentWidth + gap }
    // Task ID — restart animation whenever dimensions or motion preference change
    private var taskID: String { "\(contentWidth)-\(containerWidth)-\(reduceMotion)" }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Render path also measures content width via background GeometryReader,
                // eliminating the need for a separate hidden copy.
                if needsScroll {
                    HStack(spacing: 0) {
                        content()
                            .background(GeometryReader { inner in
                                Color.clear.preference(key: HUDLimitsWidthKey.self,
                                                       value: inner.size.width)
                            })
                        Spacer(minLength: gap)
                        content()
                    }
                    .offset(x: offset)
                } else {
                    content()
                        .background(GeometryReader { inner in
                            Color.clear.preference(key: HUDLimitsWidthKey.self,
                                                   value: inner.size.width)
                        })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .onPreferenceChange(HUDLimitsWidthKey.self) { w in contentWidth = w }
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
        }
        .task(id: taskID) {
            // Snap to start without animation, cancelling any prior repeatForever.
            offset = 0
            guard needsScroll else { return }
            // One layout pass before kicking off the animation.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: Double(loopWidth) / Double(speed))
                .repeatForever(autoreverses: false)) {
                offset = -loopWidth
            }
        }
    }
}

private struct HUDLimitsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - HUD button style

private struct HUDIconButtonStyle: ButtonStyle {
    let isOn: Bool
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(background.opacity(configuration.isPressed ? 0.85 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.toolbarButtonCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.toolbarButtonCornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
    }

    private var foreground: Color {
        if let tint, isOn {
            return tint
        }
        return isOn ? .accentColor : .secondary
    }

    private var background: Color {
        if let tint, isOn {
            return tint.opacity(0.12)
        }
        return isOn ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04)
    }

    private var border: Color {
        if let tint, isOn {
            return tint.opacity(0.30)
        }
        return isOn ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.08)
    }
}

private enum HUDFilterPillKind {
    case all
    case active
    case idle
}

private struct HUDFilterPillStyle: ButtonStyle {
    let isOn: Bool
    let kind: HUDFilterPillKind
    @Environment(\.colorScheme) private var hudColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(background.opacity(configuration.isPressed ? 0.85 : 1.0))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(border, lineWidth: 0.5)
            )
            .opacity(isOn ? 1.0 : 0.72)
    }

    private var foreground: Color {
        guard isOn else { return .secondary }
        switch kind {
        case .all:
            return .primary
        case .active:
            return Color(hex: "30d158")
        case .idle:
            return idleColor
        }
    }

    private var background: Color {
        guard isOn else { return Color.primary.opacity(0.04) }
        switch kind {
        case .all:
            return Color.primary.opacity(0.10)
        case .active:
            return Color(hex: "30d158").opacity(0.16)
        case .idle:
            return idleColor.opacity(0.16)
        }
    }

    private var border: Color {
        guard isOn else { return Color.primary.opacity(0.10) }
        switch kind {
        case .all:
            return Color.primary.opacity(0.18)
        case .active:
            return Color(hex: "30d158").opacity(0.35)
        case .idle:
            return idleColor.opacity(0.35)
        }
    }

    private var idleColor: Color {
        hudColorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
    }
}

private struct HUDSearchField: View {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            HUDSearchTextField(
                text: $text,
                placeholder: placeholder,
                focusToken: focusToken
            )
            .frame(minHeight: 18)

            if !text.isEmpty {
                Text("esc")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Text("⌘K")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}

private struct HUDSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.placeholderString = placeholder
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        tf.delegate = context.coordinator
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.stringValue != text {
            tf.stringValue = text
        }
        if tf.placeholderString != placeholder {
            tf.placeholderString = placeholder
        }
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = tf.window else { return }
                window.makeFirstResponder(tf)
                tf.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HUDSearchTextField
        var lastFocusToken: Int = 0

        init(parent: HUDSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            if parent.text != tf.stringValue {
                parent.text = tf.stringValue
            }
        }
    }
}

#Preview("Agent Cockpit HUD") {
    AgentCockpitHUDView(
        codexIndexer: SessionIndexer(),
        claudeIndexer: ClaudeSessionIndexer(),
        opencodeIndexer: OpenCodeSessionIndexer()
    )
    .environmentObject(CodexActiveSessionsModel())
    .frame(width: 760, height: 420)
}

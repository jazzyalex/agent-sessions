import SwiftUI
import AppKit
import Combine

enum HUDLiveState: Equatable {
    case active
    case idle
}

enum HUDIdleReason: String, Equatable, Sendable {
    case generic      // Idle — waiting at prompt or unknown state
    case errorOrStuck // No prompt detected for >30 minutes

    var label: String {
        switch self {
        case .generic:      return "Waiting"
        case .errorOrStuck: return "Stuck"
        }
    }
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

enum HUDNavigationConfidence: Equatable {
    /// Resolved via log-path or direct session-ID match.
    case exact
    /// Resolved via runtime session-ID match.
    case runtimeID
    /// Resolved only via working-directory / cwd fallback.
    case cwdOnly
    /// No indexed session found.
    case none

    var isNavigable: Bool {
        switch self {
        case .exact, .runtimeID: return true
        case .cwdOnly, .none: return false
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
    let parentSessionID: String?
    let logPath: String?
    let workingDirectory: String?
    let lastActivityAt: Date?
    let lastActivityTooltip: String?
    let idleReason: HUDIdleReason?
    let activeSubagentCount: Int
    let navigationConfidence: HUDNavigationConfidence

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
         parentSessionID: String? = nil,
         logPath: String? = nil,
         workingDirectory: String? = nil,
         lastActivityAt: Date? = nil,
         lastActivityTooltip: String? = nil,
         idleReason: HUDIdleReason? = nil,
         activeSubagentCount: Int = 0,
         navigationConfidence: HUDNavigationConfidence = .none) {
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
        self.parentSessionID = parentSessionID
        self.logPath = logPath
        self.workingDirectory = workingDirectory
        self.lastActivityAt = lastActivityAt
        self.lastActivityTooltip = lastActivityTooltip
        self.idleReason = idleReason
        self.activeSubagentCount = activeSubagentCount
        self.navigationConfidence = navigationConfidence
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
            && lhs.parentSessionID == rhs.parentSessionID
            && lhs.logPath == rhs.logPath
            && lhs.workingDirectory == rhs.workingDirectory
            && lhs.lastActivityAt == rhs.lastActivityAt
            && lhs.elapsed == rhs.elapsed
            && lhs.lastActivityTooltip == rhs.lastActivityTooltip
            && lhs.idleReason == rhs.idleReason
            && lhs.activeSubagentCount == rhs.activeSubagentCount
            && lhs.navigationConfidence == rhs.navigationConfidence
    }
}

private enum AgentCockpitHUDTheme {
    static let cornerRadius: CGFloat = 12
    static let toolbarButtonCornerRadius: CGFloat = 7
}

enum AgentCockpitHUDDisplayMode: String, CaseIterable, Identifiable {
    case full
    case compact
    case limits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Full"
        case .compact: return "Compact"
        case .limits: return "Quota Meter"
        }
    }

    /// Compact label for the toolbar pill (full names live in the popover).
    var shortLabel: String {
        switch self {
        case .full: return "Full"
        case .compact: return "Compact"
        case .limits: return "Meter"
        }
    }

    var systemImage: String {
        switch self {
        case .full: return "rectangle.split.3x1"
        case .compact: return "rectangle.compress.vertical"
        case .limits: return "gauge.with.dots.needle.50percent"
        }
    }

    var usesCompactChrome: Bool {
        switch self {
        case .full: return false
        case .compact, .limits: return true
        }
    }

    static func initialMode(defaults: UserDefaults = .standard) -> AgentCockpitHUDDisplayMode {
        if let raw = defaults.string(forKey: PreferencesKey.Cockpit.hudDisplayMode),
           let mode = AgentCockpitHUDDisplayMode(rawValue: raw) {
            return mode
        }
        let legacyCompact = defaults.object(forKey: PreferencesKey.Cockpit.hudCompact) as? Bool ?? false
        return legacyCompact ? .compact : .full
    }

    func next() -> AgentCockpitHUDDisplayMode {
        switch self {
        case .full: return .compact
        case .compact: return .limits
        case .limits: return .full
        }
    }
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

struct LegacyMappedRow: Identifiable {
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
    let parentSessionID: String?
    let logPath: String?
    let workingDirectory: String?
    let lastActivityAt: Date?
    let idleReason: HUDIdleReason?
    let isDefinitiveMatch: Bool
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

/// Cheap per-source content fingerprint for `AgentCockpitHUDDerivedStateModel`'s
/// `$allSessions` sinks. A provider's `@Published allSessions` can refire with
/// content the HUD doesn't care about (e.g. a focused-session hydration or an
/// unrelated background-monitor write that replaces the whole array via
/// copy-on-write for a single entry) — `Equatable` on `[Session]` would catch
/// this too, but at O(n) cost including every session's `events` array, which
/// is the exact per-body cost the row-body diet exists to avoid. This
/// fingerprint compares only the stored fields that feed the HUD rows
/// snapshot — identity/order (`id`), freshness (`modifiedAt`, `eventCount`),
/// the title-determining inputs (`customTitle`, `lightweightTitle`, and
/// `events.isEmpty`, which flips `Session.title`'s computation branch on
/// lightweight→full hydration), and the projectLabel inputs
/// (`lightweightRepoName`, `lightweightCwd`, which metadata repairs like
/// `ClaudeSessionIndexer.fixupHydratedClaudeMetadataIfNeeded` rewrite while
/// id/modifiedAt/eventCount stay identical). No per-entry allocations beyond
/// the entry array itself; the optional-string members share storage with the
/// session's own values.
/// Internal (not private) so `SessionListFingerprintTests` can pin the
/// skip/bump decision semantics the sinks rely on.
struct SessionListFingerprint: Equatable {
    private let entries: [FingerprintEntry]

    private struct FingerprintEntry: Equatable {
        let id: String
        let modifiedAt: Date
        let eventCount: Int
        let eventsIsEmpty: Bool
        let customTitle: String?
        let lightweightTitle: String?
        let lightweightCwd: String?
        let lightweightRepoName: String?
    }

    init(_ sessions: [Session]) {
        entries = sessions.map {
            FingerprintEntry(
                id: $0.id,
                modifiedAt: $0.modifiedAt,
                eventCount: $0.eventCount,
                eventsIsEmpty: $0.events.isEmpty,
                customTitle: $0.customTitle,
                lightweightTitle: $0.lightweightTitle,
                lightweightCwd: $0.lightweightCwd,
                lightweightRepoName: $0.lightweightRepoName
            )
        }
    }
}

@MainActor
private final class AgentCockpitHUDDerivedStateModel: ObservableObject {
    @Published private(set) var snapshot = HUDRowsSnapshot(rows: [], activeCount: 0, idleCount: 0)
    @Published private(set) var snapshotTimestamp: Date = Date()

    private weak var activeCodex: CodexActiveSessionsModel?
    private var codexSessions: [Session]
    private var claudeSessions: [Session]
    private var opencodeSessions: [Session]
    private var codexSessionsFingerprint: SessionListFingerprint
    private var claudeSessionsFingerprint: SessionListFingerprint
    private var opencodeSessionsFingerprint: SessionListFingerprint
    private var lookupIndexes: SessionLookupIndexes
    private var presences: [CodexActivePresence] = []
    private var isCompact: Bool
    private var lastShowProbeInHUD: Bool = UserDefaults.standard.bool(forKey: PreferencesKey.Cockpit.showProbeSessionsInHUD)
    private var cancellables: Set<AnyCancellable> = []
    private var activeCancellable: AnyCancellable?
    private var subagentBadgeCancellable: AnyCancellable?
    private var rebuildScheduled: Bool = false
    private var sessionsGeneration: UInt64 = 0
    private var rebuildGate = HUDRebuildGate(staleReclassifyInterval: 5)
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
        codexSessionsFingerprint = SessionListFingerprint(codexSessions)
        claudeSessionsFingerprint = SessionListFingerprint(claudeSessions)
        opencodeSessionsFingerprint = SessionListFingerprint(opencodeSessions)
        lookupIndexes = Self.buildSessionLookupIndexes(
            codexSessions: codexSessions,
            claudeSessions: claudeSessions,
            opencodeSessions: opencodeSessions
        )
        isCompact = initialCompact

        // Each sink below skips the rebuild when the incoming array is
        // content-identical to what the HUD already has. `@Published` fires on
        // every assignment regardless of equality, and a provider's
        // `allSessions` can be reassigned (copy-on-write whole-array replace
        // for a single-session update, an unrelated background-monitor write,
        // etc.) without any content change relevant to HUD rows. Before this
        // guard, every such refire unconditionally bumped `sessionsGeneration`
        // and ran `rebuildLookupIndexes()` (O(n) over all sessions, string
        // normalization + dictionary inserts) — bypassing `HUDRebuildGate`
        // entirely, since the gate only sees `sessionsGeneration` AFTER it was
        // already bumped. This was the dominant cost behind the W7 Task 0
        // HUD-storm sample evidence (scheduleRebuild/rebuildIfReady/
        // makeRowsSnapshot ~800/5228 main-thread samples).
        codexIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                let fingerprint = SessionListFingerprint(sessions)
                guard fingerprint != codexSessionsFingerprint else { return }
                codexSessionsFingerprint = fingerprint
                codexSessions = sessions
                sessionsGeneration &+= 1
                rebuildLookupIndexes()
                scheduleRebuild()
            }
            .store(in: &cancellables)

        claudeIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                let fingerprint = SessionListFingerprint(sessions)
                guard fingerprint != claudeSessionsFingerprint else { return }
                claudeSessionsFingerprint = fingerprint
                claudeSessions = sessions
                sessionsGeneration &+= 1
                rebuildLookupIndexes()
                scheduleRebuild()
            }
            .store(in: &cancellables)

        opencodeIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                let fingerprint = SessionListFingerprint(sessions)
                guard fingerprint != opencodeSessionsFingerprint else { return }
                opencodeSessionsFingerprint = fingerprint
                opencodeSessions = sessions
                sessionsGeneration &+= 1
                rebuildLookupIndexes()
                scheduleRebuild()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let showProbes = UserDefaults.standard.bool(forKey: PreferencesKey.Cockpit.showProbeSessionsInHUD)
                if showProbes != self.lastShowProbeInHUD {
                    self.lastShowProbeInHUD = showProbes
                    self.scheduleRebuild()
                }
            }
            .store(in: &cancellables)
    }

    func bind(activeCodex: CodexActiveSessionsModel) {
        rebuildGate.forceNextRebuild()
        self.activeCodex = activeCodex
        presences = activeCodex.presences
        activeCancellable = activeCodex.presenceUpdates.sink { [weak self] presences in
            guard let self else { return }
            self.presences = presences
            scheduleRebuild()
        }
        subagentBadgeCancellable = activeCodex.badgeTicks.sink { [weak self] _ in
            self?.scheduleRebuild()
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
        lookupIndexes = Self.buildSessionLookupIndexes(
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
        let showProbes = UserDefaults.standard.bool(forKey: PreferencesKey.Cockpit.showProbeSessionsInHUD)
        // C3: rendered row titles read this preference directly (`Session.title`
        // via `PreferencesKey.Unified.skipAgentsPreamble`) -- default `true`
        // when unset, matching `Session.title`'s own default so the gate's
        // notion of "current value" agrees with what will actually render.
        let skipAgentsPreamble = UserDefaults.standard.object(forKey: PreferencesKey.Unified.skipAgentsPreamble) == nil
            ? true
            : UserDefaults.standard.bool(forKey: PreferencesKey.Unified.skipAgentsPreamble)
        let gateInputs = HUDRebuildGate.Inputs(
            membershipVersion: activeCodex.activeMembershipVersion,
            badgeVersion: activeCodex.subagentBadgeVersion,
            sessionsGeneration: sessionsGeneration,
            isCompact: isCompact,
            showProbes: showProbes,
            skipAgentsPreamble: skipAgentsPreamble
        )
        guard rebuildGate.shouldRebuild(inputs: gateInputs, now: now) else { return }
#if DEBUG
        let _hudSpan = Perf.begin("hudRebuild", thresholdMs: 4)
        defer { Perf.end(_hudSpan) }
#endif
        let activeSubagentCounts = CodexActiveSessionsModel.activeSubagentCounts(
            presences: presences,
            sessionsByLogPath: lookupIndexes.byLogPath,
            now: now
        )
        let nextSnapshot = AgentCockpitHUDView.makeRowsSnapshot(
            codexSessions: codexSessions,
            claudeSessions: claudeSessions,
            opencodeSessions: opencodeSessions,
            presences: presences,
            activeSubagentCounts: activeSubagentCounts,
            activeCodex: activeCodex,
            isCompact: isCompact,
            lookupIndexes: lookupIndexes,
            showProbePresences: showProbes,
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

    /// Moved from `AgentCockpitHUDView` (T3) -- the only real callers are this
    /// model's `init` and `rebuildLookupIndexes()`; `AgentCockpitHUDView` keeps
    /// a thin static forwarder only because `liveSessionSummary(activeCodex:
    /// codexIndexer:...)` (used by `StatusItemController`/`UsageMenuBar`,
    /// outside this model entirely) needs a lookup-index build independent of
    /// any model instance.
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
            byLogPath[logKey] = AgentCockpitHUDView.preferredSession(existing: byLogPath[logKey], incoming: session)

            for runtimeID in CodexActiveSessionsModel.liveSessionIDCandidates(for: session) {
                let sid = runtimeID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sid.isEmpty else { continue }
                let sessionKey = CodexActiveSessionsModel.sessionLookupKey(source: session.source, sessionId: sid)
                bySessionID[sessionKey] = AgentCockpitHUDView.preferredSession(existing: bySessionID[sessionKey], incoming: session)
            }

            if let cwd = AgentCockpitHUDView.normalizedWorkingDirectory(session.cwd), !cwd.isEmpty {
                let workspaceKey = AgentCockpitHUDView.workspaceLookupKey(source: session.source, normalizedPath: cwd)
                byWorkspace[workspaceKey] = AgentCockpitHUDView.preferredSession(existing: byWorkspace[workspaceKey], incoming: session)
            }
        }

        return SessionLookupIndexes(byLogPath: byLogPath, bySessionID: bySessionID, byWorkspace: byWorkspace)
    }
}

struct AgentCockpitHUDView: View {
    let codexIndexer: SessionIndexer
    let claudeIndexer: ClaudeSessionIndexer
    let opencodeIndexer: OpenCodeSessionIndexer
    @Environment(CodexActiveSessionsModel.self) var activeCodex

    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var activeEnabled: Bool = true
    @AppStorage(PreferencesKey.Cockpit.hudGroupByProject) private var groupByProject: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudDisplayMode) private var hudDisplayModeRaw: String = AgentCockpitHUDDisplayMode.initialMode().rawValue
    @AppStorage(PreferencesKey.Cockpit.hudCompact) private var legacyCompactMode: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudPinned) private var isPinned: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudCompactBaselineRows) private var compactBaselineRows: Int = 4
    @AppStorage(PreferencesKey.Cockpit.hudCompactAutoFitEnabled) private var compactAutoFitEnabled: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudShowLimits) private var showLimits: Bool = true
    @AppStorage(PreferencesKey.Cockpit.hudReduceTransparency) private var reduceTransparency: Bool = true

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    private var hudBackground: some ShapeStyle {
        if systemReduceTransparency { return AnyShapeStyle(.ultraThickMaterial) }
        if reduceTransparency { return AnyShapeStyle(.thickMaterial) }
        return AnyShapeStyle(.regularMaterial)
    }

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
    @State private var compactToolbarHideTask: Task<Void, Never>? = nil
    @State private var compactToolbarRevealTask: Task<Void, Never>? = nil
    @State private var staleAutoCollapsedProjects: Set<String> = []
    @State private var manuallyExpandedStaleProjects: Set<String> = []
    @State private var presentationState: HUDPresentationState = .empty
    @StateObject private var derivedState: AgentCockpitHUDDerivedStateModel
    @State private var limitsContentHeight: CGFloat = 30
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

    private var hudDisplayMode: AgentCockpitHUDDisplayMode {
        AgentCockpitHUDDisplayMode(rawValue: hudDisplayModeRaw) ?? (legacyCompactMode ? .compact : .full)
    }

    private var isCompact: Bool {
        hudDisplayMode.usesCompactChrome
    }

    private var isLimitsOnly: Bool {
        hudDisplayMode == .limits
    }

    private var measuredLimitsContentHeight: CGFloat {
        guard isLimitsOnly else { return 30 }
        return max(30, limitsContentHeight)
    }

    /// Natural width of the compact limits row at the active font size. Drives the
    /// limits-only window's fixed width so it hugs its content (no right-edge dead
    /// space) and resizes once when the Enlarged font is toggled.
    private var measuredLimitsContentWidth: CGFloat {
        HUDLimitsColumnLayout.compactContentWidth(enlarged: quotaMeterEnlarged)
    }

    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabledForLimits: Bool = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabledForLimits: Bool = false
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabledForLimits: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabledForLimits: Bool = true
    @AppStorage(PreferencesKey.quotaMeterRunwayVisibility) private var runwayVisibilityRaw = QuotaMeterRunwayVisibility.automatic.rawValue
    @AppStorage(PreferencesKey.quotaMeterEnlarged) private var quotaMeterEnlarged = false
    @State private var showRunwayPopover = false
    @State private var showModePopover = false

    init(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, opencodeIndexer: OpenCodeSessionIndexer) {
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.opencodeIndexer = opencodeIndexer
        _derivedState = StateObject(
            wrappedValue: AgentCockpitHUDDerivedStateModel(
                codexIndexer: codexIndexer,
                claudeIndexer: claudeIndexer,
                opencodeIndexer: opencodeIndexer,
                initialCompact: AgentCockpitHUDDisplayMode.initialMode().usesCompactChrome
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
            normalizeHUDDisplayMode()
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
            cancelCompactToolbarRevealTask()
            cancelCompactToolbarHideTask()
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
        let showsCompactToolbar = !isCompact || isCompactWindowHovered

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
            handleCompactModeChange()
            synchronizeCollapsedProjectsForStaleGroups(with: presentationState.groupedRowsForCollapseSync)
        }
        .onChange(of: hudDisplayModeRaw) { _, _ in
            normalizeHUDDisplayMode()
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
            handleCompactWindowHoverChange(hovering)
        }
        .onPreferenceChange(LimitsContentHeightKey.self) { height in
            guard height.isFinite, height > 0 else { return }
            limitsContentHeight = height
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
        .background(
            RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.cornerRadius, style: .continuous)
                .fill(hudBackground)
                .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 8)
        )
        .background(
            AgentCockpitHUDWindowConfigurator(
                isPinned: isPinned,
                shownSessionCount: displayState.shownSessionCount,
                isCompact: isCompact,
                isLimitsOnly: isLimitsOnly,
                limitsContentHeight: measuredLimitsContentHeight,
                limitsContentWidth: measuredLimitsContentWidth,
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

            if isLimitsOnly {
                HUDLimitsRowsPanel(activeRows: displayState.rowsForDisplay)
            } else {
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
            }

            if showLimits && !isLimitsOnly {
                HUDLimitsBar(activeRows: displayState.rowsForDisplay)
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

    private func handleCompactWindowHoverChange(_ hovering: Bool) {
        guard isCompact else {
            cancelCompactToolbarRevealTask()
            cancelCompactToolbarHideTask()
            if isCompactWindowHovered {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCompactWindowHovered = false
                }
            }
            return
        }

        if hovering {
            // Hover intent: require a short dwell before revealing so a quick
            // accidental pass over the pinned window does not expand it. This
            // does not depend on window focus, so it works on a pinned,
            // non-active window.
            cancelCompactToolbarHideTask()
            guard !isCompactWindowHovered, compactToolbarRevealTask == nil else { return }
            compactToolbarRevealTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCompactWindowHovered = true
                }
                compactToolbarRevealTask = nil
            }
            return
        }

        // Hover out: drop a pending dwell, then collapse promptly so the window
        // returns to its compact widget footprint.
        cancelCompactToolbarRevealTask()
        cancelCompactToolbarHideTask()
        guard isCompactWindowHovered else { return }
        compactToolbarHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isCompactWindowHovered = false
            }
            compactToolbarHideTask = nil
        }
    }

    private func handleCompactModeChange() {
        guard isCompact else {
            cancelCompactToolbarRevealTask()
            cancelCompactToolbarHideTask()
            if isCompactWindowHovered {
                isCompactWindowHovered = false
            }
            return
        }
        cancelCompactToolbarRevealTask()
        isCompactWindowHovered = false
    }

    private func cancelCompactToolbarHideTask() {
        compactToolbarHideTask?.cancel()
        compactToolbarHideTask = nil
    }

    private func cancelCompactToolbarRevealTask() {
        compactToolbarRevealTask?.cancel()
        compactToolbarRevealTask = nil
    }

    private func normalizeHUDDisplayMode() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PreferencesKey.Cockpit.hudDisplayMode) == nil {
            setHUDDisplayMode(legacyCompactMode ? .compact : .full)
            return
        }
        guard AgentCockpitHUDDisplayMode(rawValue: hudDisplayModeRaw) == nil else {
            legacyCompactMode = isCompact
            return
        }
        setHUDDisplayMode(.full)
    }

    private func setHUDDisplayMode(_ mode: AgentCockpitHUDDisplayMode) {
        hudDisplayModeRaw = mode.rawValue
        legacyCompactMode = mode.usesCompactChrome
    }

    private func cycleHUDDisplayMode() {
        setHUDDisplayMode(hudDisplayMode.next())
    }

    @ViewBuilder
    private func header(activeCount: Int, idleCount: Int) -> some View {
        VStack(spacing: isCompact ? 0 : 8) {
            HStack(spacing: 10) {
                // Quota Meter intentionally omits the active/idle session dots and
                // counters; those stay in the Full/Compact cockpit views below.
                if !isLimitsOnly {
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
                } else {
                    // Leading action balances the Quota Meter toolbar now that the
                    // active/idle counters are gone from the left side.
                    cockpitOpenButton
                }

                Spacer(minLength: 0)

                if isLimitsOnly {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            cockpitModePicker
                            if runwayControlAvailable {
                                cockpitRunwayButton
                            }
                            cockpitFontSizeButton
                            cockpitSettingsButton
                            cockpitPinButton
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        HStack(spacing: 6) {
                            cockpitModePicker
                            if runwayControlAvailable {
                                cockpitRunwayButton
                            }
                            cockpitFontSizeButton
                            cockpitPinButton
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        HStack(spacing: 6) {
                            cockpitModePicker
                            cockpitFontSizeButton
                            cockpitPinButton
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        HStack(spacing: 6) {
                            cockpitModePicker
                            cockpitPinButton
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        cockpitPinButton
                            .fixedSize(horizontal: true, vertical: false)

                        Color.clear
                            .frame(width: 0, height: 1)
                    }
                } else {
                    HStack(spacing: 6) {
                        cockpitOpenButton
                        cockpitModePicker
                        cockpitSettingsButton
                        cockpitPinButton
                    }
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

    private var cockpitOpenButton: some View {
        Button {
            AppWindowRouter.showAgentSessionsWindow()
        } label: {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(HUDIconButtonStyle(isOn: false, tint: nil))
        .help("Open Agent Sessions")
    }

    private var cockpitModePicker: some View {
        let mode = AgentCockpitHUDDisplayMode(rawValue: hudDisplayModeRaw) ?? .full
        return Button {
            showModePopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.shortLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
        }
        .buttonStyle(HUDIconButtonStyle(isOn: showModePopover, tint: nil))
        .help("Switch Agent Cockpit view: Full, Compact, or Quota Meter (⇧⌘M cycles).")
        .popover(isPresented: $showModePopover, arrowEdge: .bottom) {
            HUDCockpitModePopover(
                selectedRaw: hudDisplayModeRaw,
                onSelect: { selected in
                    showModePopover = false
                    withAnimation(.easeInOut(duration: 0.18)) {
                        setHUDDisplayMode(selected)
                    }
                }
            )
        }
    }

    private var cockpitSettingsButton: some View {
        Button {
            NotificationCenter.default.post(
                name: .showPreferencesTab,
                object: nil,
                userInfo: ["tab": PreferencesTab.agentCockpit.rawValue]
            )
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(HUDIconButtonStyle(isOn: false, tint: nil))
        .help("Open Agent Cockpit settings")
    }

    /// Quick Standard ⇄ Enlarged text-size toggle for the Quota Meter. Highlights when
    /// Enlarged so it doubles as a status indicator; one tap flips the font and the
    /// window resizes once to hug the new content width.
    private var cockpitFontSizeButton: some View {
        Button {
            quotaMeterEnlarged.toggle()
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(HUDIconButtonStyle(isOn: quotaMeterEnlarged, tint: nil))
        .help(quotaMeterEnlarged ? "Switch to Standard text size" : "Switch to Enlarged text size")
    }

    private var cockpitPinButton: some View {
        Button {
            isPinned.toggle()
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(HUDIconButtonStyle(isOn: isPinned, tint: isPinned ? .orange : nil))
        .help(isPinned ? "Unpin — stop keeping on top" : "Pin — keep above all windows")
    }

    private var runwayControlAvailable: Bool {
        codexAgentEnabledForLimits && codexUsageEnabledForLimits
    }

    private var cockpitRunwayButton: some View {
        let visibility = QuotaMeterRunwayVisibility.current(raw: runwayVisibilityRaw)
        let isForced = visibility != .automatic
        return Button {
            showRunwayPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(visibility.shortLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
        }
        .buttonStyle(HUDIconButtonStyle(isOn: isForced, tint: nil))
        .help("Runway drawer: choose when the session runway appears.")
        .popover(isPresented: $showRunwayPopover, arrowEdge: .bottom) {
            HUDRunwayVisibilityPopover(runwayVisibilityRaw: $runwayVisibilityRaw)
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
                    cycleHUDDisplayMode()
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
        .disabled(!activeEnabled || !row.navigationConfidence.isNavigable)
        .help(row.navigationConfidence.isNavigable
              ? "Select this session in the main Agent Sessions window and open its transcript."
              : "No exact session match found — only a working-directory fallback is available.")

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
        guard activeEnabled, row.navigationConfidence.isNavigable else { return }
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
        let showProbes = UserDefaults.standard.bool(forKey: PreferencesKey.Cockpit.showProbeSessionsInHUD)
        let filtered = presences.filter { presence in
            guard supportedSources.contains(presence.source) else { return false }
            if !showProbes {
                if CodexProbeConfig.isProbeWorkingDirectory(presence.workspaceRoot)
                    || ClaudeProbeConfig.isProbeWorkingDirectory(presence.workspaceRoot) {
                    return false
                }
            }
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
                                             activeSubagentCounts: [String: Int],
                                             activeCodex: CodexActiveSessionsModel,
                                             isCompact: Bool,
                                             lookupIndexes: SessionLookupIndexes,
                                             showProbePresences: Bool = false,
                                             now: Date = Date()) -> HUDRowsSnapshot {
        let supportedSources: Set<SessionSource> = [.codex, .claude, .opencode]
        let allSessions = codexSessions + claudeSessions + opencodeSessions
        // S2: shared with `CockpitView.makeLiveRowsSnapshot()`, which used to
        // carry a byte-identical copy of this direct-join key computation.
        let directJoinFallbackKeys = SessionRowsBuilder.directJoinFallbackKeys(for: allSessions) { session in
            activeCodex.presence(for: session)
        }
        let fallbackBySessionKey = SessionRowsBuilder.buildFallbackPresenceMap(
            sessions: allSessions,
            presences: presences,
            directJoinSessionKeys: directJoinFallbackKeys
        )

        var fallbackSessionByPresenceKey: [String: Session] = [:]
        fallbackSessionByPresenceKey.reserveCapacity(fallbackBySessionKey.count)

        for session in allSessions {
            let sessionKey = SessionRowsBuilder.fallbackPresenceKey(source: session.source, sessionID: session.id)
            guard let presence = fallbackBySessionKey[sessionKey] else { continue }
            let presenceKey = CodexActiveSessionsModel.presenceKey(for: presence)
            guard presenceKey != "unknown" else { continue }
            fallbackSessionByPresenceKey[presenceKey] = Self.preferredSession(
                existing: fallbackSessionByPresenceKey[presenceKey],
                incoming: session
            )
        }

        // Build per-workspace session pools so multiple presences in the same
        // directory can each resolve to a different session (sorted newest-first).
        var workspaceSessionPool: [String: [Session]] = [:]
        for session in allSessions where supportedSources.contains(session.source) {
            if let cwd = Self.normalizedWorkingDirectory(session.cwd), !cwd.isEmpty {
                let key = Self.workspaceLookupKey(source: session.source, normalizedPath: cwd)
                workspaceSessionPool[key, default: []].append(session)
            }
        }
        for key in workspaceSessionPool.keys {
            workspaceSessionPool[key]?.sort { $0.modifiedAt > $1.modifiedAt }
        }

        var claimedSessionIDs: Set<String> = []
        var mappedRows: [LegacyMappedRow] = []
        mappedRows.reserveCapacity(presences.count)
        for presence in presences {
            guard supportedSources.contains(presence.source) else { continue }
            if !showProbePresences {
                if CodexProbeConfig.isProbeWorkingDirectory(presence.workspaceRoot)
                    || ClaudeProbeConfig.isProbeWorkingDirectory(presence.workspaceRoot) {
                    continue
                }
            }
            let logNorm = presence.sessionLogPath.map(CodexActiveSessionsModel.normalizePath)
            let presenceKey = CodexActiveSessionsModel.presenceKey(for: presence)

            let resolvedByLogOrID = logNorm.flatMap { normalized in
                lookupIndexes.byLogPath[CodexActiveSessionsModel.logLookupKey(source: presence.source, normalizedPath: normalized)]
            } ?? Self.resolveBySessionID(presence.sessionId, source: presence.source, lookupIndexes: lookupIndexes)
            let isDefinitiveMatch = resolvedByLogOrID != nil
            let candidate = resolvedByLogOrID
                ?? Self.resolveByWorkspace(presence.workspaceRoot, source: presence.source, lookupIndexes: lookupIndexes)
                ?? fallbackSessionByPresenceKey[presenceKey]

            // Prevent multiple workspace-only matches from claiming the same session.
            // When the first-choice workspace match is already claimed, try to find
            // another unclaimed session in the same workspace from the pool.
            let session: Session?
            if let candidate, !isDefinitiveMatch {
                if claimedSessionIDs.contains(candidate.id) {
                    // First choice taken — find another session in the same workspace
                    if let workspace = Self.normalizedWorkingDirectory(presence.workspaceRoot), !workspace.isEmpty {
                        let poolKey = Self.workspaceLookupKey(source: presence.source, normalizedPath: workspace)
                        let alternate = workspaceSessionPool[poolKey]?.first { !claimedSessionIDs.contains($0.id) }
                        if let alternate {
                            claimedSessionIDs.insert(alternate.id)
                            session = alternate
                        } else {
                            session = nil
                        }
                    } else {
                        session = nil
                    }
                } else {
                    claimedSessionIDs.insert(candidate.id)
                    session = candidate
                }
            } else {
                session = candidate
            }

            if Self.shouldHideUnresolvedPresencePlaceholder(presence, resolvedSession: session, lookupIndexes: lookupIndexes) {
                continue
            }

            let title = session?.title
                ?? presence.sessionId.map { "Session \($0.prefix(8))" }
                ?? "Active \(presence.source.displayName) session"

            let repo = Self.projectLabel(resolvedSession: session, presence: presence)
            let date = session?.modifiedAt ?? Self.parseSessionTimestamp(from: presence)
            let lastActivityAt = activeCodex.lastActivityAt(for: presence) ?? date
            let liveState = activeCodex.liveState(for: presence)
            let idleReason = activeCodex.idleReason(for: presence)

            let stableID: String =
                "\(presence.source.rawValue)|" + (logNorm
                ?? presence.sessionId
                ?? presence.sourceFilePath
                ?? presence.pid.map { "pid:\($0)" }
                ?? presence.tty
                ?? "\(presence.sessionLogPath ?? "unknown")|\(presence.pid ?? -1)")

            mappedRows.append(LegacyMappedRow(
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
                parentSessionID: session?.parentSessionID,
                logPath: presence.sessionLogPath,
                workingDirectory: session?.cwd ?? presence.workspaceRoot,
                lastActivityAt: lastActivityAt,
                idleReason: idleReason,
                isDefinitiveMatch: isDefinitiveMatch
            ))
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
            let confidence = Self.navigationConfidence(for: row)
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
                parentSessionID: row.parentSessionID,
                logPath: row.logPath,
                workingDirectory: row.workingDirectory,
                lastActivityAt: row.lastActivityAt,
                lastActivityTooltip: activityTooltip,
                idleReason: row.idleReason,
                activeSubagentCount: row.resolvedSessionID.flatMap { activeSubagentCounts[$0] }
                    ?? row.sessionID.flatMap { activeSubagentCounts[$0] }
                    ?? 0,
                navigationConfidence: confidence
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
        .claude: ["claude", "claude code"],
        .opencode: ["opencode"]
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

    static func navigationConfidence(for row: LegacyMappedRow) -> HUDNavigationConfidence {
        guard row.resolvedSessionID != nil else { return .none }
        if row.isDefinitiveMatch { return .exact }
        if row.sessionID != nil { return .runtimeID }
        return .cwdOnly
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
        // Secondary dedup: when multiple presences (e.g., parent + subagent) resolve
        // to the same indexed session, merge them under the resolvedSessionID key.
        var byResolvedID: [String: String] = [:]

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

            // If this row resolves to an indexed session already claimed by another
            // presence key, merge into that existing row instead of creating a new one.
            if let resolvedID = row.resolvedSessionID, !resolvedID.isEmpty {
                let resolvedKey = "\(row.source.rawValue)|resolved:\(resolvedID)"
                if let existingKey = byResolvedID[resolvedKey], existingKey != key {
                    byKey[existingKey] = Self.preferredRow(existing: byKey[existingKey], incoming: row)
                    continue
                }
                byResolvedID[resolvedKey] = key
            }

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

    static func mergeMetadata(into winner: LegacyMappedRow, from loser: LegacyMappedRow) -> LegacyMappedRow {
        LegacyMappedRow(
            id: winner.id,
            source: winner.source,
            title: winner.title,
            liveState: winner.liveState,
            lastSeenAt: winner.lastSeenAt ?? loser.lastSeenAt,
            repo: winner.repo,
            date: winner.date ?? loser.date,
            focusURL: winner.focusURL ?? loser.focusURL,
            // iTerm session GUID and TTY must stay paired to the same terminal session.
            // A winner with a TTY but no GUID should use TTY-based focusing (the two-pass
            // AppleScript falls through to the TTY pass). Inheriting a GUID from the loser
            // would be wrong — that GUID belongs to a different terminal session and would
            // navigate to the wrong tab.
            itermSessionId: winner.itermSessionId ?? (winner.tty == nil ? loser.itermSessionId : nil),
            tty: winner.tty ?? loser.tty,
            termProgram: winner.termProgram ?? loser.termProgram,
            tabTitle: winner.tabTitle ?? loser.tabTitle,
            resolvedSessionID: winner.resolvedSessionID ?? loser.resolvedSessionID,
            sessionID: winner.sessionID ?? loser.sessionID,
            parentSessionID: winner.parentSessionID ?? loser.parentSessionID,
            logPath: winner.logPath ?? loser.logPath,
            workingDirectory: winner.workingDirectory ?? loser.workingDirectory,
            lastActivityAt: winner.lastActivityAt ?? loser.lastActivityAt,
            idleReason: winner.idleReason,
            isDefinitiveMatch: winner.isDefinitiveMatch || loser.isDefinitiveMatch
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

    /// Moved to `AgentCockpitHUDDerivedStateModel` (T3) -- the only real
    /// callers are that model's `init`/`rebuildLookupIndexes()`. This
    /// forwarder stays because `liveSessionSummary(activeCodex:codexIndexer:...)`
    /// below needs a lookup-index build independent of any model instance
    /// (it's also called from `StatusItemController`/`UsageMenuBar`, outside
    /// the HUD's derived-state model entirely).
    static func buildSessionLookupIndexes(codexSessions: [Session],
                                          claudeSessions: [Session],
                                          opencodeSessions: [Session] = []) -> SessionLookupIndexes {
        AgentCockpitHUDDerivedStateModel.buildSessionLookupIndexes(
            codexSessions: codexSessions,
            claudeSessions: claudeSessions,
            opencodeSessions: opencodeSessions
        )
    }

    fileprivate static func preferredSession(existing: Session?, incoming: Session) -> Session {
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

    fileprivate static func normalizedWorkingDirectory(_ raw: String?) -> String? {
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

    fileprivate static func workspaceLookupKey(source: SessionSource, normalizedPath: String) -> String {
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
    /// Whether each window has a classified limit this snapshot. A dropped window
    /// (e.g. OpenAI pausing the 5h limit) renders a calm "no limit" rather than a
    /// misleading "0%". Defaults true so Claude / other callers are unchanged.
    var hasFiveHourRateLimit: Bool = true
    var hasWeekRateLimit: Bool = true
    /// Provider sent rate-limit data we couldn't confidently interpret → the
    /// absent line reads "can't verify" instead of the calm "no limit".
    var usageFormatSuspect: Bool = false
    let isInitialLoading: Bool
    /// For Codex: the JSONL event timestamp. For Claude: the last poll time.
    let lastDataTimestamp: Date?
    let fiveHourProjectedRunoutAt: Date?
    let fiveHourProjectionObservedAt: Date?
    var fiveHourOnTrackObservedAt: Date? = nil
    /// Aggregate token throughput (tk/h) for this provider's active sessions.
    /// Shown on the 5h line when that window is dropped — an honest "burning"
    /// signal in place of a fictitious run-out. Read by every HUD limits surface
    /// (bar, rows panel, detail panel) so they stay consistent.
    var aggregateTokensPerHour: Double? = nil
    /// CLI auth status for this provider; when alarming, HUDLimitsBar swaps the
    /// meter text for an AuthRemediationBanner. Left nil by callers (e.g. the
    /// rows panel) that don't render the banner.
    var authStatus: UsageAuthStatus? = nil
    /// Shared meter state (`QuotaData.presentationState`) so every QM surface —
    /// the limits bar, the Meter-mode rows panel, and the hover detail panel —
    /// degrades exactly like the footer / menu bar: an auth-remediation cell
    /// (`.needsAction`) or a spinning "reconnecting" cell (`.reconnecting`)
    /// instead of a misleading "0% / no reset" meter.
    var presentationState: QuotaData.PresentationState = .live
}

private extension CodexRunwaySnapshot {
    var hasRunwayContent: Bool {
        !rows.isEmpty || burstSummary != nil
    }

    var runwayVisibleRowCount: Int {
        rows.count + (burstSummary == nil ? 0 : 1)
    }

    var runwayPanelRows: Int {
        if hasRunwayContent {
            return min(5, runwayVisibleRowCount)
        }
        return 1
    }
}

private func quotaMeterVisibleRunwaySnapshot(from snapshot: CodexRunwaySnapshot?,
                                             visibility: QuotaMeterRunwayVisibility) -> CodexRunwaySnapshot? {
    guard let snapshot else { return nil }
    switch visibility {
    case .automatic:
        return snapshot.hasRunwayContent ? snapshot : nil
    case .alwaysOn:
        return snapshot
    case .alwaysOff:
        return nil
    }
}

private struct LimitsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum HUDExpansionDirection {
    case up
    case down
}

private struct HUDWindowExpansionDirectionReader: NSViewRepresentable {
    let onChange: (HUDExpansionDirection) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            context.coordinator.update(from: view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        DispatchQueue.main.async { [weak nsView] in
            context.coordinator.update(from: nsView?.window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator {
        var onChange: (HUDExpansionDirection) -> Void
        private var lastDirection: HUDExpansionDirection?

        init(onChange: @escaping (HUDExpansionDirection) -> Void) {
            self.onChange = onChange
        }

        func update(from window: NSWindow?) {
            guard let window,
                  let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                emit(.up)
                return
            }
            let frame = window.frame
            let direction: HUDExpansionDirection = frame.midY >= visibleFrame.midY ? .down : .up
            emit(direction)
        }

        private func emit(_ direction: HUDExpansionDirection) {
            guard direction != lastDirection else { return }
            lastDirection = direction
            onChange(direction)
        }
    }
}

/// An isolated view that observes usage models independently so that
/// polling updates don't cause the entire AgentCockpitHUDView to re-render.
enum HUDRunwayIdentityReducer {
    static func identities(from rows: [HUDRow], source: SessionSource = .codex) -> [RunwaySessionIdentity] {
        let candidates = rows.compactMap { row -> RunwayHUDCandidate? in
            guard row.source == source, row.liveState == .active else { return nil }
            guard let logPath = row.logPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !logPath.isEmpty else {
                return nil
            }

            let parentID = row.parentSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nonEmptyParentID = parentID.flatMap { $0.isEmpty ? nil : $0 }
            let sessionID = row.resolvedSessionID
                ?? row.runtimeSessionID
                ?? row.id
            return RunwayHUDCandidate(
                sessionID: sessionID,
                parentSessionID: nonEmptyParentID,
                displayName: compactName(for: row),
                logPath: logPath
            )
        }

        let candidateBySessionID = Dictionary(
            candidates.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let parentBySessionID = Dictionary(
            candidates.compactMap { candidate -> (String, String)? in
                guard let parentSessionID = candidate.parentSessionID,
                      parentSessionID != candidate.sessionID else {
                    return nil
                }
                return (candidate.sessionID, parentSessionID)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var grouped: [String: (displayName: String, paths: Set<String>, hasRootRow: Bool)] = [:]
        var order: [String] = []

        for candidate in candidates {
            let key = rootSessionID(for: candidate, parentBySessionID: parentBySessionID)
            let display = candidateBySessionID[key]?.displayName ?? candidate.displayName
            let isParentRow = candidate.sessionID == key

            if var existing = grouped[key] {
                existing.paths.insert(candidate.logPath)
                if isParentRow && !existing.hasRootRow {
                    existing.displayName = display
                    existing.hasRootRow = true
                }
                grouped[key] = existing
            } else {
                order.append(key)
                grouped[key] = (
                    displayName: display,
                    paths: [candidate.logPath],
                    hasRootRow: candidateBySessionID[key] != nil
                )
            }
        }

        return order.compactMap { key in
            guard let group = grouped[key] else { return nil }
            return RunwaySessionIdentity(
                id: key,
                displayName: group.displayName,
                isGoal: false,
                logPaths: Array(group.paths).sorted()
            )
        }
    }

    private static func rootSessionID(for candidate: RunwayHUDCandidate,
                                      parentBySessionID: [String: String]) -> String {
        var current = candidate.parentSessionID ?? candidate.sessionID
        var seen: Set<String> = [candidate.sessionID]
        while let parent = parentBySessionID[current],
              parent != current,
              !seen.contains(parent) {
            seen.insert(current)
            current = parent
        }
        return current
    }

    private static func compactName(for row: HUDRow) -> String {
        let candidates = [
            row.displayName,
            row.cleanedTabTitle,
            row.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
        ]
        let fallback = "\(row.source.displayName) session"
        let trimmed = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !isPlaceholderTitle($0) } ?? fallback
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.count <= 28 { return trimmed }
        return String(trimmed.prefix(27)) + "…"
    }

    private static func isPlaceholderTitle(_ title: String) -> Bool {
        // Match only the synthesized fallbacks ("Active <Agent> session" /
        // "Session <id>"), not legitimate user titles that happen to start
        // with "Active" and end with "session".
        if title.hasPrefix("Session ") { return true }
        let agentNames = SessionSource.allCases.flatMap { source in
            [source.displayName, source.rawValue.capitalized]
        }
        return agentNames.contains { title == "Active \($0) session" }
    }

    private struct RunwayHUDCandidate {
        let sessionID: String
        let parentSessionID: String?
        let displayName: String
        let logPath: String
    }
}

enum HUDRunwayRequestBuilder {
    static func request(activeRows: [HUDRow],
                        projectedRunoutEnabled: Bool,
                        codexAgentEnabled: Bool,
                        codexUsageEnabled: Bool,
                        fiveHourRemainingPercent: Int,
                        fiveHourResetText: String,
                        fiveHourProjectedRunoutAt: Date?,
                        fiveHourProjectionObservedAt: Date?,
                        windowMinutes: Int = 300,
                        now: Date,
                        maxRows: Int,
                        forceVisible: Bool = false) -> CodexRunwaySnapshotRequest? {
        // The `fiveHour*` params carry the *active* limit window — the 5h window
        // when present, else the weekly window (OpenAI can drop the 5h window).
        // `windowMinutes` is that window's length (300 = 5h, 10080 = weekly) and
        // scales the m/h yardstick. Resets parse the same regardless of `kind`.
        // When the user forces the drawer on, build the request even at 0%
        // remaining so any active session still shows a real runway row.
        guard codexAgentEnabled,
              codexUsageEnabled,
              forceVisible || fiveHourRemainingPercent > 0,
              let resetAt = UsageResetText.resetDate(
                kind: "5h",
                source: .codex,
                raw: fiveHourResetText,
                now: now
              ) else {
            return nil
        }
        let freshProjectionObservedAt: Date? = {
            guard projectedRunoutEnabled,
                  let observedAt = fiveHourProjectionObservedAt,
                  now.timeIntervalSince(observedAt) <= 3 * 60 else {
                return nil
            }
            return observedAt
        }()
        // While the 5h window is dropped the runway tracks the long (weekly)
        // window, but a weekly-scaled m/h would render on a 33.6× different scale
        // than Claude's 5h "m/h" in the same view (2383 vs 32) — same label, two
        // meanings. So on the long window the runway switches UNIT to raw token
        // throughput (tk/h): window-independent, never absurd, and it auto-reverts
        // to true 5h m/h when the window returns. Run-out/projection are unused in
        // token mode. The short (5h) window keeps the fresh projection + reset
        // fallback exactly as before.
        let isLongWindow = windowMinutes >= CodexRateLimitWindowClassifier.shortLongSplitMinutes
        let observedAt = isLongWindow ? now : (freshProjectionObservedAt ?? now)
        let runoutAt: Date = isLongWindow
            ? resetAt
            : ((freshProjectionObservedAt.flatMap { _ in fiveHourProjectedRunoutAt }) ?? resetAt)
        guard resetAt > observedAt,
              runoutAt > observedAt else {
            return nil
        }

        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: Double(fiveHourRemainingPercent),
            resetAt: resetAt,
            currentRunoutAt: runoutAt,
            observedAt: observedAt,
            // Token mode needs no run-out estimate; the 5h path keeps its
            // projection-driven attribution.
            hasProjectedRunout: isLongWindow ? false : (freshProjectionObservedAt != nil),
            windowMinutes: windowMinutes,
            rateUnit: isLongWindow ? .tokensPerHour : .quotaMinutesPerHour
        )
        return CodexRunwaySnapshotRequest(
            baseline: baseline,
            identities: HUDRunwayIdentityReducer.identities(from: activeRows, source: .codex),
            now: now,
            maxRows: maxRows
        )
    }

    static func claudeRequest(activeRows: [HUDRow],
                              projectedRunoutEnabled: Bool,
                              claudeAgentEnabled: Bool,
                              claudeUsageEnabled: Bool,
                              fiveHourRemainingPercent: Int,
                              fiveHourResetText: String,
                              fiveHourProjectedRunoutAt: Date?,
                              fiveHourProjectionObservedAt: Date?,
                              now: Date,
                              maxRows: Int,
                              forceVisible: Bool = false) -> CodexRunwaySnapshotRequest? {
        guard claudeAgentEnabled,
              claudeUsageEnabled,
              forceVisible || fiveHourRemainingPercent > 0,
              let resetAt = UsageResetText.resetDate(
                kind: "5h",
                source: .claude,
                raw: fiveHourResetText,
                now: now
              ) else {
            return nil
        }
        let freshProjectionObservedAt: Date? = {
            guard projectedRunoutEnabled,
                  let observedAt = fiveHourProjectionObservedAt,
                  now.timeIntervalSince(observedAt) <= 3 * 60 else {
                return nil
            }
            return observedAt
        }()
        let observedAt = freshProjectionObservedAt ?? now
        // No fresh projection: derive run-out from average usage so far this
        // window instead of pinning to resetAt, which makes the implied
        // per-session burn rate explode as the reset approaches.
        let runoutAt = (freshProjectionObservedAt.flatMap { _ in fiveHourProjectedRunoutAt })
            ?? RunwayBaselineMath.averageBurnRunout(
                remainingPercent: Double(fiveHourRemainingPercent),
                resetAt: resetAt,
                windowLength: RunwayBaselineMath.fiveHourWindow,
                now: now)
            ?? resetAt
        guard resetAt > observedAt,
              runoutAt > observedAt else {
            return nil
        }

        let baseline = RunwayProviderBaseline(
            source: .claude,
            remainingPercent: Double(fiveHourRemainingPercent),
            resetAt: resetAt,
            currentRunoutAt: runoutAt,
            observedAt: observedAt,
            hasProjectedRunout: freshProjectionObservedAt != nil
        )
        return CodexRunwaySnapshotRequest(
            baseline: baseline,
            identities: HUDRunwayIdentityReducer.identities(from: activeRows, source: .claude),
            now: now,
            maxRows: maxRows,
            recentSessionsRoot: ClaudeRunwayRecentSessionScanner.defaultRoot()
        )
    }
}

/// One shared 5s clock for every HUD limits panel. The collapsed bar and the
/// expanded rows panel both drive their `clockNow` (and the runway refresh keyed
/// off it) from this single publisher, so they wake the main run loop together
/// on one timer source instead of two independent, phase-offset 5s timers.
private enum HUDSharedClock {
    static let fiveSecond = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
}

private struct HUDLimitsBar: View {
    let activeRows: [HUDRow]
    @EnvironmentObject private var codexUsageModel: CodexUsageModel
    @EnvironmentObject private var claudeUsageModel: ClaudeUsageModel
    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled = false
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled = true
    @AppStorage(PreferencesKey.usageDisplayMode) private var usageDisplayModeRaw = UsageDisplayMode.left.rawValue
    @AppStorage(PreferencesKey.usageLimitCockpitProjectionEnabled) private var projectedRunoutEnabled = true
    @AppStorage(PreferencesKey.quotaMeterRunwayVisibility) private var runwayVisibilityRaw = QuotaMeterRunwayVisibility.automatic.rawValue
    @State private var clockNow = Date()
    @State private var isHovering = false
    @State private var isHoveringExpandedPanel = false
    @State private var activeVariant: Int = 0
    @State private var codexRunwaySnapshot: CodexRunwaySnapshot?
    @State private var claudeRunwaySnapshot: CodexRunwaySnapshot?
    @State private var expansionDirection: HUDExpansionDirection = .up

    private var mode: UsageDisplayMode { UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left }
    private var runwayVisibility: QuotaMeterRunwayVisibility {
        QuotaMeterRunwayVisibility.current(raw: runwayVisibilityRaw)
    }

    private var autoExpandNeeded: Bool {
        activeVariant >= 3 || (activeVariant == 2 && hasActiveProjection)
    }

    private var visibleCodexRunwaySnapshot: CodexRunwaySnapshot? {
        quotaMeterVisibleRunwaySnapshot(from: codexRunwaySnapshot, visibility: runwayVisibility)
    }

    private var visibleClaudeRunwaySnapshot: CodexRunwaySnapshot? {
        quotaMeterVisibleRunwaySnapshot(from: claudeRunwaySnapshot, visibility: runwayVisibility)
    }

    private func visibleRunwaySnapshot(for source: UsageTrackingSource) -> CodexRunwaySnapshot? {
        source == .claude ? visibleClaudeRunwaySnapshot : visibleCodexRunwaySnapshot
    }

    private var hasActiveProjection: Bool {
        guard projectedRunoutEnabled else { return false }
        return entries.contains { entry in
            formatUsageProjectionLabel(
                runoutAt: entry.fiveHourProjectedRunoutAt,
                observedAt: entry.fiveHourProjectionObservedAt,
                now: clockNow
            ) != nil
        }
    }

    private var contentRefreshID: String {
        var parts: [String] = [mode.rawValue]
        parts.append(projectedRunoutEnabled ? "projection-on" : "projection-off")
        parts.append("runway-\(runwayVisibility.rawValue)")
        if codexAgentEnabled && codexUsageEnabled {
            parts.append(
                [
                    "codex",
                    String(codexUsageModel.fiveHourRemainingPercent),
                    codexUsageModel.fiveHourResetText,
                    String(codexUsageModel.weekRemainingPercent),
                    codexUsageModel.weekResetText,
                    codexUsageModel.lastEventTimestamp?.timeIntervalSinceReferenceDate.description ?? "nil",
                    codexUsageModel.lastUpdate?.timeIntervalSinceReferenceDate.description ?? "nil",
                    codexUsageModel.fiveHourProjectedRunoutAt?.timeIntervalSinceReferenceDate.description ?? "nil",
                    codexUsageModel.fiveHourProjectionObservedAt?.timeIntervalSinceReferenceDate.description ?? "nil",
                    codexUsageModel.isUpdating ? "updating" : "idle",
                    codexUsageModel.authStatus.map { String(describing: $0.state) } ?? "auth-nil"
                ].joined(separator: "|")
            )
        }
        if claudeAgentEnabled && claudeUsageEnabled {
            parts.append(
                [
                    "claude",
                    String(claudeUsageModel.sessionRemainingPercent),
                    claudeUsageModel.sessionResetText,
                    String(claudeUsageModel.weekAllModelsRemainingPercent),
                    claudeUsageModel.weekAllModelsResetText,
                    claudeUsageModel.lastUpdate?.timeIntervalSinceReferenceDate.description ?? "nil",
                    claudeUsageModel.fiveHourProjectedRunoutAt?.timeIntervalSinceReferenceDate.description ?? "nil",
                    claudeUsageModel.fiveHourProjectionObservedAt?.timeIntervalSinceReferenceDate.description ?? "nil",
                    claudeUsageModel.isUpdating ? "updating" : "idle",
                    claudeUsageModel.authStatus.map { String(describing: $0.state) } ?? "auth-nil",
                    // presentationState inputs beyond the fields above — a stale/
                    // transient flip must rebuild the bar into its reconnecting cell.
                    claudeUsageModel.dataIsStale ? "stale" : "fresh",
                    claudeUsageModel.transientReason ?? "transient-nil"
                ].joined(separator: "|")
            )
        }
        parts.append(activeRows.map {
            "\($0.id)|\($0.displayName)|\($0.parentSessionID ?? "")|\($0.logPath ?? "")"
        }.joined(separator: ","))
        parts.append(isHovering ? "hover" : "rest")
        return parts.joined(separator: "||")
    }

    private var entries: [HUDLimitsProviderEntry] {
        var out: [HUDLimitsProviderEntry] = []
        if codexAgentEnabled && codexUsageEnabled {
            out.append(HUDLimitsProviderEntry(
                source: .codex,
                fiveHourLeft: codexUsageModel.fiveHourRemainingPercent,
                weekLeft: codexUsageModel.weekRemainingPercent,
                fiveHourResetText: codexUsageModel.fiveHourResetText,
                weekResetText: codexUsageModel.weekResetText,
                hasFiveHourRateLimit: codexUsageModel.hasFiveHourRateLimit,
                hasWeekRateLimit: codexUsageModel.hasWeekRateLimit,
                usageFormatSuspect: codexUsageModel.usageFormatSuspect,
                isInitialLoading: codexUsageModel.isUpdating && codexUsageModel.lastSuccessAt == nil,
                lastDataTimestamp: codexUsageModel.lastEventTimestamp,
                fiveHourProjectedRunoutAt: codexUsageModel.fiveHourProjectedRunoutAt,
                fiveHourProjectionObservedAt: codexUsageModel.fiveHourProjectionObservedAt,
                fiveHourOnTrackObservedAt: codexUsageModel.fiveHourOnTrackObservedAt,
                aggregateTokensPerHour: visibleRunwaySnapshot(for: .codex)?.aggregateTokensPerHour,
                authStatus: codexUsageModel.authStatus,
                presentationState: QuotaData.codex(from: codexUsageModel).presentationState
            ))
        }
        if claudeAgentEnabled && claudeUsageEnabled {
            out.append(HUDLimitsProviderEntry(
                source: .claude,
                fiveHourLeft: claudeUsageModel.sessionRemainingPercent,
                weekLeft: claudeUsageModel.weekAllModelsRemainingPercent,
                fiveHourResetText: claudeUsageModel.sessionResetText,
                weekResetText: claudeUsageModel.weekAllModelsResetText,
                isInitialLoading: claudeUsageModel.isUpdating && claudeUsageModel.lastSuccessAt == nil,
                lastDataTimestamp: claudeUsageModel.lastUpdate,
                fiveHourProjectedRunoutAt: claudeUsageModel.fiveHourProjectedRunoutAt,
                fiveHourProjectionObservedAt: claudeUsageModel.fiveHourProjectionObservedAt,
                fiveHourOnTrackObservedAt: claudeUsageModel.fiveHourOnTrackObservedAt,
                aggregateTokensPerHour: visibleRunwaySnapshot(for: .claude)?.aggregateTokensPerHour,
                authStatus: claudeUsageModel.authStatus,
                presentationState: QuotaData.claude(from: claudeUsageModel).presentationState
            ))
        }
        return out
    }

    /// True when any shown provider needs auth remediation — HUDLimitsBarContent
    /// swaps that provider's meter text for the compact AuthRemediationBanner
    /// (icon + headline + command chip + Copy button), which is taller than a
    /// plain meter row.
    private var hasAlarmingAuth: Bool {
        entries.contains { entry in
            if case .needsAction = entry.presentationState { return true }
            return false
        }
    }

    /// Signed-in bar keeps its exact 22pt clipped look (unchanged). When a
    /// provider is alarming, the compact banner's content (~19pt) plus its own
    /// 4pt top/bottom padding needs ~27pt, so grow the row just enough to clear
    /// it without clipping the command chip / Copy button.
    private var barContentHeight: CGFloat { hasAlarmingAuth ? 28 : 22 }

    /// Divider rectangle (0.5pt) + bar content height — used both for the bar's
    /// own frame and to keep the expanded panel's alignment offset in sync when
    /// the bar grows for an alarming auth banner.
    private var barTotalHeight: CGFloat { barContentHeight + 0.5 }

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
                HUDLimitsBarContent(entries: entries, mode: mode, now: clockNow)
                    .id(contentRefreshID)
                    .frame(height: barContentHeight)
                    .clipped()
                    .onPreferenceChange(LimitsBarVariantKey.self) { activeVariant = $0 }
            }
            .onHover { isHovering = $0 }
            .background(
                HUDWindowExpansionDirectionReader { direction in
                    expansionDirection = direction
                }
                .allowsHitTesting(false)
            )
            .onReceive(Self.clockTimer) { clockNow = $0 }
            .onTapGesture(count: 2) {
                if codexAgentEnabled && codexUsageEnabled && !codexUsageModel.isUpdating {
                    codexUsageModel.hardProbeNow { _ in }
                }
                if claudeAgentEnabled && claudeUsageEnabled && !claudeUsageModel.isUpdating {
                    claudeUsageModel.hardProbeNowDiagnostics { _ in }
                }
            }
            .overlay(alignment: .bottom) {
                if shouldShowExpandedPanel && expansionDirection == .up {
                    expandedPanel
                        .alignmentGuide(.bottom) { d in d[.bottom] + barTotalHeight }
                }
            }
            .overlay(alignment: .top) {
                if shouldShowExpandedPanel && expansionDirection == .down {
                    expandedPanel
                        .alignmentGuide(.top) { d in d[.top] - barTotalHeight }
                }
            }
            .task(id: runwayRequestID) {
                await refreshRunwaySnapshot()
            }
        }
    }

    private static let clockTimer = HUDSharedClock.fiveSecond

    private var shouldShowExpandedPanel: Bool {
        isHovering || isHoveringExpandedPanel || autoExpandNeeded
    }

    private var expandedPanel: some View {
        HUDLimitsExpandedPanel(
            entries: entries,
            mode: mode,
            now: clockNow,
            codexRunwaySnapshot: visibleCodexRunwaySnapshot,
            claudeRunwaySnapshot: visibleClaudeRunwaySnapshot,
            forceEmptyDrawer: runwayVisibility == .alwaysOn
        )
        .id(contentRefreshID)
        .frame(maxWidth: .infinity)
        .onHover { hovering in
            isHoveringExpandedPanel = hovering
        }
        .transition(.opacity.animation(.easeIn(duration: 0.05)))
    }

    private var runwayRequestID: String {
        "\(codexRunwayRequest?.id ?? "codex-off")||\(claudeRunwayRequest?.id ?? "claude-off")"
    }

    private var codexRunwayRequest: CodexRunwaySnapshotRequest? {
        // Feed the runway the active limit window (5h when present, else weekly),
        // with its length so the m/h yardstick stays absolute. When OpenAI drops
        // the 5h window the runway keeps showing sessions burning the weekly cap.
        return Self.runwayRequest(
            activeRows: activeRows,
            projectedRunoutEnabled: projectedRunoutEnabled,
            codexAgentEnabled: codexAgentEnabled,
            codexUsageEnabled: codexUsageEnabled,
            fiveHourRemainingPercent: codexUsageModel.activeLimitRemainingPercent,
            fiveHourResetText: codexUsageModel.activeLimitResetText,
            fiveHourProjectedRunoutAt: codexUsageModel.fiveHourProjectedRunoutAt,
            fiveHourProjectionObservedAt: codexUsageModel.fiveHourProjectionObservedAt,
            windowMinutes: codexUsageModel.activeLimitWindowMinutes,
            now: clockNow,
            maxRows: 4,
            forceVisible: runwayVisibility == .alwaysOn
        )
    }

    private var claudeRunwayRequest: CodexRunwaySnapshotRequest? {
        return HUDRunwayRequestBuilder.claudeRequest(
            activeRows: activeRows,
            projectedRunoutEnabled: projectedRunoutEnabled,
            claudeAgentEnabled: claudeAgentEnabled,
            claudeUsageEnabled: claudeUsageEnabled,
            fiveHourRemainingPercent: claudeUsageModel.sessionRemainingPercent,
            fiveHourResetText: claudeUsageModel.sessionResetText,
            fiveHourProjectedRunoutAt: claudeUsageModel.fiveHourProjectedRunoutAt,
            fiveHourProjectionObservedAt: claudeUsageModel.fiveHourProjectionObservedAt,
            now: clockNow,
            maxRows: 4,
            forceVisible: runwayVisibility == .alwaysOn
        )
    }

    private func refreshRunwaySnapshot() async {
        if let request = codexRunwayRequest {
            let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)
            if !Task.isCancelled { codexRunwaySnapshot = snapshot }
        } else {
            codexRunwaySnapshot = nil
        }
        if let request = claudeRunwayRequest {
            let snapshot = await ClaudeRunwaySnapshotLoader.snapshot(for: request)
            if !Task.isCancelled { claudeRunwaySnapshot = snapshot }
        } else {
            claudeRunwaySnapshot = nil
        }
    }

    static func runwayRequest(activeRows: [HUDRow],
                              projectedRunoutEnabled: Bool,
                              codexAgentEnabled: Bool,
                              codexUsageEnabled: Bool,
                              fiveHourRemainingPercent: Int,
                              fiveHourResetText: String,
                              fiveHourProjectedRunoutAt: Date?,
                              fiveHourProjectionObservedAt: Date?,
                              windowMinutes: Int = 300,
                              now: Date,
                              maxRows: Int,
                              forceVisible: Bool = false) -> CodexRunwaySnapshotRequest? {
        HUDRunwayRequestBuilder.request(
            activeRows: activeRows,
            projectedRunoutEnabled: projectedRunoutEnabled,
            codexAgentEnabled: codexAgentEnabled,
            codexUsageEnabled: codexUsageEnabled,
            fiveHourRemainingPercent: fiveHourRemainingPercent,
            fiveHourResetText: fiveHourResetText,
            fiveHourProjectedRunoutAt: fiveHourProjectedRunoutAt,
            fiveHourProjectionObservedAt: fiveHourProjectionObservedAt,
            windowMinutes: windowMinutes,
            now: now,
            maxRows: maxRows,
            forceVisible: forceVisible
        )
    }

    static func runwayIdentities(from rows: [HUDRow]) -> [RunwaySessionIdentity] {
        HUDRunwayIdentityReducer.identities(from: rows)
    }
}

private struct HUDLimitsRowsPanel: View {
    let activeRows: [HUDRow]
    @EnvironmentObject private var codexUsageModel: CodexUsageModel
    @EnvironmentObject private var claudeUsageModel: ClaudeUsageModel
    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled = false
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled = true
    @AppStorage(PreferencesKey.usageDisplayMode) private var usageDisplayModeRaw = UsageDisplayMode.left.rawValue
    @AppStorage(PreferencesKey.usageLimitCockpitProjectionEnabled) private var projectedRunoutEnabled = true
    @AppStorage(PreferencesKey.quotaMeterRunwayVisibility) private var runwayVisibilityRaw = QuotaMeterRunwayVisibility.automatic.rawValue
    @AppStorage(PreferencesKey.quotaMeterEnlarged) private var quotaMeterEnlarged = false
    @State private var clockNow = Date()
    @State private var codexRunwaySnapshot: CodexRunwaySnapshot?
    @State private var claudeRunwaySnapshot: CodexRunwaySnapshot?
    @State private var isHovering = false

    private var mode: UsageDisplayMode { UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left }
    private var runwayVisibility: QuotaMeterRunwayVisibility {
        QuotaMeterRunwayVisibility.current(raw: runwayVisibilityRaw)
    }

    private func visibleRunwaySnapshot(for source: UsageTrackingSource) -> CodexRunwaySnapshot? {
        let snapshot = source == .claude ? claudeRunwaySnapshot : codexRunwaySnapshot
        return quotaMeterVisibleRunwaySnapshot(from: snapshot, visibility: runwayVisibility)
    }

    private var entries: [HUDLimitsProviderEntry] {
        var out: [HUDLimitsProviderEntry] = []
        if codexAgentEnabled && codexUsageEnabled {
            out.append(HUDLimitsProviderEntry(
                source: .codex,
                fiveHourLeft: codexUsageModel.fiveHourRemainingPercent,
                weekLeft: codexUsageModel.weekRemainingPercent,
                fiveHourResetText: codexUsageModel.fiveHourResetText,
                weekResetText: codexUsageModel.weekResetText,
                hasFiveHourRateLimit: codexUsageModel.hasFiveHourRateLimit,
                hasWeekRateLimit: codexUsageModel.hasWeekRateLimit,
                usageFormatSuspect: codexUsageModel.usageFormatSuspect,
                isInitialLoading: codexUsageModel.isUpdating && codexUsageModel.lastSuccessAt == nil,
                lastDataTimestamp: codexUsageModel.lastEventTimestamp,
                fiveHourProjectedRunoutAt: codexUsageModel.fiveHourProjectedRunoutAt,
                fiveHourProjectionObservedAt: codexUsageModel.fiveHourProjectionObservedAt,
                fiveHourOnTrackObservedAt: codexUsageModel.fiveHourOnTrackObservedAt,
                aggregateTokensPerHour: visibleRunwaySnapshot(for: .codex)?.aggregateTokensPerHour,
                authStatus: codexUsageModel.authStatus,
                presentationState: QuotaData.codex(from: codexUsageModel).presentationState
            ))
        }
        if claudeAgentEnabled && claudeUsageEnabled {
            out.append(HUDLimitsProviderEntry(
                source: .claude,
                fiveHourLeft: claudeUsageModel.sessionRemainingPercent,
                weekLeft: claudeUsageModel.weekAllModelsRemainingPercent,
                fiveHourResetText: claudeUsageModel.sessionResetText,
                weekResetText: claudeUsageModel.weekAllModelsResetText,
                isInitialLoading: claudeUsageModel.isUpdating && claudeUsageModel.lastSuccessAt == nil,
                lastDataTimestamp: claudeUsageModel.lastUpdate,
                fiveHourProjectedRunoutAt: claudeUsageModel.fiveHourProjectedRunoutAt,
                fiveHourProjectionObservedAt: claudeUsageModel.fiveHourProjectionObservedAt,
                fiveHourOnTrackObservedAt: claudeUsageModel.fiveHourOnTrackObservedAt,
                aggregateTokensPerHour: visibleRunwaySnapshot(for: .claude)?.aggregateTokensPerHour,
                authStatus: claudeUsageModel.authStatus,
                presentationState: QuotaData.claude(from: claudeUsageModel).presentationState
            ))
        }
        return out
    }

    private var shouldReserveFiveHourProjectionSlot: Bool {
        guard projectedRunoutEnabled else { return false }
        return entries.contains { entry in
            formatUsageProjectionLabel(
                runoutAt: entry.fiveHourProjectedRunoutAt,
                observedAt: entry.fiveHourProjectionObservedAt,
                now: clockNow
            ) != nil
        }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyRow
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if index > 0 {
                            // Group separation: whitespace does the grouping, with a
                            // stronger full-bleed rule on top. This is deliberately
                            // heavier than the faint inset rule inside an agent block
                            // (provider row ↔ its own runway).
                            Color.clear.frame(height: 7)
                            Rectangle()
                                .fill(Color.primary.opacity(0.18))
                                .frame(height: 1)
                        }
                        row(entry: entry)
                        if entry.source == .codex,
                           isHovering,
                           let creditsLine = CodexResetCredits.quotaMeterLine(codexUsageModel.resetCredits, now: clockNow) {
                            HStack(spacing: 0) {
                                Text(creditsLine)
                                    .font(.system(size: QuotaMeterTextMetrics.providerFontSize(enlarged: quotaMeterEnlarged), weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 1)
                            .transition(.opacity)
                        }
                        runwayBlock(for: entry.source)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: LimitsContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onHover { isHovering = $0 }
        .onReceive(Self.clockTimer) { clockNow = $0 }
        .onTapGesture(count: 2) {
            if codexAgentEnabled && codexUsageEnabled && !codexUsageModel.isUpdating {
                codexUsageModel.hardProbeNow { _ in }
            }
            if claudeAgentEnabled && claudeUsageEnabled && !claudeUsageModel.isUpdating {
                claudeUsageModel.hardProbeNowDiagnostics { _ in }
            }
        }
        .task(id: runwayRequestID) {
            await refreshRunwaySnapshot()
        }
    }

    @ViewBuilder
    private func row(entry: HUDLimitsProviderEntry) -> some View {
        HStack(spacing: 0) {
            // Same shared-state degradation as the footer / menu bar / limits bar:
            // never render a misleading "0% / no reset" meter for a provider whose
            // data isn't trustworthy.
            switch entry.presentationState {
            case .needsAction(let auth):
                // Chip variant: "Claude auth expired · claude auth login [Copy]" —
                // matches the footer's FooterAuthCell language and fits the QM's
                // content-hugging width (the full headline banner would clip).
                HUDLimitsAuthCell(source: entry.source, status: auth, chip: true)
            case .idle(let auth):
                HUDLimitsIdleCell(source: entry.source, detail: auth.detail, enlarged: quotaMeterEnlarged)
            case .reconnecting:
                HUDLimitsRetryCell(source: entry.source, enlarged: quotaMeterEnlarged)
            case .live:
                HUDLimitsProviderText(
                    entry: entry,
                    mode: mode,
                    showResets: true,
                    onlyBottleneck: false,
                    showProjection: true,
                    alignColumns: entries.count > 1,
                    reserveProjectionSlot: shouldReserveFiveHourProjectionSlot,
                    enlarged: quotaMeterEnlarged,
                    now: clockNow
                )
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: QuotaMeterTextMetrics.providerRowHeight(enlarged: quotaMeterEnlarged))
    }

    @ViewBuilder
    private func runwayBlock(for source: UsageTrackingSource) -> some View {
        // The runway panels draw their own faint top rule (the within-agent
        // QM ↔ runway separator), so no extra divider is added here.
        if let snapshot = visibleRunwaySnapshot(for: source) {
            HUDRunwayPanel(snapshot: snapshot, now: clockNow, agentLabel: source == .claude ? "Claude" : "Codex")
        } else if runwayVisibility == .alwaysOn {
            HUDRunwayEmptyPanel(agentLabel: source == .claude ? "Claude" : "Codex")
        }
    }

    private static let clockTimer = HUDSharedClock.fiveSecond

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Usage tracking is off")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var runwayRequestID: String {
        "\(codexRunwayRequest?.id ?? "codex-off")||\(claudeRunwayRequest?.id ?? "claude-off")"
    }

    private var codexRunwayRequest: CodexRunwaySnapshotRequest? {
        // Feed the active limit window (5h when present, else weekly) — using
        // fiveHourRemainingPercent here fails the `> 0` guard once the 5h window
        // is dropped, which killed the runway entirely.
        return HUDLimitsBar.runwayRequest(
            activeRows: activeRows,
            projectedRunoutEnabled: projectedRunoutEnabled,
            codexAgentEnabled: codexAgentEnabled,
            codexUsageEnabled: codexUsageEnabled,
            fiveHourRemainingPercent: codexUsageModel.activeLimitRemainingPercent,
            fiveHourResetText: codexUsageModel.activeLimitResetText,
            fiveHourProjectedRunoutAt: codexUsageModel.fiveHourProjectedRunoutAt,
            fiveHourProjectionObservedAt: codexUsageModel.fiveHourProjectionObservedAt,
            windowMinutes: codexUsageModel.activeLimitWindowMinutes,
            now: clockNow,
            maxRows: 4,
            forceVisible: runwayVisibility == .alwaysOn
        )
    }

    private var claudeRunwayRequest: CodexRunwaySnapshotRequest? {
        return HUDRunwayRequestBuilder.claudeRequest(
            activeRows: activeRows,
            projectedRunoutEnabled: projectedRunoutEnabled,
            claudeAgentEnabled: claudeAgentEnabled,
            claudeUsageEnabled: claudeUsageEnabled,
            fiveHourRemainingPercent: claudeUsageModel.sessionRemainingPercent,
            fiveHourResetText: claudeUsageModel.sessionResetText,
            fiveHourProjectedRunoutAt: claudeUsageModel.fiveHourProjectedRunoutAt,
            fiveHourProjectionObservedAt: claudeUsageModel.fiveHourProjectionObservedAt,
            now: clockNow,
            maxRows: 4,
            forceVisible: runwayVisibility == .alwaysOn
        )
    }

    private func refreshRunwaySnapshot() async {
        if let request = codexRunwayRequest {
            let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)
            if !Task.isCancelled { codexRunwaySnapshot = snapshot }
        } else {
            codexRunwaySnapshot = nil
        }
        if let request = claudeRunwayRequest {
            let snapshot = await ClaudeRunwaySnapshotLoader.snapshot(for: request)
            if !Task.isCancelled { claudeRunwaySnapshot = snapshot }
        } else {
            claudeRunwaySnapshot = nil
        }
    }
}

private struct HUDLimitsExpandedPanel: View {
    let entries: [HUDLimitsProviderEntry]
    let mode: UsageDisplayMode
    let now: Date
    let codexRunwaySnapshot: CodexRunwaySnapshot?
    let claudeRunwaySnapshot: CodexRunwaySnapshot?
    var forceEmptyDrawer: Bool = false

    var body: some View {
        HUDLimitsDetailPanel(
            entries: entries,
            mode: mode,
            now: now,
            codexRunwaySnapshot: codexRunwaySnapshot,
            claudeRunwaySnapshot: claudeRunwaySnapshot,
            forceEmptyDrawer: forceEmptyDrawer
        )
    }
}

private struct HUDRunwayVisibilityPopover: View {
    @Binding var runwayVisibilityRaw: String

    private var selection: QuotaMeterRunwayVisibility {
        QuotaMeterRunwayVisibility.current(raw: runwayVisibilityRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runway drawer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)

            Picker("", selection: Binding(
                get: { runwayVisibilityRaw },
                set: { runwayVisibilityRaw = $0 }
            )) {
                ForEach(QuotaMeterRunwayVisibility.allCases) { visibility in
                    Text(visibility.shortLabel).tag(visibility.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(selection.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 236)
    }
}

private struct HUDCockpitModePopover: View {
    let selectedRaw: String
    let onSelect: (AgentCockpitHUDDisplayMode) -> Void

    private var selection: AgentCockpitHUDDisplayMode {
        AgentCockpitHUDDisplayMode(rawValue: selectedRaw) ?? .full
    }

    // Mirrors HUDRunwayVisibilityPopover's layout exactly: one segmented
    // picker instead of a row list, so a single click selects the mode.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cockpit view")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)

            Picker("", selection: Binding(
                get: { selection },
                set: { onSelect($0) }
            )) {
                ForEach(AgentCockpitHUDDisplayMode.allCases) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("⇧⌘M cycles Full → Compact → Meter while the cockpit is focused.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 236)
    }
}

private struct HUDLimitsDetailPanel: View {
    let entries: [HUDLimitsProviderEntry]
    let mode: UsageDisplayMode
    let now: Date
    var codexRunwaySnapshot: CodexRunwaySnapshot? = nil
    var claudeRunwaySnapshot: CodexRunwaySnapshot? = nil
    var forceEmptyDrawer: Bool = false
    @EnvironmentObject private var codexUsageModel: CodexUsageModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PreferencesKey.usageLimitCockpitProjectionEnabled) private var projectedRunoutEnabled = true

    private var shouldReserveFiveHourProjectionSlot: Bool {
        guard projectedRunoutEnabled else { return false }
        return entries.contains { entry in
            formatUsageProjectionLabel(
                runoutAt: entry.fiveHourProjectedRunoutAt,
                observedAt: entry.fiveHourProjectionObservedAt,
                now: now
            ) != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(maxWidth: .infinity)
                        .frame(height: 0.5)
                        .padding(.horizontal, 10)
                }
                // Same shared-state degradation as the footer / menu bar / limits
                // bar: an untrustworthy provider shows the remediation chip or the
                // reconnecting cell instead of a misleading "0% / --" detail row.
                switch entry.presentationState {
                case .needsAction(let auth):
                    HStack(spacing: 0) {
                        HUDLimitsAuthCell(source: entry.source, status: auth, chip: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 22)
                case .idle(let auth):
                    HStack(spacing: 0) {
                        HUDLimitsIdleCell(source: entry.source, detail: auth.detail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 22)
                case .reconnecting:
                    HStack(spacing: 0) {
                        HUDLimitsRetryCell(source: entry.source)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 22)
                case .live:
                    // Grid keeps the "5h:" / "Wk:" columns aligned within a provider row.
                    Grid(alignment: .leading, horizontalSpacing: HUDLimitsColumnLayout.detailGridSpacing, verticalSpacing: 0) {
                        detailRow(entry: entry, reserveProjectionSlot: shouldReserveFiveHourProjectionSlot)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                }
                if entry.source == .codex,
                   let creditsLine = CodexResetCredits.quotaMeterLine(codexUsageModel.resetCredits, now: now) {
                    HStack(spacing: 0) {
                        Text(creditsLine)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 1)
                }
                runwayBlock(for: entry.source)
            }
        }
        .background(.regularMaterial)
        .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: -3)
    }

    @ViewBuilder
    private func runwayBlock(for source: UsageTrackingSource) -> some View {
        let snapshot = source == .claude ? claudeRunwaySnapshot : codexRunwaySnapshot
        if let snapshot {
            HUDRunwayPanel(snapshot: snapshot, now: now, agentLabel: source == .claude ? "Claude" : "Codex")
        } else if forceEmptyDrawer {
            HUDRunwayEmptyPanel(agentLabel: source == .claude ? "Claude" : "Codex")
        }
    }

    @ViewBuilder
    private func detailRow(entry: HUDLimitsProviderEntry, reserveProjectionSlot: Bool) -> some View {
        // Three distinct states per window: present (percent + reset), a dropped
        // window → calm "no limit" (or "can't verify" when the format is suspect),
        // and a present-but-stale reset → the existing "--"/unavailable copy.
        let suspect = entry.usageFormatSuspect
        let fiveAbsent = !entry.hasFiveHourRateLimit
        let weekAbsent = !entry.hasWeekRateLimit
        let fiveStale = !fiveAbsent && isResetInfoUnavailable(raw: entry.fiveHourResetText)
        let weekStale = !weekAbsent && isResetInfoUnavailable(raw: entry.weekResetText)
        let projection = projectedRunoutEnabled
            ? formatUsageProjectionLabel(
                runoutAt: entry.fiveHourProjectedRunoutAt,
                observedAt: entry.fiveHourProjectionObservedAt,
                now: now
            )
            : nil
        GridRow {
            Group {
                if entry.source == .claude {
                    Image("FooterIconClaude")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image("FooterIconCodex")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                }
            }
            .frame(width: 14, height: 14)
            if fiveAbsent {
                // No 5h limit, but a session may still be burning the (weekly) cap.
                // Lead with the calm "no limit", then the burn indicator — instead
                // of the confusing "— ▶2h 25m no limit". Span the three 5h columns
                // so the phrase reads cleanly without truncation.
                // No 5h limit → no run-out to project (a "▶Xh" here would be a lie).
                // Instead show honest token throughput ("30K tk/h") when a session is
                // actively burning — magnitude of burn without a fictitious deadline.
                let burnRate = entry.aggregateTokensPerHour
                let spansThree = (projection != nil || reserveProjectionSlot)
                // Pin the spanning cell to the exact width of the columns it covers
                // so the variable-width burn chip can't stretch the shared Grid
                // tracks and reflow the whole panel as burn starts/stops.
                let spanWidth = spansThree
                    ? HUDLimitsColumnLayout.detailFiveHourPercentWidth
                        + HUDLimitsColumnLayout.detailFiveHourProjectionWidth
                        + HUDLimitsColumnLayout.detailFiveHourResetWidth
                        + HUDLimitsColumnLayout.detailGridSpacing * 2
                    : HUDLimitsColumnLayout.detailFiveHourPercentWidth
                        + HUDLimitsColumnLayout.detailFiveHourResetWidth
                        + HUDLimitsColumnLayout.detailGridSpacing
                HStack(spacing: 6) {
                    Text("5h: \(UsageLimitAbsenceCopy.label(suspect: suspect))")
                        .foregroundStyle(.secondary)
                    if let burnRate, burnRate > 0 {
                        Text(formatTokenRatePerHour(burnRate))
                            .foregroundStyle(hudProjectionColor(colorScheme))
                    }
                }
                .frame(width: spanWidth, alignment: .leading)
                .gridCellColumns(spansThree ? 3 : 2)
            } else {
                HStack(spacing: 0) {
                    Text("5h: ")
                    Text(fiveStale ? "--" : "\(mode.numericPercent(fromLeft: entry.fiveHourLeft))%")
                        .foregroundStyle(fiveStale ? Color.secondary : hudPctColor(entry.fiveHourLeft))
                }
                .frame(width: HUDLimitsColumnLayout.detailFiveHourPercentWidth, alignment: .leading)
                if projection != nil || reserveProjectionSlot {
                    HUDLimitsProjectionToken(projection: projection, reserve: reserveProjectionSlot)
                        .frame(width: HUDLimitsColumnLayout.detailFiveHourProjectionWidth, alignment: .leading)
                }
                Text("↻ \(fiveResetText(entry: entry, unavailable: fiveStale))")
                    .foregroundStyle(.secondary)
                    .frame(width: HUDLimitsColumnLayout.detailFiveHourResetWidth, alignment: .leading)
            }
            Text("|")
                .foregroundStyle(Color.primary.opacity(0.25))
                .frame(width: HUDLimitsColumnLayout.detailSeparatorWidth, alignment: .center)
            HStack(spacing: 0) {
                Text("Wk: ")
                if weekAbsent {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    Text(weekStale ? "--" : "\(mode.numericPercent(fromLeft: entry.weekLeft))%")
                        .foregroundStyle(weekStale ? Color.secondary : hudPctColor(entry.weekLeft))
                }
            }
            .frame(width: HUDLimitsColumnLayout.detailWeekPercentWidth, alignment: .leading)
            Text(weekAbsent ? (suspect ? "can't verify" : "no limit") : "↻ \(weekResetText(entry: entry, unavailable: weekStale))")
                .foregroundStyle(.secondary)
                .frame(width: HUDLimitsColumnLayout.detailWeekResetWidth, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.primary)
        .frame(minHeight: 22)
        .lineLimit(1)
    }

    private func fiveResetText(entry: HUDLimitsProviderEntry, unavailable: Bool) -> String {
        if unavailable { return UsageStaleThresholds.unavailableCopy }
        return formatUsageRelativeTimeLabel(
            UsageResetText.resetDate(kind: "5h", source: entry.source, raw: entry.fiveHourResetText, now: now),
            now: now
        ) ?? "—"
    }

    private func weekResetText(entry: HUDLimitsProviderEntry, unavailable: Bool) -> String {
        if unavailable { return UsageStaleThresholds.unavailableCopy }
        return formatUsageWeeklyResetLabel(
            UsageResetText.resetDate(kind: "Wk", source: entry.source, raw: entry.weekResetText, now: now),
            now: now
        ) ?? "—"
    }
}

/// Drives the runway load-bar shimmer with a real 0.8s timer that only runs
/// while a burning row is on screen. Scheduling and invalidating a `Timer`
/// (rather than gating an always-on publisher) means an idle runway wakes the
/// main run loop zero times; the wave resumes cleanly the moment a burn returns.
private final class RunwayShimmerTicker: ObservableObject {
    @Published private(set) var tick: Int = 0
    private var timer: Timer?

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.tick = (self.tick + 1) % 1024
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    deinit { timer?.invalidate() }
}

private struct HUDRunwayPanel: View {
    let snapshot: CodexRunwaySnapshot
    let now: Date
    var agentLabel: String = "Codex"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PreferencesKey.quotaMeterEnlarged) private var quotaMeterEnlarged = false
    // The shimmer ticker runs a real 0.8s timer ONLY while a row is actively
    // burning — an empty/idle/waiting bar ignores the tick, so a static runway
    // now issues zero periodic wakeups instead of 75/min. Reduce Motion pauses it.
    @StateObject private var shimmer = RunwayShimmerTicker()

    /// A row whose load bar is actually filled and animated. Waiting/idle rows
    /// keep an empty track, so they need no shimmer.
    private var hasAnimatedBar: Bool {
        snapshot.rows.contains { $0.confidence == .direct || $0.confidence == .mixed }
            || (snapshot.burstSummary.map { $0.quotaMinutesPerHour > 0 } ?? false)
    }

    private var runwayFontSize: CGFloat { QuotaMeterTextMetrics.runwayFontSize(enlarged: quotaMeterEnlarged) }
    private var runwayRowHeight: CGFloat { QuotaMeterTextMetrics.runwayRowHeight(enlarged: quotaMeterEnlarged) }

    /// The unit every row in this snapshot reports (m/h for the 5h yardstick, or
    /// tk/h while the 5h window is dropped). Rows carry their rate in the same
    /// `quotaMinutesPerHour` field regardless; this decides how it's read.
    private var rateUnit: RunwayRateUnit { snapshot.baseline.rateUnit }

    private var maxQuotaMinutesPerHour: Double {
        let rowMax = snapshot.rows.map(\.quotaMinutesPerHour).max() ?? 0
        let summaryMax = snapshot.burstSummary?.quotaMinutesPerHour ?? 0
        return max(1, rowMax, summaryMax)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                if snapshot.hasRunwayContent {
                    ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                        runwayRow(row, index: index)
                    }
                    if let summary = snapshot.burstSummary {
                        summaryRow(summary)
                    }
                } else {
                    Text("No active \(agentLabel) burn")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(height: runwayRowHeight, alignment: .center)
                }
            }
            .font(.system(size: runwayFontSize, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(Color.primary)
        // Match the provider row's 14pt inset so the runway hangs off the same
        // left gridline instead of sitting further left than the agent icon.
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .onAppear { shimmer.setActive(hasAnimatedBar && !reduceMotion) }
        .onDisappear { shimmer.setActive(false) }
        .onChange(of: hasAnimatedBar) { _, active in shimmer.setActive(active && !reduceMotion) }
        .onChange(of: reduceMotion) { _, reduced in shimmer.setActive(hasAnimatedBar && !reduced) }
    }

    /// Burn-rate cell. A finished session shows a calm dash; everything else
    /// shows the quota-rate text — which reads "0m/h" (dim) for a session that is
    /// alive but not currently burning (e.g. awaiting a long tool/script), so it
    /// stays informative instead of spinning.
    @ViewBuilder
    private func rateCell(quota: Double, confidence: RunwayAttributionConfidence) -> some View {
        if confidence == .idle {
            // Finished its turn, winding down — calm dash.
            Text("—")
                .foregroundStyle(.secondary)
        } else {
            Text(RunwayTimeFormatting.rate(quota, unit: rateUnit, confidence: confidence))
                .foregroundStyle(quota > 0 ? hudProjectionColor(colorScheme) : .secondary)
        }
    }

    private func runwayRow(_ row: RunwayPauseImpactRow, index: Int) -> some View {
        GeometryReader { proxy in
            let titleWidth = HUDRunwayLayout.titleWidth(for: proxy.size.width, unit: rateUnit)
            HStack(spacing: HUDRunwayLayout.columnSpacing) {
                Text(sessionLabel(row))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: titleWidth, alignment: .leading)
                rateCell(quota: row.quotaMinutesPerHour, confidence: row.confidence)
                    .frame(width: HUDRunwayLayout.rateWidth(for: rateUnit), alignment: .trailing)
                HUDRunwayLoadBar(
                    quotaMinutesPerHour: row.quotaMinutesPerHour,
                    maxQuotaMinutesPerHour: maxQuotaMinutesPerHour,
                    confidence: row.confidence,
                    unit: rateUnit,
                    animationTick: shimmer.tick,
                    index: index
                )
            }
        }
        .frame(height: runwayRowHeight)
    }

    private func summaryRow(_ summary: RunwayShortBurstSummary) -> some View {
        let confidence: RunwayAttributionConfidence = summary.quotaMinutesPerHour > 0 ? .mixed : .waiting
        return GeometryReader { proxy in
            let titleWidth = HUDRunwayLayout.titleWidth(for: proxy.size.width, unit: rateUnit)
            HStack(spacing: HUDRunwayLayout.columnSpacing) {
                Text(summaryLabel(summary))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: titleWidth, alignment: .leading)
                rateCell(quota: summary.quotaMinutesPerHour, confidence: confidence)
                    .frame(width: HUDRunwayLayout.rateWidth(for: rateUnit), alignment: .trailing)
                HUDRunwayLoadBar(
                    quotaMinutesPerHour: summary.quotaMinutesPerHour,
                    maxQuotaMinutesPerHour: maxQuotaMinutesPerHour,
                    confidence: confidence,
                    unit: rateUnit,
                    animationTick: shimmer.tick,
                    index: snapshot.rows.count
                )
            }
        }
        .frame(height: runwayRowHeight)
    }

    private func sessionLabel(_ row: RunwayPauseImpactRow) -> String {
        row.isGoal ? "GOAL \(row.displayName)" : row.displayName
    }

    private func summaryLabel(_ summary: RunwayShortBurstSummary) -> String {
        // Overflow rows aggregate the same "session" entities as the rows above,
        // so the noun stays "sessions" regardless of burn state (the rate cell
        // and load bar already convey whether they're actively burning).
        "+\(summary.count) sessions"
    }
}

/// Placeholder drawer shown when the runway is forced visible ("Always On")
/// but there is no burn data to display for the agent.
private struct HUDRunwayEmptyPanel: View {
    var agentLabel: String = "Codex"
    @AppStorage(PreferencesKey.quotaMeterEnlarged) private var quotaMeterEnlarged = false

    var body: some View {
        HStack(spacing: 0) {
            Text("No active \(agentLabel) burn")
                .font(.system(size: QuotaMeterTextMetrics.runwayFontSize(enlarged: quotaMeterEnlarged), weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}

private struct HUDRunwayLoadBar: View {
    let quotaMinutesPerHour: Double
    let maxQuotaMinutesPerHour: Double
    let confidence: RunwayAttributionConfidence
    var unit: RunwayRateUnit = .quotaMinutesPerHour
    let animationTick: Int
    let index: Int
    @Environment(\.colorScheme) private var colorScheme

    private var fillFraction: CGFloat {
        guard quotaMinutesPerHour.isFinite,
              quotaMinutesPerHour >= 0,
              maxQuotaMinutesPerHour.isFinite,
              maxQuotaMinutesPerHour > 0 else {
            return 0
        }
        let relative = quotaMinutesPerHour / maxQuotaMinutesPerHour
        // The absolute-pressure term (rate/45) is a 5h-m/h yardstick constant —
        // meaningless for token throughput — so token mode fills relative-to-max
        // only. m/h keeps the pressure anchor so a lone heavy burn still fills.
        let base: Double
        switch unit {
        case .quotaMinutesPerHour:
            let absolutePressure = min(1, quotaMinutesPerHour / 45)
            base = max(0.12, (relative * 0.60) + (absolutePressure * 0.30))
        case .tokensPerHour:
            base = max(0.12, relative * 0.85)
        }
        let wave = 0.82 + 0.18 * sin(Double(animationTick + index * 3) * 0.9)
        return CGFloat(min(1, max(0.04, base * wave)))
    }

    private var fillOpacity: Double {
        switch confidence {
        case .waiting, .idle:
            return 0
        case .unsupported:
            return 0
        case .direct, .mixed:
            return 0.82
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                // Waiting (spinner) and idle ("—") rows keep an empty track —
                // the rate cell carries the cue. Only a real rate fills the bar.
                if confidence != .waiting, confidence != .idle {
                    Capsule()
                        .fill(hudProjectionColor(colorScheme).opacity(fillOpacity))
                        .frame(width: max(0, proxy.size.width * fillFraction))
                        .animation(.easeInOut(duration: 0.28), value: animationTick)
                }
            }
        }
        .frame(minWidth: 62, maxWidth: .infinity)
        .frame(height: 5)
        .accessibilityLabel(RunwayTimeFormatting.rate(quotaMinutesPerHour, unit: unit, confidence: confidence))
    }
}

private enum HUDRunwayLayout {
    static let minBarWidth: CGFloat = 62
    static let columnSpacing: CGFloat = 8
    static let rowHeight: CGFloat = 14

    /// Rate column width. "137m/h" fits 52; token rates like "56.5M tk/h" need more.
    static func rateWidth(for unit: RunwayRateUnit) -> CGFloat {
        unit == .tokensPerHour ? 74 : 52
    }

    /// Give the session title every point not needed by the fixed-width rate
    /// and the minimum bar, so names only truncate when they genuinely overflow.
    static func titleWidth(for totalWidth: CGFloat, unit: RunwayRateUnit) -> CGFloat {
        let reservedWidth = rateWidth(for: unit) + minBarWidth + (columnSpacing * 2)
        return max(64, totalWidth - reservedWidth)
    }
}

private enum RunwayTimeFormatting {
    /// Unit-aware runway rate text. The 5h yardstick reads "137m/h"; when the 5h
    /// window is dropped the runway reports raw token throughput ("412K tk/h")
    /// instead, so "m/h" never means two things across providers.
    static func rate(_ value: Double,
                     unit: RunwayRateUnit,
                     confidence: RunwayAttributionConfidence = .mixed) -> String {
        switch unit {
        case .quotaMinutesPerHour:
            return quotaRate(value, confidence: confidence)
        case .tokensPerHour:
            guard confidence != .waiting else { return "0 tk/h" }
            guard confidence != .idle else { return "idle" }
            guard value.isFinite, value >= 1 else { return "flat" }
            return formatTokenRatePerHour(value)
        }
    }

    static func quotaRate(_ minutesPerHour: Double, confidence: RunwayAttributionConfidence = .mixed) -> String {
        // Alive but not currently burning (just appeared / awaiting a long tool):
        // a calm, honest "0m/h" rather than a spinner.
        guard confidence != .waiting else { return "0m/h" }
        guard confidence != .idle else { return "idle" }
        guard minutesPerHour.isFinite, minutesPerHour >= 0.5 else { return "flat" }
        let rounded = Int(ceil(minutesPerHour))
        return "\(rounded)m/h"
    }
}

/// Reports which ViewThatFits variant the HUD limits bar chose
/// (1 = full resets + projection, 2 = full resets without projection,
///  3 = bottleneck reset, 4 = no resets, 5 = bottleneck only).
private struct LimitsBarVariantKey: PreferenceKey {
    static let defaultValue: Int = 0
    static func reduce(value: inout Int, nextValue: () -> Int) {
        let next = nextValue()
        if next != 0 { value = next }
    }
}

/// Shared percent color used by HUDLimitsDetailPanel and HUDLimitsProviderText.
private func hudPctColor(_ left: Int) -> Color {
    if left <= 10 { return .red }
    if left < 30 { return .orange }
    return .primary
}

private func hudProjectionColor(_ colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color(red: 1.0, green: 0.60, blue: 0.12)
        : Color(red: 0.82, green: 0.30, blue: 0.00)
}

/// Compact token-throughput label, e.g. "30K tk/h" / "1.2M tk/h". Used as the
/// honest "burning" indicator on a limit line that has no run-out to show.
private func formatTokenRatePerHour(_ perHour: Double) -> String {
    let magnitude: String
    if perHour >= 1_000_000 {
        magnitude = String(format: "%.1fM", perHour / 1_000_000)
    } else if perHour >= 1_000 {
        magnitude = String(format: "%.0fK", perHour / 1_000)
    } else {
        magnitude = String(format: "%.0f", perHour)
    }
    return "\(magnitude) tk/h"
}

/// Quota Meter type scale. Standard keeps the established sizes; Enlarged raises
/// every Quota Meter font by one point (provider rows and Session Runway alike),
/// preserving the runway-one-below-provider relationship, and scales the compact
/// limit columns by the same ratio so Standard stays tight while Enlarged grows the
/// columns to match the larger text. The compact window then hugs whichever width
/// results (see HUDLimitsColumnLayout.compactContentWidth).
private enum QuotaMeterTextMetrics {
    static func providerFontSize(enlarged: Bool) -> CGFloat { enlarged ? 13 : 12 }
    static func runwayFontSize(enlarged: Bool) -> CGFloat { enlarged ? 12 : 11 }
    static func providerRowHeight(enlarged: Bool) -> CGFloat { enlarged ? 32 : 30 }
    static func runwayRowHeight(enlarged: Bool) -> CGFloat { enlarged ? 15 : 14 }
    static func columnScale(enlarged: Bool) -> CGFloat { enlarged ? 13.0 / 12.0 : 1.0 }
}

private enum HUDLimitsColumnLayout {
    static let compactSpacing: CGFloat = 3
    // Base widths are sized for the Standard provider font (12pt) and scaled up for
    // Enlarged via QuotaMeterTextMetrics.columnScale, so Standard stays compact and
    // Enlarged grows ~8%. Each fits its worst-case normal content without shrinking:
    //   • 5h%/Wk%: "Wk: 89%" (≈ 52pt) → 53 (transient "100%" shaves via minimumScaleFactor)
    //   • run-out slot: " ▸4h 59m" (≈ 59pt) → 60   ·   5h reset: "↻ 4h 59m" (≈ 59pt) → 60
    //   • weekly reset: "↻ Wed 12:00 PM" (2-digit hour, ≈ 104pt) → 104
    // Long stale/unavailable reset copy still falls back to minimumScaleFactor.
    static let compactFiveHourPercentWidth: CGFloat = 53
    static let compactFiveHourProjectionWidth: CGFloat = 60
    static let compactFiveHourResetWidth: CGFloat = 60
    static let compactSeparatorWidth: CGFloat = 5
    static let compactWeekPercentWidth: CGFloat = 53
    static let compactWeekResetWidth: CGFloat = 104

    /// Natural width of the compact limits row (icon + scaled columns + padding),
    /// used to size the Quota Meter window so it hugs its content. The icon and
    /// padding are fixed; only the columns and inter-column gaps scale with the font.
    /// Chrome constants mirror HUDLimitsProviderText (14pt icon, 8pt icon→columns
    /// spacing) and the row's 14pt horizontal padding.
    static func compactContentWidth(enlarged: Bool) -> CGFloat {
        let scale = QuotaMeterTextMetrics.columnScale(enlarged: enlarged)
        let columns = compactFiveHourPercentWidth + compactFiveHourProjectionWidth
            + compactFiveHourResetWidth + compactSeparatorWidth
            + compactWeekPercentWidth + compactWeekResetWidth
        let interColumnGaps = compactSpacing * 5 // six columns → five gaps
        let chrome: CGFloat = 14 + 8 + (14 * 2)
        return (columns + interColumnGaps) * scale + chrome + 2 // +2 epsilon to avoid edge compression
    }

    static let detailFiveHourPercentWidth: CGFloat = 58
    // Parity with the compact column: fits hour-format "▸Xh Ym" (this row has no
    // minimumScaleFactor, so an undersized width clips outright).
    static let detailFiveHourProjectionWidth: CGFloat = 60
    static let detailFiveHourResetWidth: CGFloat = 60
    static let detailSeparatorWidth: CGFloat = 7
    static let detailWeekPercentWidth: CGFloat = 58
    static let detailWeekResetWidth: CGFloat = 106
    /// Inter-column spacing of the detail-panel Grid. Used both to build the Grid
    /// and to size the absent-5h cell that spans several columns (see detailRow).
    static let detailGridSpacing: CGFloat = 6
}

private struct HUDLimitsProjectionToken: View {
    let projection: String?
    var reserve: Bool = false
    /// Compact limits row: render a muted "·" centered in the slot when there is no
    /// fresh projection, so the run-out column is never blank and the width never
    /// reflows as burn starts/stops. The detail panel leaves this off (unchanged).
    var idleMarker: Bool = false
    /// When true (compact row only), the "no early run-out" state is an *earned*
    /// on-track signal — a fresh burn that fits the 5h window — so we show a
    /// smiling face instead of the idle dot, unless the quiet preference is set.
    var onTrack: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PreferencesKey.quotaMeterOnTrackGlyph) private var onTrackGlyphRaw = QuotaMeterOnTrackGlyph.smile.rawValue

    private var showsSmile: Bool {
        onTrack && QuotaMeterOnTrackGlyph.current(raw: onTrackGlyphRaw) == .smile
    }

    var body: some View {
        Group {
            if let projection {
                Text(" \(projection)")
                    .fontWeight(.bold)
                    .foregroundStyle(hudProjectionColor(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if idleMarker && showsSmile {
                HUDOnTrackSmile()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if idleMarker {
                Text("·")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if reserve {
                Text(" ▸4h 59m")
                    .fontWeight(.bold)
                    .foregroundStyle(hudProjectionColor(colorScheme))
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The "on track" smile for the compact Quota Meter run-out column. Inherits the
/// row's foreground color (white in dark mode, black in light) so it reads as a
/// quiet "all good" rather than a colored badge. Every so often it does a quick
/// playful trick — a flat spin or a turn-around — never on a constant loop, and
/// never when Reduce Motion is on.
private struct HUDOnTrackSmile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = 0.0
    @State private var flip = 0.0

    var body: some View {
        Image(systemName: "face.smiling")
            .rotationEffect(.degrees(spin))
            .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0))
            .accessibilityLabel("On track")
            .task {
                await runTricks()
            }
    }

    private func runTricks() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            let delay = 6.0 + Double.random(in: 0...11)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { break }
            if Bool.random() {
                withAnimation(.easeInOut(duration: 0.7)) { spin += 360 }
            } else {
                withAnimation(.easeInOut(duration: 0.8)) { flip += 360 }
            }
        }
    }
}

private struct HUDLimitsBarContent: View {
    let entries: [HUDLimitsProviderEntry]
    let mode: UsageDisplayMode
    let now: Date

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Variant 1: Full — both windows with reset times and projection when it fits
            entriesRow(showResets: true, onlyBottleneck: false, showProjection: true)
                .preference(key: LimitsBarVariantKey.self, value: 1)
            // Variant 1 fallback: keep reset times before spending width on projection
            entriesRow(showResets: true, onlyBottleneck: false, showProjection: false)
                .preference(key: LimitsBarVariantKey.self, value: 2)
            // Variant 2: Bottleneck with reset — keep at least the limiting reset visible
            entriesRow(showResets: true, onlyBottleneck: true, showProjection: false)
                .preference(key: LimitsBarVariantKey.self, value: 3)
            // Variant 3: No resets — both windows, percent only
            entriesRow(showResets: false, onlyBottleneck: false, showProjection: false)
                .preference(key: LimitsBarVariantKey.self, value: 4)
            // Variant 4: Bottleneck only — whichever window has fewer % left
            entriesRow(showResets: false, onlyBottleneck: true, showProjection: false)
                .preference(key: LimitsBarVariantKey.self, value: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    @ViewBuilder private func entriesRow(showResets: Bool, onlyBottleneck: Bool, showProjection: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Text("|")
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                switch entry.presentationState {
                case .needsAction(let auth):
                    // The HUD bar is a single 22pt, clipped row and the window
                    // resizes to content, so always use the compact banner here —
                    // the full (two-line) banner would overflow. Keep the provider
                    // icon so the alarming provider stays attributable.
                    HUDLimitsAuthCell(source: entry.source, status: auth)
                case .idle(let auth):
                    // Signed in, token lapsed from inactivity: calm cell — no
                    // spinner, no Fix chip; the next session refreshes it.
                    HUDLimitsIdleCell(source: entry.source, detail: auth.detail)
                case .reconnecting:
                    // Actively retrying: spinner + quiet caption, never a broken
                    // "0% / --" meter (mirrors the footer's FooterRetryChip).
                    HUDLimitsRetryCell(source: entry.source)
                case .live:
                    HUDLimitsProviderText(
                        entry: entry,
                        mode: mode,
                        showResets: showResets,
                        onlyBottleneck: onlyBottleneck,
                        showProjection: showProjection,
                        now: now
                    )
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Compact auth-remediation cell for the HUD limits surfaces: the provider icon
/// (matching HUDLimitsProviderText) followed by the AuthRemediationBanner.
/// `chip: true` renders the banner's single-pill chip variant ("Claude auth
/// expired · claude auth login [Copy]") for the width-constrained QM rows /
/// detail panel; the default compact variant keeps the limits bar unchanged.
private struct HUDLimitsAuthCell: View {
    let source: UsageTrackingSource
    let status: UsageAuthStatus
    var chip: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            HUDLimitsProviderIcon(source: source)
            AuthRemediationBanner(status: status, compact: !chip, chip: chip, embedded: true)
        }
    }
}

/// Calm "no active session" cell for the HUD limits surfaces: provider icon +
/// moon glyph + quiet caption. The idle-token sibling of HUDLimitsRetryCell —
/// no spinner (retrying alone never recovers a lapsed token) and no remediation
/// chrome (nothing is broken; the next Claude session refreshes the token).
/// The tooltip carries the full explanation.
private struct HUDLimitsIdleCell: View {
    let source: UsageTrackingSource
    var detail: String = ""
    var enlarged: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            HUDLimitsProviderIcon(source: source)
            Image(systemName: "moon.zzz")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("no active session")
                .font(.system(size: QuotaMeterTextMetrics.providerFontSize(enlarged: enlarged), weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(detail.isEmpty ? "Usage will update after the next session." : detail)
    }
}

/// Compact "reconnecting" cell for the HUD limits surfaces: provider icon +
/// spinning arrows + a quiet caption — the QM sibling of the footer's
/// FooterRetryChip, so a transiently-unavailable provider never renders a
/// misleading "0% / no reset" meter. Escalates to HUDLimitsAuthCell once the
/// auth classifier publishes an alarming verdict.
private struct HUDLimitsRetryCell: View {
    let source: UsageTrackingSource
    var enlarged: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            HUDLimitsProviderIcon(source: source)
            HUDLimitsLoadingSpinner()
            Text("reconnecting…")
                .font(.system(size: QuotaMeterTextMetrics.providerFontSize(enlarged: enlarged), weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Provider icon shared by the HUD limits cells — matches HUDLimitsProviderText's
/// icon chrome exactly (14pt, Claude full-color / Codex template).
private struct HUDLimitsProviderIcon: View {
    let source: UsageTrackingSource
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if source == .claude {
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
    }
}

private struct HUDLimitsProviderText: View {
    let entry: HUDLimitsProviderEntry
    let mode: UsageDisplayMode
    var showResets: Bool = true
    var onlyBottleneck: Bool = false
    var showProjection: Bool = true
    var alignColumns: Bool = false
    var reserveProjectionSlot: Bool = false
    var enlarged: Bool = false
    var now: Date = Date()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PreferencesKey.usageLimitCockpitProjectionEnabled) private var projectedRunoutEnabled = true

    // 5h wins ties (<=): it's the shorter window, so equally constrained favours showing the tighter limit.
    private var bottleneckIs5h: Bool {
        // A dropped window is never the bottleneck: if the 5h window is gone the
        // weekly window is; if the weekly window is gone the 5h window is.
        guard entry.hasFiveHourRateLimit else { return false }
        guard entry.hasWeekRateLimit else { return true }
        return entry.fiveHourLeft <= entry.weekLeft
    }
    // Three distinct states per window: present, a dropped window → calm "no limit"
    // ("can't verify" when suspect), and a present-but-stale reset → "--"/unavailable.
    // A dropped window is excluded from the bottleneck (see `bottleneckIs5h`).
    private var suspect: Bool { entry.usageFormatSuspect }
    private var fiveAbsent: Bool { !entry.hasFiveHourRateLimit }
    private var weekAbsent: Bool { !entry.hasWeekRateLimit }
    private var fiveStale: Bool { !fiveAbsent && isResetInfoUnavailable(raw: entry.fiveHourResetText) }
    private var weekStale: Bool { !weekAbsent && isResetInfoUnavailable(raw: entry.weekResetText) }

    private func pct(_ left: Int) -> Int { mode.numericPercent(fromLeft: left) }
    private func percentText(left: Int, absent: Bool, stale: Bool) -> String {
        if absent { return "—" }
        return stale ? "--" : "\(pct(left))%"
    }
    private func percentColor(left: Int, absent: Bool, stale: Bool) -> Color {
        (absent || stale) ? .secondary : hudPctColor(left)
    }
    private var fiveHourProjectionLabel: String? {
        guard showProjection else { return nil }
        guard projectedRunoutEnabled else { return nil }
        // No 5h limit → no run-out to project (a "▶Xh" here is a lie); the burn chip
        // takes its place instead.
        guard !fiveAbsent else { return nil }
        return formatUsageProjectionLabel(
            runoutAt: entry.fiveHourProjectedRunoutAt,
            observedAt: entry.fiveHourProjectionObservedAt,
            now: now
        )
    }

    /// Honest "burning" indicator for a dropped 5h window: token throughput, not a
    /// fictitious run-out time. Only while a session is actively burning.
    private var fiveHourBurnChip: String? {
        guard fiveAbsent, let rate = entry.aggregateTokensPerHour, rate > 0 else { return nil }
        return formatTokenRatePerHour(rate)
    }

    // A fresh measured burn that projects run-out at/after reset: working, but
    // fitting the 5h window. The tracker only sets this timestamp in that state,
    // so no early-runout check is needed here.
    private var fiveHourOnTrack: Bool {
        guard projectedRunoutEnabled else { return false }
        return usageOnTrackIsFresh(observedAt: entry.fiveHourOnTrackObservedAt, now: now)
    }

    // Reset labels carry their own "↻ " prefix so the calm absent states can
    // drop it ("no limit" / "can't verify" read wrong with a reset glyph).
    private func fiveHourResetLabel() -> String? {
        if fiveAbsent { return UsageLimitAbsenceCopy.label(suspect: suspect) }
        if isResetInfoUnavailable(raw: entry.fiveHourResetText) { return "↻ \(UsageStaleThresholds.unavailableCopy)" }
        let raw = entry.fiveHourResetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "↻ —" }
        let date = UsageResetText.resetDate(kind: "5h", source: entry.source, raw: entry.fiveHourResetText, now: now)
        if let relative = formatRelativeTimeUntil(date, now: now) { return "↻ \(relative)" }
        let fallback = UsageResetText.displayText(kind: "5h", source: entry.source, raw: entry.fiveHourResetText, now: now)
        return "↻ \(fallback.isEmpty ? "—" : fallback)"
    }

    private func weekResetLabel() -> String? {
        if weekAbsent { return UsageLimitAbsenceCopy.label(suspect: suspect) }
        if isResetInfoUnavailable(raw: entry.weekResetText) { return "↻ \(UsageStaleThresholds.unavailableCopy)" }
        let raw = entry.weekResetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "↻ —" }
        let date = UsageResetText.resetDate(kind: "Wk", source: entry.source, raw: entry.weekResetText, now: now)
        if let weekly = formatWeeklyReset(date, now: now) { return "↻ \(weekly)" }
        let fallback = UsageResetText.displayText(kind: "Wk", source: entry.source, raw: entry.weekResetText, now: now)
        return "↻ \(fallback.isEmpty ? "—" : fallback)"
    }

    // Matches CockpitFooterView.QuotaWidget.formatRelativeTimeUntil exactly
    private func formatRelativeTimeUntil(_ date: Date?, now: Date = Date()) -> String? {
        formatUsageRelativeTimeLabel(date, now: now)
    }

    // Matches CockpitFooterView.QuotaWidget.formatWeeklyReset exactly
    private func formatWeeklyReset(_ date: Date?, now: Date = Date()) -> String? {
        formatUsageWeeklyResetLabel(date, now: now)
    }

    @ViewBuilder
    private var alignedContent: some View {
        // Per-mode column widths: base sizes (Standard) scaled up for Enlarged so the
        // Standard layout stays compact. The run-out slot is always rendered (it shows
        // a muted "·" when there is no fresh projection) so the row width never reflows
        // as burn starts/stops. minimumScaleFactor (applied by the caller) remains the
        // fallback for rare over-long content (transient "100%", stale copy).
        let scale = QuotaMeterTextMetrics.columnScale(enlarged: enlarged)
        // Combined width of the three 5h columns (+ their inter-column gaps) so the
        // dropped-5h span can occupy the same footprint and keep "|" / the Wk
        // columns aligned with a normal row.
        let fiveHourRegionWidth: CGFloat = showResets
            ? HUDLimitsColumnLayout.compactFiveHourPercentWidth
                + HUDLimitsColumnLayout.compactFiveHourProjectionWidth
                + HUDLimitsColumnLayout.compactFiveHourResetWidth
                + HUDLimitsColumnLayout.compactSpacing * 2
            : HUDLimitsColumnLayout.compactFiveHourPercentWidth
                + HUDLimitsColumnLayout.compactFiveHourProjectionWidth
                + HUDLimitsColumnLayout.compactSpacing
        HStack(spacing: HUDLimitsColumnLayout.compactSpacing * scale) {
            if fiveAbsent {
                // Dropped 5h window: one spanning unit "5h: no limit  30K tk/h"
                // (state first), sized to the combined 5h region so the variable-
                // width burn chip has room instead of colliding with "no limit".
                HStack(spacing: 6 * scale) {
                    Text("5h: \(UsageLimitAbsenceCopy.label(suspect: suspect))")
                        .foregroundStyle(.secondary)
                    if let chip = fiveHourBurnChip {
                        Text(chip).foregroundStyle(hudProjectionColor(colorScheme))
                    }
                }
                .frame(width: fiveHourRegionWidth * scale, alignment: .leading)
            } else {
                HStack(spacing: 0) {
                    Text("5h: ")
                    Text(percentText(left: entry.fiveHourLeft, absent: fiveAbsent, stale: fiveStale))
                        .foregroundStyle(percentColor(left: entry.fiveHourLeft, absent: fiveAbsent, stale: fiveStale))
                }
                .frame(width: HUDLimitsColumnLayout.compactFiveHourPercentWidth * scale, alignment: .leading)

                HUDLimitsProjectionToken(projection: fiveHourProjectionLabel, idleMarker: true, onTrack: fiveHourOnTrack)
                    .frame(width: HUDLimitsColumnLayout.compactFiveHourProjectionWidth * scale, alignment: .leading)

                if showResets, let r = fiveHourResetLabel() {
                    Text(r)
                        .frame(width: HUDLimitsColumnLayout.compactFiveHourResetWidth * scale, alignment: .leading)
                }
            }

            Text("|")
                .foregroundStyle(Color.primary.opacity(0.25))
                .frame(width: HUDLimitsColumnLayout.compactSeparatorWidth * scale, alignment: .center)

            HStack(spacing: 0) {
                Text("Wk: ")
                Text(percentText(left: entry.weekLeft, absent: weekAbsent, stale: weekStale))
                    .foregroundStyle(percentColor(left: entry.weekLeft, absent: weekAbsent, stale: weekStale))
            }
            .frame(width: HUDLimitsColumnLayout.compactWeekPercentWidth * scale, alignment: .leading)

            if showResets, let r = weekResetLabel() {
                Text(r)
                    .frame(width: HUDLimitsColumnLayout.compactWeekResetWidth * scale, alignment: .leading)
            }
        }
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

            if entry.isInitialLoading {
                HUDLimitsLoadingSpinner()
                    .transition(.opacity)
            } else {
                if alignColumns && !onlyBottleneck {
                    alignedContent
                        .font(.system(size: QuotaMeterTextMetrics.providerFontSize(enlarged: enlarged), weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 6) {
                        if !onlyBottleneck || bottleneckIs5h {
                            HStack(spacing: 4) {
                                if fiveAbsent {
                                    // Dropped 5h window: state first, then the burn
                                    // chip — "5h: no limit  30K tk/h" — never the
                                    // jumbled "— 30K tk/h no limit".
                                    Text("5h: \(UsageLimitAbsenceCopy.label(suspect: suspect))")
                                        .foregroundStyle(.secondary)
                                    if let chip = fiveHourBurnChip {
                                        Text(chip)
                                            .foregroundStyle(hudProjectionColor(colorScheme))
                                    }
                                } else {
                                    HStack(spacing: 0) {
                                        Text("5h: ")
                                        Text(percentText(left: entry.fiveHourLeft, absent: fiveAbsent, stale: fiveStale))
                                            .foregroundStyle(percentColor(left: entry.fiveHourLeft, absent: fiveAbsent, stale: fiveStale))
                                        if let projection = fiveHourProjectionLabel {
                                            Text(" \(projection)")
                                                .fontWeight(.bold)
                                                .foregroundStyle(hudProjectionColor(colorScheme))
                                        }
                                    }
                                    if showResets, let r = fiveHourResetLabel() {
                                        Text(r)
                                    }
                                }
                            }
                        }
                        if !onlyBottleneck {
                            Text("|").foregroundStyle(Color.primary.opacity(0.25))
                        }
                        if !onlyBottleneck || !bottleneckIs5h {
                            HStack(spacing: 4) {
                                HStack(spacing: 0) {
                                    Text("Wk: ")
                                    Text(percentText(left: entry.weekLeft, absent: weekAbsent, stale: weekStale))
                                        .foregroundStyle(percentColor(left: entry.weekLeft, absent: weekAbsent, stale: weekStale))
                                }
                                if showResets, let r = weekResetLabel() {
                                    Text(r)
                                }
                            }
                        }
                    }
                    .font(.system(size: QuotaMeterTextMetrics.providerFontSize(enlarged: enlarged), weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeIn(duration: 0.2), value: entry.isInitialLoading)
    }
}

private struct HUDLimitsLoadingSpinner: View {
    @State private var rotate: Bool = false
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(Color.primary.opacity(0.5))
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: rotate)
            .drawingGroup()
            .onAppear { rotate = true }
    }
}

private let hudWeeklyResetFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = .current
    f.timeZone = .autoupdatingCurrent
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()

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
    .environment(CodexActiveSessionsModel())
    .frame(width: 760, height: 420)
}

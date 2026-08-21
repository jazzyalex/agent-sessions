import Foundation
import Combine
import SwiftUI
#if os(macOS)
import IOKit.ps
#endif

/// Composite snapshot of all monitored files in a source's directories.
/// Changes to ANY tracked file (not just the global latest) produce a different snapshot.
struct DirectorySignatureSnapshot: Equatable {
    let fileCount: Int
    /// Hasher uses a per-process random seed (SE-0206), so this value is only
    /// meaningful for comparisons within the same process lifetime.
    let combinedHash: Int
    let newestModifiedAt: Date?

    static let empty = DirectorySignatureSnapshot(fileCount: 0, combinedHash: 0, newestModifiedAt: nil)

    static func from(_ signatures: [(path: String, modifiedAt: Date)]) -> DirectorySignatureSnapshot {
        guard !signatures.isEmpty else { return .empty }
        var hasher = Hasher()
        for sig in signatures.sorted(by: { $0.path < $1.path }) {
            hasher.combine(sig.path)
            hasher.combine(sig.modifiedAt)
        }
        return DirectorySignatureSnapshot(
            fileCount: signatures.count,
            combinedHash: hasher.finalize(),
            newestModifiedAt: signatures.max(by: { $0.modifiedAt < $1.modifiedAt })?.modifiedAt
        )
    }
}

/// Aggregates all agent sessions into a single list with unified filters and search.
final class UnifiedSessionIndexer: ObservableObject {
    enum CoreIndexingDisplayMode: Equatable {
        case idle
        case indexing
        case syncing
    }

    struct FocusedSessionRefreshIntervals {
        let activeOnAC: TimeInterval
        let activeOnBattery: TimeInterval
        let inactiveOnAC: TimeInterval
        let inactiveOnBattery: TimeInterval
    }

    private static let defaultFocusedSessionRefreshIntervals = FocusedSessionRefreshIntervals(
        activeOnAC: 8,
        activeOnBattery: 12,
        inactiveOnAC: 20,
        inactiveOnBattery: 60
    )
    private static let focusedSessionRefreshIntervalsBySource: [SessionSource: FocusedSessionRefreshIntervals] = [
        .codex: FocusedSessionRefreshIntervals(
            activeOnAC: 4,
            activeOnBattery: 8,
            inactiveOnAC: 20,
            inactiveOnBattery: 60
        ),
        .claude: FocusedSessionRefreshIntervals(
            activeOnAC: 6,
            activeOnBattery: 10,
            inactiveOnAC: 25,
            inactiveOnBattery: 60
        )
    ]
    private struct FileSignature: Equatable {
        let path: String
        let modifiedAt: Date
    }

    private struct FocusedSessionContext: Equatable {
        let source: SessionSource
        let sessionID: String
        let filePath: String
    }

    // Internal rather than private (SPEC §3.4 visibility amendment): `SourceRuntime` lives
    // in another file and names this enum in `ProviderHandle.reloadFocusedSession`. Nothing
    // depended on the privateness — every use is still inside this file.
    enum FocusedReloadTrigger {
        case selection
        case monitor
        case manual
    }

    // MARK: - ProviderHandle (SPEC §3.4)
    //
    // The type-erased pipeline surface one source exposes. Built by that source's
    // `makeRuntime` (next to its descriptor) and carried on `SourceRuntime`.
    //
    // RETAIN-CYCLE RULE: every closure captures the concrete indexer instance and nothing
    // else — no `self`, no catalog, no view — so this indexer's `deinit` keeps running even
    // though it holds the handles.
    //
    // As of Task 7 this is the ONLY surface this indexer has onto a provider: there are no
    // concrete indexer properties left, every pipeline is an array fold over
    // `orderedSources.map { handle($0).x }`, and every former per-source switch is a
    // handle or dictionary read.
    struct ProviderHandle {
        enum SearchIdentitySnapshots {
            case notApplicable
            case provider(@MainActor () -> SearchIngestService.IdentitySnapshot?)

            var isApplicable: Bool {
                if case .provider = self { return true }
                return false
            }

            @MainActor
            func current() -> SearchIngestService.IdentitySnapshot? {
                guard case .provider(let snapshot) = self else { return nil }
                return snapshot()
            }
        }

        let allSessions: AnyPublisher<[Session], Never>
        let isIndexing: AnyPublisher<Bool, Never>
        let isProcessingTranscripts: AnyPublisher<Bool, Never>
        let filesProcessed: AnyPublisher<Int, Never>
        let totalFiles: AnyPublisher<Int, Never>
        let indexingError: AnyPublisher<String?, Never>
        let launchPhase: AnyPublisher<LaunchPhase, Never>
        let currentSessions: @MainActor () -> [Session]
        let currentIsIndexing: @MainActor () -> Bool
        let currentLaunchPhase: @MainActor () -> LaunchPhase
        let searchIdentitySnapshots: SearchIdentitySnapshots
        let refresh: @MainActor (IndexRefreshMode, IndexRefreshTrigger, IndexRefreshExecutionProfile) -> Void
        /// Maps the trigger onto this indexer's own nominal `ReloadReason` internally.
        /// NO enablement guard here — callers guard (SPEC §3.4).
        let reloadFocusedSession: @MainActor (_ sessionID: String, _ force: Bool, _ trigger: FocusedReloadTrigger) -> Void

        init(allSessions: AnyPublisher<[Session], Never>,
             isIndexing: AnyPublisher<Bool, Never>,
             isProcessingTranscripts: AnyPublisher<Bool, Never>,
             filesProcessed: AnyPublisher<Int, Never>,
             totalFiles: AnyPublisher<Int, Never>,
             indexingError: AnyPublisher<String?, Never>,
             launchPhase: AnyPublisher<LaunchPhase, Never>,
             currentSessions: @escaping @MainActor () -> [Session],
             currentIsIndexing: @escaping @MainActor () -> Bool,
             currentLaunchPhase: @escaping @MainActor () -> LaunchPhase,
             searchIdentitySnapshots: SearchIdentitySnapshots,
             refresh: @escaping @MainActor (IndexRefreshMode, IndexRefreshTrigger, IndexRefreshExecutionProfile) -> Void,
             reloadFocusedSession: @escaping @MainActor (String, Bool, FocusedReloadTrigger) -> Void) {
            self.allSessions = allSessions
            self.isIndexing = isIndexing
            self.isProcessingTranscripts = isProcessingTranscripts
            self.filesProcessed = filesProcessed
            self.totalFiles = totalFiles
            self.indexingError = indexingError
            self.launchPhase = launchPhase
            self.currentSessions = currentSessions
            self.currentIsIndexing = currentIsIndexing
            self.currentLaunchPhase = currentLaunchPhase
            self.searchIdentitySnapshots = searchIdentitySnapshots
            self.refresh = refresh
            self.reloadFocusedSession = reloadFocusedSession
        }
    }


    private actor ProviderRefreshCoordinator {
        enum RequestResult {
            case startNow
            case scheduleAfter(TimeInterval)
            case queued
        }

        private struct State {
            var inFlight: Bool = false
            var pending: Bool = false
            var lastStartedAt: Date? = nil
        }

        private let coalesceWindowSeconds: TimeInterval
        private var states: [SessionSource: State] = [:]

        init(coalesceWindowSeconds: TimeInterval) {
            self.coalesceWindowSeconds = max(0, coalesceWindowSeconds)
        }

        func request(source: SessionSource, now: Date = Date()) -> RequestResult {
            var state = states[source] ?? State()
            if state.inFlight {
                state.pending = true
                states[source] = state
                return .queued
            }

            if let last = state.lastStartedAt {
                let elapsed = now.timeIntervalSince(last)
                if elapsed < coalesceWindowSeconds {
                    let delay = max(0, coalesceWindowSeconds - elapsed)
                    state.inFlight = true
                    state.pending = false
                    state.lastStartedAt = now.addingTimeInterval(delay)
                    states[source] = state
                    return .scheduleAfter(delay)
                }
            }

            state.inFlight = true
            state.pending = false
            state.lastStartedAt = now
            states[source] = state
            return .startNow
        }

        func finish(source: SessionSource, now: Date = Date()) -> TimeInterval? {
            var state = states[source] ?? State()
            state.inFlight = false
            let shouldRunAgain = state.pending
            state.pending = false
            states[source] = state

            guard shouldRunAgain else { return nil }
            let elapsed = now.timeIntervalSince(state.lastStartedAt ?? .distantPast)
            let delay = max(0, coalesceWindowSeconds - elapsed)
            state.inFlight = true
            state.lastStartedAt = now.addingTimeInterval(delay)
            states[source] = state
            return delay
        }
    }

    // Lightweight favorites store (UserDefaults overlay)
    struct FavoritesStore {
        struct Snapshot {
            let legacyIDs: Set<String>
            let scopedKeys: Set<StarredSessionKey>

            func contains(id: String, source: SessionSource) -> Bool {
                if scopedKeys.contains(.init(source: source, id: id)) { return true }
                return legacyIDs.contains(id)
            }
        }

        init(defaults: UserDefaults = .standard) {
            store = StarredSessionsStore(defaults: defaults)
        }
        private(set) var store: StarredSessionsStore
        func contains(id: String, source: SessionSource) -> Bool { store.contains(id: id, source: source) }
        mutating func toggle(id: String, source: SessionSource) -> Bool { store.toggle(id: id, source: source) }
        func snapshot() -> Snapshot {
            Snapshot(legacyIDs: store.legacyIDs, scopedKeys: store.scopedKeys)
        }
    }

    /// Which providers were switched on at the instant an aggregation pass was assembled.
    ///
    /// Keyed by source rather than twelve named `Bool`s: the aggregation pipeline reads
    /// enablement as a dictionary now, so a thirteenth source needs no field here at all.
    /// An absent key reads as disabled, which is also what the empty snapshot means.
    struct AgentEnablementSnapshot {
        let enabled: [SessionSource: Bool]

        func isEnabled(_ source: SessionSource) -> Bool { enabled[source] ?? false }
    }

    /// One aggregation pass's inputs: every source's current session list, keyed by source
    /// (registry order is re-imposed by `mergedAggregationResult`, which walks
    /// `SessionSource.allCases`), plus the favorites overlay and the enablement snapshot.
    struct SessionAggregationWork {
        let lists: [SessionSource: [Session]]
        let favoritesSnapshot: FavoritesStore.Snapshot
        let favoritesVersion: UInt64
        let enablement: AgentEnablementSnapshot

        static let empty = SessionAggregationWork(
            lists: [:],
            favoritesSnapshot: FavoritesStore.Snapshot(legacyIDs: [], scopedKeys: []),
            favoritesVersion: 0,
            enablement: AgentEnablementSnapshot(enabled: [:])
        )
    }
    struct SessionAggregationResult {
        let sessions: [Session]
        let favoritesVersion: UInt64
    }
    struct CoreIndexingProgress: Equatable {
        let processed: Int
        let total: Int
        let activeSources: Int
        let totalSources: Int

        static let empty = CoreIndexingProgress(processed: 0, total: 0, activeSources: 0, totalSources: 0)

        var percent: Int? {
            guard total > 0 else { return nil }
            let clamped = min(max(processed, 0), total)
            return Int((Double(clamped) / Double(total)) * 100.0)
        }
    }
    struct CoreProviderSnapshot {
        let source: SessionSource
        let enabled: Bool
        let indexing: Bool
        let processed: Int
        let total: Int
    }
    @Published private(set) var allSessions: [Session] = []
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var launchState: LaunchState = .idle

    // Filters (unified)
    @Published var query: String = ""
    @Published var queryDraft: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var selectedModel: String? = nil
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    @Published var projectFilter: String? = nil
    @Published var hasCommandsOnly: Bool = UserDefaults.standard.bool(forKey: "UnifiedHasCommandsOnly") {
        didSet {
            UserDefaults.standard.set(hasCommandsOnly, forKey: "UnifiedHasCommandsOnly")
            recomputeNow()
        }
    }
    @Published var showArchivedCodexDesktopOnly: Bool = UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showArchivedCodexDesktopOnly) {
        didSet {
            UserDefaults.standard.set(showArchivedCodexDesktopOnly, forKey: PreferencesKey.Unified.showArchivedCodexDesktopOnly)
            recomputeNow()
        }
    }
    @Published var showArchivedClaudeDesktopOnly: Bool = UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showArchivedClaudeDesktopOnly) {
        didSet {
            UserDefaults.standard.set(showArchivedClaudeDesktopOnly, forKey: PreferencesKey.Unified.showArchivedClaudeDesktopOnly)
            recomputeNow()
        }
    }

    /// Read-only overlay of Claude Desktop + Cowork sidecar records, keyed by cliSessionId
    /// (== a session's codexInternalSessionIDHint for Code-tab transcripts).
    @Published private(set) var claudeArchive: [String: ClaudeDesktopSidecarRecord] = [:]

    func isArchivedClaudeDesktop(_ session: Session) -> Bool {
        guard session.source == .claude, let key = session.claudeArchiveJoinKey else { return false }
        return claudeArchive[key]?.isArchived == true
    }

    func claudeArchiveSidecarPath(for session: Session) -> String? {
        guard session.source == .claude, let key = session.claudeArchiveJoinKey else { return nil }
        return claudeArchive[key]?.sidecarPath
    }

    /// The name Claude Desktop shows for this session (sidecar `title`), if any. AS otherwise
    /// derives the list title from the first user prompt, which differs from the Desktop name.
    func claudeDesktopTitle(for session: Session) -> String? {
        guard session.source == .claude, let key = session.claudeArchiveJoinKey else { return nil }
        guard let title = claudeArchive[key]?.title, !title.isEmpty else { return nil }
        return title
    }

    var archivedClaudeSessionIDs: Set<String> {
        Set(claudeArchive.compactMap { $0.value.isArchived ? $0.key : nil })
    }

    func rebuildClaudeArchiveOverlay() {
        let records = ClaudeDesktopSessionTitles.records(roots: ClaudeDesktopSessionTitles.defaultRoots())
        if records != claudeArchive { claudeArchive = records }
    }

    func applyOptimisticClaudeArchive(_ record: ClaudeDesktopSidecarRecord, for key: String) {
        claudeArchive[key] = record
    }

    /// The source-filter state every pipeline and policy read below consults, and the one
    /// the named `include…` properties write through.
    ///
    /// The named properties stay because views bind to them (`$unified.includeCodex` etc.); this
    /// dictionary is their backing store, so `isIncluded(_:)` is a lookup rather than a
    /// twelve-arm switch and the filter pipelines fold one publisher instead of a
    /// `CombineLatest` pyramid. Complete by construction — one entry per `SessionSource`.
    @Published private(set) var includedBySource: [SessionSource: Bool] =
        Dictionary(uniqueKeysWithValues: SessionSource.allCases.map { ($0, UnifiedSessionIndexer.storedInclude($0)) })

    /// Every provider's current enabled state — the single source of truth for "which
    /// providers are on right now", mirrored out to the named `…AgentEnabled` properties
    /// that views bind to. Read by `isAgentEnabled`, `enabledAnalyticsSources()`, the
    /// enablement-sync diff, and (as `$enablementBySource`) every aggregation pipeline.
    @Published private(set) var enablementBySource: [SessionSource: Bool] =
        Dictionary(uniqueKeysWithValues: SessionSource.allCases.map { ($0, AgentEnablement.isEnabled($0)) })

    /// K2: the persisted key is the descriptor's `includeKey`, i.e. the same
    /// `PreferencesKey.Include.*` literal each property used to name inline.
    private static func storedInclude(_ source: SessionSource) -> Bool {
        let key = SessionSourceRegistry.descriptor(for: source).includeKey
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// The shared body of all named `include…` `didSet`s: persist, update the backing
    /// dictionary (which is what republishes the filter pipelines), recompute.
    private func applyInclude(_ source: SessionSource, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: SessionSourceRegistry.descriptor(for: source).includeKey)
        if includedBySource[source] != value { includedBySource[source] = value }
        recomputeNow()
    }

    // Source filters (persisted with @Published for Combine compatibility)
    @Published var includeCodex: Bool = UnifiedSessionIndexer.storedInclude(.codex) {
        didSet { applyInclude(.codex, includeCodex) }
    }
    @Published var includeClaude: Bool = UnifiedSessionIndexer.storedInclude(.claude) {
        didSet { applyInclude(.claude, includeClaude) }
    }
    @Published var includeAntigravity: Bool = UnifiedSessionIndexer.storedInclude(.antigravity) {
        didSet { applyInclude(.antigravity, includeAntigravity) }
    }
    @Published var includeOpenCode: Bool = UnifiedSessionIndexer.storedInclude(.opencode) {
        didSet { applyInclude(.opencode, includeOpenCode) }
    }
    @Published var includeHermes: Bool = UnifiedSessionIndexer.storedInclude(.hermes) {
        didSet { applyInclude(.hermes, includeHermes) }
    }
    @Published var includeCopilot: Bool = UnifiedSessionIndexer.storedInclude(.copilot) {
        didSet { applyInclude(.copilot, includeCopilot) }
    }
    @Published var includeDroid: Bool = UnifiedSessionIndexer.storedInclude(.droid) {
        didSet { applyInclude(.droid, includeDroid) }
    }
    @Published var includeOpenClaw: Bool = UnifiedSessionIndexer.storedInclude(.openclaw) {
        didSet { applyInclude(.openclaw, includeOpenClaw) }
    }
    @Published var includeCursor: Bool = UnifiedSessionIndexer.storedInclude(.cursor) {
        didSet { applyInclude(.cursor, includeCursor) }
    }
    @Published var includePi: Bool = UnifiedSessionIndexer.storedInclude(.pi) {
        didSet { applyInclude(.pi, includePi) }
    }
    @Published var includeKimi: Bool = UnifiedSessionIndexer.storedInclude(.kimi) {
        didSet { applyInclude(.kimi, includeKimi) }
    }
    @Published var includeGrok: Bool = UnifiedSessionIndexer.storedInclude(.grok) {
        didSet { applyInclude(.grok, includeGrok) }
    }
    @Published var includeQwen: Bool = UnifiedSessionIndexer.storedInclude(.qwen) {
        didSet { applyInclude(.qwen, includeQwen) }
    }
    @Published var includeFx: Bool = UnifiedSessionIndexer.storedInclude(.fx) {
        didSet { applyInclude(.fx, includeFx) }
    }

    // Global agent enablement (drives app-wide availability). These twelve are read-only
    // mirrors of `enablementBySource` for the views that bind to them by name; the
    // dictionary is what the pipelines and policies consult.
    //
    // SPEC §8.3: `openClawAgentEnabled` used to seed itself from a bespoke
    // `object(forKey:) as? Bool ?? false` read instead of `AgentEnablement.isEnabled`,
    // the only provider that deviated. It now follows the same rule as the other eleven.
    @Published private(set) var codexAgentEnabled: Bool = AgentEnablement.isEnabled(.codex)
    @Published private(set) var claudeAgentEnabled: Bool = AgentEnablement.isEnabled(.claude)
    @Published private(set) var antigravityAgentEnabled: Bool = AgentEnablement.isEnabled(.antigravity)
    @Published private(set) var openCodeAgentEnabled: Bool = AgentEnablement.isEnabled(.opencode)
    @Published private(set) var hermesAgentEnabled: Bool = AgentEnablement.isEnabled(.hermes)
    @Published private(set) var copilotAgentEnabled: Bool = AgentEnablement.isEnabled(.copilot)
    @Published private(set) var droidAgentEnabled: Bool = AgentEnablement.isEnabled(.droid)
    @Published private(set) var openClawAgentEnabled: Bool = AgentEnablement.isEnabled(.openclaw)
    @Published private(set) var cursorAgentEnabled: Bool = AgentEnablement.isEnabled(.cursor)
    @Published private(set) var piAgentEnabled: Bool = AgentEnablement.isEnabled(.pi)
    @Published private(set) var kimiAgentEnabled: Bool = AgentEnablement.isEnabled(.kimi)
    @Published private(set) var grokAgentEnabled: Bool = AgentEnablement.isEnabled(.grok)
    @Published private(set) var qwenAgentEnabled: Bool = AgentEnablement.isEnabled(.qwen)
    @Published private(set) var fxAgentEnabled: Bool = AgentEnablement.isEnabled(.fx)

    /// Providers detected on disk that the user hasn't been notified about yet.
    @Published private(set) var newlyAvailableProviders: [SessionSource] = []

    // Sorting
    struct SessionSortDescriptor: Equatable { let key: Key; let ascending: Bool; enum Key { case modified, msgs, repo, title, agent, size } }
    @Published var sortDescriptor: SessionSortDescriptor = .init(key: .modified, ascending: false)

    // Indexing state aggregation
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var isProcessingTranscripts: Bool = false
    @Published private(set) var coreIndexingProgress: CoreIndexingProgress = .empty
    @Published private(set) var coreIndexingDisplayMode: CoreIndexingDisplayMode = .idle
    @Published private(set) var indexingError: String? = nil
    @Published var showFavoritesOnly: Bool = UserDefaults.standard.bool(forKey: "ShowFavoritesOnly") {
        didSet {
            UserDefaults.standard.set(showFavoritesOnly, forKey: "ShowFavoritesOnly")
            recomputeNow()
        }
    }

    @AppStorage("HideZeroMessageSessions") private var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") private var hideLowMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage(PreferencesKey.showHousekeepingSessions) private var showHousekeepingSessionsPref: Bool = false {
        didSet { recomputeNow() }
    }

    /// Every source's type-erased pipeline surface, from the catalog this indexer was built
    /// with. This replaces the twelve concrete indexer properties: nothing below names a
    /// provider class any more, so a thirteenth source adds no line to this file.
    private let handles: [SessionSource: ProviderHandle]

    /// Registry order — the order every array fold below emits in, the order
    /// `mergedAggregationResult` appends in, and the order `indexingError` prefers in.
    private let orderedSources: [SessionSource] = SessionSource.allCases

    /// Non-optional by design, matching `SessionProviderCatalog`'s own subscript: `init`
    /// refuses to build without a handle for every source, so a miss here is a wiring bug.
    private func handle(_ source: SessionSource) -> ProviderHandle {
        guard let handle = handles[source] else {
            preconditionFailure("UnifiedSessionIndexer has no handle for \(source)")
        }
        return handle
    }

    private static let aggregationQueue = DispatchQueue(label: "UnifiedSessionIndexer.Aggregation", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    private var notificationObserverTokens: [NSObjectProtocol] = []
    /// Key-filtered defaults observers: the raw `didChangeNotification` fires on
    /// every process-wide defaults write (incl. AppKit window/splitview
    /// bookkeeping); these narrow to only the keys each subscriber consults so
    /// unrelated writes no longer trigger a full recompute. See
    /// AgentSessions/Support/FilteredDefaultsObserver.swift.
    private var enablementSyncDefaultsObserver: FilteredDefaultsObserver?
    private var recomputeDefaultsObserver: FilteredDefaultsObserver?
    private var favorites = FavoritesStore()
    private var favoritesSnapshotVersion: UInt64 = 0
    private let favoritesAggregationVersion = CurrentValueSubject<UInt64, Never>(0)
    private var hasPublishedInitialSessions = false
    @Published private(set) var analyticsPhase: AnalyticsIndexPhase = .idle
    @Published private(set) var analyticsBuildProgress: AnalyticsBuildProgress = .empty
    @Published private(set) var analyticsLastBuiltAt: Date? = nil
    @Published private(set) var analyticsIsStale: Bool = false
    @MainActor private var analyticsProgressBySource: [String: (processed: Int, total: Int)] = [:]
    private var analyticsBuildTask: Task<Void, Never>?
    var isAnalyticsIndexing: Bool { analyticsPhase == .queued || analyticsPhase == .building }
    private static let analyticsSupportedSources = AnalyticsSourceSupport.rawValues
    private static var analyticsBackfillVersion: Int { AnalyticsIndexPhase.backfillVersion }
    private static let analyticsLastBuiltAtDefaultsKey = "AnalyticsLastBuiltAt"
    private let providerRefreshCoordinator = ProviderRefreshCoordinator(coalesceWindowSeconds: 10)
    /// One `SearchIngestService` (and its `IndexDB` handle) for this indexer's lifetime,
    /// shared across every source's search-ingest run — mirrors `AnalyticsIndexer`'s
    /// DB-per-build pattern but held rather than reopened each time. Created eagerly in
    /// `init` (not `lazy`) because `performProviderRefresh` runs on detached background
    /// tasks for multiple sources concurrently; a `lazy var` first-access race there would
    /// be undefined behavior. `nil` only if opening the DB failed at launch.
    private let searchIngestService: SearchIngestService?
    private let searchIngestCoordinator = SearchIngestCoordinatorBox()
    private let backgroundNewSessionMonitorIntervalSeconds: UInt64 = 60
    private let foregroundNewSessionMonitorIntervalSeconds: UInt64 = 5 * 60
    private let backgroundMonitorRefreshMinimumIntervalSeconds: TimeInterval = 3 * 60
    private let foregroundMonitorRefreshMinimumIntervalSeconds: TimeInterval = 10 * 60
    private var newSessionMonitorTask: Task<Void, Never>? = nil
    private var focusedSessionMonitorTask: Task<Void, Never>? = nil
    private var lastSeenCodexSnapshot: DirectorySignatureSnapshot? = nil
    private var lastSeenClaudeSnapshot: DirectorySignatureSnapshot? = nil
    private var focusedSessionContext: FocusedSessionContext? = nil
    private var lastFocusedSignatureBySource: [SessionSource: FileSignature] = [:]
    private var consecutiveMissingFocusedSignatureCountBySource: [SessionSource: Int] = [:]
    private var lastMonitorRefreshBySource: [SessionSource: Date] = [:]
    private var pendingMonitorRefreshSnapshotBySource: [SessionSource: DirectorySignatureSnapshot] = [:]
    private var pendingRefreshSourcesWhileInactive: Set<SessionSource> = []
    private var pendingManualFocusedReloadSources: Set<SessionSource> = []
    private var hasInitializedNewSessionMonitorBaseline: Bool = false
    private var appIsActive: Bool = false

    // Debouncing for expensive operations
    private var recomputeDebouncer: DispatchWorkItem? = nil

    /// Bumped (main-only) on every authoritative filter publish to `sessions`.
    /// The sort-only fast path captures this at snapshot time and skips its
    /// republish if a fresher filter pass landed while it sorted off-main —
    /// otherwise a stale re-sorted snapshot could clobber correct membership.
    private var sessionsFilterGeneration: Int = 0
    
    /// Production entry point: every handle comes from the catalog's runtimes, unchanged.
    @MainActor
    convenience init(catalog: SessionProviderCatalog) {
        self.init(handles: catalog.runtimes.mapValues(\.handle))
    }

    /// Designated init over the type-erased handles alone (SPEC §3.4).
    ///
    /// Internal rather than private so tests can build an indexer over synthetic handles —
    /// no provider indexers, no session directories, no `AvailabilityContext.live()`. It is
    /// not a weaker path than `init(catalog:)`: that convenience init feeds this one the
    /// catalog's own handles, and the completeness precondition below holds for both.
    @MainActor
    init(handles: [SessionSource: ProviderHandle]) {
        precondition(Set(handles.keys) == Set(SessionSource.allCases),
                     "UnifiedSessionIndexer needs a handle for every SessionSource; missing \(Set(SessionSource.allCases).subtracting(handles.keys))")
        self.handles = handles
        self.searchIngestService = (try? IndexDB()).map { SearchIngestService(db: $0) }
        self.analyticsLastBuiltAt = UserDefaults.standard.object(forKey: Self.analyticsLastBuiltAtDefaultsKey) as? Date

        syncAgentEnablementFromDefaults()
        // Observe UserDefaults changes to sync external toggles (Preferences) to this model.
        // Tracked keys: only the ones this closure actually reads/passes to
        // syncAgentEnablementFromDefaults(), which reads every per-agent
        // enablement key via AgentEnablement.enablementKey(for:).
        let enablementSyncObserver = FilteredDefaultsObserver(keys: [
            "UnifiedHasCommandsOnly",
            PreferencesKey.Unified.showArchivedCodexDesktopOnly
        ] + AgentEnablement.allEnablementKeys)
        self.enablementSyncDefaultsObserver = enablementSyncObserver
        enablementSyncObserver.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let v = UserDefaults.standard.bool(forKey: "UnifiedHasCommandsOnly")
                if v != self.hasCommandsOnly { self.hasCommandsOnly = v }
                let archivedOnly = UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showArchivedCodexDesktopOnly)
                if archivedOnly != self.showArchivedCodexDesktopOnly { self.showArchivedCodexDesktopOnly = archivedOnly }
                self.syncAgentEnablementFromDefaults()
            }
            .store(in: &cancellables)

        // Registry-ordered locals. Every fold below maps over these two, so the pipelines
        // carry no per-source names at all and the emitted arrays zip back against
        // `sources` positionally. Captured as locals rather than through `self` so the
        // stored closures never retain this indexer (SPEC §3.4 retain-cycle rule).
        // (the force-unwrap is what the completeness precondition above buys)
        let sources = orderedSources
        let ordered = sources.map { handles[$0]! }
        // One publisher instead of the legacy twelve-way `CombineLatest` pyramid: the
        // named `…AgentEnabled` properties are mirrors of this dictionary now.
        let agentEnabledFlags = $enablementBySource

        // Merge underlying allSessions whenever any changes
        Publishers.combineLatestArray(ordered.map(\.allSessions))
            .combineLatest(agentEnabledFlags, favoritesAggregationVersion)
            .receive(on: DispatchQueue.main)
            .map { [weak self] sourceLists, enabled, favoritesVersion -> SessionAggregationWork in
                guard let self else { return .empty }
                return SessionAggregationWork(
                    lists: Dictionary(uniqueKeysWithValues: zip(sources, sourceLists)),
                    favoritesSnapshot: self.favorites.snapshot(),
                    favoritesVersion: favoritesVersion,
                    enablement: AgentEnablementSnapshot(enabled: enabled)
                )
            }
            .receive(on: Self.aggregationQueue)
            .map(Self.mergedAggregationResult(from:))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self,
                      Self.shouldPublishAggregationResult(result, currentFavoritesVersion: self.favoritesSnapshotVersion) else { return }
                self.publishAfterCurrentUpdate { [weak self] in
                    guard let self,
                          Self.shouldPublishAggregationResult(result, currentFavoritesVersion: self.favoritesSnapshotVersion) else { return }
                    self.allSessions = result.sessions
                    self.rebuildClaudeArchiveOverlay()
                }
            }
            .store(in: &cancellables)

        // isIndexing reflects any enabled indexer working
        Publishers.combineLatestArray(ordered.map(\.isIndexing))
            .combineLatest(agentEnabledFlags)
            .map { states, enabled in
                zip(sources, states).contains { source, indexing in (enabled[source] ?? false) && indexing }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.publishAfterCurrentUpdate { [weak self] in
                    self?.isIndexing = value
                    if value == false {
                        self?.coreIndexingDisplayMode = .idle
                    }
                }
            }
            .store(in: &cancellables)

        // Aggregate core indexing progress across every provider, in registry order
        // (K14): three parallel folds — processed, totals, indexing — zipped back against
        // `sources` into one `CoreProviderSnapshot` row per provider. `aggregateProgress`
        // then ignores the disabled rows exactly as before.
        Publishers.CombineLatest3(
            Publishers.combineLatestArray(ordered.map(\.filesProcessed)),
            Publishers.combineLatestArray(ordered.map(\.totalFiles)),
            Publishers.combineLatestArray(ordered.map(\.isIndexing))
        )
        .combineLatest(agentEnabledFlags)
        .map { metrics, enabled in
            let (processed, totals, indexing) = metrics
            let snapshots = sources.enumerated().map { index, source in
                CoreProviderSnapshot(source: source,
                                     enabled: enabled[source] ?? false,
                                     indexing: indexing[index],
                                     processed: processed[index],
                                     total: totals[index])
            }
            return Self.aggregateProgress(from: snapshots)
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] progress in
            self?.publishAfterCurrentUpdate { [weak self] in
                self?.coreIndexingProgress = progress
            }
        }
        .store(in: &cancellables)

        // isProcessingTranscripts reflects any enabled indexer processing transcripts
        Publishers.combineLatestArray(ordered.map(\.isProcessingTranscripts))
            .combineLatest(agentEnabledFlags)
            .map { states, enabled in
                zip(sources, states).contains { source, processing in (enabled[source] ?? false) && processing }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.publishAfterCurrentUpdate { [weak self] in
                    self?.isProcessingTranscripts = value
                }
            }
            .store(in: &cancellables)

        // Forward the first error a still-enabled provider is reporting, in registry
        // order (K14) — the same preference the hand-nested `firstEnabledIndexingError`
        // chain expressed, minus the tuple surgery.
        Publishers.combineLatestArray(ordered.map(\.indexingError))
            .combineLatest(agentEnabledFlags)
            .map { errors, enabled in
                zip(sources, errors)
                    .compactMap { source, error in (enabled[source] ?? false) ? error : nil }
                    .first
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.publishAfterCurrentUpdate { [weak self] in
                    self?.indexingError = value
                }
            }
            .store(in: &cancellables)

        // Debounced filtering and sorting pipeline (runs off main thread)
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: OptionalDateEquality.eq),
            $dateTo.removeDuplicates(by: OptionalDateEquality.eq),
            $selectedModel.removeDuplicates()
        )
        let includes = $includedBySource
        Publishers.CombineLatest4(inputs, $selectedKinds.removeDuplicates(), $allSessions, includes.combineLatest(agentEnabledFlags))
            .receive(on: FeatureFlags.backgroundIngestQueue)
            .map { [weak self] combined -> [Session] in
                guard let self else { return [] }
                let (input, kinds, all, combinedFlags) = combined
                let (q, from, to, model) = input
                let (included, enabled) = combinedFlags
                // One policy, one place: `activeSources` is the same enabled-AND-included
                // conjunction `applyFiltersAndSort`, `updateLaunchState` and
                // `allowedSearchSources()` read, so list, launch state and search can no
                // longer disagree about a source.
                let active = Self.activeSources(included: included, enabled: enabled)

                // Start from all sessions, then apply the same filters we use elsewhere.
                var base = all
                if active.count < SessionSource.allCases.count {
                    base = base.filter { active.contains($0.source) }
                }

                let filters = Filters(query: q,
                                      dateFrom: from,
                                      dateTo: to,
                                      model: model,
                                      kinds: kinds,
                                      repoName: self.projectFilter,
                                      pathContains: nil,
                                      archivedCodexDesktopOnly: self.showArchivedCodexDesktopOnly,
                                      archivedClaudeDesktopOnly: self.showArchivedClaudeDesktopOnly,
                                      archivedClaudeSessionIDs: self.archivedClaudeSessionIDs,
                                      sideChatsOnly: false)
                var results = FilterEngine.filterSessions(base, filters: filters)

                if self.showFavoritesOnly { results = results.filter { $0.isFavorite } }
                if self.hideZeroMessageSessionsPref { results = results.filter { $0.isSideChat || $0.messageCount > 0 || CursorSessionIndexer.isDBOnlySession($0) } }
                if self.hideLowMessageSessionsPref { results = results.filter { Self.passesLowMessageVisibilityFilter($0) } }
                if !self.showHousekeepingSessionsPref { results = results.filter { !$0.isHousekeeping } }

                // Sort by the current descriptor; sort-only changes are handled by a separate
                // subscription (below) so they don't re-run the whole filter pipeline.
                results = self.applySort(results, descriptor: self.sortDescriptor)
                return results
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] results in
                guard let self else { return }
                self.publishAfterCurrentUpdate {
                    self.sessions = results
                    self.sessionsFilterGeneration &+= 1
                    if !self.hasPublishedInitialSessions {
                        self.hasPublishedInitialSessions = true
                    }
                    self.updateLaunchState()
                }
            }
            .store(in: &cancellables)

        // Sort-only changes: re-sort the already-filtered `sessions` off-main and republish,
        // WITHOUT re-running filterSessions + the filter passes. Clicking a column header only
        // reorders the same set; re-filtering thousands of sessions per click made sort lethargic.
        $sortDescriptor
            .dropFirst()
            .removeDuplicates()
            .map { [weak self] desc -> ([Session], SessionSortDescriptor, Int) in
                // Capture the current filtered set AND its generation together on main.
                (self?.sessions ?? [], desc, self?.sessionsFilterGeneration ?? 0)
            }
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] triple -> ([Session], Int) in
                (self?.applySort(triple.0, descriptor: triple.1) ?? triple.0, triple.2)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] payload in
                guard let self else { return }
                let (sorted, capturedGeneration) = payload
                self.publishAfterCurrentUpdate {
                    // A filter pass may have republished a fresher `sessions` while we
                    // sorted off-main. That pass already applied the current sort
                    // descriptor, so our snapshot is stale — skip to avoid clobbering it.
                    guard self.sessionsFilterGeneration == capturedGeneration else { return }
                    self.sessions = sorted
                }
            }
            .store(in: &cancellables)

        // recomputeNow() -> applyFiltersAndSort() consults @AppStorage-backed
        // prefs (hideZeroMessageSessionsPref/hideLowMessageSessionsPref/
        // showHousekeepingSessionsPref) that read these three keys; the rest
        // of the filter state is already tracked via @Published properties
        // with their own change handling, not raw defaults reads.
        let recomputeObserver = FilteredDefaultsObserver(keys: [
            "HideZeroMessageSessions",
            "HideLowMessageSessions",
            PreferencesKey.showHousekeepingSessions
        ])
        self.recomputeDefaultsObserver = recomputeObserver
        recomputeObserver.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeNow() }
            .store(in: &cancellables)

        // SPEC §8.1: this fold covers every registered provider. The pyramid it replaces combined
        // ten — `kimi` and `grok` were never added to it — so their launch phases could not
        // move `launchState` at all.
        Publishers.combineLatestArray(ordered.map(\.launchPhase))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLaunchState()
            }
            .store(in: &cancellables)

        // The source-filter side-channel: a source excluded from the list is not allowed to
        // block launch readiness, so `updateLaunchState` re-runs when inclusion changes.
        $includedBySource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLaunchState()
            }
            .store(in: &cancellables)

        updateLaunchState()

        // When probe cleanups succeed, mark analytics stale so they re-derive on next view.
        // Avoid calling refresh() here — probe cleanup runs during an in-flight manual refresh
        // and the coalesced second pass causes a redundant "0/N" indexing run.
        notificationObserverTokens.append(NotificationCenter.default.addObserver(forName: CodexProbeCleanup.didRunCleanupNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let info = note.userInfo as? [String: Any], let status = info["status"] as? String, status == "success" {
                if self.analyticsLastBuiltAt != nil { self.analyticsIsStale = true }
            }
        })
        notificationObserverTokens.append(NotificationCenter.default.addObserver(forName: ClaudeProbeProject.didRunCleanupNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let info = note.userInfo as? [String: Any], let status = info["status"] as? String, status == "success" {
                if self.analyticsLastBuiltAt != nil { self.analyticsIsStale = true }
            }
        })
        // A restore performed elsewhere (e.g. the transcript strip control) edits the
        // sidecar directly; refresh the overlay so the archived pill/filter reflect it.
        notificationObserverTokens.append(NotificationCenter.default.addObserver(forName: .claudeArchiveDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildClaudeArchiveOverlay()
        })
        rebuildClaudeArchiveOverlay()
    }

    func isAgentEnabled(_ source: SessionSource) -> Bool {
        enablementBySource[source] ?? false
    }

    /// The source-filter toggle for `source`, as a function of the source rather than twelve
    /// separately-named properties. A dictionary read since Task 7 — the twelve-arm switch
    /// that bridged to the `include<Provider>` properties is gone, and those properties now
    /// write through `includedBySource`.
    func isIncluded(_ source: SessionSource) -> Bool {
        includedBySource[source] ?? true
    }

    /// THE enabled-AND-included conjunction (SPEC §3.5). Everything that needs "is this
    /// source contributing right now" derives from this one place: the list filter
    /// (`applyFiltersAndSort` and its pipeline twin), launch readiness
    /// (`updateLaunchState`) and the search allow-list. It used to be written out three
    /// separate times, which is how the list and search drifted apart.
    static func activeSources(included: [SessionSource: Bool],
                              enabled: [SessionSource: Bool]) -> Set<SessionSource> {
        Set(SessionSource.allCases.filter { (enabled[$0] ?? false) && (included[$0] ?? true) })
    }

    /// Instance form of `activeSources`, over the current dictionaries.
    func isSourceActive(_ source: SessionSource) -> Bool {
        isAgentEnabled(source) && isIncluded(source)
    }

    /// Which sources a search may return results from (SPEC §3.5): globally enabled *and*
    /// included by the source filter — the same conjunction the list and the launch state
    /// use, so they can no longer disagree about a source.
    ///
    /// Lives on the indexer rather than in a view because all three production call sites need
    /// it and `UnifiedSearchFiltersView` cannot reach a helper private to `UnifiedSessionsView`.
    func allowedSearchSources() -> Set<SessionSource> {
        Self.activeSources(included: includedBySource, enabled: enablementBySource)
    }

    func syncAgentEnablementFromDefaults(defaults: UserDefaults = .standard) {
        let beforeSources = enabledAnalyticsSources()
        let previous = enablementBySource
        let next = Dictionary(uniqueKeysWithValues: SessionSource.allCases.map {
            ($0, AgentEnablement.isEnabled($0, defaults: defaults))
        })
        applyEnablement(next)

        let afterSources = enabledAnalyticsSources()
        if analyticsLastBuiltAt != nil && !afterSources.subtracting(beforeSources).isEmpty {
            analyticsIsStale = true
        }

        for source in orderedSources where previous[source] == false && next[source] == true {
            requestProviderRefresh(source: source, reason: "provider-enabled", trigger: .providerEnabled)
        }
    }

    /// Publishes a new enablement map and mirrors it out to the named properties the
    /// views bind to. The dictionary is the value the pipelines observe; those properties are a
    /// read-only projection of it.
    private func applyEnablement(_ next: [SessionSource: Bool]) {
        if next != enablementBySource { enablementBySource = next }
        func value(_ source: SessionSource) -> Bool { next[source] ?? false }
        if value(.codex) != codexAgentEnabled { codexAgentEnabled = value(.codex) }
        if value(.claude) != claudeAgentEnabled { claudeAgentEnabled = value(.claude) }
        if value(.antigravity) != antigravityAgentEnabled { antigravityAgentEnabled = value(.antigravity) }
        if value(.opencode) != openCodeAgentEnabled { openCodeAgentEnabled = value(.opencode) }
        if value(.hermes) != hermesAgentEnabled { hermesAgentEnabled = value(.hermes) }
        if value(.copilot) != copilotAgentEnabled { copilotAgentEnabled = value(.copilot) }
        if value(.droid) != droidAgentEnabled { droidAgentEnabled = value(.droid) }
        if value(.openclaw) != openClawAgentEnabled { openClawAgentEnabled = value(.openclaw) }
        if value(.cursor) != cursorAgentEnabled { cursorAgentEnabled = value(.cursor) }
        if value(.pi) != piAgentEnabled { piAgentEnabled = value(.pi) }
        if value(.kimi) != kimiAgentEnabled { kimiAgentEnabled = value(.kimi) }
        if value(.grok) != grokAgentEnabled { grokAgentEnabled = value(.grok) }
        if value(.qwen) != qwenAgentEnabled { qwenAgentEnabled = value(.qwen) }
        if value(.fx) != fxAgentEnabled { fxAgentEnabled = value(.fx) }
    }

    /// Detects providers whose data exists on disk but the user has not yet
    /// been notified about.  Called once at startup after migration.
    func detectNewlyAvailableProviders(defaults: UserDefaults = .standard) {
        let available = Set(SessionSource.allCases.filter { AgentEnablement.isAvailable($0, defaults: defaults) })
        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: available,
            defaults: defaults
        )
        if candidates != newlyAvailableProviders {
            newlyAvailableProviders = candidates
        }
    }

    /// Called when the user taps Enable or Dismiss on a detection banner.
    func dismissNewProviderBanner(for source: SessionSource, enable: Bool, defaults: UserDefaults = .standard) {
        if enable {
            AgentEnablement.setEnabled(source, enabled: true, defaults: defaults)
        }
        AgentEnablement.markProvidersAsKnown([source], defaults: defaults)
        newlyAvailableProviders.removeAll { $0 == source }
        if enable {
            syncAgentEnablementFromDefaults(defaults: defaults)
        }
    }

    func refresh(trigger: IndexRefreshTrigger = .manual) {
        LaunchProfiler.log("Unified.refresh: request enqueued")
        for source in orderedSources where isAgentEnabled(source) {
            requestProviderRefresh(source: source, reason: "unified-refresh", trigger: trigger)
        }
    }

    static func aggregateProgress(from snapshots: [CoreProviderSnapshot]) -> CoreIndexingProgress {
        let enabledRows = snapshots.filter(\.enabled)
        guard !enabledRows.isEmpty else {
            return CoreIndexingProgress.empty
        }
        let anyIndexing = enabledRows.contains(where: \.indexing)
        guard anyIndexing else {
            return CoreIndexingProgress.empty
        }

        let activeRows = enabledRows.filter(\.indexing)
        let processed = activeRows.reduce(into: 0) { partial, provider in
            let rowProcessed = max(0, provider.processed)
            let rowTotal = max(0, provider.total)
            partial += min(rowProcessed, rowTotal > 0 ? rowTotal : rowProcessed)
        }
        let total = activeRows.reduce(into: 0) { partial, provider in
            let rowTotal = max(0, provider.total)
            let rowProcessed = max(0, provider.processed)
            partial += max(rowTotal, rowProcessed)
        }

        return CoreIndexingProgress(
            processed: processed,
            total: total,
            activeSources: activeRows.count,
            totalSources: enabledRows.count
        )
    }

    func rebuildCoreIndex() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let db = try IndexDB()
                for source in SessionSource.allCases {
                    try await db.purgeSource(source.rawValue)
                }
            } catch {
                #if DEBUG
                print("[Indexing] Core rebuild purge failed: \(error)")
                #endif
            }
            await MainActor.run { [weak self] in
                self?.refresh(trigger: .cleanup)
            }
        }
    }

    @MainActor
    func setFocusedSession(_ session: Session?) {
        let newContext = session.map {
            FocusedSessionContext(source: $0.source, sessionID: $0.id, filePath: $0.filePath)
        }
        if focusedSessionContext == newContext { return }

        focusedSessionContext = newContext
        focusedSessionMonitorTask?.cancel()
        focusedSessionMonitorTask = nil

        guard let context = newContext else {
            lastFocusedSignatureBySource.removeAll()
            consecutiveMissingFocusedSignatureCountBySource.removeAll()
            return
        }
        guard Self.supportsFocusedSessionMonitoring(source: context.source) else {
            lastFocusedSignatureBySource.removeAll()
            consecutiveMissingFocusedSignatureCountBySource.removeAll()
            return
        }

        let initialSignature = focusedFileSignature(for: context)
        updateFocusedSignatureBaseline(for: context.source, signature: initialSignature)
        refreshFocusedSession(context: context, trigger: .selection)

        focusedSessionMonitorTask = Task.detached(priority: .utility) { [weak self, context] in
            await self?.runFocusedSessionMonitorLoop(context: context)
        }
    }

    @MainActor
    func setAppActive(_ active: Bool) {
        appIsActive = active
        newSessionMonitorTask?.cancel()
        newSessionMonitorTask = nil
        if active {
            // Foreground: keep lightweight monitor loop running at low cadence.
            let task = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.runNewSessionMonitorLoop()
            }
            newSessionMonitorTask = task

            let pending = pendingRefreshSourcesWhileInactive
            pendingRefreshSourcesWhileInactive.removeAll()
            if !pending.isEmpty {
                for source in pending {
                    requestProviderRefresh(source: source, reason: "deferred-foreground", trigger: .monitor)
                }
            }

            if let context = focusedSessionContext,
               Self.supportsFocusedSessionMonitoring(source: context.source) {
                focusedSessionMonitorTask?.cancel()
                focusedSessionMonitorTask = Task.detached(priority: .utility) { [weak self, context] in
                    await self?.runFocusedSessionMonitorLoop(context: context)
                }
                scheduleImmediateFocusedSessionCheck(context: context, trigger: .monitor)
            }
        } else {
            // Background: restart monitor loop with background cadence immediately.
            let task = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.runNewSessionMonitorLoop()
            }
            newSessionMonitorTask = task
            if focusedSessionMonitorTask == nil,
               let context = focusedSessionContext,
               Self.supportsFocusedSessionMonitoring(source: context.source) {
                focusedSessionMonitorTask = Task.detached(priority: .utility) { [weak self, context] in
                    await self?.runFocusedSessionMonitorLoop(context: context)
                }
            }
        }
    }

    private func runNewSessionMonitorLoop() async {
        await checkForNewSessions(establishBaselineIfNeeded: true)
        while !Task.isCancelled {
            let intervalSeconds = await MainActor.run { [weak self] () -> UInt64 in
                guard let self else { return 60 }
                return self.appIsActive
                    ? self.foregroundNewSessionMonitorIntervalSeconds
                    : self.backgroundNewSessionMonitorIntervalSeconds
            }
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            if Task.isCancelled { break }
            await checkForNewSessions()
        }
    }

    private func runFocusedSessionMonitorLoop(context: FocusedSessionContext) async {
        while !Task.isCancelled {
            let shouldContinue = await MainActor.run { [weak self] in
                guard let self, let currentContext = self.focusedSessionContext else { return false }
                return currentContext == context && Self.supportsFocusedSessionMonitoring(source: currentContext.source)
            }
            guard shouldContinue else { return }

            await performFocusedSessionCheck(context: context, trigger: .monitor)

            let intervalSeconds = await MainActor.run { [weak self] in
                self?.focusedSessionMonitorSleepSeconds(for: context.source)
                    ?? Self.focusedSessionRefreshIntervalSeconds(for: context.source, appIsActive: false, onAC: false)
            }
            try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
        }
    }

    private func checkForNewSessions(establishBaselineIfNeeded: Bool = false) async {
        let codexSnapshot = detectCodexDirectorySnapshot()
        let claudeSnapshot = detectClaudeDirectorySnapshot()
        await MainActor.run { [weak self] in
            guard let self else { return }
            if establishBaselineIfNeeded && !self.hasInitializedNewSessionMonitorBaseline {
                self.lastSeenCodexSnapshot = codexSnapshot
                self.lastSeenClaudeSnapshot = claudeSnapshot
                self.pendingMonitorRefreshSnapshotBySource[.codex] = nil
                self.pendingMonitorRefreshSnapshotBySource[.claude] = nil
                self.hasInitializedNewSessionMonitorBaseline = true
                return
            }
            if !self.hasInitializedNewSessionMonitorBaseline {
                self.hasInitializedNewSessionMonitorBaseline = true
            }

            self.processSnapshotDelta(source: .codex, snapshot: codexSnapshot,
                                      lastSnapshot: &self.lastSeenCodexSnapshot)
            self.processSnapshotDelta(source: .claude, snapshot: claudeSnapshot,
                                      lastSnapshot: &self.lastSeenClaudeSnapshot)
        }
    }

    @MainActor
    private func processSnapshotDelta(source: SessionSource,
                                      snapshot: DirectorySignatureSnapshot,
                                      lastSnapshot: inout DirectorySignatureSnapshot?) {
        if snapshot != lastSnapshot {
            lastSnapshot = snapshot
            if snapshot.fileCount > 0 {
                if self.shouldTriggerMonitorRefresh(source: source, now: Date()) {
                    self.pendingMonitorRefreshSnapshotBySource[source] = snapshot
                    self.requestProviderRefresh(source: source, reason: "directory-snapshot-delta", trigger: .monitor)
                } else {
                    self.pendingMonitorRefreshSnapshotBySource[source] = snapshot
                }
            } else {
                self.pendingMonitorRefreshSnapshotBySource[source] = nil
            }
        } else if self.pendingMonitorRefreshSnapshotBySource[source] != nil {
            if self.shouldTriggerMonitorRefresh(source: source, now: Date()) {
                self.requestProviderRefresh(source: source, reason: "directory-snapshot-delta", trigger: .monitor)
            }
        }
    }

    @MainActor
    private func shouldTriggerMonitorRefresh(source: SessionSource, now: Date) -> Bool {
        let minimumInterval = appIsActive
            ? foregroundMonitorRefreshMinimumIntervalSeconds
            : backgroundMonitorRefreshMinimumIntervalSeconds
        if let last = lastMonitorRefreshBySource[source],
           now.timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastMonitorRefreshBySource[source] = now
        return true
    }

    private func detectLatestCodexSignature() -> FileSignature? {
        let root = codexSessionsRoot()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        var newest: FileSignature? = nil

        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let folder = root
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))

            guard let signature = mostRecentFileSignature(in: folder, matching: { file in
                file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension.lowercased() == "jsonl"
            }) else {
                continue
            }
            if newest == nil || signature.modifiedAt > newest!.modifiedAt {
                newest = signature
            }
        }

        return newest
    }

    private func detectCodexDirectorySnapshot() -> DirectorySignatureSnapshot {
        let root = codexSessionsRoot()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        var allSignatures: [(path: String, modifiedAt: Date)] = []

        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let folder = root
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))

            allSignatures.append(contentsOf: collectFileSignatures(in: folder, matching: { file in
                file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension.lowercased() == "jsonl"
            }))
        }

        return DirectorySignatureSnapshot.from(allSignatures)
    }

    private func fileSignature(atPath path: String) -> FileSignature? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values?.isRegularFile == true else { return nil }
        return FileSignature(path: path, modifiedAt: values?.contentModificationDate ?? .distantPast)
    }

    private func detectLatestClaudeSignature() -> FileSignature? {
        let projectsRoot = claudeProjectsRoot()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: projectsRoot,
                                                         includingPropertiesForKeys: Array(keys),
                                                         options: [.skipsHiddenFiles]) else {
            return nil
        }

        var directories: [(url: URL, modifiedAt: Date)] = []
        directories.reserveCapacity(children.count)
        for child in children {
            let values = try? child.resourceValues(forKeys: keys)
            guard values?.isDirectory == true else { continue }
            directories.append((child, values?.contentModificationDate ?? .distantPast))
        }

        let sorted = directories.sorted { lhs, rhs in lhs.modifiedAt > rhs.modifiedAt }
        let selected = Array(sorted.prefix(5)).map(\.url)
        if !selected.isEmpty {
            return mostRecentSignature(in: selected, fileLimitPerDirectory: 500)
        }
        return mostRecentSignature(in: [projectsRoot], fileLimitPerDirectory: 500)
    }

    private func detectClaudeDirectorySnapshot() -> DirectorySignatureSnapshot {
        let projectsRoot = claudeProjectsRoot()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: projectsRoot,
                                                         includingPropertiesForKeys: Array(keys),
                                                         options: [.skipsHiddenFiles]) else {
            return .empty
        }

        var directories: [(url: URL, modifiedAt: Date)] = []
        directories.reserveCapacity(children.count)
        for child in children {
            let values = try? child.resourceValues(forKeys: keys)
            guard values?.isDirectory == true else { continue }
            directories.append((child, values?.contentModificationDate ?? .distantPast))
        }

        let sorted = directories.sorted { lhs, rhs in lhs.modifiedAt > rhs.modifiedAt }
        let selected = Array(sorted.prefix(5)).map(\.url)
        let scanDirs = selected.isEmpty ? [projectsRoot] : selected
        return collectDirectorySnapshot(in: scanDirs, fileLimitPerDirectory: 500)
    }

    private func codexSessionsRoot() -> URL {
        if let custom = UserDefaults.standard.string(forKey: PreferencesKey.Paths.codexSessionsRootOverride),
           !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    private func claudeProjectsRoot() -> URL {
        let defaults = UserDefaults.standard
        let custom = defaults.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride) ?? defaults.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride) ?? ""
        let claudeRoot: URL
        if !custom.isEmpty {
            claudeRoot = URL(fileURLWithPath: custom)
        } else {
            claudeRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        }
        let projects = claudeRoot.appendingPathComponent("projects")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDir), isDir.boolValue {
            return projects
        }
        return claudeRoot
    }

    private func mostRecentSignature(in directories: [URL], fileLimitPerDirectory: Int) -> FileSignature? {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let scanCap = fileLimitPerDirectory * 10
        var newest: FileSignature? = nil

        for directory in directories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(at: directory,
                                                 includingPropertiesForKeys: Array(keys),
                                                 options: [.skipsHiddenFiles]) else {
                continue
            }

            var scanned = 0
            var matched = 0
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { continue }
                scanned += 1
                if scanned > scanCap { break }
                let ext = file.pathExtension.lowercased()
                guard ext == "jsonl" || ext == "ndjson" else { continue }
                matched += 1
                if matched > fileLimitPerDirectory { break }
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                let signature = FileSignature(path: file.path, modifiedAt: modifiedAt)
                if newest == nil || signature.modifiedAt > newest!.modifiedAt {
                    newest = signature
                }
            }
        }

        return newest
    }

    private func mostRecentFileSignature(in folder: URL,
                                         matching predicate: (URL) -> Bool) -> FileSignature? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let items = try? fm.contentsOfDirectory(at: folder,
                                                      includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else {
            return nil
        }

        var newest: FileSignature? = nil
        for file in items where predicate(file) {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let signature = FileSignature(path: file.path, modifiedAt: values?.contentModificationDate ?? .distantPast)
            if newest == nil || signature.modifiedAt > newest!.modifiedAt {
                newest = signature
            }
        }
        return newest
    }

    private func collectFileSignatures(in folder: URL,
                                       matching predicate: (URL) -> Bool) -> [(path: String, modifiedAt: Date)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let items = try? fm.contentsOfDirectory(at: folder,
                                                      includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }

        var result: [(path: String, modifiedAt: Date)] = []
        for file in items where predicate(file) {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            result.append((path: file.path, modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        return result
    }

    private func collectDirectorySnapshot(in directories: [URL],
                                          fileLimitPerDirectory: Int) -> DirectorySignatureSnapshot {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let scanCap = fileLimitPerDirectory * 10
        var allSignatures: [(path: String, modifiedAt: Date)] = []

        for directory in directories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(at: directory,
                                                 includingPropertiesForKeys: Array(keys),
                                                 options: [.skipsHiddenFiles]) else {
                continue
            }

            var scanned = 0
            var matched = 0
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { continue }
                scanned += 1
                if scanned > scanCap { break }
                let ext = file.pathExtension.lowercased()
                guard ext == "jsonl" || ext == "ndjson" else { continue }
                matched += 1
                if matched > fileLimitPerDirectory { break }
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                allSignatures.append((path: file.path, modifiedAt: modifiedAt))
            }
        }

        return DirectorySignatureSnapshot.from(allSignatures)
    }

    private func requestProviderRefresh(source: SessionSource,
                                        reason: String,
                                        trigger: IndexRefreshTrigger = .manual) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.enqueueProviderRefresh(source: source, reason: reason, trigger: trigger)
        }
    }

    private func enqueueProviderRefresh(source: SessionSource,
                                        reason: String,
                                        trigger: IndexRefreshTrigger) async {
        if trigger == .manual, Self.supportsFocusedSessionMonitoring(source: source) {
            _ = await MainActor.run { [weak self] in
                self?.pendingManualFocusedReloadSources.insert(source)
            }
        }
        let request = await providerRefreshCoordinator.request(source: source)
        switch request {
        case .queued:
            return
        case .startNow:
            await runProviderRefreshSequence(source: source, reason: reason, trigger: trigger, delay: nil)
        case .scheduleAfter(let delay):
            await runProviderRefreshSequence(source: source, reason: reason, trigger: trigger, delay: delay)
        }
    }

    private func runProviderRefreshSequence(source: SessionSource,
                                            reason: String,
                                            trigger: IndexRefreshTrigger,
                                            delay: TimeInterval?) async {
        if let delay, delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        await performProviderRefresh(source: source, reason: reason, trigger: trigger)

        if let followUpDelay = await providerRefreshCoordinator.finish(source: source) {
            await runProviderRefreshSequence(source: source,
                                             reason: "\(reason)-coalesced",
                                             trigger: trigger,
                                             delay: followUpDelay)
        }
    }

    private func performProviderRefresh(source: SessionSource,
                                        reason: String,
                                        trigger: IndexRefreshTrigger) async {
        await AppReadyGate.waitUntilReady()
        let didTrigger = await MainActor.run { [weak self] in
            guard let self else { return false }
            guard self.shouldRefreshSource(source) else { return false }
            if !self.appIsActive && trigger != .manual && trigger != .launch {
                self.pendingRefreshSourcesWhileInactive.insert(source)
                LaunchProfiler.log("Unified.refresh[\(source.rawValue)]: deferred (inactive, trigger=\(trigger.rawValue))")
                return false
            }
            self.pendingMonitorRefreshSnapshotBySource[source] = nil
            let mode = self.refreshMode(for: source, trigger: trigger)
            let executionProfile = self.refreshExecutionProfile(for: source, trigger: trigger)
            switch trigger {
            case .launch, .manual:
                self.coreIndexingDisplayMode = .indexing
            case .monitor, .providerEnabled, .cleanup:
                if self.coreIndexingDisplayMode != .indexing {
                    self.coreIndexingDisplayMode = .syncing
                }
            }
            LaunchProfiler.log("Unified.refresh[\(source.rawValue)]: trigger (\(reason), mode=\(mode), trigger=\(trigger.rawValue))")
            self.triggerRefresh(for: source, mode: mode, trigger: trigger, executionProfile: executionProfile)
            return true
        }
        guard didTrigger else { return }

        let fingerprintBeforeWait: SessionListFingerprint? = await MainActor.run { [weak self] in
            self?.currentSearchIngestFingerprint(for: source)
        }

        var waits = 0
        while waits < 240 {
            if Task.isCancelled { break }
            let indexing = await MainActor.run { [weak self] in
                self?.isSourceIndexing(source) ?? false
            }
            if !indexing { break }
            waits += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // Source refresh has completed (core index + session_meta are current for this
        // source). Kick the search-corpus backfill/incremental ingest for it now — strictly
        // after, never blocking the refresh above. Single-flight + coalesced per source.
        //
        // Always-kick triggers (manual/launch/cleanup) bypass the no-change gate below:
        // a manual refresh/relaunch/full rebuild must never silently skip the corpus
        // pass. `.monitor`/`.providerEnabled` are the steady-state background kicks this
        // gate targets — for those, compare the discovered session list's cheap
        // fingerprint (already published by the refresh, no extra I/O) captured just
        // before vs. just after the wait loop above: identical means this refresh found
        // nothing new/changed for the source, so there is nothing for search-ingest to do.
        let alwaysKick = trigger == .manual || trigger == .launch || trigger == .cleanup
        var shouldKickSearchIngest = true
        if !alwaysKick {
            let fingerprintAfterWait: SessionListFingerprint? = await MainActor.run { [weak self] in
                self?.currentSearchIngestFingerprint(for: source)
            }
            if let before = fingerprintBeforeWait, let after = fingerprintAfterWait, before == after {
                shouldKickSearchIngest = false
            }
        }
        if !shouldKickSearchIngest {
            // Exemption: a source whose search corpus has never been populated at all
            // (fresh install, or a source just newly enabled) must still get its first
            // backfill kick even though this particular refresh found "no change" —
            // e.g. the very first refresh after launch, or a source whose corpus was
            // wiped by `rebuildCoreIndex`. Checked only in this (would-otherwise-skip)
            // branch via a single cheap `EXISTS` query — far cheaper than the full
            // ingest map reads this gate exists to avoid paying on every kick.
            let coverageDB = try? IndexDB()
            let coverageExists = try? await coverageDB?.hasSearchData(sources: [source.rawValue])
            if (coverageExists ?? nil) != true {
                shouldKickSearchIngest = true
            }
        }
        if shouldKickSearchIngest {
            kickSearchIngest(source: source)
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            if !self.isIndexing {
                self.coreIndexingDisplayMode = .idle
            } else if self.coreIndexingDisplayMode != .indexing {
                self.coreIndexingDisplayMode = .syncing
            }
        }

        let shouldForceFocusedReload = await MainActor.run { [weak self] () -> Bool in
            guard let self else { return false }
            let hasManualIntent = (trigger == .manual) || self.pendingManualFocusedReloadSources.contains(source)
            if hasManualIntent {
                self.pendingManualFocusedReloadSources.remove(source)
            }
            return hasManualIntent
        }

        if shouldForceFocusedReload {
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let context = self.focusedSessionContext,
                      context.source == source else {
                    return
                }
                self.refreshFocusedSession(context: context, trigger: .manual)
            }
        }

        if Self.analyticsSupportedSources.contains(source.rawValue) {
            await MainActor.run { [weak self] in
                guard let self, self.analyticsLastBuiltAt != nil else { return }
                if self.analyticsPhase != .building && self.analyticsPhase != .queued {
                    self.analyticsIsStale = true
                }
            }
        }
    }

    // MARK: - Search ingest wiring

    /// Fires after a source's refresh completes (launch backfill or delta). Single-flight
    /// per source via `searchIngestCoordinator`: if that source's ingest is already
    /// running, this request coalesces into one pending re-run rather than starting a
    /// second overlapping ingest or being dropped.
    private func kickSearchIngest(source: SessionSource) {
        guard let service = searchIngestService else { return }
        let coordinator = searchIngestCoordinator
        let providerHandle = handle(source)
        // Resolve every dependency before creating the caller-side request task. Neither
        // that task nor the tracked ingest captures `self`, so an active ingest cannot keep
        // UnifiedSessionIndexer alive and prevent its deinit-time cancellation. The actor
        // atomically decides whether to start and installs only the winning task; if deinit's
        // `cancelAll()` reaches it first, the request is rejected after teardown.
        Task {
            await coordinator.requestTracked(source: source) {
                await Self.runSearchIngestLoop(source: source,
                                               service: service,
                                               coordinator: coordinator,
                                               providerHandle: providerHandle)
            }
        }
    }

    /// Runs one ingest pass for `source`, then — if a request coalesced while it was
    /// running — runs exactly one more pass before reporting the coordinator idle again.
    /// `.utility` QoS is load-bearing here: `SearchIngestService.ingest` does not
    /// downgrade its own priority (see its doc comment), so this wrapper is what keeps
    /// full-parse work off higher QoS.
    private static func runSearchIngestLoop(source: SessionSource,
                                            service: SearchIngestService,
                                            coordinator: SearchIngestCoordinatorBox,
                                            providerHandle: ProviderHandle) async {
        var runAgain = true
        while runAgain {
            if Task.isCancelled { break }
            await performSearchIngestOnce(source: source,
                                          service: service,
                                          providerHandle: providerHandle)
            runAgain = await coordinator.finish(source: source)
        }
    }

    private static func performSearchIngestOnce(source: SessionSource,
                                                service: SearchIngestService,
                                                providerHandle: ProviderHandle) async {
        let input = await MainActor.run { () -> ([SearchIngestService.FileRef], SearchIngestService.IdentitySnapshot?) in
            let files = providerHandle.currentSessions().compactMap { session -> SearchIngestService.FileRef? in
                // Cursor DB-only sessions (filePath points at store.db, not a .jsonl
                // transcript) have no content for CursorSessionParser.parseFileFull to
                // read: JSONLReader silently yields zero events on a non-JSONL file, so
                // the parser returns an empty-but-non-nil Session that would otherwise get
                // upserted as search-ready and never revisited. Skip them here, same
                // detection idiom as CursorSessionIndexer.isDBOnlySession.
                if CursorSessionIndexer.isDBOnlySession(session) { return nil }
                let url = URL(fileURLWithPath: session.filePath)
                guard let stat = SessionFileStat.from(url) else { return nil }
                let descriptor = session.source.descriptor
                let usesIdentity = descriptor.parseFullByIdentity != nil
                    && descriptor.searchUsesIdentityAtURL?(url) == true
                return SearchIngestService.FileRef(path: session.filePath,
                                                   mtime: stat.mtime,
                                                   size: stat.size,
                                                   sessionID: usesIdentity ? session.id : nil,
                                                   contentRevision: usesIdentity
                                                       ? SearchIngestService.contentRevision(for: session)
                                                       : nil)
            }
            return (files, providerHandle.searchIdentitySnapshots.current())
        }
        let files = input.0
        let identitySnapshot = input.1
        // Identity-backed sources must run even with no current sessions so the
        // ingest service can remove the final archived/deleted database identity.
        if files.isEmpty, source.descriptor.searchUsesIdentityAtURL == nil { return }

        let toolIOEnabled = recentToolIOIndexEnabled()
        Perf.event("searchIngest", "source=\(source.rawValue) files=\(files.count) skipped=? start")
        do {
            let progress = try await service.ingest(source: source,
                                                    files: files,
                                                    toolIOEnabled: toolIOEnabled,
                                                    identitySnapshot: identitySnapshot)
            Perf.event("searchIngest", "source=\(source.rawValue) files=\(progress.total) skipped=\(progress.skipped) processed=\(progress.processed) end")
        } catch is CancellationError {
            Perf.event("searchIngest", "source=\(source.rawValue) files=\(files.count) skipped=? cancelled")
        } catch {
            Perf.event("searchIngest", "source=\(source.rawValue) files=\(files.count) skipped=? error=\(error)")
        }
    }

    /// The current per-source session list, keyed the same way `isSourceIndexing` is —
    /// each provider indexer's own `allSessions`, not the unified/filtered `self.allSessions`,
    /// so search-ingest sees every discovered file for that source regardless of the
    /// session-list filters (housekeeping, archived, etc.) applied to the UI-facing list.
    @MainActor
    private func currentSessions(for source: SessionSource) -> [Session] {
        handle(source).currentSessions()
    }

    /// Cheap "did this source's discovered session list change at all" signal, built
    /// purely from fields the provider refresh already computed and published on
    /// `allSessions` — no extra disk or DB I/O. Used to skip `kickSearchIngest` when a
    /// refresh completed but genuinely found nothing new/changed for this source.
    struct SessionListFingerprint: Equatable {
        let count: Int
        let totalSizeBytes: Int
        let newestEndTime: Date?
        let identityRevisions: [String]
        let identitySnapshot: SearchIngestService.IdentitySnapshot?

        init(sessions: [Session],
             identitySnapshot: SearchIngestService.IdentitySnapshot? = nil) {
            count = sessions.count
            totalSizeBytes = sessions.reduce(0) { $0 + ($1.fileSizeBytes ?? 0) }
            newestEndTime = sessions.compactMap(\.endTime).max()
            identityRevisions = sessions.compactMap { session in
                let url = URL(fileURLWithPath: session.filePath)
                let descriptor = session.source.descriptor
                guard descriptor.parseFullByIdentity != nil,
                      descriptor.searchUsesIdentityAtURL?(url) == true else { return nil }
                let revision = SearchIngestService.contentRevision(for: session)
                return "\(session.id):\(revision.updatedMillis):\(revision.extent)"
            }.sorted()
            self.identitySnapshot = identitySnapshot
        }
    }

    @MainActor
    private func currentSearchIngestFingerprint(for source: SessionSource) -> SessionListFingerprint {
        SessionListFingerprint(
            sessions: currentSessions(for: source),
            identitySnapshot: handle(source).searchIdentitySnapshots.current()
        )
    }

    private static func recentToolIOIndexEnabled() -> Bool {
        // Default OFF unless the user explicitly opts in (matches SearchCoordinator.toolIOIndexEnabled).
        if UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex)
    }

    @MainActor
    private func shouldRefreshSource(_ source: SessionSource) -> Bool {
        isAgentEnabled(source) && !handle(source).currentIsIndexing()
    }

    @MainActor
    private func refreshMode(for source: SessionSource, trigger: IndexRefreshTrigger) -> IndexRefreshMode {
        if trigger == .cleanup {
            return .fullReconcile
        }
        return .incremental
    }

    @MainActor
    private func refreshExecutionProfile(for _: SessionSource,
                                         trigger: IndexRefreshTrigger) -> IndexRefreshExecutionProfile {
        if trigger == .cleanup {
            return .interactive
        }
        if trigger == .launch || trigger == .manual {
            return .interactive
        }
        if !appIsActive {
            return .lightBackground
        }
        return .foregroundCapped
    }

    private static func onACPower() -> Bool {
        #if os(macOS)
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        if let typeCF = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() {
            let type = typeCF as String
            return type == (kIOPSACPowerValue as String)
        }
        #endif
        if #available(macOS 12.0, *) {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        }
        return true
    }

    @MainActor
    private func focusedSessionRefreshIntervalSeconds(for source: SessionSource) -> TimeInterval {
        Self.focusedSessionRefreshIntervalSeconds(for: source,
                                                  appIsActive: appIsActive,
                                                  onAC: Self.onACPower())
    }

    static func focusedSessionRefreshIntervalSeconds(for source: SessionSource,
                                                     appIsActive: Bool,
                                                     onAC: Bool) -> TimeInterval {
        let intervals = focusedSessionRefreshIntervalsBySource[source] ?? defaultFocusedSessionRefreshIntervals
        if appIsActive && onAC { return intervals.activeOnAC }
        if appIsActive && !onAC { return intervals.activeOnBattery }
        if !appIsActive && onAC { return intervals.inactiveOnAC }
        return intervals.inactiveOnBattery
    }

    @MainActor
    private func focusedSessionMonitorSleepSeconds(for source: SessionSource) -> TimeInterval {
        let base = focusedSessionRefreshIntervalSeconds(for: source)
        let missingCount = consecutiveMissingFocusedSignatureCountBySource[source] ?? 0
        guard missingCount > 0 else { return base }
        let multiplier = pow(2.0, Double(min(max(0, missingCount - 1), 3)))
        return min(120, max(10, base * multiplier))
    }

    /// The handle's `reloadFocusedSession` carries no enablement guard (SPEC §3.4) — this
    /// is the call site that owns it, exactly as the twelve deleted capability closures each
    /// opened with `guard indexer.<x>AgentEnabled else { return }`.
    @MainActor
    private func refreshFocusedSession(context: FocusedSessionContext, trigger: FocusedReloadTrigger) {
        guard focusedSessionContext == context else { return }
        guard Self.supportsFocusedSessionMonitoring(source: context.source) else { return }
        guard isAgentEnabled(context.source) else { return }
        let force = (trigger != .selection)
        handle(context.source).reloadFocusedSession(context.sessionID, force, trigger)
    }

    @MainActor
    private func focusedFileSignature(for context: FocusedSessionContext) -> FileSignature? {
        guard Self.supportsFocusedSessionMonitoring(source: context.source),
              let path = sourceAwareFocusedSignaturePath(for: context) else {
            return nil
        }
        return fileSignature(atPath: path)
    }

    @MainActor
    private func sourceAwareFocusedSignaturePath(for context: FocusedSessionContext) -> String? {
        let livePath = handle(context.source)
            .currentSessions()
            .first(where: { $0.id == context.sessionID })?
            .filePath
        if let livePath, !livePath.isEmpty { return livePath }
        return context.filePath
    }

    @MainActor
    private func updateFocusedSignatureBaseline(for source: SessionSource, signature: FileSignature?) {
        lastFocusedSignatureBySource.removeAll()
        consecutiveMissingFocusedSignatureCountBySource.removeAll()
        if let signature {
            lastFocusedSignatureBySource[source] = signature
            consecutiveMissingFocusedSignatureCountBySource[source] = 0
        } else {
            consecutiveMissingFocusedSignatureCountBySource[source] = 1
        }
    }

    @MainActor
    private func registerFocusedSignatureObservation(context: FocusedSessionContext,
                                                     signature: FileSignature?) -> Bool {
        guard focusedSessionContext == context else { return false }
        let source = context.source
        let previous = lastFocusedSignatureBySource[source]
        if previous != signature {
            if let signature {
                lastFocusedSignatureBySource[source] = signature
                consecutiveMissingFocusedSignatureCountBySource[source] = 0
                return true
            }
            lastFocusedSignatureBySource.removeValue(forKey: source)
            let next = (consecutiveMissingFocusedSignatureCountBySource[source] ?? 0) + 1
            consecutiveMissingFocusedSignatureCountBySource[source] = next
            return false
        }
        if signature == nil {
            let next = (consecutiveMissingFocusedSignatureCountBySource[source] ?? 0) + 1
            consecutiveMissingFocusedSignatureCountBySource[source] = next
        } else {
            consecutiveMissingFocusedSignatureCountBySource[source] = 0
        }
        return false
    }

    @MainActor
    private func scheduleImmediateFocusedSessionCheck(context: FocusedSessionContext,
                                                      trigger: FocusedReloadTrigger) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.performFocusedSessionCheck(context: context, trigger: trigger)
        }
    }

    private func performFocusedSessionCheck(context: FocusedSessionContext,
                                            trigger: FocusedReloadTrigger) async {
        let canRunFocusedReload = await MainActor.run { [weak self] in
            guard let self else { return false }
            return self.appIsActive || trigger != .monitor
        }
        guard canRunFocusedReload else { return }

        let signature = await MainActor.run { [weak self] () -> FileSignature? in
            guard let self else { return nil }
            return self.focusedFileSignature(for: context)
        }

        let shouldReload = await MainActor.run { [weak self] () -> Bool in
            guard let self else { return false }
            return self.registerFocusedSignatureObservation(context: context, signature: signature)
        }
        guard shouldReload else { return }

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.refreshFocusedSession(context: context, trigger: trigger)
        }
    }

    /// Every registered source supports focused-session monitoring: its handle carries a
    /// `reloadFocusedSession`, which is what the twelve deleted capability rows each said
    /// with a literal `supportsFocusedMonitoring: { true }`.
    static func focusedSessionMonitoringSupported(for source: SessionSource) -> Bool {
        SessionSourceRegistry.bySource[source] != nil
    }

    private static func supportsFocusedSessionMonitoring(source: SessionSource) -> Bool {
        focusedSessionMonitoringSupported(for: source)
    }

    /// SPEC §8.6 lives in the handles, not here: OpenCode's `refresh` takes no arguments,
    /// so its adapter's wrapper drops mode/trigger/profile — the same thing this switch's
    /// `case .opencode: opencode.refresh()` arm used to do.
    @MainActor
    private func triggerRefresh(for source: SessionSource,
                                mode: IndexRefreshMode,
                                trigger: IndexRefreshTrigger,
                                executionProfile: IndexRefreshExecutionProfile) {
        handle(source).refresh(mode, trigger, executionProfile)
    }

    @MainActor
    private func isSourceIndexing(_ source: SessionSource) -> Bool {
        handle(source).currentIsIndexing()
    }

    /// Returns the subset of currently enabled agents that support analytics.
    ///
    /// Derived from `enablementBySource` rather than its own per-provider list. The two
    /// used to be maintained in parallel — a new analytics provider had to be added to
    /// `AnalyticsSourceSupport` *and* remembered here — and nothing failed if you forgot
    /// the second one: the provider simply never entered an analytics build. Sharing the
    /// map means the omission now breaks enablement sync too, which is loud.
    func enabledAnalyticsSources() -> Set<String> {
        let enabled = enablementBySource.lazy.filter(\.value).map(\.key.rawValue)
        return Set(enabled).intersection(Self.analyticsSupportedSources)
    }

    /// Returns the set of analytics-supported sources that haven't completed a full backfill.
    func missingAnalyticsBackfillSources(db: IndexDB) async throws -> Set<String> {
        let needed = enabledAnalyticsSources()
        let completed = try await db.analyticsBackfillCompleteSources(version: Self.analyticsBackfillVersion)
        return needed.subtracting(completed)
    }

    @MainActor
    private func updateAnalyticsProgress(_ bySource: [String: (processed: Int, total: Int)], enabledSources: Set<String>, dateSpan: (String?, String?)) {
        let totals = bySource.values.reduce(into: (processed: 0, total: 0)) { partial, row in
            partial.processed += row.processed
            partial.total += row.total
        }
        let currentSource = enabledSources.first(where: { src in
            let row = bySource[src] ?? (0, 0)
            return row.total > 0 && row.processed < row.total
        })
        let completedSources = enabledSources.reduce(into: 0) { count, src in
            let row = bySource[src] ?? (0, 0)
            if row.total == 0 || row.processed >= row.total {
                count += 1
            }
        }
        analyticsBuildProgress = AnalyticsBuildProgress(
            processedSessions: totals.processed,
            totalSessions: totals.total,
            currentSource: currentSource,
            completedSources: completedSources,
            totalSources: enabledSources.count,
            dateStart: dateSpan.0,
            dateEnd: dateSpan.1
        )
    }

    @MainActor
    func requestAnalyticsBuildIfNeeded() {
        startAnalyticsBuild()
    }

    @MainActor
    func startAnalyticsBuild() {
        runAnalyticsBuild(preferIncremental: false)
    }

    @MainActor
    func updateAnalyticsNow() {
        runAnalyticsBuild(preferIncremental: true)
    }

    @MainActor
    func cancelAnalyticsBuild() {
        analyticsBuildTask?.cancel()
        analyticsBuildTask = nil
        analyticsProgressBySource = [:]
        analyticsPhase = .canceled
    }

    @MainActor
    private func runAnalyticsBuild(preferIncremental: Bool) {
        if analyticsPhase == .building || analyticsPhase == .queued { return }

        analyticsPhase = .queued
        analyticsBuildProgress = .empty

        let enabledSources = enabledAnalyticsSources()
        guard !enabledSources.isEmpty else {
            analyticsPhase = .idle
            return
        }

        analyticsBuildTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let db = try IndexDB()
                let missing = try await self.missingAnalyticsBackfillSources(db: db)
                let hasPriorBuild = await MainActor.run { self.analyticsLastBuiltAt != nil }
                let incremental = preferIncremental && hasPriorBuild && missing.isEmpty
                let version = Self.analyticsBackfillVersion
                let indexer = AnalyticsIndexer(db: db, enabledSources: enabledSources)

                await MainActor.run {
                    self.analyticsPhase = .building
                    self.analyticsBuildProgress = .empty
                    self.analyticsProgressBySource = Dictionary(uniqueKeysWithValues: enabledSources.map { ($0, (0, 0)) })
                }

                var failedSources = Set<String>()
                if incremental {
                    LaunchProfiler.log("Unified: Analytics incremental refresh start (meta-derived)")
                    failedSources = await indexer.refresh(onSourceProgress: { source, processed, total in
                        if Task.isCancelled { return }
                        await MainActor.run {
                            self.analyticsProgressBySource[source] = (processed, total)
                        }
                    })
                    LaunchProfiler.log("Unified: Analytics incremental refresh complete")
                } else {
                    LaunchProfiler.log("Unified: Analytics full build start (meta-derived)")
                    failedSources = await indexer.fullBuild(onSourceComplete: { source in
                        if Task.isCancelled { return }
                        try? await db.setAnalyticsBackfillComplete(source: source, version: version)
                    }, onSourceProgress: { source, processed, total in
                        if Task.isCancelled { return }
                        await MainActor.run {
                            self.analyticsProgressBySource[source] = (processed, total)
                        }
                    })
                    LaunchProfiler.log("Unified: Analytics full build complete")
                }

                if Task.isCancelled {
                    await MainActor.run {
                        self.analyticsProgressBySource = [:]
                        self.analyticsPhase = .canceled
                        self.analyticsBuildTask = nil
                    }
                    return
                }

                if !failedSources.isEmpty {
                    #if DEBUG
                    print("[Indexing] Analytics build had \(failedSources.count) source failures: \(failedSources)")
                    #endif
                    await MainActor.run {
                        self.analyticsProgressBySource = [:]
                        self.analyticsPhase = .failed
                        self.analyticsBuildTask = nil
                    }
                    return
                }

                // Update progress with final date span
                let span = (try? await db.analyticsSessionDaySpan(sources: Array(enabledSources))) ?? (nil, nil)
                await MainActor.run {
                    self.analyticsProgressBySource = [:]
                    self.updateAnalyticsProgress([:], enabledSources: enabledSources, dateSpan: span)
                    self.analyticsLastBuiltAt = Date()
                    UserDefaults.standard.set(self.analyticsLastBuiltAt, forKey: Self.analyticsLastBuiltAtDefaultsKey)
                    self.analyticsIsStale = false
                    self.analyticsPhase = .ready
                    self.analyticsBuildTask = nil
                }
            } catch {
                #if DEBUG
                print("[Indexing] Analytics build failed: \(error)")
                #endif
                await MainActor.run { [weak self] in
                    self?.analyticsProgressBySource = [:]
                    self?.analyticsPhase = .failed
                    self?.analyticsBuildTask = nil
                }
            }
        }
    }

    // Remove a session from the unified list (e.g., missing file cleanup)
    func removeSession(id: String) {
        allSessions.removeAll { $0.id == id }
        recomputeNow()
    }

    func applySearch() { query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    func recomputeNow() {
        // Debounce rapid recompute calls (e.g., from projectFilter changes) to prevent UI freezes
        recomputeDebouncer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // recomputeNow() is only ever triggered by discrete user actions (filter
            // toggles, favorites, sort, project-filter clear) -- run at .userInitiated so
            // it doesn't queue behind background ingest (also .utility) on large corpora.
            let queue = FeatureFlags.interactiveFilterRecomputeQueue
            queue.async {
                let results = self.applyFiltersAndSort(to: self.allSessions)
                DispatchQueue.main.async {
                    self.sessions = results
                    self.sessionsFilterGeneration &+= 1
                }
            }
        }
        recomputeDebouncer = work
        // Discrete toggles (not typing) drive recomputeNow(), so a short debounce still
        // coalesces rapid multi-clicks without adding perceptible latency to a single one.
        let delay: TimeInterval = FeatureFlags.fastFilterRecomputeDebounce ? 0.08 : (FeatureFlags.increaseFilterDebounce ? 0.28 : 0.15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// One row per source, from the same enabled-AND-included policy the list filter uses
    /// (`isSourceActive`): a source that is switched off or filtered out is reported `.ready`
    /// so it never blocks launch readiness.
    @MainActor
    private func updateLaunchState() {
        var phases: [SessionSource: LaunchPhase] = [:]
        for source in orderedSources {
            phases[source] = isSourceActive(source) ? handle(source).currentLaunchPhase() : .ready
        }

        let overall: LaunchPhase
        if phases.values.contains(.error) {
            overall = .error
        } else {
            overall = phases.values.max() ?? .idle
        }

        let blocking = phases.compactMap { source, phase -> SessionSource? in
            phase < .ready ? source : nil
        }

        let newState = LaunchState(
            sourcePhases: phases,
            overallPhase: overall,
            blockingSources: blocking,
            hasDisplayedSessions: hasPublishedInitialSessions
        )
        publishAfterCurrentUpdate { [weak self] in
            self?.launchState = newState
        }
    }

    private func publishAfterCurrentUpdate(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                // Avoid "Publishing changes from within view updates" warnings by yielding
                // past the current render pass before mutating @Published state.
                await Task.yield()
                await Task.yield()
                work()
            }
        }
    }

    static func mergedAggregationResult(from work: SessionAggregationWork) -> SessionAggregationResult {
        var merged: [Session] = []
        // Registry order, which is the order the twelve `if enablement.x { append }` lines
        // this replaces ran in. The final sort is by modifiedAt, so this only fixes ties.
        for source in SessionSource.allCases where work.enablement.isEnabled(source) {
            merged.append(contentsOf: work.lists[source] ?? [])
        }
        for index in merged.indices {
            merged[index].isFavorite = work.favoritesSnapshot.contains(id: merged[index].id, source: merged[index].source)
        }
        let sessions = merged.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt { return lhs.id > rhs.id }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return SessionAggregationResult(sessions: sessions, favoritesVersion: work.favoritesVersion)
    }

    static func mergedSessions(from work: SessionAggregationWork) -> [Session] {
        mergedAggregationResult(from: work).sessions
    }

    static func shouldPublishAggregationResult(_ result: SessionAggregationResult,
                                               currentFavoritesVersion: UInt64) -> Bool {
        result.favoritesVersion == currentFavoritesVersion
    }

    /// Backs the "has commands" quick filter.
    ///
    /// Every JSONL provider is judged on real tool-call evidence. Claude and
    /// Antigravity are stricter: an unparsed session counts as command-free
    /// because their lightweight pass does not populate `lightweightCommands`.
    static func passesHasCommandsFilter(_ session: Session) -> Bool {
        switch session.source {
        case .codex, .opencode, .hermes, .copilot, .droid, .openclaw, .cursor, .pi, .kimi, .grok, .qwen, .fx:
            // hasToolCallEvent is precomputed once at Session construction from
            // `events` (Session.swift), so this no longer rescans the full
            // events array per session per recompute.
            if !session.events.isEmpty {
                return session.hasToolCallEvent
            }
            return (session.lightweightCommands ?? 0) > 0
        case .claude, .antigravity:
            if session.events.isEmpty { return false }
            return session.hasToolCallEvent
        }
    }

    static func passesLowMessageVisibilityFilter(_ session: Session) -> Bool {
        if session.source == .opencode { return true }
        if session.source == .antigravity { return true }
        if session.isSideChat { return true }
        if CursorSessionIndexer.isDBOnlySession(session) { return true }
        return session.messageCount == 0 || session.messageCount > 2
    }

    private func bumpFavoritesSnapshotVersion() {
        favoritesSnapshotVersion &+= 1
        favoritesAggregationVersion.send(favoritesSnapshotVersion)
    }

    /// Apply current UI filters and sort preferences to a list of sessions.
    /// Used for both unified.sessions and search results to ensure consistent filtering/sorting.
    func applyFiltersAndSort(to sessions: [Session]) -> [Session] {
        // Filter by source toggle AND global agent enablement — the one policy, read from
        // `activeSources` rather than written out a third time.
        let active = allowedSearchSources()
        let base = sessions.filter { active.contains($0.source) }

        // Apply FilterEngine (query, date, model, kinds, project, path)
        let filters = Filters(query: query,
                              dateFrom: dateFrom,
                              dateTo: dateTo,
                              model: selectedModel,
                              kinds: selectedKinds,
                              repoName: projectFilter,
                              pathContains: nil,
                              archivedCodexDesktopOnly: showArchivedCodexDesktopOnly,
                              archivedClaudeDesktopOnly: showArchivedClaudeDesktopOnly,
                              archivedClaudeSessionIDs: archivedClaudeSessionIDs,
                              sideChatsOnly: false)
        var results = FilterEngine.filterSessions(base, filters: filters)

        // Optional quick filter: sessions with commands (tool calls)
        if hasCommandsOnly {
            results = results.filter { Self.passesHasCommandsFilter($0) }
        }


        // Favorites-only filter (AND with text search)
        if showFavoritesOnly { results = results.filter { $0.isFavorite } }

        // Hide housekeeping-only sessions unless explicitly enabled in Settings.
        if !showHousekeepingSessionsPref { results = results.filter { !$0.isHousekeeping } }

        // Filter by message count preferences
        if hideZeroMessageSessionsPref {
            results = results.filter { s in
                // Do not drop OpenCode sessions purely on message-count heuristics yet.
                if s.source == .opencode { return true }
                if s.isSideChat { return true }
                // Cursor DB-only sessions have no transcript; keep them visible.
                if CursorSessionIndexer.isDBOnlySession(s) { return true }
                return s.messageCount > 0
            }
        }
        if hideLowMessageSessionsPref {
            results = results.filter { s in
                Self.passesLowMessageVisibilityFilter(s)
            }
        }

        // Apply sort
        results = applySort(results, descriptor: sortDescriptor)

        return results
    }

    private func applySort(_ list: [Session], descriptor: SessionSortDescriptor) -> [Session] {
        switch descriptor.key {
        case .modified:
            return list.sorted { lhs, rhs in
                descriptor.ascending ? lhs.modifiedAt < rhs.modifiedAt : lhs.modifiedAt > rhs.modifiedAt
            }
        case .msgs:
            return list.sorted { lhs, rhs in
                descriptor.ascending ? lhs.messageCount < rhs.messageCount : lhs.messageCount > rhs.messageCount
            }
        case .repo:
            return Self.sortedByStringKey(list, ascending: descriptor.ascending) { $0.rowRepoDisplay.lowercased() }
        case .title:
            // Sort by the same value the column shows (`listTitle`, the column's `value:` keypath).
            return Self.sortedByStringKey(list, ascending: descriptor.ascending) { $0.listTitle.lowercased() }
        case .agent:
            return list.sorted { lhs, rhs in
                let l = lhs.source.rawValue
                let r = rhs.source.rawValue
                return descriptor.ascending ? (l, lhs.id) < (r, rhs.id) : (l, lhs.id) > (r, rhs.id)
            }
        case .size:
            return list.sorted { lhs, rhs in
                let l = lhs.fileSizeBytes ?? 0
                let r = rhs.fileSizeBytes ?? 0
                return descriptor.ascending ? (l, lhs.id) < (r, rhs.id) : (l, lhs.id) > (r, rhs.id)
            }
        }
    }

    /// Sort by a derived `String` key, computing the key exactly once per element
    /// (Schwartzian transform).
    ///
    /// The repo/title key getters (`rowRepoDisplay`, `listTitle`) are expensive
    /// derived values — they run project classifiers / path normalization / event
    /// scans. Calling them inside the comparator recomputes them O(n·log n) times,
    /// which froze the list for ~8s on large datasets (~3k+ sessions) and let the
    /// slow sort race past and overwrite faster sorts. Precomputing the key once
    /// reduces that to O(n) getter calls and keeps the sort sub-second.
    private static func sortedByStringKey(
        _ list: [Session],
        ascending: Bool,
        key: (Session) -> String
    ) -> [Session] {
        let decorated: [(key: String, id: String, session: Session)] =
            list.map { (key($0), $0.id, $0) }
        let sorted = decorated.sorted { lhs, rhs in
            ascending ? (lhs.key, lhs.id) < (rhs.key, rhs.id)
                      : (lhs.key, lhs.id) > (rhs.key, rhs.id)
        }
        return sorted.map(\.session)
    }

    // MARK: - Favorites
    func toggleFavorite(_ session: Session) {
        let nowStarred = favorites.toggle(id: session.id, source: session.source)
        if let idx = allSessions.firstIndex(where: { $0.id == session.id && $0.source == session.source }) {
            allSessions[idx].isFavorite = nowStarred
        }
        bumpFavoritesSnapshotVersion()

        let pins = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
        if nowStarred, pins {
            SessionArchiveManager.shared.pin(session: session)
        } else if !nowStarred {
            let removeArchive = UserDefaults.standard.bool(forKey: PreferencesKey.Archives.unstarRemovesArchive)
            SessionArchiveManager.shared.unstarred(source: session.source, id: session.id, removeArchive: removeArchive)
        }
        recomputeNow()
    }

    func toggleFavorite(_ id: String, source: SessionSource) {
        // Backward-compatible call site; prefer passing Session when available so pinning never depends on an array lookup.
        if let s = allSessions.first(where: { $0.id == id && $0.source == source }) {
            toggleFavorite(s)
        } else {
            bumpFavoritesSnapshotVersion()
            let nowStarred = favorites.toggle(id: id, source: source)
            if !nowStarred {
                let removeArchive = UserDefaults.standard.bool(forKey: PreferencesKey.Archives.unstarRemovesArchive)
                SessionArchiveManager.shared.unstarred(source: source, id: id, removeArchive: removeArchive)
            }
            recomputeNow()
        }
    }

    deinit {
        analyticsBuildTask?.cancel()
        newSessionMonitorTask?.cancel()
        focusedSessionMonitorTask?.cancel()
        let coordinator = searchIngestCoordinator
        Task { await coordinator.cancelAll() }
        for token in notificationObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
    struct LaunchState {
        let sourcePhases: [SessionSource: LaunchPhase]
        let overallPhase: LaunchPhase
        let blockingSources: [SessionSource]
        let hasDisplayedSessions: Bool

        /// SPEC §8.2: seeded from `SessionSource.allCases`. The hand-written literal this
        /// replaces named eight of the twelve sources, so `sourcePhases` started life
        /// missing four providers.
        static let idle = LaunchState(
            sourcePhases: Dictionary(uniqueKeysWithValues: SessionSource.allCases.map { ($0, LaunchPhase.idle) }),
            overallPhase: .idle,
            blockingSources: SessionSource.allCases,
            hasDisplayedSessions: false
        )

        var isInteractive: Bool {
            overallPhase == .ready && hasDisplayedSessions
        }

        var statusDescription: String {
            if isInteractive { return "Ready" }
            var text = overallPhase.statusDescription
            if !blockingSources.isEmpty {
                let joined = blockingSources.map { $0.displayName }.joined(separator: ", ")
                text += " (\(joined))"
            }
            return text
        }
    }

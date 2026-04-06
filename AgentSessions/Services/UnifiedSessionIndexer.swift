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
        ),
        .gemini: defaultFocusedSessionRefreshIntervals,
        .opencode: defaultFocusedSessionRefreshIntervals,
        .copilot: defaultFocusedSessionRefreshIntervals,
        .droid: defaultFocusedSessionRefreshIntervals,
        .openclaw: defaultFocusedSessionRefreshIntervals
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

    private enum FocusedReloadTrigger {
        case selection
        case monitor
        case manual
    }

    private struct FocusedMonitorCapability {
        let supportsFocusedMonitoring: () -> Bool
        let signatureSource: @MainActor (UnifiedSessionIndexer, FocusedSessionContext) -> String?
        let reloadFocusedSession: @MainActor (UnifiedSessionIndexer, FocusedSessionContext, FocusedReloadTrigger) -> Void
    }

    private static let focusedMonitorCapabilityBySource: [SessionSource: FocusedMonitorCapability] = [
        .codex: FocusedMonitorCapability(
            supportsFocusedMonitoring: { true },
            signatureSource: { indexer, context in
                indexer.sourceAwareFocusedSignaturePath(for: context)
            },
            reloadFocusedSession: { indexer, context, trigger in
                guard indexer.codexAgentEnabled else { return }
                let reason: SessionIndexer.ReloadReason
                switch trigger {
                case .selection:
                    reason = .selection
                case .monitor:
                    reason = .focusedSessionMonitor
                case .manual:
                    reason = .manualRefresh
                }
                indexer.codex.reloadSession(id: context.sessionID, force: true, reason: reason)
            }
        ),
        .claude: FocusedMonitorCapability(
            supportsFocusedMonitoring: { true },
            signatureSource: { indexer, context in
                indexer.sourceAwareFocusedSignaturePath(for: context)
            },
            reloadFocusedSession: { indexer, context, trigger in
                guard indexer.claudeAgentEnabled else { return }
                let force = (trigger != .selection)
                let reason: ClaudeSessionIndexer.ReloadReason
                switch trigger {
                case .selection:
                    reason = .selection
                case .monitor:
                    reason = .focusedSessionMonitor
                case .manual:
                    reason = .manualRefresh
                }
                indexer.claude.reloadSession(id: context.sessionID, force: force, reason: reason)
            }
        ),
        .gemini: FocusedMonitorCapability(
            supportsFocusedMonitoring: { true },
            signatureSource: { indexer, context in
                indexer.sourceAwareFocusedSignaturePath(for: context)
            },
            reloadFocusedSession: { indexer, context, trigger in
                guard indexer.geminiAgentEnabled else { return }
                let force = (trigger != .selection)
                let reason: GeminiSessionIndexer.ReloadReason
                switch trigger {
                case .selection:
                    reason = .selection
                case .monitor:
                    reason = .focusedSessionMonitor
                case .manual:
                    reason = .manualRefresh
                }
                indexer.gemini.reloadSession(id: context.sessionID, force: force, reason: reason)
            }
        ),
        .opencode: FocusedMonitorCapability(
            supportsFocusedMonitoring: { true },
            signatureSource: { indexer, context in
                indexer.sourceAwareFocusedSignaturePath(for: context)
            },
            reloadFocusedSession: { indexer, context, trigger in
                guard indexer.openCodeAgentEnabled else { return }
                let force = (trigger != .selection)
                let reason: OpenCodeSessionIndexer.ReloadReason
                switch trigger {
                case .selection:
                    reason = .selection
                case .monitor:
                    reason = .focusedSessionMonitor
                case .manual:
                    reason = .manualRefresh
                }
                indexer.opencode.reloadSession(id: context.sessionID, force: force, reason: reason)
            }
        ),
        .copilot: FocusedMonitorCapability(
            supportsFocusedMonitoring: { true },
            signatureSource: { indexer, context in
                indexer.sourceAwareFocusedSignaturePath(for: context)
            },
            reloadFocusedSession: { indexer, context, trigger in
                guard indexer.copilotAgentEnabled else { return }
                let force = (trigger != .selection)
                let reason: CopilotSessionIndexer.ReloadReason
                switch trigger {
                case .selection:
                    reason = .selection
                case .monitor:
                    reason = .focusedSessionMonitor
                case .manual:
                    reason = .manualRefresh
                }
                indexer.copilot.reloadSession(id: context.sessionID, force: force, reason: reason)
            }
        ),
        .droid: FocusedMonitorCapability(
            supportsFocusedMonitoring: { true },
            signatureSource: { indexer, context in
                indexer.sourceAwareFocusedSignaturePath(for: context)
            },
            reloadFocusedSession: { indexer, context, trigger in
                guard indexer.droidAgentEnabled else { return }
                let force = (trigger != .selection)
                let reason: DroidSessionIndexer.ReloadReason
                switch trigger {
                case .selection:
                    reason = .selection
                case .monitor:
                    reason = .focusedSessionMonitor
                case .manual:
                    reason = .manualRefresh
                }
                indexer.droid.reloadSession(id: context.sessionID, force: force, reason: reason)
            }
        ),
        .openclaw: FocusedMonitorCapability(
            supportsFocusedMonitoring: { true },
            signatureSource: { indexer, context in
                indexer.sourceAwareFocusedSignaturePath(for: context)
            },
            reloadFocusedSession: { indexer, context, trigger in
                guard indexer.openClawAgentEnabled else { return }
                let force = (trigger != .selection)
                let reason: OpenClawSessionIndexer.ReloadReason
                switch trigger {
                case .selection:
                    reason = .selection
                case .monitor:
                    reason = .focusedSessionMonitor
                case .manual:
                    reason = .manualRefresh
                }
                indexer.openclaw.reloadSession(id: context.sessionID, force: force, reason: reason)
            }
        )
    ]

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

    struct AgentEnablementSnapshot {
        let codex: Bool
        let claude: Bool
        let gemini: Bool
        let openCode: Bool
        let copilot: Bool
        let droid: Bool
        let openClaw: Bool
    }

    struct SessionAggregationWork {
        let codexList: [Session]
        let claudeList: [Session]
        let geminiList: [Session]
        let opencodeList: [Session]
        let copilotList: [Session]
        let droidList: [Session]
        let openclawList: [Session]
        let favoritesSnapshot: FavoritesStore.Snapshot
        let favoritesVersion: UInt64
        let enablement: AgentEnablementSnapshot

        static let empty = SessionAggregationWork(
            codexList: [],
            claudeList: [],
            geminiList: [],
            opencodeList: [],
            copilotList: [],
            droidList: [],
            openclawList: [],
            favoritesSnapshot: FavoritesStore.Snapshot(legacyIDs: [], scopedKeys: []),
            favoritesVersion: 0,
            enablement: AgentEnablementSnapshot(
                codex: false,
                claude: false,
                gemini: false,
                openCode: false,
                copilot: false,
                droid: false,
                openClaw: false
            )
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

    // Source filters (persisted with @Published for Combine compatibility)
    @Published var includeCodex: Bool = UserDefaults.standard.object(forKey: "IncludeCodexSessions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeCodex, forKey: "IncludeCodexSessions")
            recomputeNow()
        }
    }
    @Published var includeClaude: Bool = UserDefaults.standard.object(forKey: "IncludeClaudeSessions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeClaude, forKey: "IncludeClaudeSessions")
            recomputeNow()
        }
    }
    @Published var includeGemini: Bool = UserDefaults.standard.object(forKey: "IncludeGeminiSessions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeGemini, forKey: "IncludeGeminiSessions")
            recomputeNow()
        }
    }
    @Published var includeOpenCode: Bool = UserDefaults.standard.object(forKey: "IncludeOpenCodeSessions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeOpenCode, forKey: "IncludeOpenCodeSessions")
            recomputeNow()
        }
    }
    @Published var includeCopilot: Bool = UserDefaults.standard.object(forKey: "IncludeCopilotSessions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeCopilot, forKey: "IncludeCopilotSessions")
            recomputeNow()
        }
    }
    @Published var includeDroid: Bool = UserDefaults.standard.object(forKey: "IncludeDroidSessions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeDroid, forKey: "IncludeDroidSessions")
            recomputeNow()
        }
    }
    @Published var includeOpenClaw: Bool = UserDefaults.standard.object(forKey: "IncludeOpenClawSessions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(includeOpenClaw, forKey: "IncludeOpenClawSessions")
            recomputeNow()
        }
    }

    // Global agent enablement (drives app-wide availability)
    @Published private(set) var codexAgentEnabled: Bool = AgentEnablement.isEnabled(.codex)
    @Published private(set) var claudeAgentEnabled: Bool = AgentEnablement.isEnabled(.claude)
    @Published private(set) var geminiAgentEnabled: Bool = AgentEnablement.isEnabled(.gemini)
    @Published private(set) var openCodeAgentEnabled: Bool = AgentEnablement.isEnabled(.opencode)
    @Published private(set) var copilotAgentEnabled: Bool = AgentEnablement.isEnabled(.copilot)
    @Published private(set) var droidAgentEnabled: Bool = AgentEnablement.isEnabled(.droid)
    @Published private(set) var openClawAgentEnabled: Bool = UserDefaults.standard.object(forKey: PreferencesKey.Agents.openClawEnabled) as? Bool ?? false

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

    private let codex: SessionIndexer
    private let claude: ClaudeSessionIndexer
    private let gemini: GeminiSessionIndexer
    private let opencode: OpenCodeSessionIndexer
    private let copilot: CopilotSessionIndexer
    private let droid: DroidSessionIndexer
    private let openclaw: OpenClawSessionIndexer
    private static let aggregationQueue = DispatchQueue(label: "UnifiedSessionIndexer.Aggregation", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    private var notificationObserverTokens: [NSObjectProtocol] = []
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
    private static let analyticsSupportedSources: Set<String> = [
        "codex", "claude", "gemini", "opencode", "copilot", "droid"
    ]
    private static var analyticsBackfillVersion: Int { AnalyticsIndexPhase.backfillVersion }
    private static let analyticsLastBuiltAtDefaultsKey = "AnalyticsLastBuiltAt"
    private let providerRefreshCoordinator = ProviderRefreshCoordinator(coalesceWindowSeconds: 10)
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
    
    init(codexIndexer: SessionIndexer,
         claudeIndexer: ClaudeSessionIndexer,
         geminiIndexer: GeminiSessionIndexer,
         opencodeIndexer: OpenCodeSessionIndexer,
         copilotIndexer: CopilotSessionIndexer,
         droidIndexer: DroidSessionIndexer,
         openclawIndexer: OpenClawSessionIndexer) {
        self.codex = codexIndexer
        self.claude = claudeIndexer
        self.gemini = geminiIndexer
        self.opencode = opencodeIndexer
        self.copilot = copilotIndexer
        self.droid = droidIndexer
        self.openclaw = openclawIndexer
        self.analyticsLastBuiltAt = UserDefaults.standard.object(forKey: Self.analyticsLastBuiltAtDefaultsKey) as? Date

        syncAgentEnablementFromDefaults()
        // Observe UserDefaults changes to sync external toggles (Preferences) to this model
        notificationObserverTokens.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            guard let self else { return }
            let v = UserDefaults.standard.bool(forKey: "UnifiedHasCommandsOnly")
            if v != self.hasCommandsOnly { self.hasCommandsOnly = v }
            self.syncAgentEnablementFromDefaults()
        })

        let agentEnabledFlags = Publishers.CombineLatest(
            Publishers.CombineLatest4($codexAgentEnabled, $claudeAgentEnabled, $geminiAgentEnabled, $openCodeAgentEnabled),
            Publishers.CombineLatest3($copilotAgentEnabled, $droidAgentEnabled, $openClawAgentEnabled)
        )

        // Merge underlying allSessions whenever any changes
        Publishers.CombineLatest(
            Publishers.CombineLatest4(codex.$allSessions, claude.$allSessions, gemini.$allSessions, opencode.$allSessions),
            Publishers.CombineLatest3(copilot.$allSessions, droid.$allSessions, openclaw.$allSessions)
        )
            .combineLatest(agentEnabledFlags, favoritesAggregationVersion)
            .receive(on: DispatchQueue.main)
            .map { [weak self] sourceLists, flags, favoritesVersion -> SessionAggregationWork in
                guard let self else { return .empty }
                let (combined, tail) = sourceLists
                let (codexList, claudeList, geminiList, opencodeList) = combined
                let (copilotList, droidList, openclawList) = tail
                let (enabled4, tailEnabled) = flags
                let (codexEnabled, claudeEnabled, geminiEnabled, openCodeEnabled) = enabled4
                let (copilotEnabled, droidEnabled, openClawEnabled) = tailEnabled
                return SessionAggregationWork(
                    codexList: codexList,
                    claudeList: claudeList,
                    geminiList: geminiList,
                    opencodeList: opencodeList,
                    copilotList: copilotList,
                    droidList: droidList,
                    openclawList: openclawList,
                    favoritesSnapshot: self.favorites.snapshot(),
                    favoritesVersion: favoritesVersion,
                    enablement: AgentEnablementSnapshot(
                        codex: codexEnabled,
                        claude: claudeEnabled,
                        gemini: geminiEnabled,
                        openCode: openCodeEnabled,
                        copilot: copilotEnabled,
                        droid: droidEnabled,
                        openClaw: openClawEnabled
                    )
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
                }
            }
            .store(in: &cancellables)

        // isIndexing reflects any enabled indexer working
        Publishers.CombineLatest(
            Publishers.CombineLatest4(codex.$isIndexing, claude.$isIndexing, gemini.$isIndexing, opencode.$isIndexing),
            Publishers.CombineLatest3(copilot.$isIndexing, droid.$isIndexing, openclaw.$isIndexing)
        )
            .combineLatest(agentEnabledFlags)
            .map { states, flags in
                let (s4, tailStates) = states
                let (c, cl, g, o) = s4
                let (copilotState, droidState, openclawState) = tailStates
                let (f4, tailFlags) = flags
                let (ec, ecl, eg, eo) = f4
                let (eCopilot, eDroid, eOpenClaw) = tailFlags
                return (ec && c) || (ecl && cl) || (eg && g) || (eo && o) || (eCopilot && copilotState) || (eDroid && droidState) || (eOpenClaw && openclawState)
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

        // Aggregate core indexing progress across enabled providers.
        // Provider tuple order is fixed: codex, claude, gemini, opencode, copilot, droid, openclaw.
        Publishers.CombineLatest3(
            Publishers.CombineLatest(
                Publishers.CombineLatest4(codex.$filesProcessed, claude.$filesProcessed, gemini.$filesProcessed, opencode.$filesProcessed),
                Publishers.CombineLatest3(copilot.$filesProcessed, droid.$filesProcessed, openclaw.$filesProcessed)
            ),
            Publishers.CombineLatest(
                Publishers.CombineLatest4(codex.$totalFiles, claude.$totalFiles, gemini.$totalFiles, opencode.$totalFiles),
                Publishers.CombineLatest3(copilot.$totalFiles, droid.$totalFiles, openclaw.$totalFiles)
            ),
            Publishers.CombineLatest(
                Publishers.CombineLatest4(codex.$isIndexing, claude.$isIndexing, gemini.$isIndexing, opencode.$isIndexing),
                Publishers.CombineLatest3(copilot.$isIndexing, droid.$isIndexing, openclaw.$isIndexing)
            )
        )
        .combineLatest(agentEnabledFlags)
        .map { metrics, flags in
            let snapshots = Self.coreProviderSnapshots(metrics: metrics, flags: flags)
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
        Publishers.CombineLatest(
            Publishers.CombineLatest4(codex.$isProcessingTranscripts, claude.$isProcessingTranscripts, gemini.$isProcessingTranscripts, opencode.$isProcessingTranscripts),
            Publishers.CombineLatest3(copilot.$isProcessingTranscripts, droid.$isProcessingTranscripts, openclaw.$isProcessingTranscripts)
        )
            .combineLatest(agentEnabledFlags)
            .map { states, flags in
                let (s4, tailStates) = states
                let (c, cl, g, o) = s4
                let (copilotState, droidState, openclawState) = tailStates
                let (f4, tailFlags) = flags
                let (ec, ecl, eg, eo) = f4
                let (eCopilot, eDroid, eOpenClaw) = tailFlags
                return (ec && c) || (ecl && cl) || (eg && g) || (eo && o) || (eCopilot && copilotState) || (eDroid && droidState) || (eOpenClaw && openclawState)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.publishAfterCurrentUpdate { [weak self] in
                    self?.isProcessingTranscripts = value
                }
            }
            .store(in: &cancellables)

        // Forward errors (preference order codex → claude → gemini → opencode → copilot), ignoring disabled agents
        Publishers.CombineLatest(
            Publishers.CombineLatest4(codex.$indexingError, claude.$indexingError, gemini.$indexingError, opencode.$indexingError),
            Publishers.CombineLatest3(copilot.$indexingError, droid.$indexingError, openclaw.$indexingError)
        )
            .combineLatest(agentEnabledFlags)
            .map { errs, flags in
                let (errs4, tailErrs) = errs
                let (codexErr, claudeErr, geminiErr, opencodeErr) = errs4
                let (copilotErr, droidErr, openclawErr) = tailErrs
                let (f4, tailFlags) = flags
                let (ec, ecl, eg, eo) = f4
                let a = ec ? codexErr : nil
                let b = ecl ? claudeErr : nil
                let c = eg ? geminiErr : nil
                let d = eo ? opencodeErr : nil
                let (eCopilot, eDroid, eOpenClaw) = tailFlags
                let e = eCopilot ? copilotErr : nil
                let f = eDroid ? droidErr : nil
                let g = eOpenClaw ? openclawErr : nil
                return a ?? b ?? c ?? d ?? e ?? f ?? g
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
        let includes = Publishers.CombineLatest(
            Publishers.CombineLatest4($includeCodex, $includeClaude, $includeGemini, $includeOpenCode),
            Publishers.CombineLatest3($includeCopilot, $includeDroid, $includeOpenClaw)
        )
        Publishers.CombineLatest(
            Publishers.CombineLatest4(inputs, $selectedKinds.removeDuplicates(), $allSessions, includes.combineLatest(agentEnabledFlags)),
            $sortDescriptor.removeDuplicates()
        )
            .receive(on: FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] combined, sortDesc -> [Session] in
                guard let self else { return [] }
                let (input, kinds, all, combinedFlags) = combined
                let (q, from, to, model) = input
                let (sources, enabledFlags) = combinedFlags
                let (src4, tailSources) = sources
                let (incCodex, incClaude, incGemini, incOpenCode) = src4
                let (incCopilot, incDroid, incOpenClaw) = tailSources
                let (en4, tailEnabled) = enabledFlags
                let (enCodex, enClaude, enGemini, enOpenCode) = en4
                let (enCopilot, enDroid, enOpenClaw) = tailEnabled
                let effectiveCodex = incCodex && enCodex
                let effectiveClaude = incClaude && enClaude
                let effectiveGemini = incGemini && enGemini
                let effectiveOpenCode = incOpenCode && enOpenCode
                let effectiveCopilot = incCopilot && enCopilot
                let effectiveDroid = incDroid && enDroid
                let effectiveOpenClaw = incOpenClaw && enOpenClaw

                // Start from all sessions, then apply the same filters we use elsewhere.
                var base = all
                if !(effectiveCodex && effectiveClaude && effectiveGemini && effectiveOpenCode && effectiveCopilot && effectiveDroid && effectiveOpenClaw) {
                    base = base.filter { s in
                        (s.source == .codex && effectiveCodex) ||
                        (s.source == .claude && effectiveClaude) ||
                        (s.source == .gemini && effectiveGemini) ||
                        (s.source == .opencode && effectiveOpenCode) ||
                        (s.source == .copilot && effectiveCopilot) ||
                        (s.source == .droid && effectiveDroid) ||
                        (s.source == .openclaw && effectiveOpenClaw)
                    }
                }

                let filters = Filters(query: q,
                                      dateFrom: from,
                                      dateTo: to,
                                      model: model,
                                      kinds: kinds,
                                      repoName: self.projectFilter,
                                      pathContains: nil)
                var results = FilterEngine.filterSessions(base, filters: filters)

                if self.showFavoritesOnly { results = results.filter { $0.isFavorite } }
                if self.hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
                if self.hideLowMessageSessionsPref { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
                if !self.showHousekeepingSessionsPref { results = results.filter { !$0.isHousekeeping } }

                // Apply sort descriptor (now included in pipeline so changes trigger background re-sort)
                results = self.applySort(results, descriptor: sortDesc)
                return results
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] results in
                guard let self else { return }
                self.publishAfterCurrentUpdate {
                    self.sessions = results
                    if !self.hasPublishedInitialSessions {
                        self.hasPublishedInitialSessions = true
                    }
                    self.updateLaunchState()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeNow() }
            .store(in: &cancellables)

        // Seed Gemini hash resolver with known working directories from Codex/Claude sessions
        Publishers.CombineLatest(codex.$allSessions, claude.$allSessions)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] codexList, claudeList in
                guard let self else { return }
                if !self.codexAgentEnabled && !self.claudeAgentEnabled { return }
                var base: [Session] = []
                if self.codexAgentEnabled { base.append(contentsOf: codexList) }
                if self.claudeAgentEnabled { base.append(contentsOf: claudeList) }
                let paths = base.compactMap { $0.cwd }
                GeminiHashResolver.shared.registerCandidates(paths)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(Publishers.CombineLatest4(codex.$launchPhase, claude.$launchPhase, gemini.$launchPhase, opencode.$launchPhase),
                                Publishers.CombineLatest3(copilot.$launchPhase, droid.$launchPhase, openclaw.$launchPhase))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateLaunchState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            Publishers.CombineLatest4($includeCodex, $includeClaude, $includeGemini, $includeOpenCode),
            Publishers.CombineLatest3($includeCopilot, $includeDroid, $includeOpenClaw)
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
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
    }

    func syncAgentEnablementFromDefaults(defaults: UserDefaults = .standard) {
        let beforeSources = enabledAnalyticsSources()
        let c1 = AgentEnablement.isEnabled(.codex, defaults: defaults)
        let c2 = AgentEnablement.isEnabled(.claude, defaults: defaults)
        let c3 = AgentEnablement.isEnabled(.gemini, defaults: defaults)
        let c4 = AgentEnablement.isEnabled(.opencode, defaults: defaults)
        let c5 = AgentEnablement.isEnabled(.copilot, defaults: defaults)
        let c6 = AgentEnablement.isEnabled(.droid, defaults: defaults)
        let c7 = AgentEnablement.isEnabled(.openclaw, defaults: defaults)
        if c1 != codexAgentEnabled { codexAgentEnabled = c1 }
        if c2 != claudeAgentEnabled { claudeAgentEnabled = c2 }
        if c3 != geminiAgentEnabled { geminiAgentEnabled = c3 }
        if c4 != openCodeAgentEnabled { openCodeAgentEnabled = c4 }
        if c5 != copilotAgentEnabled { copilotAgentEnabled = c5 }
        if c6 != droidAgentEnabled { droidAgentEnabled = c6 }
        if c7 != openClawAgentEnabled { openClawAgentEnabled = c7 }

        let afterSources = enabledAnalyticsSources()
        if analyticsLastBuiltAt != nil && !afterSources.subtracting(beforeSources).isEmpty {
            analyticsIsStale = true
        }
    }

    func refresh(trigger: IndexRefreshTrigger = .manual) {
        LaunchProfiler.log("Unified.refresh: request enqueued")
        let sources: [SessionSource] = [
            codexAgentEnabled ? .codex : nil,
            claudeAgentEnabled ? .claude : nil,
            geminiAgentEnabled ? .gemini : nil,
            openCodeAgentEnabled ? .opencode : nil,
            copilotAgentEnabled ? .copilot : nil,
            droidAgentEnabled ? .droid : nil,
            openClawAgentEnabled ? .openclaw : nil
        ].compactMap { $0 }
        for source in sources {
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

    private static func coreProviderSnapshots(
        metrics: (
            (
                (Int, Int, Int, Int),
                (Int, Int, Int)
            ),
            (
                (Int, Int, Int, Int),
                (Int, Int, Int)
            ),
            (
                (Bool, Bool, Bool, Bool),
                (Bool, Bool, Bool)
            )
        ),
        flags: (
            (Bool, Bool, Bool, Bool),
            (Bool, Bool, Bool)
        )
    ) -> [CoreProviderSnapshot] {
        let (processedTuple, totalsTuple, indexingTuple) = metrics
        let (processed4, processedTail) = processedTuple
        let (pCodex, pClaude, pGemini, pOpenCode) = processed4
        let (pCopilot, pDroid, pOpenClaw) = processedTail
        let (totals4, totalsTail) = totalsTuple
        let (tCodex, tClaude, tGemini, tOpenCode) = totals4
        let (tCopilot, tDroid, tOpenClaw) = totalsTail
        let (index4, indexTail) = indexingTuple
        let (iCodex, iClaude, iGemini, iOpenCode) = index4
        let (iCopilot, iDroid, iOpenClaw) = indexTail
        let (f4, tailFlags) = flags
        let (eCodex, eClaude, eGemini, eOpenCode) = f4
        let (eCopilot, eDroid, eOpenClaw) = tailFlags

        return [
            CoreProviderSnapshot(source: .codex, enabled: eCodex, indexing: iCodex, processed: pCodex, total: tCodex),
            CoreProviderSnapshot(source: .claude, enabled: eClaude, indexing: iClaude, processed: pClaude, total: tClaude),
            CoreProviderSnapshot(source: .gemini, enabled: eGemini, indexing: iGemini, processed: pGemini, total: tGemini),
            CoreProviderSnapshot(source: .opencode, enabled: eOpenCode, indexing: iOpenCode, processed: pOpenCode, total: tOpenCode),
            CoreProviderSnapshot(source: .copilot, enabled: eCopilot, indexing: iCopilot, processed: pCopilot, total: tCopilot),
            CoreProviderSnapshot(source: .droid, enabled: eDroid, indexing: iDroid, processed: pDroid, total: tDroid),
            CoreProviderSnapshot(source: .openclaw, enabled: eOpenClaw, indexing: iOpenClaw, processed: pOpenClaw, total: tOpenClaw)
        ]
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
        if let custom = UserDefaults.standard.string(forKey: "SessionsRootOverride"),
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
        let custom = defaults.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride) ?? defaults.string(forKey: "ClaudeSessionsRootOverride") ?? ""
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

    @MainActor
    private func shouldRefreshSource(_ source: SessionSource) -> Bool {
        switch source {
        case .codex: return codexAgentEnabled && !codex.isIndexing
        case .claude: return claudeAgentEnabled && !claude.isIndexing
        case .gemini: return geminiAgentEnabled && !gemini.isIndexing
        case .opencode: return openCodeAgentEnabled && !opencode.isIndexing
        case .copilot: return copilotAgentEnabled && !copilot.isIndexing
        case .droid: return droidAgentEnabled && !droid.isIndexing
        case .openclaw: return openClawAgentEnabled && !openclaw.isIndexing
        }
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

    @MainActor
    private func focusedMonitorCapability(for source: SessionSource) -> FocusedMonitorCapability? {
        Self.focusedMonitorCapabilityBySource[source]
    }

    @MainActor
    private func refreshFocusedSession(context: FocusedSessionContext, trigger: FocusedReloadTrigger) {
        guard focusedSessionContext == context else { return }
        guard let capability = focusedMonitorCapability(for: context.source),
              capability.supportsFocusedMonitoring() else {
            return
        }
        capability.reloadFocusedSession(self, context, trigger)
    }

    @MainActor
    private func focusedFileSignature(for context: FocusedSessionContext) -> FileSignature? {
        guard let capability = focusedMonitorCapability(for: context.source),
              capability.supportsFocusedMonitoring(),
              let path = capability.signatureSource(self, context) else {
            return nil
        }
        return fileSignature(atPath: path)
    }

    @MainActor
    private func sourceAwareFocusedSignaturePath(for context: FocusedSessionContext) -> String? {
        let livePath: String?
        switch context.source {
        case .codex:
            livePath = codex.allSessions.first(where: { $0.id == context.sessionID })?.filePath
        case .claude:
            livePath = claude.allSessions.first(where: { $0.id == context.sessionID })?.filePath
        case .gemini:
            livePath = gemini.allSessions.first(where: { $0.id == context.sessionID })?.filePath
        case .opencode:
            livePath = opencode.allSessions.first(where: { $0.id == context.sessionID })?.filePath
        case .copilot:
            livePath = copilot.allSessions.first(where: { $0.id == context.sessionID })?.filePath
        case .droid:
            livePath = droid.allSessions.first(where: { $0.id == context.sessionID })?.filePath
        case .openclaw:
            livePath = openclaw.allSessions.first(where: { $0.id == context.sessionID })?.filePath
        }
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

    static func focusedSessionMonitoringSupported(for source: SessionSource) -> Bool {
        guard let capability = focusedMonitorCapabilityBySource[source] else { return false }
        return capability.supportsFocusedMonitoring()
    }

    private static func supportsFocusedSessionMonitoring(source: SessionSource) -> Bool {
        focusedSessionMonitoringSupported(for: source)
    }

    @MainActor
    private func triggerRefresh(for source: SessionSource,
                                mode: IndexRefreshMode,
                                trigger: IndexRefreshTrigger,
                                executionProfile: IndexRefreshExecutionProfile) {
        switch source {
        case .codex: codex.refresh(mode: mode, trigger: trigger, executionProfile: executionProfile)
        case .claude: claude.refresh(mode: mode, trigger: trigger, executionProfile: executionProfile)
        case .gemini: gemini.refresh(mode: mode, trigger: trigger, executionProfile: executionProfile)
        case .opencode: opencode.refresh()
        case .copilot: copilot.refresh(mode: mode, trigger: trigger, executionProfile: executionProfile)
        case .droid: droid.refresh(mode: mode, trigger: trigger, executionProfile: executionProfile)
        case .openclaw: openclaw.refresh(mode: mode, trigger: trigger, executionProfile: executionProfile)
        }
    }

    @MainActor
    private func isSourceIndexing(_ source: SessionSource) -> Bool {
        switch source {
        case .codex: return codex.isIndexing
        case .claude: return claude.isIndexing
        case .gemini: return gemini.isIndexing
        case .opencode: return opencode.isIndexing
        case .copilot: return copilot.isIndexing
        case .droid: return droid.isIndexing
        case .openclaw: return openclaw.isIndexing
        }
    }

    /// Returns the subset of currently enabled agents that support analytics.
    func enabledAnalyticsSources() -> Set<String> {
        var enabled = Set<String>()
        if codexAgentEnabled { enabled.insert("codex") }
        if claudeAgentEnabled { enabled.insert("claude") }
        if geminiAgentEnabled { enabled.insert("gemini") }
        if openCodeAgentEnabled { enabled.insert("opencode") }
        if copilotAgentEnabled { enabled.insert("copilot") }
        if droidAgentEnabled { enabled.insert("droid") }
        return enabled.intersection(Self.analyticsSupportedSources)
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
            let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
            bgQueue.async {
                let results = self.applyFiltersAndSort(to: self.allSessions)
                DispatchQueue.main.async {
                    self.sessions = results
                }
            }
        }
        recomputeDebouncer = work
        let delay: TimeInterval = FeatureFlags.increaseFilterDebounce ? 0.28 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateLaunchState() {
        var phases: [SessionSource: LaunchPhase] = [:]
        phases[.codex] = (codexAgentEnabled && includeCodex) ? codex.launchPhase : .ready
        phases[.claude] = (claudeAgentEnabled && includeClaude) ? claude.launchPhase : .ready
        phases[.gemini] = (geminiAgentEnabled && includeGemini) ? gemini.launchPhase : .ready
        phases[.opencode] = (openCodeAgentEnabled && includeOpenCode) ? opencode.launchPhase : .ready
        phases[.copilot] = (copilotAgentEnabled && includeCopilot) ? copilot.launchPhase : .ready
        phases[.droid] = (droidAgentEnabled && includeDroid) ? droid.launchPhase : .ready
        phases[.openclaw] = (openClawAgentEnabled && includeOpenClaw) ? openclaw.launchPhase : .ready

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
        if work.enablement.codex { merged.append(contentsOf: work.codexList) }
        if work.enablement.claude { merged.append(contentsOf: work.claudeList) }
        if work.enablement.gemini { merged.append(contentsOf: work.geminiList) }
        if work.enablement.openCode { merged.append(contentsOf: work.opencodeList) }
        if work.enablement.copilot { merged.append(contentsOf: work.copilotList) }
        if work.enablement.droid { merged.append(contentsOf: work.droidList) }
        if work.enablement.openClaw { merged.append(contentsOf: work.openclawList) }
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

    private func bumpFavoritesSnapshotVersion() {
        favoritesSnapshotVersion &+= 1
        favoritesAggregationVersion.send(favoritesSnapshotVersion)
    }

    /// Apply current UI filters and sort preferences to a list of sessions.
    /// Used for both unified.sessions and search results to ensure consistent filtering/sorting.
    func applyFiltersAndSort(to sessions: [Session]) -> [Session] {
        // Filter by source (Codex/Claude/Gemini/OpenCode toggles) and global agent enablement.
        let base = sessions.filter { s in
            switch s.source {
            case .codex:    return codexAgentEnabled && includeCodex
            case .claude:   return claudeAgentEnabled && includeClaude
            case .gemini:   return geminiAgentEnabled && includeGemini
            case .opencode: return openCodeAgentEnabled && includeOpenCode
            case .copilot:  return copilotAgentEnabled && includeCopilot
            case .droid:    return droidAgentEnabled && includeDroid
            case .openclaw: return openClawAgentEnabled && includeOpenClaw
            }
        }

        // Apply FilterEngine (query, date, model, kinds, project, path)
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(base, filters: filters)

        // Optional quick filter: sessions with commands (tool calls)
        if hasCommandsOnly {
            results = results.filter { s in
                // For Codex, Copilot, and OpenCode, require evidence of commands/tool calls (or lightweightCommands>0).
                if s.source == .codex || s.source == .opencode || s.source == .copilot || s.source == .droid || s.source == .openclaw {
                    if !s.events.isEmpty {
                        return s.events.contains { $0.kind == .tool_call }
                    } else {
                        return (s.lightweightCommands ?? 0) > 0
                    }
                }
                // For Claude and Gemini, treat sessions as command-bearing only when we see tool_call events.
                if s.source == .claude || s.source == .gemini {
                    if s.events.isEmpty { return false }
                    return s.events.contains { $0.kind == .tool_call }
                }
                return true
            }
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
                return s.messageCount > 0
            }
        }
        if hideLowMessageSessionsPref {
            results = results.filter { s in
                if s.source == .opencode { return true }
                return s.messageCount == 0 || s.messageCount > 2
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
            return list.sorted { lhs, rhs in
                let l = lhs.repoDisplay.lowercased(); let r = rhs.repoDisplay.lowercased()
                return descriptor.ascending ? (l, lhs.id) < (r, rhs.id) : (l, lhs.id) > (r, rhs.id)
            }
        case .title:
            return list.sorted { lhs, rhs in
                let l = lhs.title.lowercased(); let r = rhs.title.lowercased()
                return descriptor.ascending ? (l, lhs.id) < (r, rhs.id) : (l, lhs.id) > (r, rhs.id)
            }
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

        static let idle = LaunchState(
            sourcePhases: [.codex: .idle, .claude: .idle, .gemini: .idle, .opencode: .idle, .copilot: .idle, .droid: .idle, .openclaw: .idle],
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

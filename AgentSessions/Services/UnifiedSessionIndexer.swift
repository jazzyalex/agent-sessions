import Foundation
import Combine
import SwiftUI
#if os(macOS)
import IOKit.ps
#endif

/// Aggregates Codex and Claude sessions into a single list with unified filters and search.
final class UnifiedSessionIndexer: ObservableObject {
    private struct FileSignature: Equatable {
        let path: String
        let modifiedAt: Date
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
        init(defaults: UserDefaults = .standard) {
            store = StarredSessionsStore(defaults: defaults)
        }
        private(set) var store: StarredSessionsStore
        func contains(id: String, source: SessionSource) -> Bool { store.contains(id: id, source: source) }
        mutating func toggle(id: String, source: SessionSource) -> Bool { store.toggle(id: id, source: source) }
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
    @Published private(set) var openClawAgentEnabled: Bool = AgentEnablement.isEnabled(.openclaw)

    // Sorting
    struct SessionSortDescriptor: Equatable { let key: Key; let ascending: Bool; enum Key { case modified, msgs, repo, title, agent, size } }
    @Published var sortDescriptor: SessionSortDescriptor = .init(key: .modified, ascending: false)

    // Indexing state aggregation
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var isProcessingTranscripts: Bool = false
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
    private var cancellables = Set<AnyCancellable>()
    private var favorites = FavoritesStore()
    private var hasPublishedInitialSessions = false
    @Published private(set) var isAnalyticsIndexing: Bool = false
    private var lastAnalyticsRefreshStartedAt: Date? = nil
    private var pendingAnalyticsSources: Set<String> = []
    private let analyticsRefreshTTLSeconds: TimeInterval = 5 * 60  // 5 minutes
    private let analyticsStartDelaySeconds: TimeInterval = 2.0     // small delay to avoid launch contention
    private let providerRefreshCoordinator = ProviderRefreshCoordinator(coalesceWindowSeconds: 10)
    private let newSessionMonitorIntervalSeconds: UInt64 = 60
    private var newSessionMonitorTask: Task<Void, Never>? = nil
    private var lastSeenCodexSignature: FileSignature? = nil
    private var lastSeenClaudeSignature: FileSignature? = nil
    private var hasInitializedNewSessionMonitorBaseline: Bool = false
    private var appIsActive: Bool = false
    private var lastFullReconcileBySource: [SessionSource: Date] = [:]
    private let manualFullFallbackIntervalSeconds: TimeInterval = 15 * 60

    // Debouncing for expensive operations
    private var recomputeDebouncer: DispatchWorkItem? = nil
    
    // Auto-refresh recency guards (per provider)
    private var lastAutoRefreshCodex: Date? = nil
    private var lastAutoRefreshClaude: Date? = nil
    private var lastAutoRefreshGemini: Date? = nil
    private var lastAutoRefreshOpenCode: Date? = nil
    private var lastAutoRefreshCopilot: Date? = nil
    private var lastAutoRefreshDroid: Date? = nil
    private var lastAutoRefreshOpenClaw: Date? = nil

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

        syncAgentEnablementFromDefaults()
        // Observe UserDefaults changes to sync external toggles (Preferences) to this model
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            guard let self else { return }
            let v = UserDefaults.standard.bool(forKey: "UnifiedHasCommandsOnly")
            if v != self.hasCommandsOnly { self.hasCommandsOnly = v }
            self.syncAgentEnablementFromDefaults()
        }

        // Merge underlying allSessions whenever any changes
        Publishers.CombineLatest(
            Publishers.CombineLatest4(codex.$allSessions, claude.$allSessions, gemini.$allSessions, opencode.$allSessions),
            Publishers.CombineLatest3(copilot.$allSessions, droid.$allSessions, openclaw.$allSessions)
        )
            .map { [weak self] combined, tail -> [Session] in
                guard let self else { return [] }
                let (codexList, claudeList, geminiList, opencodeList) = combined
                let (copilotList, droidList, openclawList) = tail
                var merged: [Session] = []
                if self.codexAgentEnabled { merged.append(contentsOf: codexList) }
                if self.claudeAgentEnabled { merged.append(contentsOf: claudeList) }
                if self.geminiAgentEnabled { merged.append(contentsOf: geminiList) }
                if self.openCodeAgentEnabled { merged.append(contentsOf: opencodeList) }
                if self.copilotAgentEnabled { merged.append(contentsOf: copilotList) }
                if self.droidAgentEnabled { merged.append(contentsOf: droidList) }
                if self.openClawAgentEnabled { merged.append(contentsOf: openclawList) }
                for i in merged.indices { merged[i].isFavorite = self.favorites.contains(id: merged[i].id, source: merged[i].source) }
                return merged.sorted { lhs, rhs in
                    if lhs.modifiedAt == rhs.modifiedAt { return lhs.id > rhs.id }
                    return lhs.modifiedAt > rhs.modifiedAt
                }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.publishAfterCurrentUpdate { [weak self] in
                    self?.allSessions = value
                }
            }
            .store(in: &cancellables)

        let agentEnabledFlags = Publishers.CombineLatest(
            Publishers.CombineLatest4($codexAgentEnabled, $claudeAgentEnabled, $geminiAgentEnabled, $openCodeAgentEnabled),
            Publishers.CombineLatest3($copilotAgentEnabled, $droidAgentEnabled, $openClawAgentEnabled)
        )

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

        // Auto-refresh providers when toggled ON (10s recency guard, debounced)
        $includeCodex
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.maybeAutoRefreshCodex() }
            }
            .store(in: &cancellables)

        $includeClaude
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.maybeAutoRefreshClaude() }
            }
            .store(in: &cancellables)

        $includeGemini
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.maybeAutoRefreshGemini() }
            }
            .store(in: &cancellables)

        $includeOpenCode
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.maybeAutoRefreshOpenCode() }
            }
            .store(in: &cancellables)

        $includeCopilot
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.maybeAutoRefreshCopilot() }
            }
            .store(in: &cancellables)

        $includeDroid
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.maybeAutoRefreshDroid() }
            }
            .store(in: &cancellables)

        $includeOpenClaw
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.maybeAutoRefreshOpenClaw() }
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

        // When probe cleanups succeed, refresh underlying providers and analytics rollups
        NotificationCenter.default.addObserver(forName: CodexProbeCleanup.didRunCleanupNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let info = note.userInfo as? [String: Any], let status = info["status"] as? String, status == "success" {
                self.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: ClaudeProbeProject.didRunCleanupNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let info = note.userInfo as? [String: Any], let status = info["status"] as? String, status == "success" {
                self.refresh()
            }
        }
    }

    private func syncAgentEnablementFromDefaults(defaults: UserDefaults = .standard) {
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
    }

    func refresh() {
        LaunchProfiler.log("Unified.refresh: request enqueued")
        requestProviderRefresh(source: .codex, reason: "unified-refresh", trigger: .manual)
        requestProviderRefresh(source: .claude, reason: "unified-refresh", trigger: .manual)
        requestProviderRefresh(source: .gemini, reason: "unified-refresh", trigger: .manual)
        requestProviderRefresh(source: .opencode, reason: "unified-refresh", trigger: .manual)
        requestProviderRefresh(source: .copilot, reason: "unified-refresh", trigger: .manual)
        requestProviderRefresh(source: .droid, reason: "unified-refresh", trigger: .manual)
        requestProviderRefresh(source: .openclaw, reason: "unified-refresh", trigger: .manual)
    }

    @MainActor
    func setAppActive(_ active: Bool) {
        appIsActive = active
        if active {
            guard newSessionMonitorTask == nil else { return }
            let task = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.runNewSessionMonitorLoop()
            }
            newSessionMonitorTask = task
        } else {
            newSessionMonitorTask?.cancel()
            newSessionMonitorTask = nil
        }
    }

    private func runNewSessionMonitorLoop() async {
        await checkForNewSessions(establishBaselineIfNeeded: true)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: newSessionMonitorIntervalSeconds * 1_000_000_000)
            if Task.isCancelled { break }
            await checkForNewSessions()
        }
    }

    private func checkForNewSessions(establishBaselineIfNeeded: Bool = false) async {
        let codexSignature = detectLatestCodexSignature()
        let claudeSignature = detectLatestClaudeSignature()
        await MainActor.run { [weak self] in
            guard let self else { return }
            if establishBaselineIfNeeded && !self.hasInitializedNewSessionMonitorBaseline {
                self.lastSeenCodexSignature = codexSignature
                self.lastSeenClaudeSignature = claudeSignature
                self.hasInitializedNewSessionMonitorBaseline = true
                return
            }
            if !self.hasInitializedNewSessionMonitorBaseline {
                self.hasInitializedNewSessionMonitorBaseline = true
            }

            if codexSignature != self.lastSeenCodexSignature {
                self.lastSeenCodexSignature = codexSignature
                if codexSignature != nil {
                    self.requestProviderRefresh(source: .codex, reason: "foreground-new-session", trigger: .monitor)
                }
            }
            if claudeSignature != self.lastSeenClaudeSignature {
                self.lastSeenClaudeSignature = claudeSignature
                if claudeSignature != nil {
                    self.requestProviderRefresh(source: .claude, reason: "foreground-new-session", trigger: .monitor)
                }
            }
        }
    }

    private func detectLatestCodexSignature() -> FileSignature? {
        let root = codexSessionsRoot()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        var newest: FileSignature? = nil

        for offset in 0...1 {
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
        var newest: FileSignature? = nil

        for directory in directories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(at: directory,
                                                 includingPropertiesForKeys: Array(keys),
                                                 options: [.skipsHiddenFiles]) else {
                continue
            }

            var visited = 0
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { continue }
                visited += 1
                if visited > fileLimitPerDirectory { break }
                let ext = file.pathExtension.lowercased()
                guard ext == "jsonl" || ext == "ndjson" else { continue }
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
        let context = await MainActor.run { [weak self] in
            guard let self else {
                return (didTrigger: false,
                        requestGlobalAnalytics: false)
            }
            guard self.shouldRefreshSource(source) else {
                return (didTrigger: false,
                        requestGlobalAnalytics: false)
            }
            let mode = self.refreshMode(for: source, trigger: trigger)
            let executionProfile = self.refreshExecutionProfile(for: source)
            LaunchProfiler.log("Unified.refresh[\(source.rawValue)]: trigger (\(reason), mode=\(mode), trigger=\(trigger.rawValue))")
            self.triggerRefresh(for: source, mode: mode, trigger: trigger, executionProfile: executionProfile)
            let shouldRunGlobalAnalytics = source != .codex && source != .claude
            return (didTrigger: true,
                    requestGlobalAnalytics: shouldRunGlobalAnalytics)
        }
        guard context.didTrigger else { return }

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

        if context.requestGlobalAnalytics {
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.requestAnalyticsRefreshIfNeeded(enabledSourcesOverride: [source.rawValue])
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
        guard source == .codex || source == .claude else { return .incremental }
        guard trigger == .manual else { return .incremental }
        let now = Date()
        guard let last = lastFullReconcileBySource[source] else {
            lastFullReconcileBySource[source] = now
            return .incremental
        }
        if now.timeIntervalSince(last) >= manualFullFallbackIntervalSeconds {
            lastFullReconcileBySource[source] = now
            return .fullReconcile
        }
        return .incremental
    }

    @MainActor
    private func refreshExecutionProfile(for source: SessionSource) -> IndexRefreshExecutionProfile {
        let onAC = Self.onACPower()
        let isHighVolumeProvider = (source == .codex || source == .claude)

        if isHighVolumeProvider && appIsActive && onAC {
            return .interactive
        }
        if isHighVolumeProvider && appIsActive && !onAC {
            return IndexRefreshExecutionProfile(
                workerCount: 1,
                sliceSize: 6,
                interSliceYieldNanoseconds: 50_000_000,
                deferNonCriticalWork: true
            )
        }
        if isHighVolumeProvider {
            return .lightBackground
        }

        if appIsActive && onAC {
            return IndexRefreshExecutionProfile(
                workerCount: 1,
                sliceSize: 8,
                interSliceYieldNanoseconds: 20_000_000,
                deferNonCriticalWork: false
            )
        }
        if appIsActive && !onAC {
            return IndexRefreshExecutionProfile(
                workerCount: 1,
                sliceSize: 6,
                interSliceYieldNanoseconds: 60_000_000,
                deferNonCriticalWork: true
            )
        }
        return .lightBackground
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

    @MainActor
    private func requestAnalyticsRefreshIfNeeded(enabledSourcesOverride: Set<String>? = nil) {
        let enabledSources: Set<String> = {
            let effective = enabledSourcesOverride ?? {
                var s: Set<String> = []
                if codexAgentEnabled { s.insert("codex") }
                if claudeAgentEnabled { s.insert("claude") }
                if geminiAgentEnabled { s.insert("gemini") }
                if openCodeAgentEnabled { s.insert("opencode") }
                if copilotAgentEnabled { s.insert("copilot") }
                if droidAgentEnabled { s.insert("droid") }
                if openClawAgentEnabled { s.insert("openclaw") }
                return s
            }()
            var filtered: Set<String> = []
            if codexAgentEnabled && effective.contains("codex") { filtered.insert("codex") }
            if claudeAgentEnabled && effective.contains("claude") { filtered.insert("claude") }
            if geminiAgentEnabled && effective.contains("gemini") { filtered.insert("gemini") }
            if openCodeAgentEnabled && effective.contains("opencode") { filtered.insert("opencode") }
            if copilotAgentEnabled && effective.contains("copilot") { filtered.insert("copilot") }
            if droidAgentEnabled && effective.contains("droid") { filtered.insert("droid") }
            if openClawAgentEnabled && effective.contains("openclaw") { filtered.insert("openclaw") }
            return filtered
        }()
        if enabledSources.isEmpty {
            return
        }

        if isAnalyticsIndexing {
            pendingAnalyticsSources.formUnion(enabledSources)
            return
        }

        let now = Date()
        if let last = lastAnalyticsRefreshStartedAt,
           now.timeIntervalSince(last) < analyticsRefreshTTLSeconds {
            LaunchProfiler.log("Unified.refresh: Analytics refresh skipped (within TTL)")
            return
        }

        lastAnalyticsRefreshStartedAt = now
        isAnalyticsIndexing = true
        let delaySeconds = analyticsStartDelaySeconds

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAnalyticsIndexing = false
                    if !self.pendingAnalyticsSources.isEmpty {
                        let pending = self.pendingAnalyticsSources
                        self.pendingAnalyticsSources.removeAll()
                        self.requestAnalyticsRefreshIfNeeded(enabledSourcesOverride: pending)
                    }
                }
            }
            do {
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
                LaunchProfiler.log("Unified.refresh: Analytics warmup (open IndexDB)")
                let db = try IndexDB()
                let indexer = AnalyticsIndexer(db: db, enabledSources: enabledSources)
                if try await db.isEmpty() {
                    LaunchProfiler.log("Unified.refresh: Analytics fullBuild start")
                    await indexer.fullBuild()
                    LaunchProfiler.log("Unified.refresh: Analytics fullBuild complete")
                } else {
                    LaunchProfiler.log("Unified.refresh: Analytics refresh start")
                    await indexer.refresh()
                    LaunchProfiler.log("Unified.refresh: Analytics refresh complete")
                }
            } catch {
                #if DEBUG
                print("[Indexing] Analytics refresh failed: \(error)")
                #endif
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

    // MARK: - Auto-refresh helpers
    private func withinGuard(_ last: Date?) -> Bool {
        guard let last else { return false }
        return Date().timeIntervalSince(last) < 10.0
    }

    private func maybeAutoRefreshCodex() {
        if !codexAgentEnabled { return }
        if codex.isIndexing { return }
        if withinGuard(lastAutoRefreshCodex) { return }
        lastAutoRefreshCodex = Date()
        requestProviderRefresh(source: .codex, reason: "provider-enabled", trigger: .providerEnabled)
    }

    private func maybeAutoRefreshClaude() {
        if !claudeAgentEnabled { return }
        if claude.isIndexing { return }
        if withinGuard(lastAutoRefreshClaude) { return }
        lastAutoRefreshClaude = Date()
        requestProviderRefresh(source: .claude, reason: "provider-enabled", trigger: .providerEnabled)
    }

    private func maybeAutoRefreshGemini() {
        if !geminiAgentEnabled { return }
        if gemini.isIndexing { return }
        if withinGuard(lastAutoRefreshGemini) { return }
        lastAutoRefreshGemini = Date()
        requestProviderRefresh(source: .gemini, reason: "provider-enabled", trigger: .providerEnabled)
    }
    private func maybeAutoRefreshOpenCode() {
        if !openCodeAgentEnabled { return }
        if opencode.isIndexing { return }
        if withinGuard(lastAutoRefreshOpenCode) { return }
        lastAutoRefreshOpenCode = Date()
        requestProviderRefresh(source: .opencode, reason: "provider-enabled", trigger: .providerEnabled)
    }

    private func maybeAutoRefreshCopilot() {
        if !copilotAgentEnabled { return }
        if copilot.isIndexing { return }
        if withinGuard(lastAutoRefreshCopilot) { return }
        lastAutoRefreshCopilot = Date()
        requestProviderRefresh(source: .copilot, reason: "provider-enabled", trigger: .providerEnabled)
    }

    private func maybeAutoRefreshDroid() {
        if !droidAgentEnabled { return }
        if droid.isIndexing { return }
        if withinGuard(lastAutoRefreshDroid) { return }
        lastAutoRefreshDroid = Date()
        requestProviderRefresh(source: .droid, reason: "provider-enabled", trigger: .providerEnabled)
    }

    private func maybeAutoRefreshOpenClaw() {
        if !openClawAgentEnabled { return }
        if openclaw.isIndexing { return }
        if withinGuard(lastAutoRefreshOpenClaw) { return }
        lastAutoRefreshOpenClaw = Date()
        requestProviderRefresh(source: .openclaw, reason: "provider-enabled", trigger: .providerEnabled)
    }

    // MARK: - Favorites
    func toggleFavorite(_ session: Session) {
        let nowStarred = favorites.toggle(id: session.id, source: session.source)
        if let idx = allSessions.firstIndex(where: { $0.id == session.id && $0.source == session.source }) {
            allSessions[idx].isFavorite = nowStarred
        }

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
            let nowStarred = favorites.toggle(id: id, source: source)
            if !nowStarred {
                let removeArchive = UserDefaults.standard.bool(forKey: PreferencesKey.Archives.unstarRemovesArchive)
                SessionArchiveManager.shared.unstarred(source: source, id: id, removeArchive: removeArchive)
            }
            recomputeNow()
        }
    }

    deinit {
        newSessionMonitorTask?.cancel()
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

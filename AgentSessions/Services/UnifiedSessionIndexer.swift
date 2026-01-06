import Foundation
import Combine
import SwiftUI

/// Aggregates Codex and Claude sessions into a single list with unified filters and search.
final class UnifiedSessionIndexer: ObservableObject {
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

    // Global agent enablement (drives app-wide availability)
    @Published private(set) var codexAgentEnabled: Bool = AgentEnablement.isEnabled(.codex)
    @Published private(set) var claudeAgentEnabled: Bool = AgentEnablement.isEnabled(.claude)
    @Published private(set) var geminiAgentEnabled: Bool = AgentEnablement.isEnabled(.gemini)
    @Published private(set) var openCodeAgentEnabled: Bool = AgentEnablement.isEnabled(.opencode)
    @Published private(set) var copilotAgentEnabled: Bool = AgentEnablement.isEnabled(.copilot)
    @Published private(set) var droidAgentEnabled: Bool = AgentEnablement.isEnabled(.droid)

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

    private let codex: SessionIndexer
    private let claude: ClaudeSessionIndexer
    private let gemini: GeminiSessionIndexer
    private let opencode: OpenCodeSessionIndexer
    private let copilot: CopilotSessionIndexer
    private let droid: DroidSessionIndexer
    private var cancellables = Set<AnyCancellable>()
    private var favorites = FavoritesStore()
    private var hasPublishedInitialSessions = false
    @Published private(set) var isAnalyticsIndexing: Bool = false
    private var lastRefreshStartedAt: Date? = nil
    private var lastAnalyticsRefreshStartedAt: Date? = nil
    private let analyticsRefreshTTLSeconds: TimeInterval = 5 * 60  // 5 minutes
    private let analyticsStartDelaySeconds: TimeInterval = 2.0     // small delay to avoid launch contention

    // Periodic Codex search-corpus warmup while the app is open.
    // Keeps the actively updating session searchable without manual refresh.
    private var codexSearchWarmupTimer: DispatchSourceTimer? = nil
    private var codexSearchWarmupTask: Task<Void, Never>? = nil
    private var lastCodexSearchWarmupStartedAt: Date? = nil
    private let codexSearchWarmupIntervalSeconds: TimeInterval = 20
    private let codexSearchWarmupTTLSeconds: TimeInterval = 20

    // Debouncing for expensive operations
    private var recomputeDebouncer: DispatchWorkItem? = nil
    
    // Auto-refresh recency guards (per provider)
    private var lastAutoRefreshCodex: Date? = nil
    private var lastAutoRefreshClaude: Date? = nil
    private var lastAutoRefreshGemini: Date? = nil
    private var lastAutoRefreshOpenCode: Date? = nil
    private var lastAutoRefreshCopilot: Date? = nil
    private var lastAutoRefreshDroid: Date? = nil

    init(codexIndexer: SessionIndexer,
         claudeIndexer: ClaudeSessionIndexer,
         geminiIndexer: GeminiSessionIndexer,
         opencodeIndexer: OpenCodeSessionIndexer,
         copilotIndexer: CopilotSessionIndexer,
         droidIndexer: DroidSessionIndexer) {
        self.codex = codexIndexer
        self.claude = claudeIndexer
        self.gemini = geminiIndexer
        self.opencode = opencodeIndexer
        self.copilot = copilotIndexer
        self.droid = droidIndexer

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
            Publishers.CombineLatest(copilot.$allSessions, droid.$allSessions)
        )
            .map { [weak self] combined, tail -> [Session] in
                guard let self else { return [] }
                let (codexList, claudeList, geminiList, opencodeList) = combined
                let (copilotList, droidList) = tail
                var merged: [Session] = []
                if self.codexAgentEnabled { merged.append(contentsOf: codexList) }
                if self.claudeAgentEnabled { merged.append(contentsOf: claudeList) }
                if self.geminiAgentEnabled { merged.append(contentsOf: geminiList) }
                if self.openCodeAgentEnabled { merged.append(contentsOf: opencodeList) }
                if self.copilotAgentEnabled { merged.append(contentsOf: copilotList) }
                if self.droidAgentEnabled { merged.append(contentsOf: droidList) }
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
            Publishers.CombineLatest($copilotAgentEnabled, $droidAgentEnabled)
        )

        // isIndexing reflects any enabled indexer working
        Publishers.CombineLatest(
            Publishers.CombineLatest4(codex.$isIndexing, claude.$isIndexing, gemini.$isIndexing, opencode.$isIndexing),
            Publishers.CombineLatest(copilot.$isIndexing, droid.$isIndexing)
        )
            .combineLatest(agentEnabledFlags)
            .map { states, flags in
                let (s4, tailStates) = states
                let (c, cl, g, o) = s4
                let (copilotState, droidState) = tailStates
                let (f4, tailFlags) = flags
                let (ec, ecl, eg, eo) = f4
                let (eCopilot, eDroid) = tailFlags
                return (ec && c) || (ecl && cl) || (eg && g) || (eo && o) || (eCopilot && copilotState) || (eDroid && droidState)
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
            Publishers.CombineLatest(copilot.$isProcessingTranscripts, droid.$isProcessingTranscripts)
        )
            .combineLatest(agentEnabledFlags)
            .map { states, flags in
                let (s4, tailStates) = states
                let (c, cl, g, o) = s4
                let (copilotState, droidState) = tailStates
                let (f4, tailFlags) = flags
                let (ec, ecl, eg, eo) = f4
                let (eCopilot, eDroid) = tailFlags
                return (ec && c) || (ecl && cl) || (eg && g) || (eo && o) || (eCopilot && copilotState) || (eDroid && droidState)
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
            Publishers.CombineLatest(copilot.$indexingError, droid.$indexingError)
        )
            .combineLatest(agentEnabledFlags)
            .map { errs, flags in
                let (errs4, tailErrs) = errs
                let (codexErr, claudeErr, geminiErr, opencodeErr) = errs4
                let (copilotErr, droidErr) = tailErrs
                let (f4, tailFlags) = flags
                let (ec, ecl, eg, eo) = f4
                let a = ec ? codexErr : nil
                let b = ecl ? claudeErr : nil
                let c = eg ? geminiErr : nil
                let d = eo ? opencodeErr : nil
                let (eCopilot, eDroid) = tailFlags
                let e = eCopilot ? copilotErr : nil
                let f = eDroid ? droidErr : nil
                return a ?? b ?? c ?? d ?? e ?? f
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
            Publishers.CombineLatest($includeCopilot, $includeDroid)
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
                let (incCopilot, incDroid) = tailSources
                let (en4, tailEnabled) = enabledFlags
                let (enCodex, enClaude, enGemini, enOpenCode) = en4
                let (enCopilot, enDroid) = tailEnabled
                let effectiveCodex = incCodex && enCodex
                let effectiveClaude = incClaude && enClaude
                let effectiveGemini = incGemini && enGemini
                let effectiveOpenCode = incOpenCode && enOpenCode
                let effectiveCopilot = incCopilot && enCopilot
                let effectiveDroid = incDroid && enDroid

                // Start from all sessions, then apply the same filters we use elsewhere.
                var base = all
                if !(effectiveCodex && effectiveClaude && effectiveGemini && effectiveOpenCode && effectiveCopilot && effectiveDroid) {
                    base = base.filter { s in
                        (s.source == .codex && effectiveCodex) ||
                        (s.source == .claude && effectiveClaude) ||
                        (s.source == .gemini && effectiveGemini) ||
                        (s.source == .opencode && effectiveOpenCode) ||
                        (s.source == .copilot && effectiveCopilot) ||
                        (s.source == .droid && effectiveDroid)
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
                if self.hideLowMessageSessionsPref { results = results.filter { $0.messageCount > 2 } }

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

        Publishers.CombineLatest(Publishers.CombineLatest4(codex.$launchPhase, claude.$launchPhase, gemini.$launchPhase, opencode.$launchPhase),
                                Publishers.CombineLatest(copilot.$launchPhase, droid.$launchPhase))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateLaunchState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            Publishers.CombineLatest4($includeCodex, $includeClaude, $includeGemini, $includeOpenCode),
            Publishers.CombineLatest($includeCopilot, $includeDroid)
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateLaunchState()
            }
            .store(in: &cancellables)

        updateLaunchState()
        startCodexSearchWarmupTimerIfNeeded()

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

    private func startCodexSearchWarmupTimerIfNeeded() {
        guard codexSearchWarmupTimer == nil else { return }
        let queue = DispatchQueue.global(qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + codexSearchWarmupIntervalSeconds,
                       repeating: codexSearchWarmupIntervalSeconds,
                       leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.kickCodexSearchWarmupIfNeeded()
            }
        }
        timer.resume()
        codexSearchWarmupTimer = timer
    }

    @MainActor
    private func kickCodexSearchWarmupIfNeeded() {
        guard codexAgentEnabled, includeCodex else { return }
        if codex.isIndexing { return }
        guard codexSearchWarmupTask == nil else { return }

        let now = Date()
        if let last = lastCodexSearchWarmupStartedAt, now.timeIntervalSince(last) < codexSearchWarmupTTLSeconds {
            return
        }
        lastCodexSearchWarmupStartedAt = now

        codexSearchWarmupTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.codexSearchWarmupTask = nil } }
            do {
                let db = try IndexDB()
                let indexer = AnalyticsIndexer(db: db, enabledSources: ["codex"])
                await indexer.refresh()
            } catch {
                // Non-fatal: search warmup is best-effort.
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
        if c1 != codexAgentEnabled { codexAgentEnabled = c1 }
        if c2 != claudeAgentEnabled { claudeAgentEnabled = c2 }
        if c3 != geminiAgentEnabled { geminiAgentEnabled = c3 }
        if c4 != openCodeAgentEnabled { openCodeAgentEnabled = c4 }
        if c5 != copilotAgentEnabled { copilotAgentEnabled = c5 }
        if c6 != droidAgentEnabled { droidAgentEnabled = c6 }
    }

    func refresh() {
        // Guard against rapid consecutive refreshes (e.g., from probe cleanup
        // or other background notifications) to avoid re-running Stage 1 and
        // transcript prewarm immediately after launch.
        let now = Date()
        if let last = lastRefreshStartedAt, now.timeIntervalSince(last) < 15 {
            LaunchProfiler.log("Unified.refresh: skipped (within 15s guard)")
            return
        }
        lastRefreshStartedAt = now

        // Stage 1: kick off per-source fast metadata hydration in parallel.
        // Each indexer is internally serial and already hydrates from IndexDB.session_meta
        // before scanning for new files, so starting them together is safe.
        LaunchProfiler.log("Unified.refresh: Stage 1 (per-source) start")
        let shouldRefreshCodex = codexAgentEnabled && includeCodex && !codex.isIndexing
        let shouldRefreshClaude = claudeAgentEnabled && includeClaude && !claude.isIndexing
        let shouldRefreshGemini = geminiAgentEnabled && includeGemini && !gemini.isIndexing
        let shouldRefreshOpenCode = openCodeAgentEnabled && includeOpenCode && !opencode.isIndexing
        let shouldRefreshCopilot = copilotAgentEnabled && includeCopilot && !copilot.isIndexing
        let shouldRefreshDroid = droidAgentEnabled && includeDroid && !droid.isIndexing

        if shouldRefreshCodex { codex.refresh() }
        if shouldRefreshClaude { claude.refresh() }
        if shouldRefreshGemini { gemini.refresh() }
        if shouldRefreshOpenCode { opencode.refresh() }
        if shouldRefreshCopilot { copilot.refresh() }
        if shouldRefreshDroid { droid.refresh() }

        // Stage 2: analytics enrichment (non-blocking, runs after hydration has begun).
        // Use a simple gate and TTL so only one analytics index run happens at a time
        // and we avoid re-walking the entire corpus on every refresh.
        if !isAnalyticsIndexing {
            let now = Date()
            if let last = lastAnalyticsRefreshStartedAt,
               now.timeIntervalSince(last) < analyticsRefreshTTLSeconds {
                LaunchProfiler.log("Unified.refresh: Analytics refresh skipped (within TTL)")
            } else {
                lastAnalyticsRefreshStartedAt = now
                isAnalyticsIndexing = true
                let delaySeconds = analyticsStartDelaySeconds
                Task.detached(priority: FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated) { [weak self] in
                    guard let self else { return }
                    defer {
                        Task { @MainActor [weak self] in self?.isAnalyticsIndexing = false }
                    }
                    do {
                        if delaySeconds > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        }
                        LaunchProfiler.log("Unified.refresh: Analytics warmup (open IndexDB)")
                        let db = try IndexDB()
                        let enabledSources: Set<String> = {
                            var s: Set<String> = []
                            if self.codexAgentEnabled { s.insert("codex") }
                            if self.claudeAgentEnabled { s.insert("claude") }
                            if self.geminiAgentEnabled { s.insert("gemini") }
                            if self.openCodeAgentEnabled { s.insert("opencode") }
                            if self.copilotAgentEnabled { s.insert("copilot") }
                            if self.droidAgentEnabled { s.insert("droid") }
                            return s
                        }()
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
                        // Silent failure: analytics are additive and optional for core UX.
                        #if DEBUG
                        print("[Indexing] Analytics refresh failed: \(error)")
                        #endif
                    }
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
            DispatchQueue.main.async {
                Task { @MainActor in
                    work()
                }
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
            }
        }

        // Apply FilterEngine (query, date, model, kinds, project, path)
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(base, filters: filters)

        // Optional quick filter: sessions with commands (tool calls)
        if hasCommandsOnly {
            results = results.filter { s in
                // For Codex, Copilot, and OpenCode, require evidence of commands/tool calls (or lightweightCommands>0).
                if s.source == .codex || s.source == .opencode || s.source == .copilot || s.source == .droid {
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
                // Default: keep other sources (none today).
                return true
            }
        }


        // Favorites-only filter (AND with text search)
        if showFavoritesOnly { results = results.filter { $0.isFavorite } }

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
                return s.messageCount > 2
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
        codex.refresh()
    }

    private func maybeAutoRefreshClaude() {
        if !claudeAgentEnabled { return }
        if claude.isIndexing { return }
        if withinGuard(lastAutoRefreshClaude) { return }
        lastAutoRefreshClaude = Date()
        claude.refresh()
    }

    private func maybeAutoRefreshGemini() {
        if !geminiAgentEnabled { return }
        if gemini.isIndexing { return }
        if withinGuard(lastAutoRefreshGemini) { return }
        lastAutoRefreshGemini = Date()
        gemini.refresh()
    }
    private func maybeAutoRefreshOpenCode() {
        if !openCodeAgentEnabled { return }
        if opencode.isIndexing { return }
        if withinGuard(lastAutoRefreshOpenCode) { return }
        lastAutoRefreshOpenCode = Date()
        opencode.refresh()
    }

    private func maybeAutoRefreshCopilot() {
        if !copilotAgentEnabled { return }
        if copilot.isIndexing { return }
        if withinGuard(lastAutoRefreshCopilot) { return }
        lastAutoRefreshCopilot = Date()
        copilot.refresh()
    }

    private func maybeAutoRefreshDroid() {
        if !droidAgentEnabled { return }
        if droid.isIndexing { return }
        if withinGuard(lastAutoRefreshDroid) { return }
        lastAutoRefreshDroid = Date()
        droid.refresh()
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
}
    struct LaunchState {
        let sourcePhases: [SessionSource: LaunchPhase]
        let overallPhase: LaunchPhase
        let blockingSources: [SessionSource]
        let hasDisplayedSessions: Bool

        static let idle = LaunchState(
            sourcePhases: [.codex: .idle, .claude: .idle, .gemini: .idle, .opencode: .idle, .copilot: .idle, .droid: .idle],
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

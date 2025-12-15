import Foundation
import Combine
import SwiftUI

/// Aggregates Codex and Claude sessions into a single list with unified filters and search.
final class UnifiedSessionIndexer: ObservableObject {
    // Lightweight favorites store (UserDefaults overlay)
    struct FavoritesStore {
        static let key = "favoriteSessionIDs"
        private(set) var ids: Set<String>
        private let defaults: UserDefaults
        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
        }
        func contains(_ id: String) -> Bool { ids.contains(id) }
        mutating func toggle(_ id: String) { if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }; persist() }
        mutating func add(_ id: String) { ids.insert(id); persist() }
        mutating func remove(_ id: String) { ids.remove(id); persist() }
        private func persist() { defaults.set(Array(ids), forKey: Self.key) }
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

    // Sorting
    struct SessionSortDescriptor: Equatable { let key: Key; let ascending: Bool; enum Key { case modified, msgs, repo, title, agent } }
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
    private var cancellables = Set<AnyCancellable>()
    private var favorites = FavoritesStore()
    private var hasPublishedInitialSessions = false
    @Published private(set) var isAnalyticsIndexing: Bool = false
    private var lastRefreshStartedAt: Date? = nil
    private var lastAnalyticsRefreshStartedAt: Date? = nil
    private let analyticsRefreshTTLSeconds: TimeInterval = 5 * 60  // 5 minutes
    private let analyticsStartDelaySeconds: TimeInterval = 2.0     // small delay to avoid launch contention

    // Debouncing for expensive operations
    private var recomputeDebouncer: DispatchWorkItem? = nil
    
    // Auto-refresh recency guards (per provider)
    private var lastAutoRefreshCodex: Date? = nil
    private var lastAutoRefreshClaude: Date? = nil
    private var lastAutoRefreshGemini: Date? = nil
    private var lastAutoRefreshOpenCode: Date? = nil

    init(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, geminiIndexer: GeminiSessionIndexer, opencodeIndexer: OpenCodeSessionIndexer) {
        self.codex = codexIndexer
        self.claude = claudeIndexer
        self.gemini = geminiIndexer
        self.opencode = opencodeIndexer
        // Observe UserDefaults changes to sync external toggles (Preferences) to this model
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            guard let self else { return }
            let v = UserDefaults.standard.bool(forKey: "UnifiedHasCommandsOnly")
            if v != self.hasCommandsOnly { self.hasCommandsOnly = v }
        }

        // Merge underlying allSessions whenever any changes
        Publishers.CombineLatest4(codex.$allSessions, claude.$allSessions, gemini.$allSessions, opencode.$allSessions)
            .map { [weak self] codexList, claudeList, geminiList, opencodeList -> [Session] in
                var merged = codexList + claudeList + geminiList + opencodeList
                if let favs = self?.favorites {
                    for i in merged.indices { merged[i].isFavorite = favs.contains(merged[i].id) }
                }
                return merged.sorted { lhs, rhs in
                    if lhs.modifiedAt == rhs.modifiedAt { return lhs.id > rhs.id }
                    return lhs.modifiedAt > rhs.modifiedAt
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$allSessions)

        // isIndexing reflects any indexer working
        Publishers.CombineLatest4(codex.$isIndexing, claude.$isIndexing, gemini.$isIndexing, opencode.$isIndexing)
            .map { $0 || $1 || $2 || $3 }
            .assign(to: &$isIndexing)

        // isProcessingTranscripts reflects any indexer processing transcripts
        Publishers.CombineLatest4(codex.$isProcessingTranscripts, claude.$isProcessingTranscripts, gemini.$isProcessingTranscripts, opencode.$isProcessingTranscripts)
            .map { $0 || $1 || $2 || $3 }
            .assign(to: &$isProcessingTranscripts)

        // Forward errors (preference order codex → claude → gemini → opencode)
        Publishers.CombineLatest4(codex.$indexingError, claude.$indexingError, gemini.$indexingError, opencode.$indexingError)
            .map { codexErr, claudeErr, geminiErr, opencodeErr in codexErr ?? claudeErr ?? geminiErr ?? opencodeErr }
            .assign(to: &$indexingError)

        // Debounced filtering and sorting pipeline (runs off main thread)
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: Self.dateEq),
            $dateTo.removeDuplicates(by: Self.dateEq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest(
            Publishers.CombineLatest4(inputs, $selectedKinds.removeDuplicates(), $allSessions, Publishers.CombineLatest4($includeCodex, $includeClaude, $includeGemini, $includeOpenCode)),
            $sortDescriptor.removeDuplicates()
        )
            .receive(on: FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] combined, sortDesc -> [Session] in
                guard let self else { return [] }
                let (input, kinds, all, sources) = combined
                let (q, from, to, model) = input
                let (incCodex, incClaude, incGemini, incOpenCode) = sources

                // Start from all sessions, then apply the same filters we use elsewhere.
                var base = all
                if !incCodex || !incClaude || !incGemini || !incOpenCode {
                    base = base.filter { s in
                        (s.source == .codex && incCodex) ||
                        (s.source == .claude && incClaude) ||
                        (s.source == .gemini && incGemini) ||
                        (s.source == .opencode && incOpenCode)
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
                self.sessions = results
                if !self.hasPublishedInitialSessions {
                    self.hasPublishedInitialSessions = true
                }
                self.updateLaunchState()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeNow() }
            .store(in: &cancellables)

        // Seed Gemini hash resolver with known working directories from Codex/Claude sessions
        Publishers.CombineLatest(codex.$allSessions, claude.$allSessions)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.global(qos: .utility))
            .sink { codexList, claudeList in
                let paths = (codexList + claudeList).compactMap { $0.cwd }
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

        Publishers.CombineLatest4(codex.$launchPhase, claude.$launchPhase, gemini.$launchPhase, opencode.$launchPhase)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.updateLaunchState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4($includeCodex, $includeClaude, $includeGemini, $includeOpenCode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
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
        let shouldRefreshCodex = includeCodex && !codex.isIndexing
        let shouldRefreshClaude = includeClaude && !claude.isIndexing
        let shouldRefreshGemini = includeGemini && !gemini.isIndexing
        let shouldRefreshOpenCode = includeOpenCode && !opencode.isIndexing

        if shouldRefreshCodex { codex.refresh() }
        if shouldRefreshClaude { claude.refresh() }
        if shouldRefreshGemini { gemini.refresh() }
        if shouldRefreshOpenCode { opencode.refresh() }

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
                        let indexer = AnalyticsIndexer(db: db)
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
                        print("[Indexing] Analytics refresh failed: \(error)")
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
        phases[.codex] = includeCodex ? codex.launchPhase : .ready
        phases[.claude] = includeClaude ? claude.launchPhase : .ready
        phases[.gemini] = includeGemini ? gemini.launchPhase : .ready
        phases[.opencode] = includeOpenCode ? opencode.launchPhase : .ready

        let overall: LaunchPhase
        if phases.values.contains(.error) {
            overall = .error
        } else {
            overall = phases.values.max() ?? .idle
        }

        let blocking = phases.compactMap { source, phase -> SessionSource? in
            phase < .ready ? source : nil
        }

        launchState = LaunchState(
            sourcePhases: phases,
            overallPhase: overall,
            blockingSources: blocking,
            hasDisplayedSessions: hasPublishedInitialSessions
        )
    }

    /// Apply current UI filters and sort preferences to a list of sessions.
    /// Used for both unified.sessions and search results to ensure consistent filtering/sorting.
    func applyFiltersAndSort(to sessions: [Session]) -> [Session] {
        // Filter by source (Codex/Claude/Gemini/OpenCode toggles) and CLI availability.
        let defaults = UserDefaults.standard
        let codexAvailable = defaults.object(forKey: PreferencesKey.codexCLIAvailable) as? Bool ?? true
        let claudeAvailable = defaults.object(forKey: PreferencesKey.claudeCLIAvailable) as? Bool ?? true
        let geminiAvailable = defaults.object(forKey: PreferencesKey.geminiCLIAvailable) as? Bool ?? true
        let openCodeAvailable = defaults.object(forKey: PreferencesKey.openCodeCLIAvailable) as? Bool ?? true

        let base = sessions.filter { s in
            switch s.source {
            case .codex:    return codexAvailable && includeCodex
            case .claude:   return claudeAvailable && includeClaude
            case .gemini:   return geminiAvailable && includeGemini
            case .opencode: return openCodeAvailable && includeOpenCode
            }
        }

        // Apply FilterEngine (query, date, model, kinds, project, path)
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(base, filters: filters)

        // Optional quick filter: sessions with commands (tool calls)
        if hasCommandsOnly {
            results = results.filter { s in
                // For Codex and OpenCode, require evidence of commands/tool calls (or lightweightCommands>0).
                if s.source == .codex || s.source == .opencode {
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
        }
    }

    private static func dateEq(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) < 0.5
        default: return false
        }
    }

    // MARK: - Auto-refresh helpers
    private func withinGuard(_ last: Date?) -> Bool {
        guard let last else { return false }
        return Date().timeIntervalSince(last) < 10.0
    }

    private func maybeAutoRefreshCodex() {
        if codex.isIndexing { return }
        if withinGuard(lastAutoRefreshCodex) { return }
        lastAutoRefreshCodex = Date()
        codex.refresh()
    }

    private func maybeAutoRefreshClaude() {
        if claude.isIndexing { return }
        if withinGuard(lastAutoRefreshClaude) { return }
        lastAutoRefreshClaude = Date()
        claude.refresh()
    }

    private func maybeAutoRefreshGemini() {
        if gemini.isIndexing { return }
        if withinGuard(lastAutoRefreshGemini) { return }
        lastAutoRefreshGemini = Date()
        gemini.refresh()
    }
    private func maybeAutoRefreshOpenCode() {
        if opencode.isIndexing { return }
        if withinGuard(lastAutoRefreshOpenCode) { return }
        lastAutoRefreshOpenCode = Date()
        opencode.refresh()
    }

    // MARK: - Favorites
    func toggleFavorite(_ id: String) {
        favorites.toggle(id)
        if let idx = allSessions.firstIndex(where: { $0.id == id }) {
            allSessions[idx].isFavorite.toggle()
        }
        recomputeNow()
    }
}
    struct LaunchState {
        let sourcePhases: [SessionSource: LaunchPhase]
        let overallPhase: LaunchPhase
        let blockingSources: [SessionSource]
        let hasDisplayedSessions: Bool

        static let idle = LaunchState(
            sourcePhases: [.codex: .idle, .claude: .idle, .gemini: .idle, .opencode: .idle],
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

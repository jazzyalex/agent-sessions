import Foundation
import Combine
import SwiftUI

/// Aggregates Codex and Claude sessions into a single list with unified filters and search.
final class UnifiedSessionIndexer: ObservableObject {
    @Published private(set) var allSessions: [Session] = []
    @Published private(set) var sessions: [Session] = []

    // Filters (unified)
    @Published var query: String = ""
    @Published var queryDraft: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var selectedModel: String? = nil
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    @Published var projectFilter: String? = nil

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

    // Sorting
    struct SessionSortDescriptor: Equatable { let key: Key; let ascending: Bool; enum Key { case modified, msgs, repo, title, agent } }
    @Published var sortDescriptor: SessionSortDescriptor = .init(key: .modified, ascending: false)

    // Indexing state aggregation
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var indexingError: String? = nil

    @AppStorage("HideZeroMessageSessions") private var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") private var hideLowMessageSessionsPref: Bool = false {
        didSet { recomputeNow() }
    }

    private let codex: SessionIndexer
    private let claude: ClaudeSessionIndexer
    private let gemini: GeminiSessionIndexer
    private var cancellables = Set<AnyCancellable>()

    // Debouncing for expensive operations
    private var recomputeDebouncer: DispatchWorkItem? = nil
    
    // Auto-refresh recency guards (per provider)
    private var lastAutoRefreshCodex: Date? = nil
    private var lastAutoRefreshClaude: Date? = nil
    private var lastAutoRefreshGemini: Date? = nil

    init(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, geminiIndexer: GeminiSessionIndexer) {
        self.codex = codexIndexer
        self.claude = claudeIndexer
        self.gemini = geminiIndexer

        // Merge underlying allSessions whenever any changes
        Publishers.CombineLatest3(codex.$allSessions, claude.$allSessions, gemini.$allSessions)
            .map { codexList, claudeList, geminiList -> [Session] in
                let merged = codexList + claudeList + geminiList
                return merged.sorted { lhs, rhs in
                    if lhs.modifiedAt == rhs.modifiedAt { return lhs.id > rhs.id }
                    return lhs.modifiedAt > rhs.modifiedAt
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$allSessions)

        // isIndexing reflects any indexer working
        Publishers.CombineLatest3(codex.$isIndexing, claude.$isIndexing, gemini.$isIndexing)
            .map { $0 || $1 || $2 }
            .assign(to: &$isIndexing)

        // Forward errors (preference order codex → claude → gemini)
        Publishers.CombineLatest3(codex.$indexingError, claude.$indexingError, gemini.$indexingError)
            .map { codexErr, claudeErr, geminiErr in codexErr ?? claudeErr ?? geminiErr }
            .assign(to: &$indexingError)

        // Debounced filtering and sorting pipeline (runs off main thread)
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: Self.dateEq),
            $dateTo.removeDuplicates(by: Self.dateEq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest(
            Publishers.CombineLatest4(inputs, $selectedKinds.removeDuplicates(), $allSessions, Publishers.CombineLatest3($includeCodex, $includeClaude, $includeGemini)),
            $sortDescriptor.removeDuplicates()
        )
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] combined, sortDesc -> [Session] in
                let (input, kinds, all, sources) = combined
                let (q, from, to, model) = input
                let (incCodex, incClaude, incGemini) = sources
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var base = all
                if !incCodex || !incClaude || !incGemini {
                    base = base.filter { s in
                        (s.source == .codex && incCodex) ||
                        (s.source == .claude && incClaude) ||
                        (s.source == .gemini && incGemini)
                    }
                }
                var results = FilterEngine.filterSessions(base, filters: filters)
                if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 } }
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 2 } }
                // Apply sort descriptor (now included in pipeline so changes trigger background re-sort)
                results = self?.applySort(results, descriptor: sortDesc) ?? results
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)

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
    }

    func refresh() {
        // Sequential refresh: Codex → Claude → Gemini, gated by source toggles
        // This stabilizes resolver seeding and avoids UI churn from parallel updates.
        struct Step { let enabled: Bool; let start: () -> Void; let busy: () -> Bool }
        let steps: [Step] = [
            Step(enabled: includeCodex, start: { self.codex.refresh() }, busy: { self.codex.isIndexing }),
            Step(enabled: includeClaude, start: { self.claude.refresh() }, busy: { self.claude.isIndexing }),
            Step(enabled: includeGemini, start: { self.gemini.refresh() }, busy: { self.gemini.isIndexing })
        ]

        func run(from index: Int) {
            // Find next enabled step
            var i = index
            while i < steps.count && !steps[i].enabled { i += 1 }
            guard i < steps.count else { return }

            let step = steps[i]
            step.start()

            func poll() {
                if step.busy() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { poll() }
                } else {
                    run(from: i + 1)
                }
            }
            // Poll until this step finishes, then move on
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { poll() }
        }

        run(from: 0)
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
            DispatchQueue.global(qos: .userInitiated).async {
                let results = self.applyFiltersAndSort(to: self.allSessions)
                DispatchQueue.main.async {
                    self.sessions = results
                }
            }
        }
        recomputeDebouncer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Apply current UI filters and sort preferences to a list of sessions.
    /// Used for both unified.sessions and search results to ensure consistent filtering/sorting.
    func applyFiltersAndSort(to sessions: [Session]) -> [Session] {
        // Filter by source (Codex/Claude toggles)
        var base = sessions
        if !includeCodex || !includeClaude || !includeGemini {
            base = base.filter { s in
                (s.source == .codex && includeCodex) ||
                (s.source == .claude && includeClaude) ||
                (s.source == .gemini && includeGemini)
            }
        }

        // Apply FilterEngine (query, date, model, kinds, project, path)
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(base, filters: filters)

        // Filter by message count preferences
        if hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount > 2 } }

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
}

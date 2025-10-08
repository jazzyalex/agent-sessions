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
    private var cancellables = Set<AnyCancellable>()

    // Debouncing for expensive operations
    private var recomputeDebouncer: DispatchWorkItem? = nil

    init(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer) {
        self.codex = codexIndexer
        self.claude = claudeIndexer

        // Merge underlying allSessions whenever either changes
        Publishers.CombineLatest(codex.$allSessions, claude.$allSessions)
            .map { codexList, claudeList -> [Session] in
                let merged = codexList + claudeList
                return merged.sorted { lhs, rhs in
                    if lhs.modifiedAt == rhs.modifiedAt { return lhs.id > rhs.id }
                    return lhs.modifiedAt > rhs.modifiedAt
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$allSessions)

        // isIndexing reflects either indexer working
        Publishers.CombineLatest(codex.$isIndexing, claude.$isIndexing)
            .map { $0 || $1 }
            .assign(to: &$isIndexing)

        // Forward errors (simple preference for codex error else claude error)
        Publishers.CombineLatest(codex.$indexingError, claude.$indexingError)
            .map { codexErr, claudeErr in codexErr ?? claudeErr }
            .assign(to: &$indexingError)

        // Debounced filtering and sorting pipeline (runs off main thread)
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: Self.dateEq),
            $dateTo.removeDuplicates(by: Self.dateEq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest(
            Publishers.CombineLatest4(inputs, $selectedKinds.removeDuplicates(), $allSessions, Publishers.CombineLatest($includeCodex, $includeClaude)),
            $sortDescriptor.removeDuplicates()
        )
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] combined, sortDesc -> [Session] in
                let (input, kinds, all, sources) = combined
                let (q, from, to, model) = input
                let (incCodex, incClaude) = sources
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var base = all
                if !incCodex || !incClaude {
                    base = base.filter { s in (s.source == .codex && incCodex) || (s.source == .claude && incClaude) }
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
    }

    func refresh() {
        codex.refresh()
        claude.refresh()
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
        if !includeCodex || !includeClaude {
            base = base.filter { s in (s.source == .codex && includeCodex) || (s.source == .claude && includeClaude) }
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
}

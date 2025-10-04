import Foundation
import Combine

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
    @Published var includeCodex: Bool = true
    @Published var includeClaude: Bool = true

    // Sorting
    struct SessionSortDescriptor: Equatable { let key: Key; let ascending: Bool; enum Key { case modified, msgs, repo, title, agent } }
    @Published var sortDescriptor: SessionSortDescriptor = .init(key: .modified, ascending: false)

    // Indexing state aggregation
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var indexingError: String? = nil

    private let codex: SessionIndexer
    private let claude: ClaudeSessionIndexer
    private var cancellables = Set<AnyCancellable>()

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

        // Debounced filtering pipeline
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: Self.dateEq),
            $dateTo.removeDuplicates(by: Self.dateEq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest4(inputs, $selectedKinds.removeDuplicates(), $allSessions, Publishers.CombineLatest($includeCodex, $includeClaude))
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] input, kinds, all, sources -> [Session] in
                let (q, from, to, model) = input
                let (incCodex, incClaude) = sources
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var base = all
                if !incCodex || !incClaude {
                    base = base.filter { s in (s.source == .codex && incCodex) || (s.source == .claude && incClaude) }
                }
                var results = FilterEngine.filterSessions(base, filters: filters)
                let d = UserDefaults.standard
                if d.bool(forKey: "HideZeroMessageSessions") { results = results.filter { $0.messageCount > 0 } }
                if d.bool(forKey: "HideLowMessageSessions") { results = results.filter { $0.messageCount > 2 } }
                // Apply sort descriptor
                results = self?.applySort(results) ?? results
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)
    }

    func refresh() {
        codex.refresh()
        claude.refresh()
    }

    func applySearch() { query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    func recomputeNow() {
        // Force recompute by setting sessions from allSessions path
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var base = allSessions
        if !includeCodex || !includeClaude {
            base = base.filter { s in (s.source == .codex && includeCodex) || (s.source == .claude && includeClaude) }
        }
        var results = FilterEngine.filterSessions(base, filters: filters)
        let d = UserDefaults.standard
        if d.bool(forKey: "HideZeroMessageSessions") { results = results.filter { $0.messageCount > 0 } }
        if d.bool(forKey: "HideLowMessageSessions") { results = results.filter { $0.messageCount > 2 } }
        results = applySort(results)
        sessions = results
    }

    private func applySort(_ list: [Session]) -> [Session] {
        switch sortDescriptor.key {
        case .modified:
            return list.sorted { lhs, rhs in
                sortDescriptor.ascending ? lhs.modifiedAt < rhs.modifiedAt : lhs.modifiedAt > rhs.modifiedAt
            }
        case .msgs:
            return list.sorted { lhs, rhs in
                sortDescriptor.ascending ? lhs.messageCount < rhs.messageCount : lhs.messageCount > rhs.messageCount
            }
        case .repo:
            return list.sorted { lhs, rhs in
                let l = lhs.repoDisplay.lowercased(); let r = rhs.repoDisplay.lowercased()
                return sortDescriptor.ascending ? (l, lhs.id) < (r, rhs.id) : (l, lhs.id) > (r, rhs.id)
            }
        case .title:
            return list.sorted { lhs, rhs in
                let l = lhs.title.lowercased(); let r = rhs.title.lowercased()
                return sortDescriptor.ascending ? (l, lhs.id) < (r, rhs.id) : (l, lhs.id) > (r, rhs.id)
            }
        case .agent:
            return list.sorted { lhs, rhs in
                let l = lhs.source.rawValue
                let r = rhs.source.rawValue
                return sortDescriptor.ascending ? (l, lhs.id) < (r, rhs.id) : (l, lhs.id) > (r, rhs.id)
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

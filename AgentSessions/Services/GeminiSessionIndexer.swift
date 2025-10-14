import Foundation
import Combine
import SwiftUI

/// Session indexer for Gemini CLI sessions (ephemeral, read-only)
final class GeminiSessionIndexer: ObservableObject {
    @Published private(set) var allSessions: [Session] = []
    @Published private(set) var sessions: [Session] = []
    @Published var isIndexing: Bool = false
    @Published var progressText: String = ""
    @Published var filesProcessed: Int = 0
    @Published var totalFiles: Int = 0
    @Published var indexingError: String? = nil
    @Published var hasEmptyDirectory: Bool = false

    // Filters
    @Published var query: String = ""
    @Published var queryDraft: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var selectedModel: String? = nil
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    @Published var projectFilter: String? = nil
    @Published var isLoadingSession: Bool = false
    @Published var loadingSessionID: String? = nil
    @Published var unreadableSessionIDs: Set<String> = []
    // Transcript cache for accurate search
    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }
    // Focus coordination for transcript vs list searches
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    // Minimal transcript cache is not needed for MVP indexing; search integration comes later
    private let discovery: GeminiSessionDiscovery
    private var cancellables = Set<AnyCancellable>()
    private var previewMTimeByID: [String: Date] = [:]

    init() {
        self.discovery = GeminiSessionDiscovery()

        // Debounced filtering similar to Claude indexer
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: Self.dateEq),
            $dateTo.removeDuplicates(by: Self.dateEq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest3(inputs, $selectedKinds.removeDuplicates(), $allSessions)
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] input, kinds, all -> [Session] in
                let (q, from, to, model) = input
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(all, filters: filters)
                // Mirror default prefs behavior for message count filters
                let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
                let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? false
                if hideZero { results = results.filter { $0.messageCount > 0 } }
                if hideLow { results = results.filter { $0.messageCount > 2 } }
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)
    }

    var canAccessRootDirectory: Bool {
        let root = discovery.sessionsRoot()
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    func refresh() {
        let root = discovery.sessionsRoot()
        print("\n🔵 GEMINI INDEXING START: root=\(root.path)")

        isIndexing = true
        progressText = "Scanning…"
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        DispatchQueue.global(qos: .userInitiated).async {
            let files = self.discovery.discoverSessionFiles()
            DispatchQueue.main.async {
                self.totalFiles = files.count
                self.hasEmptyDirectory = files.isEmpty
            }

            var sessions: [Session] = []
            sessions.reserveCapacity(files.count)

            for (i, url) in files.enumerated() {
                if let session = GeminiSessionParser.parseFile(at: url) {
                    sessions.append(session)
                    // Record preview build mtime for staleness detection
                    if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                       let m = rv.contentModificationDate {
                        self.previewMTimeByID[session.id] = m
                    }
                }
                DispatchQueue.main.async {
                    self.filesProcessed = i + 1
                    self.progressText = "Indexed \(i + 1)/\(files.count)"
                }
            }

            let sorted = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
            DispatchQueue.main.async {
                self.allSessions = sorted
                self.isIndexing = false
                print("✅ GEMINI INDEXING DONE: total=\(sessions.count)")

                // Background transcript cache generation for accurate search
                let cache = self.transcriptCache
                Task.detached(priority: .utility) {
                    await cache.generateAndCache(sessions: sorted)
                }
            }
        }
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(allSessions, filters: filters)
        let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
        let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? false
        if hideZero { results = results.filter { $0.messageCount > 0 } }
        if hideLow { results = results.filter { $0.messageCount > 2 } }
        DispatchQueue.main.async { self.sessions = results }
    }

    // Reload a specific lightweight session with a parse pass
    func reloadSession(id: String) {
        guard let existing = allSessions.first(where: { $0.id == id }),
              let url = URL(string: "file://\(existing.filePath)") else {
            return
        }

        isLoadingSession = true
        loadingSessionID = id

        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            let full = GeminiSessionParser.parseFileFull(at: url)
            let elapsed = Date().timeIntervalSince(start)
            print("  ⏱️ Gemini parse took \(String(format: "%.1f", elapsed))s - events=\(full?.events.count ?? 0)")

            DispatchQueue.main.async {
                if let full, let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                    self.allSessions[idx] = full
                    self.unreadableSessionIDs.remove(id)
                    if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                       let m = rv.contentModificationDate {
                        self.previewMTimeByID[id] = m
                    }
                }
                self.isLoadingSession = false
                self.loadingSessionID = nil
                if full == nil { self.unreadableSessionIDs.insert(id) }
            }
        }
    }

    func isPreviewStale(id: String) -> Bool {
        guard let existing = allSessions.first(where: { $0.id == id }) else { return false }
        let url = URL(fileURLWithPath: existing.filePath)
        guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let current = rv.contentModificationDate else { return false }
        guard let preview = previewMTimeByID[id] else { return false }
        return current > preview
    }

    func refreshPreview(id: String) {
        guard let existing = allSessions.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: existing.filePath)
        DispatchQueue.global(qos: .userInitiated).async {
            if let light = GeminiSessionParser.parseFile(at: url) {
                DispatchQueue.main.async {
                    if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                        self.allSessions[idx] = light
                        if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                           let m = rv.contentModificationDate {
                            self.previewMTimeByID[id] = m
                        }
                    }
                }
            }
        }
    }

    // Update an existing session after full parse (used by SearchCoordinator)
    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
        // Optionally update cache immediately
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: updated, filters: filters, mode: .normal)
        transcriptCache.set(updated.id, transcript: transcript)
    }

    private static func dateEq(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) < 0.5
        default: return false
        }
    }
}

// MARK: - SessionIndexerProtocol Conformance
extension GeminiSessionIndexer: SessionIndexerProtocol {}

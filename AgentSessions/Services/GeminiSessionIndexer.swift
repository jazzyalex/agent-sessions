import Foundation
import Combine
import SwiftUI

/// Session indexer for Gemini CLI sessions (ephemeral, read-only)
final class GeminiSessionIndexer: ObservableObject {
    @Published private(set) var allSessions: [Session] = []
    @Published private(set) var sessions: [Session] = []
    @Published var isIndexing: Bool = false
    @Published var isProcessingTranscripts: Bool = false
    @Published var progressText: String = ""
    @Published var filesProcessed: Int = 0
    @Published var totalFiles: Int = 0
    @Published var indexingError: String? = nil
    @Published var hasEmptyDirectory: Bool = false
    @Published var launchPhase: LaunchPhase = .idle

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
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var previewMTimeByID: [String: Date] = [:]
    private var refreshToken = UUID()

    init() {
        self.discovery = GeminiSessionDiscovery()

        // Debounced filtering similar to Claude indexer
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: OptionalDateEquality.eq),
            $dateTo.removeDuplicates(by: OptionalDateEquality.eq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest3(inputs, $selectedKinds.removeDuplicates(), $allSessions)
            .receive(on: FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] input, kinds, all -> [Session] in
                let (q, from, to, model) = input
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(all, filters: filters)
                // Mirror default prefs behavior for message count filters
                let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
                let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true
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
        if !AgentEnablement.isEnabled(.gemini) { return }
        let root = discovery.sessionsRoot()
        #if DEBUG
        print("\n🔵 GEMINI INDEXING START: root=\(root.path)")
        #endif
        LaunchProfiler.log("Gemini.refresh: start")

        let token = UUID()
        refreshToken = token
        launchPhase = .hydrating
        isIndexing = true
        isProcessingTranscripts = false
        progressText = "Scanning…"
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        let ioQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        ioQueue.async {
            // Fast path: hydrate from SQLite index if available (bridge async)
            var indexed: [Session]? = nil
            let sema = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                indexed = try? await self.hydrateFromIndexDBIfAvailable()
                if (indexed?.isEmpty ?? true) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let retry = try? await self.hydrateFromIndexDBIfAvailable()
                    if let r = retry, !r.isEmpty { indexed = r }
                }
                sema.signal()
            }
            sema.wait()
            if let sessions = indexed, !sessions.isEmpty {
                DispatchQueue.main.async {
                    LaunchProfiler.log("Gemini.refresh: DB hydrate hit (sessions=\(sessions.count))")
                    self.allSessions = sessions
                    self.isIndexing = false
                    self.filesProcessed = sessions.count
                    self.totalFiles = sessions.count
                    self.progressText = "Loaded \(sessions.count) from index"
                    if self.refreshToken == token {
                        self.launchPhase = .ready
                    }
                    #if DEBUG
                    print("[Launch] Hydrated Gemini sessions from DB: count=\(sessions.count)")
                    #endif
                }
                return
            }
            #if DEBUG
            print("[Launch] DB hydration returned nil for Gemini – falling back to filesystem scan")
            #endif
            let files = self.discovery.discoverSessionFiles()
            LaunchProfiler.log("Gemini.refresh: file enumeration done (files=\(files.count))")
            DispatchQueue.main.async {
                self.totalFiles = files.count
                self.hasEmptyDirectory = files.isEmpty
                if self.refreshToken == token {
                    self.launchPhase = .scanning
                }
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
                if FeatureFlags.throttleIndexingUIUpdates {
                    if self.progressThrottler.incrementAndShouldFlush() {
                        DispatchQueue.main.async {
                            self.filesProcessed = i + 1
                            self.progressText = "Indexed \(i + 1)/\(files.count)"
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.filesProcessed = i + 1
                        self.progressText = "Indexed \(i + 1)/\(files.count)"
                    }
                }
            }

            let sorted = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sorted, source: .gemini)
            DispatchQueue.main.async {
                LaunchProfiler.log("Gemini.refresh: sessions merged (total=\(mergedWithArchives.count))")
                self.allSessions = mergedWithArchives
                self.isIndexing = false
                if FeatureFlags.throttleIndexingUIUpdates {
                    self.filesProcessed = self.totalFiles
                    self.progressText = "Indexed \(self.totalFiles)/\(self.totalFiles)"
                }
                #if DEBUG
                print("✅ GEMINI INDEXING DONE: total=\(sessions.count)")
                #endif

                // Background transcript cache generation for accurate search (bounded batch).
                let delta: [Session] = {
                    var out: [Session] = []
                    out.reserveCapacity(mergedWithArchives.count)
                    for s in mergedWithArchives {
                        if s.events.isEmpty { continue }
                        if s.messageCount <= 2 { continue }
                        out.append(s)
                        if out.count >= 256 { break }
                    }
                    return out
                }()
                if !delta.isEmpty {
                    self.isProcessingTranscripts = true
                    self.progressText = "Processing transcripts..."
                    if self.refreshToken == token {
                        self.launchPhase = .transcripts
                    }
                    let cache = self.transcriptCache
                    Task.detached(priority: FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated) {
                        LaunchProfiler.log("Gemini.refresh: transcript prewarm start (delta=\(delta.count))")
                        await cache.generateAndCache(sessions: delta)
                        await MainActor.run {
                            LaunchProfiler.log("Gemini.refresh: transcript prewarm complete")
                            self.isProcessingTranscripts = false
                            self.progressText = "Ready"
                            if self.refreshToken == token {
                                self.launchPhase = .ready
                            }
                        }
                    }
                } else {
                    self.progressText = "Ready"
                    if self.refreshToken == token {
                        self.launchPhase = .ready
                    }
                }
            }
        }
    }

    private func hydrateFromIndexDBIfAvailable() async throws -> [Session]? {
        // Hydrate from session_meta without rollups gating.
        let db = try IndexDB()
        let repo = SessionMetaRepository(db: db)
        let list = try await repo.fetchSessions(for: .gemini)
        guard !list.isEmpty else { return nil }
        return list.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(allSessions, filters: filters)
        let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
        let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true
        if hideZero { results = results.filter { $0.messageCount > 0 } }
        if hideLow { results = results.filter { $0.messageCount > 2 } }
        DispatchQueue.main.async { self.sessions = results }
    }

    // Reload a specific lightweight session with a parse pass
    func reloadSession(id: String) {
        guard let existing = allSessions.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: existing.filePath) else {
            return
        }
        let url = URL(fileURLWithPath: existing.filePath)

        isLoadingSession = true
        loadingSessionID = id

        let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            let start = Date()
            let full = GeminiSessionParser.parseFileFull(at: url, forcedID: id)
            let elapsed = Date().timeIntervalSince(start)
            #if DEBUG
            print("  ⏱️ Gemini parse took \(String(format: "%.1f", elapsed))s - events=\(full?.events.count ?? 0)")
            #endif

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
        let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            if let light = GeminiSessionParser.parseFile(at: url, forcedID: id) {
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

    // Parse all lightweight sessions (for Analytics or full-index use cases)
    func parseAllSessionsFull(progress: @escaping (Int, Int) -> Void) async {
        let lightweightSessions = allSessions.filter { $0.events.isEmpty }
        guard !lightweightSessions.isEmpty else {
            #if DEBUG
            print("ℹ️ No lightweight Gemini sessions to parse")
            #endif
            return
        }

        #if DEBUG
        print("🔍 Starting full parse of \(lightweightSessions.count) lightweight Gemini sessions")
        #endif

        for (index, session) in lightweightSessions.enumerated() {
            let url = URL(fileURLWithPath: session.filePath)

            // Report progress on main thread
            await MainActor.run {
                progress(index + 1, lightweightSessions.count)
            }

            // Parse on background thread
            let fullSession = await Task.detached(priority: .userInitiated) {
                return GeminiSessionParser.parseFileFull(at: url)
            }.value

            // Update allSessions on main thread
            if let fullSession = fullSession {
                await MainActor.run {
                    if let idx = self.allSessions.firstIndex(where: { $0.id == session.id }) {
                        self.allSessions[idx] = fullSession
                        self.unreadableSessionIDs.remove(session.id)

                        // Update transcript cache
                        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                            session: fullSession,
                            filters: filters,
                            mode: .normal
                        )
                        self.transcriptCache.set(fullSession.id, transcript: transcript)
                    }
                }
            }
        }

        #if DEBUG
        print("✅ Completed parsing \(lightweightSessions.count) lightweight Gemini sessions")
        #endif
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

}

// MARK: - SessionIndexerProtocol Conformance
extension GeminiSessionIndexer: SessionIndexerProtocol {}

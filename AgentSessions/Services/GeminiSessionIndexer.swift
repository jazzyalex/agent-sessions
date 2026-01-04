import Foundation
import Combine
import SwiftUI

/// Session indexer for Gemini CLI sessions (ephemeral, read-only)
final class GeminiSessionIndexer: ObservableObject, @unchecked Sendable {
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

	        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
		        Task.detached(priority: prio) { [weak self, token] in
		            guard let self else { return }

		            let config = SessionIndexingEngine.ScanConfig(
		                source: .gemini,
		                discoverFiles: {
		                    let files = self.discovery.discoverSessionFiles()
	                    LaunchProfiler.log("Gemini.refresh: file enumeration done (files=\(files.count))")
	                    return files
	                },
	                parseLightweight: { GeminiSessionParser.parseFile(at: $0) },
		                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
		                throttler: self.progressThrottler,
		                onProgress: { processed, total in
		                    guard self.refreshToken == token else { return }
		                    self.totalFiles = total
		                    self.hasEmptyDirectory = (total == 0)
		                    self.filesProcessed = processed
		                    if processed > 0 {
		                        self.progressText = "Indexed \(processed)/\(total)"
		                    }
		                    if self.launchPhase == .hydrating {
		                        self.launchPhase = .scanning
		                    }
		                }
		            )

            let result = await SessionIndexingEngine.hydrateOrScan(
	                hydrate: { try await self.hydrateFromIndexDBIfAvailable() },
	                config: config
	            )

	            var previewTimes: [String: Date] = [:]
	            previewTimes.reserveCapacity(result.sessions.count)
		            for s in result.sessions {
		                let url = URL(fileURLWithPath: s.filePath)
		                if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
		                   let m = rv.contentModificationDate {
		                    previewTimes[s.id] = m
		                }
		            }
		            let previewTimesByID = previewTimes

		            await MainActor.run {
		                guard self.refreshToken == token else { return }
		                switch result.kind {
	                case .hydrated:
                    LaunchProfiler.log("Gemini.refresh: DB hydrate hit (sessions=\(result.sessions.count))")
                    self.allSessions = result.sessions
                    self.isIndexing = false
	                    self.filesProcessed = result.sessions.count
		                    self.totalFiles = result.sessions.count
		                    self.progressText = "Loaded \(result.sessions.count) from index"
		                    self.launchPhase = .ready
		                    self.previewMTimeByID = previewTimesByID
		                    #if DEBUG
		                    print("[Launch] Hydrated Gemini sessions from DB: count=\(result.sessions.count)")
		                    #endif
		                    return
	                case .scanned:
	                    break
	                }

		                LaunchProfiler.log("Gemini.refresh: sessions merged (total=\(result.sessions.count))")
		                self.previewMTimeByID = previewTimesByID
		                self.allSessions = result.sessions
		                self.isIndexing = false
	                if FeatureFlags.throttleIndexingUIUpdates {
                    self.filesProcessed = self.totalFiles
                    if self.totalFiles > 0 {
                        self.progressText = "Indexed \(self.totalFiles)/\(self.totalFiles)"
                    }
                }
                #if DEBUG
                print("✅ GEMINI INDEXING DONE: total=\(self.totalFiles)")
                #endif

                // Background transcript cache generation for accurate search (bounded batch).
                let mergedWithArchives = result.sessions
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
	                    self.launchPhase = .transcripts
	                    let cache = self.transcriptCache
	                    let finishPrewarm: @Sendable @MainActor () -> Void = { [weak self, token] in
	                        guard let self, self.refreshToken == token else { return }
	                        LaunchProfiler.log("Gemini.refresh: transcript prewarm complete")
	                        self.isProcessingTranscripts = false
	                        self.progressText = "Ready"
	                        self.launchPhase = .ready
	                    }
	                    Task.detached(priority: FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated) { [delta, cache, finishPrewarm] in
	                        LaunchProfiler.log("Gemini.refresh: transcript prewarm start (delta=\(delta.count))")
	                        await cache.generateAndCache(sessions: delta)
	                        await finishPrewarm()
	                    }
	                } else {
	                    self.progressText = "Ready"
	                    self.launchPhase = .ready
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
	        Task { @MainActor [weak self] in
	            self?.sessions = results
	        }
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

	            Task { @MainActor [weak self] in
	                guard let self else { return }
	                if let full, let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
	                    let current = self.allSessions[idx]
	                    let merged = Session(
	                        id: full.id,
	                        source: full.source,
	                        startTime: full.startTime ?? current.startTime,
	                        endTime: full.endTime ?? current.endTime,
	                        model: full.model ?? current.model,
	                        filePath: full.filePath,
	                        fileSizeBytes: full.fileSizeBytes ?? current.fileSizeBytes,
	                        eventCount: max(current.eventCount, full.nonMetaCount),
	                        events: full.events,
	                        cwd: current.lightweightCwd ?? full.cwd,
	                        repoName: current.repoName,
	                        lightweightTitle: current.lightweightTitle ?? full.lightweightTitle,
	                        lightweightCommands: current.lightweightCommands
	                    )
	                    self.allSessions[idx] = merged
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
	                Task { @MainActor [weak self] in
	                    guard let self else { return }
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

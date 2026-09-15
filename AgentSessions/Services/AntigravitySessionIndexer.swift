import Foundation
import Combine
import SwiftUI

/// Session indexer for Antigravity CLI artifacts.
final class AntigravitySessionIndexer: ObservableObject, @unchecked Sendable {
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
    /// `var`, not `let`: the sessions-root override is re-read on every refresh
    /// so a Preferences change re-points discovery without an app restart.
    private var discovery: AntigravitySessionDiscovery
    private var lastSessionsRootOverride: String = ""
    internal var hydrateOverride: (() async throws -> [Session]?)? = nil
    internal var parseLightweightOverride: ((URL) -> Session?)? = nil
    internal var discoverSnapshotOverride: (() -> AntigravitySessionDiscovery.DiscoverySnapshot)? = nil
    internal var deletePersistedPathsOverride: (([String]) async throws -> Void)? = nil
    internal var archiveMergeOverride: (([Session]) -> [Session])? = nil
    internal var reconciliationShouldContinueOverride: (() -> Bool)? = nil
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var previewMTimeByID: [String: Date] = [:]
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]
    /// HideZero/HideLow are read inline in the $allSessions filter pipeline and
    /// in recomputeNow() below (raw UserDefaults reads, not @AppStorage); this
    /// key-filtered observer tracks exactly those two keys so toggling either
    /// preference refreshes the visible list instead of waiting for an
    /// unrelated input to change first. See
    /// AgentSessions/Support/FilteredDefaultsObserver.swift.
    private var recomputeDefaultsObserver: FilteredDefaultsObserver?

    init() {
        let initialOverride = UserDefaults.standard.string(forKey: PreferencesKey.Paths.antigravitySessionsRootOverride) ?? ""
        self.discovery = AntigravitySessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)
        self.lastSessionsRootOverride = initialOverride

        // Debounced filtering similar to Claude indexer
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: OptionalDateEquality.eq),
            $dateTo.removeDuplicates(by: OptionalDateEquality.eq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest3(inputs, $selectedKinds.removeDuplicates(), $allSessions)
            .receive(on: FeatureFlags.backgroundIngestQueue)
            .map { [weak self] input, kinds, all -> [Session] in
                let (q, from, to, model) = input
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(all, filters: filters)
                // Mirror default prefs behavior for message count filters
                let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
                let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true
                if hideZero { results = results.filter { $0.messageCount > 0 } }
                if hideLow { results = results.filter { $0.source == .antigravity || $0.messageCount == 0 || $0.messageCount > 2 } }
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)

        // recomputeNow() -> the filter pipeline above both consult HideZero/
        // HideLow via raw UserDefaults reads; track exactly those two keys so
        // toggling either preference refreshes the visible list.
        let recomputeObserver = FilteredDefaultsObserver(keys: [
            "HideZeroMessageSessions",
            "HideLowMessageSessions"
        ])
        self.recomputeDefaultsObserver = recomputeObserver
        recomputeObserver.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeNow() }
            .store(in: &cancellables)
    }

    var canAccessRootDirectory: Bool {
        let root = discovery.sessionsRoot()
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(.antigravity) { return }

        // Update discovery if override changed
        let currentOverride = UserDefaults.standard.string(forKey: PreferencesKey.Paths.antigravitySessionsRootOverride) ?? ""
        if currentOverride != lastSessionsRootOverride {
            discovery = AntigravitySessionDiscovery(customRoot: currentOverride.isEmpty ? nil : currentOverride)
            lastSessionsRootOverride = currentOverride
        }

        // Snapshot for the detached scan below. A later refresh() can reassign
        // `discovery` on the caller's thread while that scan is still enumerating,
        // and the scan must keep reading the root it started with.
        let scanDiscovery = discovery
        let root = scanDiscovery.sessionsRoot()
        #if DEBUG
        print("\nANTIGRAVITY INDEXING START: root=\(root.path) mode=\(mode) trigger=\(trigger.rawValue)")
        #endif
        LaunchProfiler.log("Antigravity.refresh: start (mode=\(mode), trigger=\(trigger.rawValue))")

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

	        let requestedPriority: TaskPriority = executionProfile.deferNonCriticalWork ? .utility : .userInitiated
	        let prio: TaskPriority = FeatureFlags.lowerQoSForBackgroundIngest ? .utility : requestedPriority
		        Task.detached(priority: prio) { [weak self, token, executionProfile] in
		            guard let self else { return }

	            let discoverSnapshot: () -> AntigravitySessionDiscovery.DiscoverySnapshot = {
	                if let override = self.discoverSnapshotOverride {
	                    return override()
	                }
	                return scanDiscovery.discoverSnapshot()
	            }
	            let discoverFiles: () -> [URL] = { discoverSnapshot().files }

	            let config = SessionIndexingEngine.ScanConfig(
		                source: .antigravity,
		                discoverFiles: {
		                    let files = discoverFiles()
	                    LaunchProfiler.log("Antigravity.refresh: file enumeration done (files=\(files.count))")
	                    return files
	                },
	                parseLightweight: { [weak self] url in
                    if let override = self?.parseLightweightOverride {
                        return override(url)
                    }
                    return AntigravitySessionParser.parseFile(at: url)
                },
		                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
		                throttler: self.progressThrottler,
                        workerCount: executionProfile.workerCount,
                        sliceSize: executionProfile.sliceSize,
                        interSliceYieldNanoseconds: executionProfile.interSliceYieldNanoseconds,
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
                hydrate: {
                    if let override = self.hydrateOverride {
                        return try await override()
                    }
                    return try await self.hydrateFromIndexDBIfAvailable()
                },
                config: config
            )

            guard self.refreshToken == token else { return }
            if Task.isCancelled { return }

            var hydratedReconciled: [Session]? = nil
            var hydratedDeletionError: Error? = nil
            if case .hydrated = result.kind {
                let snapshot = discoverSnapshot()
                guard self.refreshToken == token else { return }
                if Task.isCancelled { return }
                let shouldContinue: () -> Bool = {
                    if self.refreshToken != token { return false }
                    if Task.isCancelled { return false }
                    if let override = self.reconciliationShouldContinueOverride, !override() { return false }
                    return true
                }
                let reconciliation = Self.reconcileHydratedSessions(
                    hydrated: result.sessions,
                    snapshot: snapshot,
                    parseNew: config.parseLightweight,
                    currentStat: { Self.fileStat(for: $0) },
                    shouldContinue: shouldContinue
                )
                guard self.refreshToken == token else { return }
                if Task.isCancelled { return }
                let withArchives: [Session] = {
                    if let override = self.archiveMergeOverride {
                        return override(reconciliation.sessions)
                    }
                    return SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: reconciliation.sessions, source: .antigravity)
                }()
                guard self.refreshToken == token else { return }
                if Task.isCancelled { return }
                if !reconciliation.confirmedMissingPaths.isEmpty {
                    do {
                        if let deleteOverride = self.deletePersistedPathsOverride {
                            try await deleteOverride(reconciliation.confirmedMissingPaths)
                        } else {
                            let db = try IndexDB()
                            _ = try await db.deleteSessionsForPaths(source: SessionSource.antigravity.rawValue, paths: reconciliation.confirmedMissingPaths)
                        }
                    } catch {
                        hydratedDeletionError = error
                    }
                }
                guard self.refreshToken == token else { return }
                if Task.isCancelled { return }
                hydratedReconciled = withArchives
            }

            let sessionsForPreview = hydratedReconciled ?? result.sessions
            var previewTimes: [String: Date] = [:]
            previewTimes.reserveCapacity(sessionsForPreview.count)
            for s in sessionsForPreview {
		                let url = URL(fileURLWithPath: s.filePath)
		                if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
		                   let m = rv.contentModificationDate {
		                    previewTimes[s.id] = m
		                }
		            }
		            let previewTimesByID = previewTimes
		            let hydratedReconciledSnapshot = hydratedReconciled
		            let hydratedDeletionErrorSnapshot = hydratedDeletionError

		            await MainActor.run {
		                guard self.refreshToken == token else { return }
		                switch result.kind {
	                case .hydrated:
                    guard let reconciled = hydratedReconciledSnapshot else { return }
                    LaunchProfiler.log("Antigravity.refresh: DB hydrate hit (sessions=\(reconciled.count))")
                    self.allSessions = reconciled
                    self.isIndexing = false
	                    self.filesProcessed = reconciled.count
		                    self.totalFiles = reconciled.count
		                    if hydratedDeletionErrorSnapshot != nil {
		                        self.indexingError = "Index cleanup did not persist; showing reconciled rows."
		                    }
		                    self.progressText = "Loaded \(reconciled.count) from index"
		                    self.launchPhase = .ready
		                    self.previewMTimeByID = previewTimesByID
		                    #if DEBUG
		                    print("[Launch] Hydrated Antigravity sessions from DB: count=\(reconciled.count)")
		                    #endif
		                    return
	                case .scanned:
	                    break
	                }

		                LaunchProfiler.log("Antigravity.refresh: sessions merged (total=\(result.sessions.count))")
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
                print("ANTIGRAVITY INDEXING DONE: total=\(self.totalFiles)")
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
                if !delta.isEmpty && !executionProfile.deferNonCriticalWork {
                    self.isProcessingTranscripts = true
	                    self.progressText = "Processing transcripts..."
	                    self.launchPhase = .transcripts
	                    let cache = self.transcriptCache
	                    let finishPrewarm: @Sendable @MainActor () -> Void = { [weak self, token] in
	                        guard let self, self.refreshToken == token else { return }
	                        LaunchProfiler.log("Antigravity.refresh: transcript prewarm complete")
	                        self.isProcessingTranscripts = false
	                        self.progressText = "Ready"
	                        self.launchPhase = .ready
	                    }
	                    Task.detached(priority: FeatureFlags.backgroundIngestTaskPriority) { [delta, cache, finishPrewarm] in
	                        LaunchProfiler.log("Antigravity.refresh: transcript prewarm start (delta=\(delta.count))")
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
        let list = try await repo.fetchSessions(for: .antigravity)
        guard !list.isEmpty else { return nil }
        return list.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    internal static func normalizedSessionPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    internal static func normalizedSessionPath(for url: URL) -> String {
        URL(fileURLWithPath: url.path).standardized.path
    }

    internal struct HydratedReconciliation {
        var sessions: [Session]
        var confirmedMissingPaths: [String]
    }

    internal static func reconcileHydratedSessions(
        hydrated: [Session],
        snapshot: AntigravitySessionDiscovery.DiscoverySnapshot,
        parseNew: (URL) -> Session?,
        currentStat: (URL) -> SessionFileStat? = { fileStat(for: $0) },
        shouldContinue: () -> Bool = { true }
    ) -> HydratedReconciliation {
        var hydratedByPath: [String: Session] = [:]
        hydratedByPath.reserveCapacity(hydrated.count)
        for s in hydrated {
            let key = normalizedSessionPath(s.filePath)
            if hydratedByPath[key] == nil { hydratedByPath[key] = s }
        }
        var discoveredByPath: [String: URL] = [:]
        discoveredByPath.reserveCapacity(snapshot.files.count)
        for url in snapshot.files {
            let key = normalizedSessionPath(for: url)
            if discoveredByPath[key] == nil { discoveredByPath[key] = url }
        }
        var placeholders: [Session] = []
        placeholders.reserveCapacity(hydrated.count)
        var placeholderIndexByPath: [String: Int] = [:]
        var confirmedMissing: [String] = []
        for s in hydrated {
            let key = normalizedSessionPath(s.filePath)
            if !snapshot.isAuthoritative(path: s.filePath) {
                placeholderIndexByPath[key] = placeholders.count
                placeholders.append(s)
                continue
            }
            if discoveredByPath[key] == nil {
                confirmedMissing.append(key)
                continue
            }
            placeholderIndexByPath[key] = placeholders.count
            placeholders.append(s)
        }
        for url in snapshot.files {
            if !shouldContinue() { break }
            let key = normalizedSessionPath(for: url)
            if let cached = hydratedByPath[key] {
                guard snapshot.isAuthoritative(path: cached.filePath) else { continue }
                guard let stat = currentStat(url) else { continue }
                let cachedSecond = Int64(cached.modifiedAt.timeIntervalSince1970)
                let cachedSize = cached.fileSizeBytes.map { Int64($0) }
                if cachedSecond == stat.mtime && cachedSize == stat.size { continue }
                guard shouldContinue() else { break }
                if let reparsed = parseNew(url) {
                    if let idx = placeholderIndexByPath[key] {
                        placeholders[idx] = reparsed
                    } else {
                        placeholderIndexByPath[key] = placeholders.count
                        placeholders.append(reparsed)
                    }
                }
                continue
            }
            guard shouldContinue() else { break }
            if let session = parseNew(url) {
                let parsedKey = normalizedSessionPath(session.filePath)
                if placeholderIndexByPath[parsedKey] == nil {
                    placeholderIndexByPath[parsedKey] = placeholders.count
                    placeholders.append(session)
                }
            }
        }
        let ordered = placeholders.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id < $1.id
        }
        return HydratedReconciliation(sessions: ordered, confirmedMissingPaths: confirmedMissing.sorted())
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
	        if hideLow { results = results.filter { $0.source == .antigravity || $0.messageCount == 0 || $0.messageCount > 2 } }
	        Task { @MainActor [weak self] in
	            self?.sessions = results
	        }
	    }

    enum ReloadReason: String {
        case selection
        case focusedSessionMonitor
        case manualRefresh
    }

    // Reload a specific lightweight session with a parse pass.
    func reloadSession(id: String,
                       force: Bool = false,
                       reason: ReloadReason = .selection) {
        reloadLock.lock()
        if reloadingSessionIDs.contains(id) {
            reloadLock.unlock()
            return
        }
        reloadingSessionIDs.insert(id)
        reloadLock.unlock()

        let existingSnapshot: Session? = {
            if Thread.isMainThread {
                return self.allSessions.first(where: { $0.id == id })
            }
            var session: Session?
            DispatchQueue.main.sync {
                session = self.allSessions.first(where: { $0.id == id })
            }
            return session
        }()

        let bgQueue = FeatureFlags.backgroundIngestQueue
        bgQueue.async {
            defer {
                self.reloadLock.lock()
                self.reloadingSessionIDs.remove(id)
                self.reloadLock.unlock()
            }

            guard let existing = existingSnapshot,
                  FileManager.default.fileExists(atPath: existing.filePath) else {
                return
            }

            let hasLoadedEvents = !existing.events.isEmpty
            if hasLoadedEvents && !force { return }

            let url = URL(fileURLWithPath: existing.filePath)
            let preParseStat = Self.fileStat(for: url)
            self.reloadLock.lock()
            let lastReloadStat = self.lastFullReloadFileStatsBySessionID[id]
            self.reloadLock.unlock()

            if force,
               reason != .manualRefresh,
               hasLoadedEvents,
               let preParseStat,
               let lastReloadStat,
               preParseStat == lastReloadStat {
                return
            }

            let shouldSurfaceLoadingState = reason == .manualRefresh || !hasLoadedEvents
            if shouldSurfaceLoadingState {
                Task { @MainActor [weak self] in
                    self?.isLoadingSession = true
                    self?.loadingSessionID = id
                }
            }

            let full = AntigravitySessionParser.parseFileFull(at: url, forcedID: id)

            let postParseStat = Self.fileStat(for: url)
            self.reloadLock.lock()
            if let preParseStat {
                self.lastFullReloadFileStatsBySessionID[id] = preParseStat
            } else {
                self.lastFullReloadFileStatsBySessionID.removeValue(forKey: id)
            }
            self.reloadLock.unlock()
            if preParseStat != postParseStat {
                #if DEBUG
            print("Antigravity file changed during reload; next monitor tick will retry")
                #endif
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if shouldSurfaceLoadingState, self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }

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
                } else if full == nil {
                    self.unreadableSessionIDs.insert(id)
                }
            }
        }
    }

    private static func fileStat(for url: URL) -> SessionFileStat? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else {
            return nil
        }
        let size = Int64(values.fileSize ?? 0)
        return SessionFileStat(mtime: Int64(modified.timeIntervalSince1970), size: size)
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
	        let bgQueue = FeatureFlags.backgroundIngestQueue
	        bgQueue.async {
	            if let light = AntigravitySessionParser.parseFile(at: url, forcedID: id) {
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
            print("No lightweight Antigravity sessions to parse")
            #endif
            return
        }

        #if DEBUG
        print("Starting full parse of \(lightweightSessions.count) lightweight Antigravity sessions")
        #endif

        for (index, session) in lightweightSessions.enumerated() {
            let url = URL(fileURLWithPath: session.filePath)

            // Report progress on main thread
            await MainActor.run {
                progress(index + 1, lightweightSessions.count)
            }

            // Parse on background thread
            let fullSession = await Task.detached(priority: .userInitiated) {
                return AntigravitySessionParser.parseFileFull(at: url)
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
        print("Completed parsing \(lightweightSessions.count) lightweight Antigravity sessions")
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
extension AntigravitySessionIndexer: SessionIndexerProtocol {}

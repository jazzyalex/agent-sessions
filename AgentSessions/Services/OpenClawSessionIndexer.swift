import Foundation
import Combine
import SwiftUI
import os.log

private let indexLog = OSLog(subsystem: "com.triada.AgentSessions", category: "OpenClawIndexing")

/// Session indexer for OpenClaw / Clawdbot sessions.
final class OpenClawSessionIndexer: ObservableObject, @unchecked Sendable {
    private struct PersistedFileStat: Codable {
        let mtime: Int64
        let size: Int64
    }

    private struct PersistedFileStatPayload: Codable {
        let version: Int
        let stats: [String: PersistedFileStat]
    }

    private static let coreFileStatsStateKey = "core_file_stats_v1:openclaw"

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

    // Focus coordination for transcript vs list searches
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    // Search cache parity with other providers (prewarm is optional)
    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    private var discovery: OpenClawSessionDiscovery
    private var lastIncludeDeleted: Bool = false
    private var lastCustomRootOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var previewMTimeByID: [String: Date] = [:]
    private var refreshToken = UUID()
    private let fileStatsLock = NSLock()
    private var lastKnownFileStatsByPath: [String: SessionFileStat] = [:]
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]

    init() {
        UserDefaults.standard.register(defaults: [
            PreferencesKey.Advanced.includeOpenClawDeletedSessions: true
        ])
        let customRoot = UserDefaults.standard.string(forKey: PreferencesKey.Paths.openClawSessionsRootOverride) ?? ""
        let includeDeleted = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions)
        self.lastCustomRootOverride = customRoot
        self.lastIncludeDeleted = includeDeleted
        self.discovery = OpenClawSessionDiscovery(customRoot: customRoot.isEmpty ? nil : customRoot,
                                                  includeDeleted: includeDeleted)

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
                var results = FilterEngine.filterSessions(all, filters: filters, transcriptCache: self?.transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
                let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
                let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true
                if hideZero { results = results.filter { $0.messageCount > 0 } }
                if hideLow { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
                let showHousekeeping = UserDefaults.standard.bool(forKey: PreferencesKey.showHousekeepingSessions)
                if !showHousekeeping { results = results.filter { !$0.isHousekeeping } }
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let customRoot = UserDefaults.standard.string(forKey: PreferencesKey.Paths.openClawSessionsRootOverride) ?? ""
                let includeDeleted = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions)
                if includeDeleted != self.lastIncludeDeleted || customRoot != self.lastCustomRootOverride {
                    self.lastCustomRootOverride = customRoot
                    self.lastIncludeDeleted = includeDeleted
                    self.discovery = OpenClawSessionDiscovery(customRoot: customRoot.isEmpty ? nil : customRoot,
                                                              includeDeleted: includeDeleted)
                    self.refresh()
                }
            }
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
        if !AgentEnablement.isEnabled(.openclaw) { return }
        let root = discovery.sessionsRoot()
        #if DEBUG
        print("\n🔵 OPENCLAW INDEXING START: root=\(root.path) mode=\(mode) trigger=\(trigger.rawValue)")
        #endif
        LaunchProfiler.log("OpenClaw.refresh: start (mode=\(mode), trigger=\(trigger.rawValue))")

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
        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : requestedPriority
        Task.detached(priority: prio) { [weak self, token, mode, executionProfile] in
            guard let self else { return }

            // ── Phase 1: Hydrate from IndexDB ──
            var indexed: [Session] = []
            do {
                if let hydrated = try await self.hydrateFromIndexDBIfAvailable() {
                    indexed = hydrated
                }
            } catch {
                // DB errors are non-fatal; fall back to filesystem.
            }
            if indexed.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                do {
                    if let retry = try await self.hydrateFromIndexDBIfAvailable(), !retry.isEmpty {
                        indexed = retry
                    }
                } catch {}
            }

            await self.seedKnownFileStatsIfNeeded()
            let fm = FileManager.default
            let exists: (Session) -> Bool = { s in fm.fileExists(atPath: s.filePath) }
            let existingSessions = indexed.filter(exists)
            self.bootstrapKnownFileStatsIfNeeded(from: existingSessions)

            // ── Phase 2: Publish hydrated sessions immediately ──
            let presentedHydration = !existingSessions.isEmpty
            if presentedHydration {
                let hydratedSorted = existingSessions.sorted { $0.modifiedAt > $1.modifiedAt }
                // Archive fallbacks merged here for immediate display; re-merged on the final
                // complete list at end of Phase 7 to avoid duplication from delta slices.
                let hydratedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(
                    into: hydratedSorted, source: .openclaw)

                var hydratedPreviewTimes: [String: Date] = [:]
                hydratedPreviewTimes.reserveCapacity(hydratedWithArchives.count)
                for s in hydratedWithArchives {
                    let url = URL(fileURLWithPath: s.filePath)
                    if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                       let m = rv.contentModificationDate {
                        hydratedPreviewTimes[s.id] = m
                    }
                }
                let capturedPreviewTimes = hydratedPreviewTimes

                await MainActor.run {
                    guard self.refreshToken == token else { return }
                    self.allSessions = hydratedWithArchives
                    self.previewMTimeByID = capturedPreviewTimes
                    self.launchPhase = .scanning
                    self.filesProcessed = hydratedWithArchives.count
                    self.totalFiles = hydratedWithArchives.count
                    self.progressText = "Loaded \(hydratedWithArchives.count) from index"
                }
                #if DEBUG
                print("[Launch] Hydrated \(existingSessions.count) OpenClaw sessions from DB, now scanning for changes…")
                #endif
                LaunchProfiler.log("OpenClaw.refresh: DB hydrate published (existing=\(existingSessions.count))")
            } else {
                #if DEBUG
                print("[Launch] DB hydration returned nil for OpenClaw – scanning all files")
                #endif
            }

            // ── Phase 3: Delta scan (only changed/new files) ──
            let previousStats = self.knownFileStatsSnapshot()
            let delta = self.discovery.discoverDelta(previousByPath: previousStats)

            let files: [URL]
            let missingHydratedCount: Int
            if mode == .fullReconcile || previousStats.isEmpty {
                // First-ever scan or manual full reconcile: parse everything
                files = delta.currentByPath.keys.map { URL(fileURLWithPath: $0) }
                missingHydratedCount = 0
            } else {
                // Supplement: force-parse files on disk but missing from hydrated snapshot.
                let existingPaths = Set(existingSessions.map(\.filePath))
                let changedPaths = Set(delta.changedFiles.map(\.path))
                let missingPaths = Set(delta.currentByPath.keys)
                    .subtracting(existingPaths)
                    .subtracting(changedPaths)
                missingHydratedCount = missingPaths.count
                if missingPaths.isEmpty {
                    files = delta.changedFiles
                } else {
                    var combined = delta.changedFiles
                    combined.append(contentsOf: missingPaths.sorted().map { URL(fileURLWithPath: $0) })
                    files = combined
                }
            }

            #if DEBUG
            print("📁 Found \(files.count) OpenClaw changed/new files (removed=\(delta.removedPaths.count), total_on_disk=\(delta.currentByPath.count))")
            #endif
            LaunchProfiler.log("OpenClaw.refresh: file enumeration done (changed=\(files.count), removed=\(delta.removedPaths.count), gap=\(missingHydratedCount))")

            // shouldMergeArchives: false — we call mergePinnedArchiveFallbacks once below
            // on the complete merged list, preventing duplication from delta slices.
            let config = SessionIndexingEngine.ScanConfig(
                source: .openclaw,
                discoverFiles: { files },
                parseLightweight: { OpenClawSessionParser.parseFile(at: $0) },
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: self.progressThrottler,
                shouldContinue: { self.refreshToken == token },
                shouldMergeArchives: false,
                workerCount: executionProfile.workerCount,
                sliceSize: executionProfile.sliceSize,
                interSliceYieldNanoseconds: executionProfile.interSliceYieldNanoseconds,
                onProgress: { processed, total in
                    guard self.refreshToken == token else { return }
                    self.totalFiles = existingSessions.count + total
                    self.hasEmptyDirectory = existingSessions.isEmpty && total == 0
                    self.filesProcessed = existingSessions.count + processed
                    if processed > 0 {
                        self.progressText = "Indexed \(processed)/\(total)"
                    }
                    if self.launchPhase == .hydrating {
                        self.launchPhase = .scanning
                    }
                }
            )

            let scanResult = await SessionIndexingEngine.hydrateOrScan(config: config)
            let changedSessions = scanResult.sessions

            // Bail early if a newer refresh has started — don't touch shared state.
            guard self.refreshToken == token else { return }

            // ── Phase 4: Merge hydrated + scanned ──
            var mergedByPath: [String: Session] = [:]
            mergedByPath.reserveCapacity(existingSessions.count + changedSessions.count)
            for session in existingSessions {
                mergedByPath[session.filePath] = session
            }
            for removed in delta.removedPaths {
                mergedByPath.removeValue(forKey: removed)
            }
            for session in changedSessions {
                mergedByPath[session.filePath] = session
            }

            let merged = Array(mergedByPath.values).filter(exists)
            let sortedSessions = merged.sorted { $0.modifiedAt > $1.modifiedAt }
            // Single archive fallback merge on the complete, deduplicated list.
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(
                into: sortedSessions, source: .openclaw)

            // ── Phase 5: Persist file stats (token-guarded) ──
            if self.refreshToken == token {
                self.applyKnownFileStatsDelta(delta)
                await self.persistKnownFileStats()
            }

            // ── Phase 6: Persist session_meta for next launch's hydration (token-guarded) ──
            if self.refreshToken == token, !merged.isEmpty {
                do {
                    let db = try IndexDB()
                    try await db.begin()
                    for session in merged {
                        try? await db.upsertSessionMetaCore(SessionIndexer.sessionMetaRow(from: session))
                    }
                    try await db.commit()
                    os_log("OpenClaw: wrote %d session_meta rows", log: indexLog, type: .info, merged.count)
                } catch {
                    os_log("OpenClaw: session_meta write failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
                }
            }

            // ── Phase 7: Publish final merged sessions ──
            var previewTimes: [String: Date] = [:]
            previewTimes.reserveCapacity(mergedWithArchives.count)
            for s in mergedWithArchives {
                let url = URL(fileURLWithPath: s.filePath)
                if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let m = rv.contentModificationDate {
                    previewTimes[s.id] = m
                }
            }
            let previewTimesByID = previewTimes

            await MainActor.run {
                guard self.refreshToken == token else { return }
                LaunchProfiler.log("OpenClaw.refresh: sessions merged (total=\(mergedWithArchives.count))")
                self.previewMTimeByID = previewTimesByID
                self.allSessions = mergedWithArchives
                self.isIndexing = false
                if FeatureFlags.throttleIndexingUIUpdates {
                    self.filesProcessed = self.totalFiles
                    if self.totalFiles > 0 {
                        self.progressText = "Indexed \(self.totalFiles)/\(self.totalFiles)"
                    }
                }
                #if DEBUG
                print("✅ OPENCLAW INDEXING DONE: total=\(mergedWithArchives.count) (existing=\(existingSessions.count), changed=\(changedSessions.count), removed=\(delta.removedPaths.count))")
                #endif
                self.progressText = "Ready"
                self.launchPhase = .ready
            }
        }
    }

    private func hydrateFromIndexDBIfAvailable() async throws -> [Session]? {
        let db = try IndexDB()
        let repo = SessionMetaRepository(db: db)
        let list = try await repo.fetchSessions(for: .openclaw)
        guard !list.isEmpty else { return nil }
        return list.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(allSessions, filters: filters, transcriptCache: transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
        let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
        let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true
        if hideZero { results = results.filter { $0.messageCount > 0 } }
        if hideLow { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
        let showHousekeeping = UserDefaults.standard.bool(forKey: PreferencesKey.showHousekeepingSessions)
        if !showHousekeeping { results = results.filter { !$0.isHousekeeping } }
        Task { @MainActor [weak self] in
            self?.sessions = results
        }
    }

    enum ReloadReason: String {
        case selection
        case focusedSessionMonitor
        case manualRefresh
    }

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

        let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
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

            let full = OpenClawSessionParser.parseFileFull(at: url)
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
                print("ℹ️ OpenClaw file changed during reload; next monitor tick will retry")
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
                        id: current.id,
                        source: .openclaw,
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
                        lightweightCommands: current.lightweightCommands,
                        isHousekeeping: full.isHousekeeping,
                        deletedAt: current.deletedAt ?? full.deletedAt
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
        let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            if let light = OpenClawSessionParser.parseFile(at: url, forcedID: existing.id) {
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

    // Update an existing session after full parse (used by SearchCoordinator)
    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: updated, filters: filters, mode: .normal)
        transcriptCache.set(updated.id, transcript: transcript)
    }

    // MARK: - File Stat Persistence

    private func hasKnownFileStats() -> Bool {
        fileStatsLock.lock()
        let hasStats = !lastKnownFileStatsByPath.isEmpty
        fileStatsLock.unlock()
        return hasStats
    }

    private func initializeKnownFileStatsIfNeeded(_ stats: [String: SessionFileStat]) {
        fileStatsLock.lock()
        if lastKnownFileStatsByPath.isEmpty {
            lastKnownFileStatsByPath = stats
        }
        fileStatsLock.unlock()
    }

    private func knownFileStatsSnapshot() -> [String: SessionFileStat] {
        fileStatsLock.lock()
        let snapshot = lastKnownFileStatsByPath
        fileStatsLock.unlock()
        return snapshot
    }

    private func applyKnownFileStatsDelta(_ delta: SessionDiscoveryDelta) {
        fileStatsLock.lock()
        lastKnownFileStatsByPath = delta.currentByPath
        fileStatsLock.unlock()
    }

    private func bootstrapKnownFileStatsIfNeeded(from sessions: [Session]) {
        if hasKnownFileStats() { return }
        guard !sessions.isEmpty else { return }
        var map: [String: SessionFileStat] = [:]
        map.reserveCapacity(sessions.count)
        for session in sessions {
            let url = URL(fileURLWithPath: session.filePath)
            if let stat = Self.fileStat(for: url) {
                map[session.filePath] = stat
            } else {
                let size = Int64(max(0, session.fileSizeBytes ?? 0))
                let mtime = Int64(max(0, session.modifiedAt.timeIntervalSince1970))
                map[session.filePath] = SessionFileStat(mtime: mtime, size: size)
            }
        }
        initializeKnownFileStatsIfNeeded(map)
    }

    private func seedKnownFileStatsIfNeeded() async {
        if hasKnownFileStats() { return }
        do {
            if let persisted = try await loadPersistedKnownFileStats() {
                initializeKnownFileStatsIfNeeded(persisted)
                os_log("OpenClaw: seeded file stats from persisted baseline (%d entries)", log: indexLog, type: .info, persisted.count)
            }
        } catch {
            os_log("OpenClaw: seedKnownFileStats failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
        }
    }

    private func persistKnownFileStats() async {
        let snapshot = knownFileStatsSnapshot()
        guard !snapshot.isEmpty else { return }
        do {
            let payload = PersistedFileStatPayload(
                version: 1,
                stats: snapshot.reduce(into: [:]) { partial, entry in
                    partial[entry.key] = PersistedFileStat(mtime: entry.value.mtime, size: entry.value.size)
                }
            )
            let data = try JSONEncoder().encode(payload)
            guard let json = String(data: data, encoding: .utf8) else { return }
            let db = try IndexDB()
            try await db.setIndexState(key: Self.coreFileStatsStateKey, value: json)
        } catch {
            // Non-fatal. Next run can still bootstrap from DB/filesystem.
        }
    }

    private func loadPersistedKnownFileStats() async throws -> [String: SessionFileStat]? {
        let db = try IndexDB()
        guard let raw = try await db.indexStateValue(for: Self.coreFileStatsStateKey),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        let payload = try JSONDecoder().decode(PersistedFileStatPayload.self, from: data)
        guard payload.version == 1 else { return nil }
        let map = payload.stats.reduce(into: [String: SessionFileStat]()) { partial, entry in
            partial[entry.key] = SessionFileStat(mtime: entry.value.mtime, size: entry.value.size)
        }
        return map.isEmpty ? nil : map
    }
}

// MARK: - SessionIndexerProtocol Conformance
extension OpenClawSessionIndexer: SessionIndexerProtocol {}

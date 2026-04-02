import Foundation
import Combine
import SwiftUI
import os.log

private let indexLog = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeIndexing")

/// Session indexer for Claude Code sessions
final class ClaudeSessionIndexer: ObservableObject, @unchecked Sendable {
    private struct PersistedFileStat: Codable {
        let mtime: Int64
        let size: Int64
    }

    private struct PersistedFileStatPayload: Codable {
        let version: Int
        let stats: [String: PersistedFileStat]
    }

    private static let coreFileStatsStateKey = "core_file_stats_v1:claude"

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

    // UI focus coordination (shared with Codex via protocol)
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    // Transcript cache for accurate search
    private let transcriptCache = TranscriptCache()

    // Expose cache for SearchCoordinator (internal - not public API)
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    @AppStorage("ClaudeSessionsRootOverride") var sessionsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true {
        didSet {
            publishAfterCurrentUpdate { [weak self] in
                self?.filterEpoch &+= 1
            }
        }
    }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true {
        didSet {
            publishAfterCurrentUpdate { [weak self] in
                self?.filterEpoch &+= 1
            }
        }
    }
    @AppStorage(PreferencesKey.showHousekeepingSessions) var showHousekeepingSessionsPref: Bool = false {
        didSet {
            publishAfterCurrentUpdate { [weak self] in
                self?.filterEpoch &+= 1
            }
        }
    }
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    private var discovery: ClaudeSessionDiscovery
    private var lastSessionsRootOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private let refreshStateLock = NSLock()
    private var cancellables = Set<AnyCancellable>()
    private var lastShowSystemProbeSessions: Bool = UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions")
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]
    private var lastPrewarmSignatureByID: [String: Int] = [:]
    private var lastKnownFileStatsByPath: [String: SessionFileStat] = [:]
    @Published private var filterEpoch: Int = 0
    private var transcriptPrewarmTask: Task<Void, Never>? = nil
    private var refreshTask: Task<Void, Never>? = nil

    init() {
        // Initialize discovery with current override (if any)
        let initialOverride = UserDefaults.standard.string(forKey: "ClaudeSessionsRootOverride") ?? ""
        self.discovery = ClaudeSessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)
        self.lastSessionsRootOverride = initialOverride

        // Debounced filtering
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: OptionalDateEquality.eq),
            $dateTo.removeDuplicates(by: OptionalDateEquality.eq),
            $selectedModel.removeDuplicates()
        )

        let inputsWithProjectAndEpoch = Publishers.CombineLatest3(
            inputs,
            $projectFilter.removeDuplicates(),
            $filterEpoch.removeDuplicates()
        )

        Publishers.CombineLatest3(
            inputsWithProjectAndEpoch,
            $selectedKinds.removeDuplicates(),
            $allSessions
        )
        .receive(on: FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated))
        .map { [weak self] combined, kinds, all -> [Session] in
            let (input, repoName, _) = combined
            let (q, from, to, model) = input
            let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: repoName, pathContains: nil)
            var results = FilterEngine.filterSessions(all,
                                                     filters: filters,
                                                     transcriptCache: self?.transcriptCache,
                                                     allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)

            if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 } }
            if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
            if !(self?.showHousekeepingSessionsPref ?? false) { results = results.filter { !$0.isHousekeeping } }

            return results
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] value in
            self?.publishAfterCurrentUpdate { [weak self] in
                self?.sessions = value
            }
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.publishAfterCurrentUpdate { [weak self] in
                    guard let self else { return }
                    // React to Sessions root override changes from Preferences
                    let current = UserDefaults.standard.string(forKey: "ClaudeSessionsRootOverride") ?? ""
                    if current != self.lastSessionsRootOverride {
                        self.lastSessionsRootOverride = current
                        self.discovery = ClaudeSessionDiscovery(customRoot: current.isEmpty ? nil : current)
                        self.refresh()
                    }
                    let show = UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions")
                    if show != self.lastShowSystemProbeSessions {
                        self.lastShowSystemProbeSessions = show
                        self.refresh()
                    }
                    self.filterEpoch &+= 1
                }
            }
            .store(in: &cancellables)

        // Refresh when Claude probe cleanup succeeds so removed probe sessions disappear immediately
        NotificationCenter.default.publisher(for: ClaudeProbeProject.didRunCleanupNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self = self else { return }
                if let info = note.userInfo as? [String: Any], let status = info["status"] as? String, status == "success" {
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
        if !AgentEnablement.isEnabled(.claude) { return }
        let root = discovery.sessionsRoot()
        #if DEBUG
        print("\n🔵 CLAUDE INDEXING START: root=\(root.path) mode=\(mode) trigger=\(trigger.rawValue)")
        #endif
        LaunchProfiler.log("Claude.refresh: start (mode=\(mode), trigger=\(trigger.rawValue))")

        let token = UUID()
        setRefreshToken(token)
        refreshTask?.cancel()
        refreshTask = nil
        transcriptPrewarmTask?.cancel()
        transcriptPrewarmTask = nil
        publishAfterCurrentUpdate { [weak self] in
            guard let self else { return }
            self.launchPhase = .hydrating
            self.isIndexing = true
            self.isProcessingTranscripts = false
            self.progressText = "Scanning…"
            self.filesProcessed = 0
            self.totalFiles = 0
            self.indexingError = nil
            self.hasEmptyDirectory = false
        }

        let task = Task.detached(priority: .utility) { [weak self, token, mode, executionProfile] in
            guard let self else { return }

            // Fast path: hydrate from SQLite index if available.
            var indexed: [Session] = []
            do {
                if let hydrated = try await self.hydrateFromIndexDBIfAvailable() {
                    indexed = hydrated
                }
            } catch {
                // DB errors are non-fatal for UI; fall back to filesystem only.
            }
            if indexed.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                do {
                    if let retry = try await self.hydrateFromIndexDBIfAvailable(), !retry.isEmpty {
                        indexed = retry
                    }
                } catch {
                    // Still no DB hydrate; fall back to filesystem.
                }
            }

            await self.seedKnownFileStatsIfNeeded()
            let fm = FileManager.default
            let exists: (Session) -> Bool = { s in fm.fileExists(atPath: s.filePath) }
            let existingSessions = indexed.filter(exists)
            self.bootstrapKnownFileStatsIfNeeded(from: existingSessions)

            // Publish hydrated sessions immediately so the UI is populated
            // while the background file scan runs (matches Codex indexer pattern).
            let presentedHydration = !existingSessions.isEmpty
            if presentedHydration {
                let hideProbes = !(UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"))
                let hydratedFiltered = existingSessions.filter { hideProbes ? !ClaudeProbeConfig.isProbeSession($0) : true }
                let hydratedSorted = hydratedFiltered.sorted { $0.modifiedAt > $1.modifiedAt }
                let hydratedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: hydratedSorted, source: .claude)
                self.publishAfterCurrentUpdate { [weak self] in
                    guard let self, self.isRefreshTokenCurrent(token) else { return }
                    self.allSessions = hydratedWithArchives
                    self.launchPhase = .scanning
                }
            }

            #if DEBUG
            if !existingSessions.isEmpty {
                print("[Launch] Hydrated \(existingSessions.count) Claude sessions from DB (after pruning non-existent), now scanning for new files…")
            } else {
                print("[Launch] DB hydration returned nil for Claude – scanning all files")
            }
            LaunchProfiler.log("Claude.refresh: DB hydrate complete (existing=\(existingSessions.count))")
            #endif

            let deltaScope: SessionDeltaScope = (mode == .fullReconcile || trigger == .manual || trigger == .launch) ? .full : .recent
            let previousStats = self.knownFileStatsByPathSnapshot()
            let initialDelta = self.discovery.discoverDelta(previousByPath: previousStats, scope: deltaScope)
            let shouldEscalate = Self.shouldEscalateRecentDeltaToFullReconcile(mode: mode)
            let effectiveMode: IndexRefreshMode = shouldEscalate ? .fullReconcile : mode
            let delta: SessionDiscoveryDelta = {
                if shouldEscalate {
                    return self.discovery.discoverDelta(previousByPath: previousStats, scope: .full)
                }
                return initialDelta
            }()
            let files: [URL]
            let missingHydratedCount: Int
            if effectiveMode == .fullReconcile {
                files = delta.currentByPath.keys.map { URL(fileURLWithPath: $0) }
                missingHydratedCount = 0
            } else {
                // Supplement: force-parse files on disk but missing from hydrated snapshot.
                // Without this, sessions not in session_meta AND not file-stat-changed stay invisible.
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
            if shouldEscalate {
                LaunchProfiler.log("Claude.refresh: escalating recent delta to full reconcile due to drift")
            }
            #if DEBUG
            print(
                "📁 Found \(files.count) Claude Code changed/new files " +
                "(removed=\(delta.removedPaths.count), drift=\(delta.driftDetected), mode=\(effectiveMode))"
            )
            #endif
            LaunchProfiler.log("Claude.refresh: file enumeration done (changed=\(files.count), removed=\(delta.removedPaths.count), drift=\(delta.driftDetected))")
            os_log("Claude.refresh: found=%d changed=%d gap=%d hydrated=%d removed=%d scope=%{public}@",
                   log: indexLog, type: .info,
                   delta.currentByPath.count, delta.changedFiles.count,
                   missingHydratedCount,
                   existingSessions.count, delta.removedPaths.count,
                   deltaScope == .full ? "full" : "recent")

            let config = SessionIndexingEngine.ScanConfig(
                source: .claude,
                discoverFiles: { files },
                parseLightweight: { ClaudeSessionParser.parseFile(at: $0) },
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: self.progressThrottler,
                shouldContinue: { self.isRefreshTokenCurrent(token) },
                shouldMergeArchives: false,
                workerCount: executionProfile.workerCount,
                sliceSize: executionProfile.sliceSize,
                interSliceYieldNanoseconds: executionProfile.interSliceYieldNanoseconds,
                onProgress: { processed, total in
                    self.publishAfterCurrentUpdate { [weak self] in
                        guard let self, self.isRefreshTokenCurrent(token) else { return }
                        self.totalFiles = existingSessions.count + total
                        self.hasEmptyDirectory = existingSessions.isEmpty && total == 0
                        self.filesProcessed = existingSessions.count + processed
                        if processed > 0 {
                            self.progressText = "Indexed \(processed)/\(total)"
                        }
                        if self.launchPhase == .hydrating { self.launchPhase = .scanning }
                    }
                }
            )

            let scanResult = await SessionIndexingEngine.hydrateOrScan(config: config)
            let changedSessions = scanResult.sessions

            var mergedByPath: [String: Session] = [:]
            mergedByPath.reserveCapacity(existingSessions.count + changedSessions.count)
            for session in existingSessions {
                mergedByPath[session.filePath] = session
            }
            for removed in delta.removedPaths {
                mergedByPath.removeValue(forKey: removed)
            }
            for session in changedSessions {
                if let existing = mergedByPath[session.filePath],
                   !existing.events.isEmpty,
                   session.events.isEmpty {
                    #if DEBUG
                    let filename = session.filePath.components(separatedBy: "/").last ?? "?"
                    print("⚠️ Preserve full events during refresh: \(filename)")
                    #endif
                    let merged = Session(
                        id: existing.id,
                        source: existing.source,
                        startTime: existing.startTime ?? session.startTime,
                        endTime: session.endTime ?? existing.endTime,
                        model: session.model ?? existing.model,
                        filePath: existing.filePath,
                        fileSizeBytes: session.fileSizeBytes ?? existing.fileSizeBytes,
                        eventCount: max(existing.eventCount, session.eventCount),
                        events: existing.events,
                        cwd: session.lightweightCwd ?? existing.lightweightCwd,
                        repoName: nil,
                        lightweightTitle: session.lightweightTitle ?? existing.lightweightTitle,
                        lightweightCommands: session.lightweightCommands ?? existing.lightweightCommands,
                        isHousekeeping: existing.isHousekeeping,
                        codexInternalSessionIDHint: session.codexInternalSessionIDHint ?? existing.codexInternalSessionIDHint,
                        parentSessionID: session.parentSessionID ?? existing.parentSessionID,
                        subagentType: session.subagentType ?? existing.subagentType,
                        customTitle: session.customTitle ?? existing.customTitle
                    )
                    mergedByPath[session.filePath] = merged
                } else {
                    mergedByPath[session.filePath] = session
                }
            }
            let hideProbes = !(UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"))
            let merged = Array(mergedByPath.values).filter(exists)
            let filtered = merged.filter { hideProbes ? !ClaudeProbeConfig.isProbeSession($0) : true }
            let sortedSessions = filtered.sorted { $0.modifiedAt > $1.modifiedAt }
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sortedSessions, source: .claude)
            self.applyKnownFileStatsDelta(mode: effectiveMode, delta: delta)
            await self.persistKnownFileStats()

            // Persist lightweight session_meta so subsequent hydration is complete.
            // Excludes probe sessions to match analytics policy.
            let sessionsForMeta = merged.filter { !ClaudeProbeConfig.isProbeSession($0) }
            if !sessionsForMeta.isEmpty {
                do {
                    let db = try IndexDB()
                    try await db.begin()
                    for session in sessionsForMeta {
                        try? await db.upsertSessionMetaCore(SessionIndexer.sessionMetaRow(from: session))
                    }
                    try await db.commit()
                    os_log("Claude: wrote %d session_meta rows", log: indexLog, type: .info, sessionsForMeta.count)
                } catch {
                    os_log("Claude: session_meta write failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
                    // Non-fatal: hydration gap will persist until next successful write.
                }
            }

            self.publishAfterCurrentUpdate { [weak self] in
                guard let self, self.isRefreshTokenCurrent(token) else { return }
                LaunchProfiler.log("Claude.refresh: sessions merged (total=\(mergedWithArchives.count))")
                self.allSessions = mergedWithArchives
                self.isIndexing = false
                #if DEBUG
                print("✅ CLAUDE INDEXING DONE: total=\(mergedWithArchives.count) (existing=\(existingSessions.count), changed=\(changedSessions.count), removed=\(delta.removedPaths.count))")
                #endif

                // Delta-based transcript prewarm for Claude sessions.
	                let prewarmDelta: [Session] = {
	                    var out: [Session] = []
	                    out.reserveCapacity(mergedWithArchives.count)
	                    for s in mergedWithArchives {
                        if s.events.isEmpty { continue }
                        if s.messageCount <= 2 { continue }
                        if let sizeBytes = s.fileSizeBytes, sizeBytes > FeatureFlags.transcriptPrewarmMaxSessionBytes { continue }
                        if !self.shouldPrewarmSessionSignature(s) { continue }
                        out.append(s)
                        if out.count >= FeatureFlags.transcriptPrewarmMaxSessionsPerRefresh { break }
                    }
                    return out
                }()
                if !prewarmDelta.isEmpty && !executionProfile.deferNonCriticalWork {
                    self.isProcessingTranscripts = true
                    self.progressText = "Processing transcripts..."
                    self.launchPhase = .transcripts
                    let cache = self.transcriptCache
                    let finishPrewarm: @Sendable @MainActor () -> Void = { [weak self, token] in
                        guard let self, self.isRefreshTokenCurrent(token) else { return }
                        LaunchProfiler.log("Claude.refresh: transcript prewarm complete")
                        self.transcriptPrewarmTask = nil
                        self.publishAfterCurrentUpdate { [weak self, token] in
                            guard let self, self.isRefreshTokenCurrent(token) else { return }
                            self.isProcessingTranscripts = false
                            self.progressText = "Ready"
                            self.launchPhase = .ready
                        }
                    }
                    self.transcriptPrewarmTask?.cancel()
                    self.transcriptPrewarmTask = Task.detached(priority: .utility) { [prewarmDelta, cache, finishPrewarm] in
                        LaunchProfiler.log("Claude.refresh: transcript prewarm start (delta=\(prewarmDelta.count))")
                        await cache.generateAndCache(sessions: prewarmDelta)
                        if Task.isCancelled { return }
                        await finishPrewarm()
                    }
                } else {
                    self.transcriptPrewarmTask = nil
                    self.progressText = "Ready"
                    self.launchPhase = .ready
                }
            }
        }
        refreshTask = task
    }

    @MainActor
    func cancelInFlightWork() {
        setRefreshToken(UUID())
        refreshTask?.cancel()
        refreshTask = nil
        transcriptPrewarmTask?.cancel()
        transcriptPrewarmTask = nil
        isIndexing = false
        isProcessingTranscripts = false
        progressText = "Ready"
        if launchPhase != .error {
            launchPhase = .ready
        }
    }

    private func seedKnownFileStatsIfNeeded() async {
        if hasKnownFileStats() { return }
        do {
            if let persisted = try await loadPersistedKnownFileStats() {
                initializeKnownFileStatsIfNeeded(persisted)
                os_log("Claude: seeded file stats from persisted baseline (%d entries)", log: indexLog, type: .info, persisted.count)
                #if DEBUG
                LaunchProfiler.log("Claude.refresh: known file stats loaded from persisted core baseline (\(persisted.count))")
                #endif
            }
        } catch {
            os_log("Claude: seedKnownFileStats failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
            // Non-fatal. We'll bootstrap from hydrated sessions or runtime deltas.
        }
    }

    static func shouldEscalateRecentDeltaToFullReconcile(mode: IndexRefreshMode) -> Bool {
        guard mode != .fullReconcile else { return false }
        // Do not auto-upgrade recent delta scans to full reconciles during normal
        // launch/monitor refreshes. For large histories this can repeatedly trigger
        // near-full reindex passes on each app start.
        return false
    }

    private func setRefreshToken(_ token: UUID) {
        refreshStateLock.lock()
        refreshToken = token
        refreshStateLock.unlock()
    }

    private func isRefreshTokenCurrent(_ token: UUID) -> Bool {
        refreshStateLock.lock()
        let isCurrent = refreshToken == token
        refreshStateLock.unlock()
        return isCurrent
    }

    private func hasKnownFileStats() -> Bool {
        refreshStateLock.lock()
        let hasStats = !lastKnownFileStatsByPath.isEmpty
        refreshStateLock.unlock()
        return hasStats
    }

    private func initializeKnownFileStatsIfNeeded(_ stats: [String: SessionFileStat]) {
        refreshStateLock.lock()
        if lastKnownFileStatsByPath.isEmpty {
            lastKnownFileStatsByPath = stats
        }
        refreshStateLock.unlock()
    }

    private func knownFileStatsByPathSnapshot() -> [String: SessionFileStat] {
        refreshStateLock.lock()
        let snapshot = lastKnownFileStatsByPath
        refreshStateLock.unlock()
        return snapshot
    }

    private func applyKnownFileStatsDelta(mode: IndexRefreshMode, delta: SessionDiscoveryDelta) {
        refreshStateLock.lock()
        if mode == .fullReconcile {
            lastKnownFileStatsByPath = delta.currentByPath
            refreshStateLock.unlock()
            return
        }
        for removed in delta.removedPaths {
            lastKnownFileStatsByPath.removeValue(forKey: removed)
        }
        for (path, stat) in delta.currentByPath {
            lastKnownFileStatsByPath[path] = stat
        }
        refreshStateLock.unlock()
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
        #if DEBUG
        LaunchProfiler.log("Claude.refresh: known file stats bootstrapped from hydrated sessions (\(map.count))")
        #endif
    }

    private func knownFileStatsSnapshot() -> [String: SessionFileStat] {
        refreshStateLock.lock()
        let snapshot = lastKnownFileStatsByPath
        refreshStateLock.unlock()
        return snapshot
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

    private func shouldPrewarmSessionSignature(_ session: Session) -> Bool {
        let size = session.fileSizeBytes ?? 0
        let signature = size ^ (session.eventCount << 16)
        refreshStateLock.lock()
        let shouldPrewarm = (lastPrewarmSignatureByID[session.id] != signature)
        if shouldPrewarm {
            lastPrewarmSignatureByID[session.id] = signature
        }
        refreshStateLock.unlock()
        return shouldPrewarm
    }

    private func hydrateFromIndexDBIfAvailable() async throws -> [Session]? {
        // Hydrate from session_meta without requiring rollups to exist yet.
        let db = try IndexDB()
        let repo = SessionMetaRepository(db: db)
        let list = try await repo.fetchSessions(for: .claude)
        guard !list.isEmpty else { return nil }
        let sorted = list.sorted { $0.modifiedAt > $1.modifiedAt }
        return await Self.fixupHydratedClaudeTitlesIfNeeded(sorted, db: db, limit: 200)
    }

    private static func fixupHydratedClaudeTitlesIfNeeded(_ sessions: [Session], db: IndexDB, limit: Int) async -> [Session] {
        var out = sessions
        let cap = min(limit, out.count)
        guard cap > 0 else { return out }

        for i in 0..<cap {
            let current = out[i]
            guard current.source == .claude, current.events.isEmpty else { continue }
            guard let existing = current.lightweightTitle, Self.looksLikeClaudeLocalCommandTitle(existing) else { continue }
            let url = URL(fileURLWithPath: current.filePath)
            guard let reparsed = ClaudeSessionParser.parseFile(at: url),
                  let newTitleRaw = reparsed.lightweightTitle else { continue }

            let newTitle = newTitleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newTitle.isEmpty, !Self.looksLikeClaudeLocalCommandTitle(newTitle) else { continue }
            if newTitle == existing { continue }

            out[i] = Session(
                id: current.id,
                source: current.source,
                startTime: current.startTime,
                endTime: current.endTime,
                model: current.model,
                filePath: current.filePath,
                fileSizeBytes: current.fileSizeBytes,
                eventCount: current.eventCount,
                events: current.events,
                cwd: current.lightweightCwd,
                repoName: nil,
                lightweightTitle: newTitle,
                lightweightCommands: current.lightweightCommands,
                codexInternalSessionIDHint: current.codexInternalSessionIDHint,
                parentSessionID: current.parentSessionID,
                subagentType: current.subagentType,
                customTitle: current.customTitle
            )

            do {
                try await db.updateSessionMetaTitle(sessionID: current.id, source: SessionSource.claude.rawValue, title: newTitle)
            } catch {
                // Non-fatal: leave DB stale; in-memory list is still improved for this run.
            }
        }

        return out
    }

    private static func looksLikeClaudeLocalCommandTitle(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.hasPrefix("Caveat:") { return true }
        if t.contains("<local-command-") { return true }
        if t.contains("<command-name>") { return true }
        if t.contains("<command-message>") { return true }
        if t.contains("<command-args>") { return true }
        return false
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sessions list is driven by the Combine pipeline.
    }

    var modelsSeen: [String] {
        Array(Set(allSessions.compactMap { $0.model })).sorted()
    }

    // Update an existing session in allSessions (used by SearchCoordinator to persist parsed sessions)
    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
    }

    enum ReloadReason: String {
        case selection
        case focusedSessionMonitor
        case manualRefresh
    }

    // Reload a specific session with full parse.
    // When force is true, reload even if events are already present.
    func reloadSession(id: String,
                       force: Bool = false,
                       reason: ReloadReason = .selection) {
        reloadLock.lock()
        if reloadingSessionIDs.contains(id) {
            reloadLock.unlock()
            #if DEBUG
            print("⏭️ Skip reload: Claude session \(id.prefix(8)) already reloading")
            #endif
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
                #if DEBUG
                print("⏭️ Skip Claude reload: unchanged file for \(id.prefix(8)) reason=\(reason.rawValue)")
                #endif
                return
            }

            let shouldSurfaceLoadingState = reason == .manualRefresh || !hasLoadedEvents
            if shouldSurfaceLoadingState {
                self.publishAfterCurrentUpdate { [weak self] in
                    self?.isLoadingSession = true
                    self?.loadingSessionID = id
                }
            }

            let startTime = Date()
            let fullSession = ClaudeSessionParser.parseFileFull(at: url, forcedID: id)
            let elapsed = Date().timeIntervalSince(startTime)
            #if DEBUG
            print("🔄 Reloading Claude session \(id.prefix(8)) force=\(force) reason=\(reason.rawValue) elapsed=\(String(format: "%.1f", elapsed))s events=\(fullSession?.events.count ?? 0)")
            #endif

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
                print("ℹ️ Claude file changed during reload; next monitor tick will retry")
                #endif
            }

            self.publishAfterCurrentUpdate { [weak self] in
                guard let self else { return }
                defer {
                    if shouldSurfaceLoadingState, self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }

                guard let fullSession,
                      let idx = self.allSessions.firstIndex(where: { $0.id == id }) else {
                    return
                }

                let current = self.allSessions[idx]
                let merged = Session(
                    id: fullSession.id,
                    source: fullSession.source,
                    startTime: fullSession.startTime ?? current.startTime,
                    endTime: fullSession.endTime ?? current.endTime,
                    model: fullSession.model ?? current.model,
                    filePath: fullSession.filePath,
                    fileSizeBytes: fullSession.fileSizeBytes ?? current.fileSizeBytes,
                    eventCount: max(current.eventCount, fullSession.nonMetaCount),
                    events: fullSession.events,
                    cwd: current.lightweightCwd ?? fullSession.cwd,
                    repoName: current.repoName,
                    lightweightTitle: current.lightweightTitle ?? fullSession.lightweightTitle,
                    lightweightCommands: current.lightweightCommands,
                    codexInternalSessionIDHint: fullSession.codexInternalSessionIDHint ?? current.codexInternalSessionIDHint,
                    parentSessionID: fullSession.parentSessionID ?? current.parentSessionID,
                    subagentType: fullSession.subagentType ?? current.subagentType,
                    customTitle: fullSession.customTitle ?? current.customTitle
                )
                self.allSessions[idx] = merged

                let cache = self.transcriptCache
                Task.detached(priority: FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated) {
                    let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                    let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                        session: merged,
                        filters: filters,
                        mode: .normal
                    )
                    cache.set(merged.id, transcript: transcript)
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

    private func publishAfterCurrentUpdate(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                // Avoid "Publishing changes from within view updates" warnings by yielding
                // past the current render pass before mutating @Published state.
                await Task.yield()
                await Task.yield()
                work()
            }
        }
    }

    // Parse all lightweight sessions (for Analytics or full-index use cases)
    func parseAllSessionsFull(progress: @escaping (Int, Int) -> Void) async {
        let lightweightSessions = allSessions.filter { $0.events.isEmpty }
        guard !lightweightSessions.isEmpty else {
            #if DEBUG
            print("ℹ️ No lightweight Claude sessions to parse")
            #endif
            return
        }

        #if DEBUG
        print("🔍 Starting full parse of \(lightweightSessions.count) lightweight Claude sessions")
        #endif

        for (index, session) in lightweightSessions.enumerated() {
            let url = URL(fileURLWithPath: session.filePath)

            // Report progress on main thread
            await MainActor.run {
                progress(index + 1, lightweightSessions.count)
            }

            // Parse on background thread
            let fullSession = await Task.detached(priority: .userInitiated) {
                return ClaudeSessionParser.parseFileFull(at: url, forcedID: session.id)
            }.value

            // Update allSessions on main thread
            if let fullSession = fullSession {
                await MainActor.run {
                    if let idx = self.allSessions.firstIndex(where: { $0.id == session.id }) {
                        self.allSessions[idx] = fullSession

                        // Update transcript cache
                        let cache = self.transcriptCache
                        Task.detached(priority: .utility) {
                            let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                                session: fullSession,
                                filters: filters,
                                mode: .normal
                            )
                            cache.set(fullSession.id, transcript: transcript)
                        }
                    }
                }
            }
        }

        #if DEBUG
        print("✅ Completed parsing \(lightweightSessions.count) lightweight Claude sessions")
        #endif
    }

}

// MARK: - SessionIndexerProtocol Conformance
extension ClaudeSessionIndexer: SessionIndexerProtocol {
    // Uses default implementations from protocol extension
    // (requestOpenRawSheet, requestCopyPlainPublisher, requestTranscriptFindFocusPublisher)
}

import Foundation
import Combine
import SwiftUI

/// Session indexer for Claude Code sessions
final class ClaudeSessionIndexer: ObservableObject, @unchecked Sendable {
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

            #if DEBUG
            if !existingSessions.isEmpty {
                print("[Launch] Hydrated \(existingSessions.count) Claude sessions from DB (after pruning non-existent), now scanning for new files…")
            } else {
                print("[Launch] DB hydration returned nil for Claude – scanning all files")
            }
            LaunchProfiler.log("Claude.refresh: DB hydrate complete (existing=\(existingSessions.count))")
            #endif

            let deltaScope: SessionDeltaScope = (mode == .fullReconcile) ? .full : .recent
            let previousStats = self.knownFileStatsByPathSnapshot()
            let delta = self.discovery.discoverDelta(previousByPath: previousStats, scope: deltaScope)
            let files: [URL] = {
                if mode == .fullReconcile {
                    return delta.currentByPath.keys.map { URL(fileURLWithPath: $0) }
                }
                return delta.changedFiles
            }()
            #if DEBUG
            print("📁 Found \(files.count) Claude Code changed/new files (removed=\(delta.removedPaths.count), drift=\(delta.driftDetected))")
            #endif
            LaunchProfiler.log("Claude.refresh: file enumeration done (changed=\(files.count), removed=\(delta.removedPaths.count), drift=\(delta.driftDetected))")

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
                mergedByPath[session.filePath] = session
            }
            let hideProbes = !(UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"))
            let merged = Array(mergedByPath.values).filter(exists)
            let filtered = merged.filter { hideProbes ? !ClaudeProbeConfig.isProbeSession($0) : true }
            let sortedSessions = filtered.sorted { $0.modifiedAt > $1.modifiedAt }
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sortedSessions, source: .claude)
            self.applyKnownFileStatsDelta(mode: mode, delta: delta)
            self.scheduleAnalyticsDelta(changedFiles: files,
                                        removedPaths: delta.removedPaths,
                                        executionProfile: executionProfile)

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
            let db = try IndexDB()
            let indexed = try await db.fetchIndexedFiles(for: SessionSource.claude.rawValue)
            var map: [String: SessionFileStat] = [:]
            map.reserveCapacity(indexed.count)
            for row in indexed {
                map[row.path] = SessionFileStat(mtime: row.mtime, size: row.size)
            }
            initializeKnownFileStatsIfNeeded(map)
        } catch {
            // Non-fatal. Cache will be built from runtime deltas.
        }
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

    private func scheduleAnalyticsDelta(changedFiles: [URL],
                                        removedPaths: [String],
                                        executionProfile: IndexRefreshExecutionProfile) {
        guard !(changedFiles.isEmpty && removedPaths.isEmpty) else { return }
        let delay = executionProfile.deferNonCriticalWork ? UInt64(500_000_000) : UInt64(120_000_000)
        Task.detached(priority: .utility) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                let db = try IndexDB()
                let indexer = AnalyticsIndexer(db: db, enabledSources: [SessionSource.claude.rawValue])
                await indexer.refreshDelta(source: SessionSource.claude.rawValue,
                                           changed: changedFiles,
                                           removedPaths: removedPaths)
            } catch {
                // Non-fatal: analytics delta indexing is best-effort.
            }
        }
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
                lightweightCommands: current.lightweightCommands
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

    // Reload a specific lightweight session with full parse
    func reloadSession(id: String) {
        guard let existing = allSessions.first(where: { $0.id == id }),
              existing.events.isEmpty,
              FileManager.default.fileExists(atPath: existing.filePath) else {
            return
        }
        let url = URL(fileURLWithPath: existing.filePath)

        let filename = existing.filePath.components(separatedBy: "/").last ?? "?"
        #if DEBUG
        print("🔄 Reloading lightweight Claude session: \(filename)")
        #endif

        isLoadingSession = true
        loadingSessionID = id

        let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            let startTime = Date()

            if let fullSession = ClaudeSessionParser.parseFileFull(at: url, forcedID: id) {
                let elapsed = Date().timeIntervalSince(startTime)
                #if DEBUG
                print("  ⏱️ Parse took \(String(format: "%.1f", elapsed))s - events=\(fullSession.events.count)")
                #endif

                self.publishAfterCurrentUpdate { [weak self] in
                    guard let self else { return }
                    if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
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
                            lightweightCommands: current.lightweightCommands
                        )
                        self.allSessions[idx] = merged

                        // Update transcript cache for accurate search
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
                    self.isLoadingSession = false
                    self.loadingSessionID = nil
                }
            } else {
                #if DEBUG
                print("  ❌ Full parse failed")
                #endif
                self.publishAfterCurrentUpdate { [weak self] in
                    self?.isLoadingSession = false
                    self?.loadingSessionID = nil
                }
            }
        }
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

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
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    private var discovery: ClaudeSessionDiscovery
    private var lastSessionsRootOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var lastShowSystemProbeSessions: Bool = UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions")
    private var refreshToken = UUID()
    private var lastPrewarmSignatureByID: [String: Int] = [:]
    @Published private var filterEpoch: Int = 0

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
            if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 2 } }

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

    func refresh() {
        if !AgentEnablement.isEnabled(.claude) { return }
        let root = discovery.sessionsRoot()
        #if DEBUG
        print("\n🔵 CLAUDE INDEXING START: root=\(root.path)")
        #endif
        LaunchProfiler.log("Claude.refresh: start")

        let token = UUID()
        refreshToken = token
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

        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
        Task.detached(priority: prio) { [weak self, token] in
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

	            let fm = FileManager.default
	            let exists: (Session) -> Bool = { s in fm.fileExists(atPath: s.filePath) }
	            let existingSessions = indexed.filter(exists)
	            let existingPaths = Set(existingSessions.map { $0.filePath })

            #if DEBUG
            if !existingSessions.isEmpty {
                print("[Launch] Hydrated \(existingSessions.count) Claude sessions from DB (after pruning non-existent), now scanning for new files…")
            } else {
                print("[Launch] DB hydration returned nil for Claude – scanning all files")
            }
            LaunchProfiler.log("Claude.refresh: DB hydrate complete (existing=\(existingSessions.count))")
            #endif

            let files = self.discovery.discoverSessionFiles()
            #if DEBUG
            print("📁 Found \(files.count) Claude Code session files")
            #endif
            LaunchProfiler.log("Claude.refresh: file enumeration done (files=\(files.count))")

            let config = SessionIndexingEngine.ScanConfig(
                source: .claude,
                discoverFiles: { files },
                shouldParseFile: { !existingPaths.contains($0.path) },
                parseLightweight: { ClaudeSessionParser.parseFile(at: $0) },
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: self.progressThrottler,
                shouldContinue: { self.refreshToken == token },
                shouldMergeArchives: false,
                onProgress: { processed, total in
                    self.publishAfterCurrentUpdate { [weak self] in
                        guard let self, self.refreshToken == token else { return }
                        self.totalFiles = total
                        self.hasEmptyDirectory = total == 0
                        self.filesProcessed = processed
                        if processed > 0 {
                            self.progressText = "Indexed \(processed)/\(total)"
                        }
                        if self.launchPhase == .hydrating { self.launchPhase = .scanning }
                    }
                }
            )

            let scanResult = await SessionIndexingEngine.hydrateOrScan(config: config)
            let newSessions = scanResult.sessions

            // Merge existing + new, prune non-existent again, and apply probe visibility filter
            let hideProbes = !(UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"))
            let merged = (existingSessions + newSessions).filter(exists)
            let filtered = merged.filter { hideProbes ? !ClaudeProbeConfig.isProbeSession($0) : true }
            let sortedSessions = filtered.sorted { $0.modifiedAt > $1.modifiedAt }
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sortedSessions, source: .claude)

            self.publishAfterCurrentUpdate { [weak self] in
                guard let self, self.refreshToken == token else { return }
                LaunchProfiler.log("Claude.refresh: sessions merged (total=\(mergedWithArchives.count))")
                self.allSessions = mergedWithArchives
                self.isIndexing = false
                #if DEBUG
                print("✅ CLAUDE INDEXING DONE: total=\(mergedWithArchives.count) (existing=\(existingSessions.count), new=\(newSessions.count))")
                #endif

                // Delta-based transcript prewarm for Claude sessions.
                let delta: [Session] = {
                    var out: [Session] = []
                    out.reserveCapacity(mergedWithArchives.count)
                    for s in mergedWithArchives {
                        if s.events.isEmpty { continue }
                        if s.messageCount <= 2 { continue }
                        let size = s.fileSizeBytes ?? 0
                        let sig = size ^ (s.eventCount << 16)
                        if self.lastPrewarmSignatureByID[s.id] == sig { continue }
                        self.lastPrewarmSignatureByID[s.id] = sig
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
		                        LaunchProfiler.log("Claude.refresh: transcript prewarm complete")
		                        self.publishAfterCurrentUpdate { [weak self, token] in
		                            guard let self, self.refreshToken == token else { return }
		                            self.isProcessingTranscripts = false
		                            self.progressText = "Ready"
		                            self.launchPhase = .ready
		                        }
		                    }
	                    Task.detached(priority: FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated) { [delta, cache, finishPrewarm] in
	                        LaunchProfiler.log("Claude.refresh: transcript prewarm start (delta=\(delta.count))")
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
            DispatchQueue.main.async {
                Task { @MainActor in
                    work()
                }
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

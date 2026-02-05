import Foundation
import Combine
import SwiftUI

/// Session indexer for OpenClaw / Clawdbot sessions.
final class OpenClawSessionIndexer: ObservableObject, @unchecked Sendable {
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
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var previewMTimeByID: [String: Date] = [:]
    private var refreshToken = UUID()

    init() {
        let includeDeleted = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions)
        self.lastIncludeDeleted = includeDeleted
        self.discovery = OpenClawSessionDiscovery(includeDeleted: includeDeleted)

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
                let includeDeleted = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions)
                if includeDeleted != self.lastIncludeDeleted {
                    self.lastIncludeDeleted = includeDeleted
                    self.discovery = OpenClawSessionDiscovery(includeDeleted: includeDeleted)
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
        if !AgentEnablement.isEnabled(.openclaw) { return }
        let root = discovery.sessionsRoot()
        #if DEBUG
        print("\n🔵 OPENCLAW INDEXING START: root=\(root.path)")
        #endif
        LaunchProfiler.log("OpenClaw.refresh: start")

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
                source: .openclaw,
                discoverFiles: {
                    let files = self.discovery.discoverSessionFiles()
                    LaunchProfiler.log("OpenClaw.refresh: file enumeration done (files=\(files.count))")
                    return files
                },
                parseLightweight: { OpenClawSessionParser.parseFile(at: $0) },
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
                    LaunchProfiler.log("OpenClaw.refresh: DB hydrate hit (sessions=\(result.sessions.count))")
                    self.allSessions = result.sessions
                    self.isIndexing = false
                    self.filesProcessed = result.sessions.count
                    self.totalFiles = result.sessions.count
                    self.progressText = "Loaded \(result.sessions.count) from index"
                    self.launchPhase = .ready
                    self.previewMTimeByID = previewTimesByID
                    #if DEBUG
                    print("[Launch] Hydrated OpenClaw sessions from DB: count=\(result.sessions.count)")
                    #endif
                    return
                case .scanned:
                    break
                }

                LaunchProfiler.log("OpenClaw.refresh: sessions merged (total=\(result.sessions.count))")
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
                print("✅ OPENCLAW INDEXING DONE: total=\(self.totalFiles)")
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
            let full = OpenClawSessionParser.parseFileFull(at: url)
            let elapsed = Date().timeIntervalSince(start)
            #if DEBUG
            print("  ⏱️ OpenClaw parse took \(String(format: "%.1f", elapsed))s - events=\(full?.events.count ?? 0)")
            #endif

            Task { @MainActor [weak self] in
                guard let self else { return }
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
                        isHousekeeping: full.isHousekeeping
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
}

// MARK: - SessionIndexerProtocol Conformance
extension OpenClawSessionIndexer: SessionIndexerProtocol {}

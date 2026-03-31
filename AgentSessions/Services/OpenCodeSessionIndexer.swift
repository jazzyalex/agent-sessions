import Foundation
import Combine
import SwiftUI

/// Session indexer for OpenCode sessions (read-only, local storage)
final class OpenCodeSessionIndexer: ObservableObject, @unchecked Sendable {
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

    // UI focus coordination (shared with other indexers via protocol)
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    // Transcript cache for accurate search
    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    @AppStorage("OpenCodeSessionsRootOverride") var sessionsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }

    private var discovery: OpenCodeSessionDiscovery
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]
    private var detectedBackend: OpenCodeStorageBackend = .none

    init() {
        let initialOverride = UserDefaults.standard.string(forKey: "OpenCodeSessionsRootOverride") ?? ""
        self.discovery = OpenCodeSessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)

        // Debounced filtering similar to Claude/Gemini indexers
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
                let filters = Filters(query: q,
                                      dateFrom: from,
                                      dateTo: to,
                                      model: model,
                                      kinds: kinds,
                                      repoName: self?.projectFilter,
                                      pathContains: nil)
                var results = FilterEngine.filterSessions(all,
                                                          filters: filters,
                                                          transcriptCache: self?.transcriptCache,
                                                          allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
                if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 } }
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
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
        if !AgentEnablement.isEnabled(.opencode) { return }

        let customRoot = sessionsRootOverride.isEmpty ? nil : sessionsRootOverride
        let backend = OpenCodeBackendDetector.detect(customRoot: customRoot)
        detectedBackend = backend

        #if DEBUG
        if backend == .json {
            let root = discovery.sessionsRoot()
            let storageRoot = (root.lastPathComponent == "session") ? root.deletingLastPathComponent() : root
            let migrationURL = storageRoot.appendingPathComponent("migration", isDirectory: false)
            if let data = try? Data(contentsOf: migrationURL),
               let str = String(data: data, encoding: .utf8) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                let version = trimmed.isEmpty ? "(empty)" : trimmed
                print("OpenCode storage schema: migration=\(version)")
            } else {
                print("OpenCode storage schema: migration=(missing)")
            }
        }
        print("\n🟣 OPENCode INDEXING START: backend=\(backend.rawValue)")
        #endif
        LaunchProfiler.log("OpenCode.refresh: start (backend=\(backend.rawValue))")

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

        switch backend {
        case .sqlite:
            let capturedCustomRoot = customRoot
            Task.detached(priority: prio) { [weak self, token] in
                guard let self else { return }
                LaunchProfiler.log("OpenCode.refresh: reading SQLite sessions")
                let sessions = OpenCodeSqliteReader.listSessions(customRoot: capturedCustomRoot)
                let sorted = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
                let merged = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sorted, source: .opencode)
                await MainActor.run {
                    guard self.refreshToken == token else { return }
                    LaunchProfiler.log("OpenCode.refresh: SQLite sessions loaded (total=\(merged.count))")
                    self.allSessions = merged
                    self.isIndexing = false
                    self.hasEmptyDirectory = merged.isEmpty
                    self.progressText = "Ready"
                    self.launchPhase = .ready
                }
            }

        case .json:
            Task.detached(priority: prio) { [weak self, token] in
                guard let self else { return }

                let config = SessionIndexingEngine.ScanConfig(
                    source: .opencode,
                    discoverFiles: { self.discovery.discoverSessionFiles() },
                    parseLightweight: { OpenCodeSessionParser.parseFile(at: $0) },
                    shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                    throttler: self.progressThrottler,
                    onProgress: { processed, total in
                        guard self.refreshToken == token else { return }
                        self.totalFiles = total
                        self.filesProcessed = processed
                        self.hasEmptyDirectory = (total == 0)
                        if total > 0 {
                            self.progressText = "Indexed \(processed)/\(total)"
                        }
                        if self.launchPhase == .hydrating {
                            self.launchPhase = .scanning
                        }
                    }
                )

                let result = await SessionIndexingEngine.hydrateOrScan(config: config)
                await MainActor.run {
                    guard self.refreshToken == token else { return }
                    LaunchProfiler.log("OpenCode.refresh: JSON sessions merged (total=\(result.sessions.count))")
                    self.allSessions = result.sessions
                    self.isIndexing = false
                    if FeatureFlags.throttleIndexingUIUpdates {
                        self.filesProcessed = self.totalFiles
                        if self.totalFiles > 0 {
                            self.progressText = "Indexed \(self.totalFiles)/\(self.totalFiles)"
                        }
                    }
                    self.progressText = "Ready"
                    self.launchPhase = .ready
                }
            }

        case .none:
            Task { @MainActor [weak self, token] in
                guard let self, self.refreshToken == token else { return }
                self.allSessions = []
                self.isIndexing = false
                self.hasEmptyDirectory = true
                self.progressText = "Ready"
                self.launchPhase = .ready
            }
        }
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query,
                              dateFrom: dateFrom,
                              dateTo: dateTo,
                              model: selectedModel,
                              kinds: selectedKinds,
                              repoName: projectFilter,
                              pathContains: nil)
	        var results = FilterEngine.filterSessions(allSessions, filters: filters, transcriptCache: transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
	        if hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
	        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
	        Task { @MainActor [weak self] in
	            self?.sessions = results
	        }
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

        let ioQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        let capturedBackend = detectedBackend
        let capturedCustomRoot = sessionsRootOverride.isEmpty ? nil : sessionsRootOverride
        ioQueue.async {
            defer {
                self.reloadLock.lock()
                self.reloadingSessionIDs.remove(id)
                self.reloadLock.unlock()
            }

            guard let existing = existingSnapshot else { return }
            let hasLoadedEvents = !existing.events.isEmpty
            if hasLoadedEvents && !force { return }

            if capturedBackend == .sqlite {
                // SQLite path: no file on disk, load from DB directly
                let shouldSurfaceLoadingState = reason == .manualRefresh || !hasLoadedEvents
                if shouldSurfaceLoadingState {
                    Task { @MainActor [weak self] in
                        self?.isLoadingSession = true
                        self?.loadingSessionID = id
                    }
                }

                let parsed = OpenCodeSqliteReader.loadFullSession(customRoot: capturedCustomRoot, sessionID: id) ?? existing
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        if shouldSurfaceLoadingState, self.loadingSessionID == id {
                            self.isLoadingSession = false
                            self.loadingSessionID = nil
                        }
                    }
                    if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                        let current = self.allSessions[idx]
                        let merged = Session(
                            id: parsed.id,
                            source: parsed.source,
                            startTime: parsed.startTime ?? current.startTime,
                            endTime: parsed.endTime ?? current.endTime,
                            model: parsed.model ?? current.model,
                            filePath: parsed.filePath,
                            fileSizeBytes: parsed.fileSizeBytes ?? current.fileSizeBytes,
                            eventCount: max(current.eventCount, parsed.nonMetaCount),
                            events: parsed.events,
                            cwd: current.lightweightCwd ?? parsed.cwd,
                            repoName: current.repoName,
                            lightweightTitle: current.lightweightTitle ?? parsed.lightweightTitle,
                            lightweightCommands: current.lightweightCommands,
                            parentSessionID: parsed.parentSessionID ?? current.parentSessionID,
                            subagentType: parsed.subagentType ?? current.subagentType,
                            customTitle: parsed.customTitle ?? current.customTitle
                        )
                        self.allSessions[idx] = merged
                    }
                    self.recomputeNow()
                }
                return
            }

            // JSON path
            guard FileManager.default.fileExists(atPath: existing.filePath) else { return }

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

            let parsed = OpenCodeSessionParser.parseFileFull(at: url) ?? existing
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
                print("ℹ️ OpenCode file changed during reload; next monitor tick will retry")
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

                if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                    let current = self.allSessions[idx]
                    let merged = Session(
                        id: parsed.id,
                        source: parsed.source,
                        startTime: parsed.startTime ?? current.startTime,
                        endTime: parsed.endTime ?? current.endTime,
                        model: parsed.model ?? current.model,
                        filePath: parsed.filePath,
                        fileSizeBytes: parsed.fileSizeBytes ?? current.fileSizeBytes,
                        eventCount: max(current.eventCount, parsed.nonMetaCount),
                        events: parsed.events,
                        cwd: current.lightweightCwd ?? parsed.cwd,
                        repoName: current.repoName,
                        lightweightTitle: current.lightweightTitle ?? parsed.lightweightTitle,
                        lightweightCommands: current.lightweightCommands,
                        parentSessionID: parsed.parentSessionID ?? current.parentSessionID,
                        subagentType: parsed.subagentType ?? current.subagentType,
                        customTitle: parsed.customTitle ?? current.customTitle
                    )
                    self.allSessions[idx] = merged
                }
                self.recomputeNow()
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

}

// MARK: - SessionIndexerProtocol Conformance

extension OpenCodeSessionIndexer: SessionIndexerProtocol {}

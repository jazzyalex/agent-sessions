import Foundation
import Combine
import SwiftUI

final class HermesSessionIndexer: ObservableObject, SessionIndexerProtocol, @unchecked Sendable {
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
    @Published var query: String = ""
    @Published var queryDraft: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var selectedModel: String? = nil
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    @Published var projectFilter: String? = nil
    @Published var isLoadingSession: Bool = false
    @Published var loadingSessionID: String? = nil
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    @AppStorage(PreferencesKey.Paths.hermesSessionsRootOverride) var sessionsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true { didSet { recomputeNow() } }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true { didSet { recomputeNow() } }

    private var discovery: HermesSessionDiscovery
    private var lastOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]

    init() {
        let initialOverride = UserDefaults.standard.string(forKey: PreferencesKey.Paths.hermesSessionsRootOverride) ?? ""
        self.discovery = HermesSessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)
        self.lastOverride = initialOverride

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
                var results = FilterEngine.filterSessions(all, filters: filters, transcriptCache: self?.transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
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

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(.hermes) { return }

        let currentOverride = UserDefaults.standard.string(forKey: PreferencesKey.Paths.hermesSessionsRootOverride) ?? ""
        if currentOverride != lastOverride {
            discovery = HermesSessionDiscovery(customRoot: currentOverride.isEmpty ? nil : currentOverride)
            lastOverride = currentOverride
        }

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
        Task.detached(priority: prio) { [weak self, token, executionProfile] in
            guard let self else { return }

            let config = SessionIndexingEngine.ScanConfig(
                source: .hermes,
                discoverFiles: { self.discovery.discoverSessionFiles() },
                parseLightweight: { HermesSessionParser.parseFile(at: $0) },
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: self.progressThrottler,
                shouldContinue: { self.refreshToken == token },
                workerCount: executionProfile.workerCount,
                sliceSize: executionProfile.sliceSize,
                interSliceYieldNanoseconds: executionProfile.interSliceYieldNanoseconds,
                onProgress: { processed, total in
                    guard self.refreshToken == token else { return }
                    self.totalFiles = total
                    self.filesProcessed = processed
                    self.hasEmptyDirectory = (total == 0)
                    if processed > 0 { self.progressText = "Indexed \(processed)/\(total)" }
                    if self.launchPhase == .hydrating { self.launchPhase = .scanning }
                }
            )

            let result = await SessionIndexingEngine.hydrateOrScan(config: config)
            await MainActor.run {
                guard self.refreshToken == token else { return }
                self.allSessions = result.sessions
                self.isIndexing = false
                self.filesProcessed = self.totalFiles
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
        Task { @MainActor [weak self] in self?.sessions = results }
    }

    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: updated, filters: filters, mode: .normal)
        transcriptCache.set(updated.id, transcript: transcript)
    }

    enum ReloadReason: String {
        case selection
        case focusedSessionMonitor
        case manualRefresh
    }

    func reloadSession(id: String, force: Bool = false, reason: ReloadReason = .selection) {
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
        ioQueue.async {
            defer {
                self.reloadLock.lock()
                self.reloadingSessionIDs.remove(id)
                self.reloadLock.unlock()
            }

            guard let existing = existingSnapshot,
                  FileManager.default.fileExists(atPath: existing.filePath) else { return }

            let hasLoadedEvents = !existing.events.isEmpty
            if hasLoadedEvents && !force { return }

            let url = URL(fileURLWithPath: existing.filePath)
            let preParseStat = Self.fileStat(for: url)
            self.reloadLock.lock()
            let lastReloadStat = self.lastFullReloadFileStatsBySessionID[id]
            self.reloadLock.unlock()
            if force, reason != .manualRefresh, hasLoadedEvents, let preParseStat, let lastReloadStat, preParseStat == lastReloadStat {
                return
            }

            let shouldSurfaceLoadingState = reason == .manualRefresh || !hasLoadedEvents
            if shouldSurfaceLoadingState {
                Task { @MainActor [weak self] in
                    self?.isLoadingSession = true
                    self?.loadingSessionID = id
                }
            }

            let parsed = HermesSessionParser.parseFileFull(at: url) ?? existing
            self.reloadLock.lock()
            if let preParseStat { self.lastFullReloadFileStatsBySessionID[id] = preParseStat }
            self.reloadLock.unlock()

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
                    let merged = Session(id: parsed.id,
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
                                         lightweightCommands: current.lightweightCommands)
                    self.allSessions[idx] = merged
                    let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                    let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: merged, filters: filters, mode: .normal)
                    self.transcriptCache.set(merged.id, transcript: transcript)
                }
                self.recomputeNow()
            }
        }
    }

    private static func fileStat(for url: URL) -> SessionFileStat? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else { return nil }
        return SessionFileStat(mtime: Int64(modified.timeIntervalSince1970), size: Int64(values.fileSize ?? 0))
    }
}

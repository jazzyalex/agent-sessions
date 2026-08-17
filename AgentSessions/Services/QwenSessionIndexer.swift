import Foundation
import Combine
import SwiftUI

final class QwenSessionIndexer: ObservableObject, SessionIndexerProtocol, @unchecked Sendable {
    @Published private(set) var allSessions: [Session] = []
    @Published private(set) var sessions: [Session] = []
    @Published var isIndexing = false
    @Published var isProcessingTranscripts = false
    @Published var progressText = ""
    @Published var filesProcessed = 0
    @Published var totalFiles = 0
    @Published var indexingError: String?
    @Published var hasEmptyDirectory = false
    @Published var launchPhase: LaunchPhase = .idle
    @Published var query = ""
    @Published var queryDraft = ""
    @Published var dateFrom: Date?
    @Published var dateTo: Date?
    @Published var selectedModel: String?
    @Published var selectedKinds = Set(SessionEventKind.allCases)
    @Published var projectFilter: String?
    @Published var isLoadingSession = false
    @Published var loadingSessionID: String?
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    @AppStorage(QwenPreferencesKey.sessionsRootOverride) var sessionsRootOverride = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref = true { didSet { recomputeNow() } }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref = true { didSet { recomputeNow() } }

    private var discovery: QwenSessionDiscovery
    private var lastOverride: String
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]

    init() {
        let initialOverride = UserDefaults.standard.string(forKey: QwenPreferencesKey.sessionsRootOverride) ?? ""
        discovery = QwenSessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)
        lastOverride = initialOverride

        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: OptionalDateEquality.eq),
            $dateTo.removeDuplicates(by: OptionalDateEquality.eq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest3(inputs, $selectedKinds.removeDuplicates(), $allSessions)
            .receive(on: FeatureFlags.backgroundIngestQueue)
            .map { [weak self] input, kinds, all -> [Session] in
                let (query, from, to, model) = input
                let filters = Filters(query: query, dateFrom: from, dateTo: to, model: model,
                                      kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var result = FilterEngine.filterSessions(
                    all,
                    filters: filters,
                    transcriptCache: self?.transcriptCache,
                    allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly
                )
                if self?.hideZeroMessageSessionsPref ?? true { result = result.filter { $0.messageCount > 0 } }
                if self?.hideLowMessageSessionsPref ?? true { result = result.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
                return result
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)
    }

    var canAccessRootDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: discovery.sessionsRoot().path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        guard AgentEnablement.isEnabled(.qwen) else { return }
        let currentOverride = UserDefaults.standard.string(forKey: QwenPreferencesKey.sessionsRootOverride) ?? ""
        if currentOverride != lastOverride {
            discovery = QwenSessionDiscovery(customRoot: currentOverride.isEmpty ? nil : currentOverride)
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
        let priority: TaskPriority = FeatureFlags.lowerQoSForBackgroundIngest ? .utility : requestedPriority
        Task.detached(priority: priority) { [weak self, token, executionProfile] in
            guard let self else { return }
            let config = SessionIndexingEngine.ScanConfig(
                source: .qwen,
                discoverFiles: { self.discovery.discoverSessionFiles() },
                parseLightweight: { QwenSessionParser.parseFile(at: $0) },
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: self.progressThrottler,
                shouldContinue: { self.refreshToken == token },
                workerCount: executionProfile.workerCount,
                sliceSize: executionProfile.sliceSize,
                interSliceYieldNanoseconds: executionProfile.interSliceYieldNanoseconds,
                onProgress: { processed, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.refreshToken == token else { return }
                        self.totalFiles = total
                        self.filesProcessed = processed
                        self.hasEmptyDirectory = total == 0
                        if processed > 0 { self.progressText = "Indexed \(processed)/\(total)" }
                        if self.launchPhase == .hydrating { self.launchPhase = .scanning }
                    }
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
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo,
                              model: selectedModel, kinds: selectedKinds,
                              repoName: projectFilter, pathContains: nil)
        var result = FilterEngine.filterSessions(
            allSessions,
            filters: filters,
            transcriptCache: transcriptCache,
            allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly
        )
        if hideZeroMessageSessionsPref { result = result.filter { $0.messageCount > 0 } }
        if hideLowMessageSessionsPref { result = result.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
        Task { @MainActor [weak self] in self?.sessions = result }
    }

    func updateSession(_ updated: Session) {
        if let index = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[index] = updated
        }
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        transcriptCache.set(updated.id, transcript: SessionTranscriptBuilder.buildPlainTerminalTranscript(
            session: updated, filters: filters, mode: .normal
        ))
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
            if Thread.isMainThread { return allSessions.first(where: { $0.id == id }) }
            var value: Session?
            DispatchQueue.main.sync { value = allSessions.first(where: { $0.id == id }) }
            return value
        }()

        FeatureFlags.backgroundIngestQueue.async {
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
            let lastStat = self.lastFullReloadFileStatsBySessionID[id]
            self.reloadLock.unlock()
            if force, reason != .manualRefresh, hasLoadedEvents,
               let preParseStat, let lastStat, preParseStat == lastStat { return }

            let showLoading = reason == .manualRefresh || !hasLoadedEvents
            if showLoading {
                Task { @MainActor [weak self] in
                    self?.isLoadingSession = true
                    self?.loadingSessionID = id
                }
            }

            let parsed = QwenSessionParser.parseFileFull(at: url, allowLargeFile: true)
            self.reloadLock.lock()
            if let preParseStat { self.lastFullReloadFileStatsBySessionID[id] = preParseStat }
            self.reloadLock.unlock()

            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if showLoading, self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }
                guard let index = self.allSessions.firstIndex(where: { $0.id == id }) else { return }
                let current = self.allSessions[index]
                let merged = Self.mergeReloadedSession(current: current, parsed: parsed)
                self.allSessions[index] = merged
                let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                self.transcriptCache.set(merged.id, transcript: SessionTranscriptBuilder.buildPlainTerminalTranscript(
                    session: merged, filters: filters, mode: .normal
                ))
                self.recomputeNow()
            }
        }
    }

    /// A full Qwen parse reconstructs the writer's current active parent chain.
    /// Chain-derived list metadata must therefore replace, not monotonically
    /// merge with, a pre-rewind lightweight snapshot.
    static func mergeReloadedSession(current: Session, parsed: Session?) -> Session {
        parsed ?? current
    }

    private static func fileStat(for url: URL) -> SessionFileStat? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else { return nil }
        return SessionFileStat(mtime: Int64(modified.timeIntervalSince1970),
                               size: Int64(values.fileSize ?? 0))
    }
}

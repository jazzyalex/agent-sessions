import Foundation
import Combine
import SwiftUI

final class DevinSessionIndexer: ObservableObject, SessionIndexerProtocol, @unchecked Sendable {
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

    // K2: keys stay in the descriptor as literals; the @AppStorage mirror reads
    // the same string so the indexer's override observation matches the pane.
    @AppStorage("DevinSessionsRootOverride") var sessionsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true { didSet { recomputeNow() } }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true { didSet { recomputeNow() } }

    private var discovery: DevinSessionDiscovery
    private var lastOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]
    private(set) var searchIdentitySnapshot: SearchIngestService.IdentitySnapshot?

    init() {
        let initialOverride = UserDefaults.standard.string(forKey: "DevinSessionsRootOverride") ?? ""
        self.discovery = DevinSessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)
        self.lastOverride = initialOverride

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
        return discovery.hasDatabase()
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(.devin) { return }

        let currentOverride = UserDefaults.standard.string(forKey: "DevinSessionsRootOverride") ?? ""
        if currentOverride != lastOverride {
            discovery = DevinSessionDiscovery(customRoot: currentOverride.isEmpty ? nil : currentOverride)
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
        let prio: TaskPriority = FeatureFlags.lowerQoSForBackgroundIngest ? .utility : requestedPriority
        Task.detached(priority: prio) { [weak self, token] in
            guard let self else { return }

            // A single database, so there is nothing to enumerate and no
            // per-file progress to report: one read returns every session.
            let dbPath = self.discovery.databaseURL().path
            let readResult = DevinSqliteReader.listSessionsIfReadable(databasePath: dbPath)
            let sessions = readResult ?? []
            let merged = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sessions, source: .devin)
            let identitySnapshot = readResult.map {
                SearchIngestService.IdentitySnapshot(storagePaths: [dbPath],
                                                     sessionIDs: Set($0.map(\.id)))
            }
            await MainActor.run {
                guard self.refreshToken == token else { return }
                self.allSessions = merged
                self.searchIdentitySnapshot = identitySnapshot
                self.isIndexing = false
                self.totalFiles = merged.count
                self.filesProcessed = merged.count
                self.hasEmptyDirectory = merged.isEmpty
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

        let ioQueue = FeatureFlags.backgroundIngestQueue
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

            let parsed = DevinSqliteReader.loadFullSession(databasePath: url.path, sessionID: id) ?? existing
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
                    // Devin supports rewind/branch replacement (message_nodes is a
                    // forest and main_chain_id names the live tip), so a successful
                    // reload is authoritative for every branch-derived field:
                    // rendered events, non-metadata count, title, custom title, cwd,
                    // and model. Do not merge with max or stale non-nil fallbacks —
                    // that would preserve discarded-branch metadata beside the newly
                    // parsed transcript.
                    let merged = Session(id: parsed.id,
                                         source: parsed.source,
                                         startTime: parsed.startTime ?? current.startTime,
                                         endTime: parsed.endTime ?? current.endTime,
                                         model: parsed.model,
                                         filePath: parsed.filePath,
                                         fileSizeBytes: parsed.fileSizeBytes ?? current.fileSizeBytes,
                                         eventCount: parsed.nonMetaCount,
                                         events: parsed.events,
                                         cwd: parsed.cwd,
                                         repoName: parsed.repoName,
                                         lightweightTitle: parsed.lightweightTitle,
                                         lightweightCommands: current.lightweightCommands,
                                         parentSessionID: parsed.parentSessionID ?? current.parentSessionID,
                                         subagentType: parsed.subagentType ?? current.subagentType,
                                         customTitle: parsed.customTitle,
                                         surface: parsed.surface ?? current.surface,
                                         reasoningEffort: parsed.reasoningEffort)
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

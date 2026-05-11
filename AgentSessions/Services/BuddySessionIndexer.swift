import Foundation
import Combine
import SwiftUI

/// Indexes JSONL transcripts for one Buddy product (CodeBuddy or WorkBuddy).
final class BuddySessionIndexer: ObservableObject, @unchecked Sendable {
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

    private let productSource: SessionSource
    private var discovery: BuddySessionDiscovery
    private var lastCodebuddyOverride: String = ""
    private var lastWorkbuddyOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]

    init(productSessionSource: SessionSource) {
        precondition(productSessionSource == .codebuddy || productSessionSource == .workbuddy)
        self.productSource = productSessionSource
        let c = UserDefaults.standard.string(forKey: PreferencesKey.Paths.buddyCodebuddyProjectsRootOverride) ?? ""
        let w = UserDefaults.standard.string(forKey: PreferencesKey.Paths.buddyWorkbuddyProjectsRootOverride) ?? ""
        self.lastCodebuddyOverride = c
        self.lastWorkbuddyOverride = w
        self.discovery = BuddySessionDiscovery(
            codebuddyProjectsRoot: c.isEmpty ? nil : c,
            workbuddyProjectsRoot: w.isEmpty ? nil : w,
            scanCodebuddy: productSessionSource == .codebuddy,
            scanWorkbuddy: productSessionSource == .workbuddy
        )

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
                var results = FilterEngine.filterSessions(
                    all,
                    filters: filters,
                    transcriptCache: self?.transcriptCache,
                    allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly
                )
                let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
                let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true
                if hideZero { results = results.filter { $0.messageCount > 0 } }
                if hideLow { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)
    }

    var canAccessRootDirectory: Bool {
        discovery.projectRoots().contains { root in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(productSource) { return }

        let c = UserDefaults.standard.string(forKey: PreferencesKey.Paths.buddyCodebuddyProjectsRootOverride) ?? ""
        let w = UserDefaults.standard.string(forKey: PreferencesKey.Paths.buddyWorkbuddyProjectsRootOverride) ?? ""
        if c != lastCodebuddyOverride || w != lastWorkbuddyOverride {
            discovery = BuddySessionDiscovery(
                codebuddyProjectsRoot: c.isEmpty ? nil : c,
                workbuddyProjectsRoot: w.isEmpty ? nil : w,
                scanCodebuddy: productSource == .codebuddy,
                scanWorkbuddy: productSource == .workbuddy
            )
            lastCodebuddyOverride = c
            lastWorkbuddyOverride = w
        }

        let token = UUID()
        refreshToken = token
        launchPhase = .hydrating
        isIndexing = true
        isProcessingTranscripts = false
        progressText = "Scanning..."
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        let parseLightweight: (URL) -> Session? = { [productSource] url in
            switch productSource {
            case .codebuddy: return CodebuddySessionParser.parseFile(at: url)
            case .workbuddy: return WorkbuddySessionParser.parseFile(at: url)
            default: return nil
            }
        }

        let requestedPriority: TaskPriority = executionProfile.deferNonCriticalWork ? .utility : .userInitiated
        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : requestedPriority
        Task.detached(priority: prio) { [weak self, token, executionProfile, parseLightweight] in
            guard let self else { return }

            let config = SessionIndexingEngine.ScanConfig(
                source: self.productSource,
                discoverFiles: {
                    let files = self.discovery.discoverSessionFiles()
                    LaunchProfiler.log("Buddy[\(self.productSource.rawValue)].refresh: file enumeration done (files=\(files.count))")
                    return files
                },
                parseLightweight: parseLightweight,
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: self.progressThrottler,
                shouldContinue: { self.refreshToken == token },
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

            let result = await SessionIndexingEngine.hydrateOrScan(config: config)

            await MainActor.run {
                guard self.refreshToken == token else { return }
                LaunchProfiler.log("Buddy[\(self.productSource.rawValue)].refresh: sessions merged (total=\(result.sessions.count))")
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

            let shouldSurfaceLoadingState = reason == .manualRefresh || !hasLoadedEvents
            if shouldSurfaceLoadingState {
                Task { @MainActor [weak self] in
                    self?.isLoadingSession = true
                    self?.loadingSessionID = id
                }
            }

            let full: Session?
            switch self.productSource {
            case .codebuddy: full = CodebuddySessionParser.parseFileFull(at: url, forcedID: id)
            case .workbuddy: full = WorkbuddySessionParser.parseFileFull(at: url, forcedID: id)
            default: full = nil
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
                        repoName: current.repoName ?? full.repoName,
                        lightweightTitle: current.lightweightTitle ?? full.lightweightTitle,
                        lightweightCommands: current.lightweightCommands,
                        isHousekeeping: full.isHousekeeping,
                        codexInternalSessionIDHint: full.codexInternalSessionIDHint ?? current.codexInternalSessionIDHint
                    )
                    self.allSessions[idx] = merged
                    if let preParseStat {
                        self.lastFullReloadFileStatsBySessionID[id] = preParseStat
                    }
                    let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                    let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: merged, filters: filters, mode: .normal)
                    self.transcriptCache.set(merged.id, transcript: transcript)
                }
            }
        }
    }

    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: updated, filters: filters, mode: .normal)
        transcriptCache.set(updated.id, transcript: transcript)
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

extension BuddySessionIndexer: SessionIndexerProtocol {}

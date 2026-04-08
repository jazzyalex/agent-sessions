import Foundation
import Combine
import SwiftUI

/// Session indexer for Cursor sessions (read-only, local storage).
///
/// Dual-backend: JSONL transcripts for messages + chat DB meta for session metadata.
/// Merges both sources by session UUID.
final class CursorSessionIndexer: ObservableObject, SessionIndexerProtocol, @unchecked Sendable {
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

    // UI focus coordination
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    // Transcript cache for accurate search
    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    @AppStorage(PreferencesKey.Paths.cursorSessionsRootOverride) private var sessionsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") private var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") private var hideLowMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }

    private var discovery: CursorSessionDiscovery
    private var lastOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]

    init() {
        let initial = UserDefaults.standard.string(forKey: PreferencesKey.Paths.cursorSessionsRootOverride) ?? ""
        self.discovery = CursorSessionDiscovery(customRoot: initial.isEmpty ? nil : initial)
        self.lastOverride = initial

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
                if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 || CursorSessionIndexer.isDBOnlySession($0) } }
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 || CursorSessionIndexer.isDBOnlySession($0) } }
                return results
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] results in
                self?.sessions = results
            }
            .store(in: &cancellables)
    }

    var canAccessRootDirectory: Bool {
        let fm = FileManager.default
        let projects = discovery.sessionsRoot()
        let chats = discovery.chatsRoot()
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: projects.path, isDirectory: &isDir), isDir.boolValue { return true }
        var isDir2: ObjCBool = false
        return fm.fileExists(atPath: chats.path, isDirectory: &isDir2) && isDir2.boolValue
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(.cursor) { return }

        // Update discovery if override changed
        let current = UserDefaults.standard.string(forKey: PreferencesKey.Paths.cursorSessionsRootOverride) ?? ""
        if current != lastOverride {
            discovery = CursorSessionDiscovery(customRoot: current.isEmpty ? nil : current)
            lastOverride = current
        }

        #if DEBUG
        print("\n🟤 CURSOR INDEXING START: projects=\(discovery.sessionsRoot().path) mode=\(mode) trigger=\(trigger.rawValue)")
        #endif
        LaunchProfiler.log("Cursor.refresh: start (mode=\(mode), trigger=\(trigger.rawValue))")

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
        let capturedCustomRoot = current.isEmpty ? nil : current

        Task.detached(priority: prio) { [weak self, token] in
            guard let self else { return }

            // Step 1: Discover and parse JSONL transcripts
            let config = SessionIndexingEngine.ScanConfig(
                source: .cursor,
                discoverFiles: { self.discovery.discoverSessionFiles() },
                parseLightweight: { CursorSessionParser.parseFile(at: $0) },
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
                    if processed > 0 {
                        self.progressText = "Indexed \(processed)/\(total)"
                    }
                    if self.launchPhase == .hydrating { self.launchPhase = .scanning }
                }
            )

            let scanResult = await SessionIndexingEngine.hydrateOrScan(config: config)
            var transcriptSessions = scanResult.sessions

            // Step 2: Read chat DB metadata
            let metaList = CursorChatMetaReader.listSessionMeta(customRoot: capturedCustomRoot)
            let metaByID = Dictionary(metaList.map { ($0.agentId, $0) }, uniquingKeysWith: { a, _ in a })

            // Step 3: Collect known project paths for workspace hash resolution
            let projectPaths = self.collectKnownProjectPaths()

            // Step 4: Merge — enrich transcript sessions with DB metadata
            for i in transcriptSessions.indices {
                let session = transcriptSessions[i]
                if let meta = metaByID[session.id] {
                    transcriptSessions[i] = Self.enrichSession(session, with: meta, knownProjectPaths: projectPaths)
                }
            }

            // Step 5: Add DB-only sessions (no transcript)
            let transcriptIDs = Set(transcriptSessions.map(\.id))
            for meta in metaList where !transcriptIDs.contains(meta.agentId) {
                let dbOnlySession = Self.sessionFromMeta(meta, knownProjectPaths: projectPaths)
                transcriptSessions.append(dbOnlySession)
            }

            // Sort by most recent first
            let sorted = transcriptSessions.sorted { $0.modifiedAt > $1.modifiedAt }

            await MainActor.run {
                guard self.refreshToken == token else { return }
                self.allSessions = sorted
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
        var results = FilterEngine.filterSessions(allSessions,
                                                  filters: filters,
                                                  transcriptCache: transcriptCache,
                                                  allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
        // Exempt DB-only Cursor sessions (no transcript) from zero/low-message filters
        // so they remain visible when transcripts are absent.
        if hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 || Self.isDBOnlySession($0) } }
        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 || Self.isDBOnlySession($0) } }
        Task { @MainActor [weak self] in
            self?.sessions = results
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
        ioQueue.async {
            defer {
                self.reloadLock.lock()
                self.reloadingSessionIDs.remove(id)
                self.reloadLock.unlock()
            }

            guard let existing = existingSnapshot else { return }
            let hasLoadedEvents = !existing.events.isEmpty
            if hasLoadedEvents && !force { return }

            // DB-only sessions have no transcript file to reload
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

            let parsed = CursorSessionParser.parseFileFull(at: url, forcedID: id) ?? existing
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
                print("ℹ️ Cursor file changed during reload; next monitor tick will retry")
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
                        lightweightCommands: current.lightweightCommands ?? parsed.lightweightCommands,
                        parentSessionID: parsed.parentSessionID ?? current.parentSessionID,
                        subagentType: parsed.subagentType ?? current.subagentType,
                        customTitle: current.customTitle ?? parsed.customTitle
                    )
                    self.allSessions[idx] = merged

                    let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                    let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: merged, filters: filters, mode: .normal)
                    self.transcriptCache.set(merged.id, transcript: transcript)
                }
                self.recomputeNow()
            }
        }
    }

    // MARK: - Merge Helpers

    /// Enrich a transcript-parsed session with chat DB metadata.
    private static func enrichSession(_ session: Session, with meta: CursorSessionMeta, knownProjectPaths: [String]) -> Session {
        let model: String?
        if meta.lastUsedModel != "default" && !meta.lastUsedModel.isEmpty {
            model = meta.lastUsedModel
        } else {
            model = session.model
        }

        let cwd = session.cwd ?? resolveWorkspaceCWD(hash: meta.workspaceHash, knownPaths: knownProjectPaths)

        return Session(
            id: session.id,
            source: .cursor,
            startTime: meta.createdAt,
            endTime: session.endTime,
            model: model,
            filePath: session.filePath,
            fileSizeBytes: session.fileSizeBytes,
            eventCount: session.eventCount,
            events: session.events,
            cwd: cwd,
            repoName: session.repoName,
            lightweightTitle: session.lightweightTitle,
            lightweightCommands: session.lightweightCommands,
            parentSessionID: session.parentSessionID,
            subagentType: session.subagentType,
            customTitle: meta.name.isEmpty ? nil : meta.name
        )
    }

    /// Create a metadata-only session from chat DB meta (no transcript available).
    private static func sessionFromMeta(_ meta: CursorSessionMeta, knownProjectPaths: [String]) -> Session {
        let cwd = resolveWorkspaceCWD(hash: meta.workspaceHash, knownPaths: knownProjectPaths)
        let repoName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }

        // Use the store.db file modification time as endTime so sorting reflects last activity
        let dbMtime: Date? = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: meta.dbPath)
            return attrs?[.modificationDate] as? Date
        }()

        return Session(
            id: meta.agentId,
            source: .cursor,
            startTime: meta.createdAt,
            endTime: dbMtime ?? meta.createdAt,
            model: meta.lastUsedModel == "default" ? nil : meta.lastUsedModel,
            filePath: meta.dbPath,
            fileSizeBytes: nil,
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: repoName,
            lightweightTitle: nil,
            customTitle: meta.name.isEmpty ? nil : meta.name
        )
    }

    /// Resolve workspace hash to a project path using known transcript project directories.
    private static func resolveWorkspaceCWD(hash: String, knownPaths: [String]) -> String? {
        return CursorChatMetaReader.resolveWorkspacePath(hash: hash, knownProjectDirs: knownPaths)
    }

    /// Collect project paths from the transcript projects directory.
    private func collectKnownProjectPaths() -> [String] {
        let projectsRoot = discovery.sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsRoot.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        var paths: [String] = []
        guard let enumerator = fm.enumerator(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }

        for case let url as URL in enumerator {
            var isDirCheck: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirCheck), isDirCheck.boolValue else { continue }
            let dirName = url.lastPathComponent
            if dirName == "empty-window" { continue }
            // Try to resolve the encoded directory name to a real path
            if let cwd = CursorSessionParser.inferCWD(fromProjectDirName: dirName) {
                paths.append(cwd)
            }
        }
        return paths
    }

    /// Returns true if the session is a DB-metadata-only Cursor session (no transcript file).
    ///
    /// Detection: Cursor transcript sessions have `.jsonl` file paths; DB-only sessions point
    /// at the chat `store.db`. We check for the absence of `.jsonl` rather than the presence
    /// of a specific DB filename, so this survives if Cursor renames the database file.
    static func isDBOnlySession(_ session: Session) -> Bool {
        session.source == .cursor && session.events.isEmpty && !session.filePath.hasSuffix(".jsonl")
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

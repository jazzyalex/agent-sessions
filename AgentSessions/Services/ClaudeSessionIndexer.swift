import Foundation
import Combine
import SwiftUI

/// Session indexer for Claude Code sessions
final class ClaudeSessionIndexer: ObservableObject {
    // Throttler for coalescing progress UI updates
    final class ProgressThrottler {
        private var lastFlush = DispatchTime.now()
        private var pendingFiles = 0
        private let intervalMs: Int = 100
        func incrementAndShouldFlush() -> Bool {
            pendingFiles += 1
            let now = DispatchTime.now()
            if now.uptimeNanoseconds - lastFlush.uptimeNanoseconds > UInt64(intervalMs) * 1_000_000 {
                lastFlush = now
                pendingFiles = 0
                return true
            }
            if pendingFiles >= 50 { pendingFiles = 0; return true }
            return false
        }
    }
    @Published private(set) var allSessions: [Session] = []
    @Published private(set) var sessions: [Session] = []
    @Published var isIndexing: Bool = false
    @Published var isProcessingTranscripts: Bool = false
    @Published var progressText: String = ""
    @Published var filesProcessed: Int = 0
    @Published var totalFiles: Int = 0
    @Published var indexingError: String? = nil
    @Published var hasEmptyDirectory: Bool = false

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
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
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

    init() {
        // Initialize discovery with current override (if any)
        let initialOverride = UserDefaults.standard.string(forKey: "ClaudeSessionsRootOverride") ?? ""
        self.discovery = ClaudeSessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)
        self.lastSessionsRootOverride = initialOverride

        // Debounced filtering
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: Self.dateEq),
            $dateTo.removeDuplicates(by: Self.dateEq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest3(
            inputs,
            $selectedKinds.removeDuplicates(),
            $allSessions
        )
        .receive(on: FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated))
        .map { [weak self] input, kinds, all -> [Session] in
            let (q, from, to, model) = input
            let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
            var results = FilterEngine.filterSessions(all,
                                                     filters: filters,
                                                     transcriptCache: self?.transcriptCache,
                                                     allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)

            if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 } }
            if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 2 } }

            return results
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$sessions)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
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
                self.recomputeNow()
            }
            .store(in: &cancellables)
    }

    var canAccessRootDirectory: Bool {
        let root = discovery.sessionsRoot()
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    func refresh() {
        let root = discovery.sessionsRoot()
        print("\n🔵 CLAUDE INDEXING START: root=\(root.path)")

        isIndexing = true
        isProcessingTranscripts = false
        progressText = "Scanning…"
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        let ioQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        ioQueue.async {
            // Fast path: hydrate from SQLite index if available (bridge async)
            var indexed: [Session]? = nil
            let sema = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                indexed = try? await self.hydrateFromIndexDBIfAvailable()
                if (indexed?.isEmpty ?? true) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let retry = try? await self.hydrateFromIndexDBIfAvailable()
                    if let r = retry, !r.isEmpty { indexed = r }
                }
                sema.signal()
            }
            sema.wait()
            if let sessions = indexed {
                DispatchQueue.main.async {
                    self.allSessions = sessions
                    self.isIndexing = false
                    self.filesProcessed = sessions.count
                    self.totalFiles = sessions.count
                    self.progressText = "Loaded \(sessions.count) from index"
                    #if DEBUG
                    print("[Launch] Hydrated Claude sessions from DB: count=\(sessions.count)")
                    #endif
                }
                return
            }
            #if DEBUG
            print("[Launch] DB hydration returned nil for Claude – falling back to filesystem scan")
            #endif
            let files = self.discovery.discoverSessionFiles()

            print("📁 Found \(files.count) Claude Code session files")

            DispatchQueue.main.async {
                self.totalFiles = files.count
                self.hasEmptyDirectory = files.isEmpty
            }

            var sessions: [Session] = []
            sessions.reserveCapacity(files.count)

            for (i, url) in files.enumerated() {
                if let session = ClaudeSessionParser.parseFile(at: url) {
                    // Extra guard: hide Agent Sessions' Claude probe sessions when not showing system probes
                    let hideProbes = !(UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"))
                    if hideProbes {
                        if !ClaudeProbeConfig.isProbeSession(session) { sessions.append(session) }
                    } else {
                        sessions.append(session)
                    }
                }

                if FeatureFlags.throttleIndexingUIUpdates {
                    if self.progressThrottler.incrementAndShouldFlush() {
                        DispatchQueue.main.async {
                            self.filesProcessed = i + 1
                            self.progressText = "Indexed \(i + 1)/\(files.count)"
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.filesProcessed = i + 1
                        self.progressText = "Indexed \(i + 1)/\(files.count)"
                    }
                }
            }

            // Sort by modified time
            let sortedSessions = sessions.sorted { $0.modifiedAt > $1.modifiedAt }

            DispatchQueue.main.async {
                self.allSessions = sortedSessions
                self.isIndexing = false
                print("✅ CLAUDE INDEXING DONE: total=\(sessions.count)")

                // Start background transcript indexing for accurate search
                self.isProcessingTranscripts = true
                self.progressText = "Processing transcripts..."
                let cache = self.transcriptCache
                Task.detached(priority: FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated) {
                    await cache.generateAndCache(sessions: sortedSessions)
                    await MainActor.run {
                        self.isProcessingTranscripts = false
                        self.progressText = "Ready"
                    }
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
        return list.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(allSessions,
                                                 filters: filters,
                                                 transcriptCache: transcriptCache,
                                                 allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
        if hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount > 2 } }
        DispatchQueue.main.async { self.sessions = results }
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
              let url = URL(string: "file://\(existing.filePath)") else {
            return
        }

        let filename = existing.filePath.components(separatedBy: "/").last ?? "?"
        print("🔄 Reloading lightweight Claude session: \(filename)")

        isLoadingSession = true
        loadingSessionID = id

        let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            let startTime = Date()

            if let fullSession = ClaudeSessionParser.parseFileFull(at: url) {
                let elapsed = Date().timeIntervalSince(startTime)
                print("  ⏱️ Parse took \(String(format: "%.1f", elapsed))s - events=\(fullSession.events.count)")

                DispatchQueue.main.async {
                    if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                        self.allSessions[idx] = fullSession

                        // Update transcript cache for accurate search
                        let cache = self.transcriptCache
                        Task.detached(priority: FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated) {
                            let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                                session: fullSession,
                                filters: filters,
                                mode: .normal
                            )
                            cache.set(fullSession.id, transcript: transcript)
                        }
                    }
                    self.isLoadingSession = false
                    self.loadingSessionID = nil
                }
            } else {
                print("  ❌ Full parse failed")
                DispatchQueue.main.async {
                    self.isLoadingSession = false
                    self.loadingSessionID = nil
                }
            }
        }
    }

    // Parse all lightweight sessions (for Analytics or full-index use cases)
    func parseAllSessionsFull(progress: @escaping (Int, Int) -> Void) async {
        let lightweightSessions = allSessions.filter { $0.events.isEmpty }
        guard !lightweightSessions.isEmpty else {
            print("ℹ️ No lightweight Claude sessions to parse")
            return
        }

        print("🔍 Starting full parse of \(lightweightSessions.count) lightweight Claude sessions")

        for (index, session) in lightweightSessions.enumerated() {
            guard let url = URL(string: "file://\(session.filePath)") else { continue }

            // Report progress on main thread
            await MainActor.run {
                progress(index + 1, lightweightSessions.count)
            }

            // Parse on background thread
            let fullSession = await Task.detached(priority: .userInitiated) {
                return ClaudeSessionParser.parseFileFull(at: url)
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

        print("✅ Completed parsing \(lightweightSessions.count) lightweight Claude sessions")
    }

    private static func dateEq(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) < 0.5
        default: return false
        }
    }
}

// MARK: - SessionIndexerProtocol Conformance
extension ClaudeSessionIndexer: SessionIndexerProtocol {
    // Uses default implementations from protocol extension
    // (requestOpenRawSheet, requestCopyPlainPublisher, requestTranscriptFindFocusPublisher)
}

import Foundation
import Combine
import SwiftUI

/// Session indexer for GitHub Copilot CLI agent sessions (read-only, local storage).
final class CopilotSessionIndexer: ObservableObject, SessionIndexerProtocol {
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

    @AppStorage(PreferencesKey.Paths.copilotSessionsRootOverride) var sessionsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }

    private var discovery: CopilotSessionDiscovery
    private var lastSessionsRootOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()

    init() {
        let initialOverride = UserDefaults.standard.string(forKey: PreferencesKey.Paths.copilotSessionsRootOverride) ?? ""
        self.discovery = CopilotSessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)
        self.lastSessionsRootOverride = initialOverride

        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: Self.dateEq),
            $dateTo.removeDuplicates(by: Self.dateEq),
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
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 2 } }
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
        if !AgentEnablement.isEnabled(.copilot) { return }

        // Update discovery if override changed
        let currentOverride = UserDefaults.standard.string(forKey: PreferencesKey.Paths.copilotSessionsRootOverride) ?? ""
        if currentOverride != lastSessionsRootOverride {
            discovery = CopilotSessionDiscovery(customRoot: currentOverride.isEmpty ? nil : currentOverride)
            lastSessionsRootOverride = currentOverride
        }

        let root = discovery.sessionsRoot()
        #if DEBUG
        print("\n🟡 COPILOT INDEXING START: root=\(root.path)")
        #endif
        LaunchProfiler.log("Copilot.refresh: start")

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

        let ioQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        ioQueue.async {
            let files = self.discovery.discoverSessionFiles()
            DispatchQueue.main.async {
                self.totalFiles = files.count
                self.hasEmptyDirectory = files.isEmpty
                if self.refreshToken == token { self.launchPhase = .scanning }
            }

            var sessions: [Session] = []
            sessions.reserveCapacity(files.count)

            for (i, url) in files.enumerated() {
                if token != self.refreshToken { return }

                if let s = CopilotSessionParser.parseFile(at: url) {
                    sessions.append(s)
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

            let sorted = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sorted, source: .copilot)

            DispatchQueue.main.async {
                LaunchProfiler.log("Copilot.refresh: sessions merged (total=\(mergedWithArchives.count))")
                self.allSessions = mergedWithArchives
                self.isIndexing = false
                self.filesProcessed = self.totalFiles
                self.progressText = "Ready"
                if self.refreshToken == token { self.launchPhase = .ready }
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
        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount > 2 } }
        DispatchQueue.main.async { self.sessions = results }
    }

    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: updated, filters: filters, mode: .normal)
        transcriptCache.set(updated.id, transcript: transcript)
    }

    func reloadSession(id: String) {
        guard let existing = allSessions.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: existing.filePath)
        isLoadingSession = true
        loadingSessionID = id
        let ioQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        ioQueue.async {
            let parsed = CopilotSessionParser.parseFileFull(at: url) ?? existing
            DispatchQueue.main.async {
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
                        eventCount: max(current.eventCount, parsed.events.count),
                        events: parsed.events,
                        cwd: current.lightweightCwd ?? parsed.cwd,
                        repoName: current.repoName,
                        lightweightTitle: current.lightweightTitle ?? parsed.lightweightTitle,
                        lightweightCommands: current.lightweightCommands
                    )
                    self.allSessions[idx] = merged

                    let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                    let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: merged, filters: filters, mode: .normal)
                    self.transcriptCache.set(merged.id, transcript: transcript)
                }
                self.recomputeNow()
                self.isLoadingSession = false
                self.loadingSessionID = nil
            }
        }
    }

    // Parse all lightweight sessions (for Analytics or full-index use cases)
    func parseAllSessionsFull(progress: @escaping (Int, Int) -> Void) async {
        let lightweightSessions = allSessions.filter { $0.events.isEmpty }
        guard !lightweightSessions.isEmpty else {
            return
        }

        for (index, session) in lightweightSessions.enumerated() {
            let url = URL(fileURLWithPath: session.filePath)
            await MainActor.run { progress(index + 1, lightweightSessions.count) }

            let fullSession = await Task.detached(priority: .userInitiated) {
                CopilotSessionParser.parseFileFull(at: url, forcedID: session.id)
            }.value

            if let fullSession {
                await MainActor.run {
                    if let idx = self.allSessions.firstIndex(where: { $0.id == session.id }) {
                        self.allSessions[idx] = fullSession
                        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: fullSession, filters: filters, mode: .normal)
                        self.transcriptCache.set(fullSession.id, transcript: transcript)
                    }
                }
            }
        }
    }

    private static func dateEq(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) < 0.5
        default: return false
        }
    }
}

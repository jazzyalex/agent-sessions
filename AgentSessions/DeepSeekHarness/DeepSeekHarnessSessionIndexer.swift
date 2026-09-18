import Foundation
import Combine
import SwiftUI

/// Read-only DSH projection.  Discovery and parsing happen off the main queue; a refresh
/// publishes only a complete healthy candidate set and otherwise keeps the prior rows.
final class DeepSeekHarnessSessionIndexer: ObservableObject, SessionIndexerProtocol, @unchecked Sendable {
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
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    @Published var projectFilter: String?
    @Published var isLoadingSession = false
    @Published var loadingSessionID: String?
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    @AppStorage(DeepSeekHarnessSettings.Keys.rootOverride) var sessionsRootOverride = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref = true { didSet { recomputeNow() } }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref = true { didSet { recomputeNow() } }

    private let transcriptCache = TranscriptCache()
    private var discovery: DeepSeekHarnessDiscovery
    private var refreshToken = UUID()
    private var lastHealthy: [String: Session] = [:]
    private let reloadLock = NSLock()
    private var reloadingIDs = Set<String>()

    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    init() {
        discovery = DeepSeekHarnessDiscovery(customRoot: nil)
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        let override = DeepSeekHarnessSettings.normalizedOverride(sessionsRootOverride)
        discovery = DeepSeekHarnessDiscovery(customRoot: override.isEmpty ? nil : override)
        let token = UUID()
        refreshToken = token
        isIndexing = true
        launchPhase = .hydrating
        progressText = "Scanning…"
        indexingError = nil
        hasEmptyDirectory = false
        filesProcessed = 0
        totalFiles = 0
        let sourceDiscovery = discovery

        DispatchQueue.global(qos: executionProfile.deferNonCriticalWork ? .utility : .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = sourceDiscovery.discover()
            var parsed: [Session] = []
            var parseFailure = false
            for candidate in result.candidates {
                if let session = DeepSeekHarnessSessionParser.parseFile(at: candidate.selectedURL) {
                    parsed.append(session)
                } else {
                    parseFailure = true
                }
            }
            let errorText = result.issues.first?.localizedDescription
                ?? (parseFailure ? "DeepSeek Harness session could not be parsed." : nil)
            DispatchQueue.main.async {
                guard self.refreshToken == token else { return }
                self.totalFiles = result.candidates.count
                self.filesProcessed = parsed.count
                self.hasEmptyDirectory = result.candidates.isEmpty && result.issues.isEmpty
                self.launchPhase = .scanning
                let refreshFailed = !result.issues.isEmpty || parseFailure
                if refreshFailed && !self.allSessions.isEmpty {
                    self.indexingError = errorText
                    // A failed refresh is not permission to replace a healthy
                    // projection with a partial one.  Parsed candidates may
                    // still advance, while any previously healthy candidate
                    // that failed this pass remains visible until a clean
                    // refresh confirms its removal.
                    var merged = self.lastHealthy
                    for session in parsed { merged[session.id] = session }
                    self.allSessions = Array(merged.values).sorted {
                        ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast)
                    }
                    self.finishRefresh(token: token, preserve: false)
                    return
                }
                self.lastHealthy = Dictionary(uniqueKeysWithValues: parsed.map { ($0.id, $0) })
                self.allSessions = parsed.sorted { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) }
                self.indexingError = errorText
                self.finishRefresh(token: token, preserve: false)
            }
        }
    }

    private func finishRefresh(token: UUID, preserve: Bool) {
        guard refreshToken == token else { return }
        isIndexing = false
        isProcessingTranscripts = false
        launchPhase = .ready
        progressText = "Ready"
        if !preserve { recomputeNow() }
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo,
                              model: selectedModel, kinds: selectedKinds,
                              repoName: projectFilter, pathContains: nil)
        var output = FilterEngine.filterSessions(allSessions, filters: filters,
                                                 transcriptCache: transcriptCache,
                                                 allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
        if hideZeroMessageSessionsPref { output = output.filter { $0.messageCount > 0 } }
        if hideLowMessageSessionsPref { output = output.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
        sessions = output
    }

    func updateSession(_ updated: Session) {
        if let index = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[index] = updated
            lastHealthy[updated.id] = updated
        }
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
            session: updated,
            filters: .current(showTimestamps: false, showMeta: false),
            mode: .normal)
        transcriptCache.set(updated.id, transcript: transcript)
        recomputeNow()
    }

    enum ReloadReason { case selection, focusedSessionMonitor, manualRefresh }

    func reloadSession(id: String, force: Bool = false, reason: ReloadReason = .selection) {
        reloadLock.lock()
        guard reloadingIDs.insert(id).inserted else { reloadLock.unlock(); return }
        reloadLock.unlock()
        let old = allSessions.first(where: { $0.id == id })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer {
                self.reloadLock.lock(); self.reloadingIDs.remove(id); self.reloadLock.unlock()
                DispatchQueue.main.async {
                    if self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }
            }
            guard let old, let candidate = self.discovery.discover().candidates.first(where: { $0.id == id }) else { return }
            guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: candidate.selectedURL) else { return }
            // Generation selection belongs to the directory, not only the selected
            // file. Recheck after the parse so a successor published concurrently
            // cannot let an older generation overwrite the healthy projection.
            guard let current = self.discovery.discover().candidates.first(where: { $0.id == id }),
                  current.manifestRevision == candidate.manifestRevision,
                  current.selectedURL == candidate.selectedURL else { return }
            DispatchQueue.main.async {
                guard let index = self.allSessions.firstIndex(where: { $0.id == id }) else { return }
                self.allSessions[index] = full
                self.lastHealthy[id] = full
                self.transcriptCache.set(id, transcript: SessionTranscriptBuilder.buildPlainTerminalTranscript(
                    session: full, filters: .current(showTimestamps: false, showMeta: false), mode: .normal))
                self.recomputeNow()
            }
            _ = old
            _ = force
            _ = reason
        }
        if reason == .manualRefresh || old?.events.isEmpty == true {
            isLoadingSession = true
            loadingSessionID = id
        }
    }
}

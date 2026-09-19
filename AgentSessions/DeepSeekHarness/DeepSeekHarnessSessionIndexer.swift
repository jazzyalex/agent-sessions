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
    /// Authoritative live generation paths from the last completed refresh. nil is
    /// applicable-but-unknown: any failed or partial discovery/parse pass, a root
    /// change before its rescan completes, or no completed pass yet. A non-nil value
    /// (empty allowed) is published only after a clean, stable completed pass.
    private(set) var searchLivePathSnapshot: Set<String>?
    /// Canonical sessions root the `lastHealthy` projection was built from.
    /// A root change clears the projection before any new-root result is
    /// published or preserved, so rows from a prior root never leak across
    /// the boundary. Nil until the first refresh completes.
    private var lastIndexedRoot: URL?
    private let reloadLock = NSLock()
    private var reloadingIDs = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    /// Key-filtered observer for the sessions-root override: the raw
    /// `didChangeNotification` fires on every process-wide defaults write
    /// (incl. AppKit bookkeeping), so narrowing to this one key avoids
    /// refresh storms on unrelated writes. See
    /// AgentSessions/Support/FilteredDefaultsObserver.swift.
    private var rootOverrideDefaultsObserver: FilteredDefaultsObserver?
    private var lastSessionsRootOverride: String

    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    init() {
        discovery = DeepSeekHarnessDiscovery(customRoot: nil)
        let initialOverride = UserDefaults.standard.string(forKey: DeepSeekHarnessSettings.Keys.rootOverride) ?? ""
        lastSessionsRootOverride = initialOverride
        let rootOverrideObserver = FilteredDefaultsObserver(keys: [DeepSeekHarnessSettings.Keys.rootOverride])
        rootOverrideDefaultsObserver = rootOverrideObserver
        rootOverrideObserver.mainPublisher
            .sink { [weak self] in
                guard let self else { return }
                let current = UserDefaults.standard.string(forKey: DeepSeekHarnessSettings.Keys.rootOverride) ?? ""
                guard current != self.lastSessionsRootOverride else { return }
                self.lastSessionsRootOverride = current
                self.refresh()
            }
            .store(in: &cancellables)
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        let storedOverride = UserDefaults.standard.string(
            forKey: DeepSeekHarnessSettings.Keys.rootOverride) ?? sessionsRootOverride
        let override = DeepSeekHarnessSettings.normalizedOverride(storedOverride)
        lastSessionsRootOverride = storedOverride
        discovery = DeepSeekHarnessDiscovery(customRoot: override.isEmpty ? nil : override)
        let sourceDiscovery = discovery
        let currentRoot = sourceDiscovery.sessionsRoot().standardizedFileURL
        if let lastIndexedRoot, lastIndexedRoot != currentRoot {
            // Clear synchronously at the preference boundary: rows and cached
            // transcripts from the old root must not remain visible while the
            // new root is being scanned, and matching session ids must not
            // reuse old-root transcript text.
            lastHealthy.removeAll()
            allSessions = []
            // A root change invalidates live-path authority before the rescan
            // completes. Unknown, never empty: the new root may be unreadable.
            searchLivePathSnapshot = nil
            transcriptCache.clear()
            recomputeNow()
        }
        let token = UUID()
        refreshToken = token
        isIndexing = true
        launchPhase = .hydrating
        progressText = "Scanning…"
        indexingError = nil
        hasEmptyDirectory = false
        filesProcessed = 0
        totalFiles = 0
        DispatchQueue.global(qos: executionProfile.deferNonCriticalWork ? .utility : .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = sourceDiscovery.discover()
            var parsedByID: [String: (candidate: DeepSeekHarnessSessionCandidate, session: Session)] = [:]
            var parseFailure = false
            for candidate in result.candidates {
                if let session = DeepSeekHarnessSessionParser.parseFile(at: candidate.selectedURL) {
                    parsedByID[candidate.id] = (candidate, session)
                } else {
                    parseFailure = true
                }
            }

            // Generations are immutable, so parsing the selected file alone is
            // insufficient: a successor can become authoritative without
            // changing that file. Re-resolve the logical directory after all
            // parsing and publish only candidates whose selected URL and full
            // sibling-manifest revision are unchanged.
            let postParseResult = sourceDiscovery.discover()
            let postParseCandidates = Dictionary(
                uniqueKeysWithValues: postParseResult.candidates.map { ($0.id, $0) }
            )
            var parsed: [Session] = []
            for (id, value) in parsedByID {
                guard let current = postParseCandidates[id],
                      current.manifestRevision == value.candidate.manifestRevision,
                      current.selectedURL.standardizedFileURL == value.candidate.selectedURL.standardizedFileURL else {
                    parseFailure = true
                    continue
                }
                parsed.append(value.session)
            }
            let allIssues = result.issues + postParseResult.issues
            let errorText = allIssues.first?.localizedDescription
                ?? (parseFailure ? "DeepSeek Harness session could not be parsed." : nil)
            let livePaths = Set(parsed.map(\.filePath))
            let projected = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(
                into: parsed,
                source: .deepseekHarness
            )
            DispatchQueue.main.async {
                guard self.refreshToken == token else { return }
                // Root boundary: the healthy projection belongs to one
                // canonical sessions root. When the root changed, drop the
                // prior projection before publishing or preserving anything,
                // so a partial new-root failure can only preserve same-root
                // rows. A clean new-root scan still replaces normally below.
                let currentRoot = sourceDiscovery.sessionsRoot().standardizedFileURL
                if self.lastIndexedRoot != currentRoot {
                    self.lastHealthy = [:]
                    self.allSessions = []
                    // Root-change failure remains unknown, never empty: the new
                    // root has no completed pass yet. A clean pass below still
                    // publishes its authoritative set normally.
                    self.searchLivePathSnapshot = nil
                }
                self.lastIndexedRoot = currentRoot
                self.totalFiles = result.candidates.count
                self.filesProcessed = parsed.count
                self.hasEmptyDirectory = result.candidates.isEmpty && result.issues.isEmpty
                self.launchPhase = .scanning
                let refreshFailed = !allIssues.isEmpty || parseFailure
                if refreshFailed && !self.allSessions.isEmpty {
                    self.indexingError = errorText
                    // A failed refresh is not permission to replace a healthy
                    // projection with a partial one.  Parsed candidates may
                    // still advance, while any previously healthy candidate
                    // that failed this pass remains visible until a clean
                    // refresh confirms its removal.
                    for session in parsed { self.lastHealthy[session.id] = session }
                    self.allSessions = Array(self.lastHealthy.values).sorted {
                        ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast)
                    }
                    // Any failed or partial discovery/parse pass publishes nil:
                    // unknown authority may run ingest but can never delete.
                    self.searchLivePathSnapshot = nil
                    self.finishRefresh(token: token, preserve: false)
                    return
                }
                self.lastHealthy = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
                self.allSessions = projected.sorted { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) }
                self.indexingError = errorText
                // Clean stable completed pass (empty allowed): the authoritative
                // set of selected live generation paths. A failed pass above
                // stays nil, so root-change failure remains unknown, never empty.
                self.searchLivePathSnapshot = refreshFailed
                    ? nil
                    : livePaths
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
        let sourceDiscovery = discovery
        let sourceRoot = sourceDiscovery.sessionsRoot()
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
            guard let old else { return }
            let discovered = sourceDiscovery.discover()
            let full: Session
            if let candidate = discovered.candidates.first(where: { $0.id == id }) {
                guard let parsed = DeepSeekHarnessSessionParser.parseFileFull(at: candidate.selectedURL) else { return }
                // Generation selection belongs to the directory, not only the selected
                // file. Recheck after the parse so a successor published concurrently
                // cannot let an older generation overwrite the healthy projection.
                guard let current = sourceDiscovery.discover().candidates.first(where: { $0.id == id }),
                      current.manifestRevision == candidate.manifestRevision,
                      current.selectedURL.standardizedFileURL == candidate.selectedURL.standardizedFileURL else { return }
                full = parsed
            } else {
                // Archive fallbacks already point at their copied primary. Once the
                // live bundle is gone they must hydrate directly instead of depending
                // on discovery under the live sessions root.
                guard SessionArchiveManager.shared.isArchivedPrimary(session: old) else { return }
                guard let parsed = DeepSeekHarnessSessionParser.parseFileFull(
                    at: URL(fileURLWithPath: old.filePath)
                ) else { return }
                full = parsed
            }
            DispatchQueue.main.async {
                guard self.discovery.sessionsRoot() == sourceRoot else { return }
                guard let index = self.allSessions.firstIndex(where: { $0.id == id }) else { return }
                self.allSessions[index] = full
                self.lastHealthy[id] = full
                self.transcriptCache.set(id, transcript: SessionTranscriptBuilder.buildPlainTerminalTranscript(
                    session: full, filters: .current(showTimestamps: false, showMeta: false), mode: .normal))
                self.recomputeNow()
            }
            _ = force
            _ = reason
        }
        if reason == .manualRefresh || old?.events.isEmpty == true {
            isLoadingSession = true
            loadingSessionID = id
        }
    }
}

import Foundation
import Combine
import CryptoKit
import SwiftUI
import os.log
import SQLite3

private let indexLog = OSLog(subsystem: "com.triada.AgentSessions", category: "CodexIndexing")

enum LaunchPhase: Int, Comparable {
    case idle = 0
    case hydrating
    case scanning
    case transcripts
    case ready
    case error

    static func < (lhs: LaunchPhase, rhs: LaunchPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var isInteractive: Bool {
        self == .ready
    }

    var statusDescription: LocalizedStringResource {
        switch self {
        case .idle: return "Waiting to index…"
        case .hydrating: return "Preparing session index…"
        case .scanning: return "Scanning session files…"
        case .transcripts: return "Processing transcripts…"
        case .ready: return "Ready"
        case .error: return "Indexing error"
        }
    }
}

// MARK: - Session Indexer Protocol

/// Protocol defining the common interface for session indexers (Codex and Claude)
protocol SessionIndexerProtocol: ObservableObject {
    var allSessions: [Session] { get }
    var sessions: [Session] { get }
    var isIndexing: Bool { get }
    var isLoadingSession: Bool { get }
    var loadingSessionID: String? { get }
    var launchPhase: LaunchPhase { get }

    // Focus coordination
    var activeSearchUI: SessionIndexer.ActiveSearchUI { get set }

    // Optional features (Codex only)
    var requestOpenRawSheet: Bool { get set }
    var requestCopyPlainPublisher: AnyPublisher<Void, Never> { get }
    var requestTranscriptFindFocusPublisher: AnyPublisher<Void, Never> { get }
}

// Default implementations for Claude (which doesn't have these features)
extension SessionIndexerProtocol {
    var requestOpenRawSheet: Bool {
        get { false }
        set { }
    }

    var requestCopyPlainPublisher: AnyPublisher<Void, Never> {
        Empty<Void, Never>().eraseToAnyPublisher()
    }

    var requestTranscriptFindFocusPublisher: AnyPublisher<Void, Never> {
        Empty<Void, Never>().eraseToAnyPublisher()
    }
}

// DEBUG logging helper (no-ops in Release)
#if DEBUG
@inline(__always) private func DBG(_ message: @autoclosure () -> String) {
    print(message())
}
#else
@inline(__always) private func DBG(_ message: @autoclosure () -> String) {}
#endif
// swiftlint:disable type_body_length
final class SessionIndexer: ObservableObject {
    private struct PersistedFileStat: Codable {
        let mtime: Int64
        let size: Int64
    }

    private struct PersistedFileStatPayload: Codable {
        let version: Int
        let stats: [String: PersistedFileStat]
    }

    private static let coreFileStatsStateKey = "core_file_stats_v1:codex"

    // Source of truth
    @Published private(set) var allSessions: [Session] = []
    // Exposed to UI after filters
    @Published private(set) var sessions: [Session] = []

    @Published var isIndexing: Bool = false
    @Published var isProcessingTranscripts: Bool = false
    @Published var progressText: String = ""
    @Published var filesProcessed: Int = 0
    @Published var totalFiles: Int = 0
    @Published var launchPhase: LaunchPhase = .idle

    // Lazy loading state
    @Published var isLoadingSession: Bool = false
    @Published var loadingSessionID: String? = nil

    // Transcript cache for accurate search
    private let transcriptCache = TranscriptCache()
    private let progressThrottler = ProgressThrottler()
    private var refreshTask: Task<Void, Never>? = nil
    private var sideChatRefreshTask: Task<Void, Never>? = nil

    // Expose cache for SearchCoordinator (internal - not public API)
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    // Error states
    @Published var indexingError: String? = nil
    @Published var hasEmptyDirectory: Bool = false

    // Filters
    // Applied query (used for filtering) and draft (typed value)
    @Published var query: String = ""
    @Published var queryDraft: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var selectedModel: String? = nil
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)

    // UI focus coordination (mutually exclusive search UI)
    enum ActiveSearchUI {
        case sessionSearch   // Search sessions list (Cmd+Option+F)
        case transcriptFind  // Find in transcript (Cmd+F)
        case none
    }
    @Published var activeSearchUI: ActiveSearchUI = .none

    // Legacy focus coordination (deprecated in favor of activeSearchUI)
    @Published var requestFocusSearch: Bool = false
    @Published var requestTranscriptFindFocus: Bool = false
    @Published var requestCopyPlain: Bool = false
    @Published var requestCopyANSI: Bool = false
    @Published var requestOpenRawSheet: Bool = false
    // Project filter set by clicking the Project cell or via repo: operator
    @Published var projectFilter: String? = nil

    // Sorting (mirrors UI's column sort state)
    struct SessionSortDescriptor: Equatable {
        enum Key: Equatable { case modified, msgs, repo, title, size }
        var key: Key
        var ascending: Bool
    }
    @Published var sortDescriptor: SessionSortDescriptor = .init(key: .modified, ascending: false)
    // Preferences
    @AppStorage(PreferencesKey.Paths.codexSessionsRootOverride) var sessionsRootOverride: String = ""
    @AppStorage("TranscriptTheme") private var themeRaw: String = TranscriptTheme.codexDark.rawValue
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage(PreferencesKey.showHousekeepingSessions) var showHousekeepingSessionsPref: Bool = false {
        didSet { recomputeNow() }
    }
    @AppStorage("SelectedKindsRaw") private var selectedKindsRaw: String = ""
    @AppStorage("AppAppearance") private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = ModifiedDisplay.relative.rawValue
    @AppStorage("TranscriptRenderMode") private var renderModeRaw: String = TranscriptRenderMode.normal.rawValue
    // Column visibility/order prefs
    let columnVisibility: ColumnVisibilityStore
    // Persist active project filter
    @AppStorage("ProjectFilter") private var projectFilterStored: String = ""

    // Track sessions currently being reloaded to prevent duplicate loads
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSCondition()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]
    private var appendCursorsBySessionID: [String: CodexAppendCursor] = [:]
    private struct TranscriptCacheBuildRequest {
        let session: Session
        let sourceStat: SessionFileStat?
        let delayForSelection: Bool
    }
    private var pendingTranscriptCacheBuildsBySessionID: [String: TranscriptCacheBuildRequest] = [:]
    private var activeTranscriptCacheBuilderSessionIDs: Set<String> = []
#if DEBUG
    private var fullParseInvocationCountForTesting = 0
    private var appendParseInvocationCountForTesting = 0
    private var transcriptCacheBuildHookForTesting: ((Session) -> Void)?
#endif
    private var lastPrewarmSignatureByID: [String: Int] = [:]
    private var transcriptPrewarmTask: Task<Void, Never>? = nil

    var prefTheme: TranscriptTheme { TranscriptTheme(rawValue: themeRaw) ?? .codexDark }
    func setTheme(_ t: TranscriptTheme) { themeRaw = t.rawValue }
    var appAppearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }
    func setAppearance(_ a: AppAppearance) { appearanceRaw = a.rawValue }
    func toggleDarkLight(systemScheme: ColorScheme) {
        let current = appAppearance
        setAppearance(current.toggledDarkLight(systemScheme: systemScheme))
    }
    func toggleDarkLightUsingSystemAppearance() {
        toggleDarkLight(systemScheme: AppAppearance.systemColorSchemeFallback())
    }
    func useSystemAppearance() {
        setAppearance(.system)
    }

    enum ModifiedDisplay: String, CaseIterable, Identifiable {
        case relative
        case absolute
        var id: String { rawValue }
        var title: String { self == .relative ? "Relative" : "Timestamp" }
    }
    var modifiedDisplay: ModifiedDisplay { ModifiedDisplay(rawValue: modifiedDisplayRaw) ?? .relative }
    func setModifiedDisplay(_ m: ModifiedDisplay) { modifiedDisplayRaw = m.rawValue }
    var transcriptRenderMode: TranscriptRenderMode { TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal }
    func setTranscriptRenderMode(_ m: TranscriptRenderMode) { renderModeRaw = m.rawValue }

    private var cancellables = Set<AnyCancellable>()
    private var recomputeDebouncer: DispatchWorkItem? = nil
    private var lastShowSystemProbeSessions: Bool = UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions")
    /// Key-filtered defaults observers: the raw `didChangeNotification` fires on
    /// every process-wide defaults write (incl. AppKit window/splitview
    /// bookkeeping); these narrow to only the keys each subscriber consults so
    /// unrelated writes no longer trigger a refresh/recompute. See
    /// AgentSessions/Support/FilteredDefaultsObserver.swift.
    private var probeVisibilityDefaultsObserver: FilteredDefaultsObserver?
    private var recomputeDefaultsObserver: FilteredDefaultsObserver?
    private var refreshToken = UUID()
    private let knownFileStatsLock = NSLock()
    private var lastKnownFileStatsByPath: [String: SessionFileStat] = [:]
    private var codexInternalIDBackfillTask: Task<Void, Never>? = nil
    private static let codexInternalIDBackfillCursorKey = "CodexInternalIDBackfillCursor"
    private static let codexInternalIDBackfillLastRunAtKey = "CodexInternalIDBackfillLastRunAt"
    private static let codexInternalIDBackfillBatchSize = 50
    private static let codexInternalIDBackfillMinInterval: TimeInterval = 15

    init(columnVisibility: ColumnVisibilityStore = ColumnVisibilityStore()) {
        self.columnVisibility = columnVisibility
        columnVisibility.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Load persisted project filter
        if !projectFilterStored.isEmpty { projectFilter = projectFilterStored }
        // Debounced computed sessions
        let inputs = Publishers.CombineLatest4(
            $query
                .removeDuplicates(),
            $dateFrom.removeDuplicates(by: OptionalDateEquality.eq),
            $dateTo.removeDuplicates(by: OptionalDateEquality.eq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest3(
            inputs,
            $selectedKinds.removeDuplicates(),
            $allSessions
        )
            .receive(on: FeatureFlags.backgroundIngestQueue)
            .map { [weak self] input, kinds, all -> [Session] in
                let (q, from, to, model) = input
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(all,
                                                         filters: filters,
                                                         transcriptCache: self?.transcriptCache,
                                                         allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)

                if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.isSideChat || $0.messageCount > 0 } }
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.isSideChat || $0.messageCount == 0 || $0.messageCount > 2 } }
                if !(self?.showHousekeepingSessionsPref ?? false) { results = results.filter { !$0.isHousekeeping } }

                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)

        // Load persisted selected kinds on startup
        if !selectedKindsRaw.isEmpty {
            let kinds = selectedKindsRaw.split(separator: ",").compactMap { SessionEventKind(rawValue: String($0)) }
            if !kinds.isEmpty { selectedKinds = Set(kinds) }
        }

        // Persist selected kinds whenever they change (empty string means all kinds)
        $selectedKinds
            .map { kinds -> String in
                if kinds.count == SessionEventKind.allCases.count { return "" }
                return kinds.map { $0.rawValue }.sorted().joined(separator: ",")
            }
            .removeDuplicates()
            .sink { [weak self] raw in self?.selectedKindsRaw = raw }
            .store(in: &cancellables)

        // Observe probe-visibility toggle and refresh index when it changes
        let probeVisibilityObserver = FilteredDefaultsObserver(keys: ["ShowSystemProbeSessions"])
        self.probeVisibilityDefaultsObserver = probeVisibilityObserver
        probeVisibilityObserver.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self else { return }
                let show = UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions")
                if show != self.lastShowSystemProbeSessions {
                    self.lastShowSystemProbeSessions = show
                    self.refresh()
                }
            }
            .store(in: &cancellables)

        // Persist project filter to AppStorage whenever it changes
        $projectFilter
            .map { $0 ?? "" }
            .removeDuplicates()
            .sink { [weak self] raw in self?.projectFilterStored = raw }
            .store(in: &cancellables)

        // recomputeNow() consults @AppStorage-backed hideZeroMessageSessionsPref/
        // hideLowMessageSessionsPref/showHousekeepingSessionsPref — those three
        // keys are the only raw defaults reads in its filter path.
        let recomputeObserver = FilteredDefaultsObserver(keys: [
            "HideZeroMessageSessions",
            "HideLowMessageSessions",
            PreferencesKey.showHousekeepingSessions
        ])
        self.recomputeDefaultsObserver = recomputeObserver
        recomputeObserver.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeNow() }
            .store(in: &cancellables)

        // Refresh Codex sessions when probe cleanup succeeds so removed probe files disappear immediately
        NotificationCenter.default.publisher(for: CodexProbeCleanup.didRunCleanupNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self = self else { return }
                if let info = note.userInfo as? [String: Any], let status = info["status"] as? String, status == "success" {
                    self.refresh()
                }
            }
            .store(in: &cancellables)
    }

    func applySearch() {
        // Apply the user's draft query explicitly (not on each keystroke)
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    // Update an existing session in allSessions (used by SearchCoordinator to persist parsed sessions)
    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            var sessions = allSessions
            sessions[idx] = updated
            allSessions = sessions
        }
    }

#if DEBUG
    func installSessionsForReloadTesting(_ sessions: [Session]) {
        allSessions = sessions
    }

    func reloadParseInvocationCountsForTesting() -> (full: Int, append: Int) {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        return (fullParseInvocationCountForTesting, appendParseInvocationCountForTesting)
    }

    func waitForReloadToFinishForTesting(id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        reloadLock.lock()
        defer { reloadLock.unlock() }
        while reloadingSessionIDs.contains(id) {
            guard reloadLock.wait(until: deadline) else { return false }
        }
        return true
    }

    func setTranscriptCacheBuildHookForTesting(_ hook: ((Session) -> Void)?) {
        reloadLock.lock()
        transcriptCacheBuildHookForTesting = hook
        reloadLock.unlock()
    }

    func waitForTranscriptCacheBuildsToFinishForTesting(id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        reloadLock.lock()
        defer { reloadLock.unlock() }
        while activeTranscriptCacheBuilderSessionIDs.contains(id) {
            guard reloadLock.wait(until: deadline) else { return false }
        }
        return true
    }
#endif

    enum ReloadReason: String {
        case selection
        case focusedSessionMonitor
        case manualRefresh
    }

    enum ReloadHydrationStage {
        case tail
        case full
    }

    typealias CodexAppendCursor = CodexSessionParser.CodexAppendCursor
    typealias CodexAppendParseResult = CodexSessionParser.CodexAppendParseResult
    private typealias FullParseResult = CodexSessionParser.FullParseResult

    /// Replaces transcript data after a reload without discarding the stable metadata
    /// that keeps the list row identified and grouped. In particular, Codex child rows
    /// refer to a parent's raw runtime UUID while the parent row itself uses a path-hash
    /// ID, so dropping `codexInternalSessionIDHint` temporarily dissolves the hierarchy.
    static func mergeReloadedSession(current: Session,
                                     parsed: Session,
                                     stage: ReloadHydrationStage) -> Session {
        let isTail = stage == .tail
        var merged = Session(
            id: current.id,
            source: current.source,
            startTime: parsed.startTime ?? current.startTime,
            endTime: parsed.endTime ?? current.endTime,
            model: isTail ? current.model : (parsed.model ?? current.model),
            filePath: current.filePath,
            fileSizeBytes: isTail ? current.fileSizeBytes : (parsed.fileSizeBytes ?? current.fileSizeBytes),
            eventCount: isTail ? current.eventCount : max(current.eventCount, parsed.nonMetaCount),
            events: parsed.events,
            cwd: isTail ? current.lightweightCwd : (current.lightweightCwd ?? parsed.cwd),
            repoName: current.lightweightRepoName,
            lightweightTitle: current.lightweightTitle,
            lightweightCommands: current.lightweightCommands,
            isHousekeeping: isTail ? current.isHousekeeping : parsed.isHousekeeping,
            codexInternalSessionIDHint: parsed.codexInternalSessionIDHint ?? current.codexInternalSessionIDHint,
            parentSessionID: parsed.parentSessionID ?? current.parentSessionID,
            subagentType: parsed.subagentType ?? current.subagentType,
            relationshipKind: parsed.relationshipKind ?? current.relationshipKind,
            customTitle: parsed.customTitle ?? current.customTitle,
            codexOriginator: parsed.codexOriginator ?? current.codexOriginator,
            codexSource: parsed.codexSource ?? current.codexSource,
            codexSurface: parsed.codexSurface ?? current.codexSurface,
            originator: parsed.originator ?? current.originator,
            originSource: parsed.originSource ?? current.originSource,
            surface: parsed.surface ?? current.surface,
            reasoningEffort: parsed.reasoningEffort ?? current.reasoningEffort,
            deletedAt: parsed.deletedAt ?? current.deletedAt
        )
        merged.isFavorite = current.isFavorite
        merged.isPartiallyHydrated = isTail
        return merged
    }

    // Reload a session with full parse.
    // - Parameters:
    //   - id: Session identifier
    //   - force: Reload even when session already has events
    //   - reason: Origin for diagnostics and force semantics
    func reloadSession(id: String,
                       force: Bool = false,
                       reason: ReloadReason = .selection) {
        // Check if already reloading this session
        reloadLock.lock()
        if reloadingSessionIDs.contains(id) {
            reloadLock.unlock()
            DBG("⏭️ Skip reload: session \(id.prefix(8)) already reloading")
            return
        }
        reloadingSessionIDs.insert(id)
        reloadLock.unlock()

        let bgQueue = FeatureFlags.backgroundIngestQueue
        bgQueue.async {
            let loadingTimer: DispatchSourceTimer? = nil
            defer {
                // Always clean up timer and reloading state
                loadingTimer?.cancel()
                self.reloadLock.lock()
                self.reloadingSessionIDs.remove(id)
                self.reloadLock.broadcast()
                self.reloadLock.unlock()
            }

            guard let existing = self.allSessions.first(where: { $0.id == id }) else {
                DBG("⏭️ Skip reload: session not found")
                // Clear loading state on early exit
                DispatchQueue.main.async {
                    if self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }
                return
            }

            // A tail-only provisional session (Task 9e stage 0) must never look
            // "already loaded" here — the full parse must always follow it.
            let hasLoadedEvents = !existing.events.isEmpty && !existing.isPartiallyHydrated
            if hasLoadedEvents && !force {
                DBG("⏭️ Skip reload: session already loaded")
                DispatchQueue.main.async {
                    if self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }
                return
            }

            let url = URL(fileURLWithPath: existing.filePath)
            let preParseStat = Self.fileStat(for: url)
            var lastReloadStat: SessionFileStat? = nil
            self.reloadLock.lock()
            lastReloadStat = self.lastFullReloadFileStatsBySessionID[id]
            self.reloadLock.unlock()

            if force,
               reason != .manualRefresh,
               reason != .focusedSessionMonitor,
               hasLoadedEvents,
               let preParseStat,
               let lastReloadStat,
               preParseStat == lastReloadStat {
                DBG("⏭️ Skip reload: unchanged file for \(id.prefix(8)) reason=\(reason.rawValue)")
                DispatchQueue.main.async {
                    if self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }
                return
            }

            let filename = existing.filePath.components(separatedBy: "/").last ?? "?"
            let shouldSurfaceLoadingState = reason == .manualRefresh || !hasLoadedEvents
            DBG("🔄 Reloading session: \(filename) force=\(force) reason=\(reason.rawValue)")
            DBG("  📂 Path: \(existing.filePath)")

            if shouldSurfaceLoadingState {
                // Surface loading only for first-time/manual loads; background monitor refreshes
                // should not overlay already visible transcript content.
                DispatchQueue.main.async {
                    self.isLoadingSession = true
                    self.loadingSessionID = id
                }
            }

            // Task 9e stage 0: tail-first cold paint. For a monster session that
            // has no events loaded yet, publish a fast, disposable tail-only
            // parse BEFORE running the (slow) full parse below, so the user sees
            // the last screen of the transcript in well under a second. This is
            // throwaway content: the full parse that follows always replaces it
            // (events.count changes, which drives the existing two-stage
            // rebuild in SessionTerminalView). Only the transcript-facing
            // `events`/`eventCount`/timestamps are touched here — list metadata
            // (cwd/repoName/lightweightTitle/lightweightCommands) is carried
            // over from `existing` untouched, exactly as the final merge below
            // already does for those fields.
            if FeatureFlags.transcriptTailFirstPaint,
               !hasLoadedEvents,
               let existingSize = existing.fileSizeBytes,
               existingSize >= FeatureFlags.transcriptTailFirstPaintMinBytes,
               let tailSession = self.parseFileTail(at: url, forcedID: id) {
                DispatchQueue.main.async {
                    guard let idx = self.allSessions.firstIndex(where: { $0.id == id }) else { return }
                    let current = self.allSessions[idx]
                    // Only publish the tail content if the real session still has
                    // no events (avoid clobbering a full parse that raced ahead,
                    // e.g. via a concurrent manual refresh).
                    guard current.events.isEmpty else { return }
                    let published = Self.mergeReloadedSession(
                        current: current,
                        parsed: tailSession,
                        stage: .tail
                    )
                    var updated = self.allSessions
                    updated[idx] = published
                    self.allSessions = updated
                    DBG("⚡ Tail-first paint published: \(filename) tailEvents=\(published.events.count)")
                }
            }

            let startTime = Date()
            var parsedSession: Session?
            var nextAppendCursor: CodexAppendCursor?

            if reason == .focusedSessionMonitor, hasLoadedEvents {
                self.reloadLock.lock()
                let cursor = self.appendCursorsBySessionID[id]
                self.reloadLock.unlock()
                if let cursor {
                    switch self.parseFileAppend(at: url, existing: existing, cursor: cursor) {
                    case let .appended(session, nextCursor):
                        parsedSession = session
                        nextAppendCursor = nextCursor
                        DBG("  ⚡ Append parse: bytes=\(nextCursor.byteOffset - cursor.byteOffset) events=\(session.events.count - existing.events.count)")
                    case .incompleteTail:
                        DBG("  ⏭️ Deferring reload until appended JSONL line is complete")
                        return
                    case .unchanged:
                        self.reloadLock.lock()
                        if let preParseStat {
                            self.lastFullReloadFileStatsBySessionID[id] = preParseStat
                        }
                        self.reloadLock.unlock()
                        return
                    case .fallbackToFullParse:
                        self.reloadLock.lock()
                        self.appendCursorsBySessionID.removeValue(forKey: id)
                        self.reloadLock.unlock()
                    }
                }
            }

            if parsedSession == nil {
                DBG("  🚀 Starting parseFileFull...")
                // Force full parse by calling parseFile directly (skip lightweight check).
                // JSONLReader is bounded to the size captured inside this call, so growth
                // after the snapshot is left for the next append pass.
                if let fullResult = self.parseFileFullResult(at: url, forcedID: id) {
                    parsedSession = fullResult.session
                    if fullResult.readSucceeded,
                       let snapshotByteCount = fullResult.snapshotByteCount,
                       let verifiedCursor = self.makeAppendCursor(
                            at: url,
                            lastLineIndex: fullResult.lastLineIndex,
                            byteOffset: snapshotByteCount
                       ),
                       verifiedCursor.systemNumber == fullResult.snapshotSystemNumber,
                       verifiedCursor.fileNumber == fullResult.snapshotFileNumber {
                        nextAppendCursor = verifiedCursor
                    }
                }
            }

            if let parsedSession {
                let elapsed = Date().timeIntervalSince(startTime)
                DBG("  ⏱️ Parse took \(String(format: "%.1f", elapsed))s - events=\(parsedSession.events.count)")
                let postParseStat = Self.fileStat(for: url)
                self.reloadLock.lock()
                if let preParseStat {
                    // Persist the pre-parse stat so follow-up monitor ticks can still
                    // reload if the file advanced while parse was in flight.
                    self.lastFullReloadFileStatsBySessionID[id] = preParseStat
                } else {
                    self.lastFullReloadFileStatsBySessionID.removeValue(forKey: id)
                }
                self.reloadLock.unlock()
                if preParseStat != postParseStat {
                    DBG("  ℹ️ File changed during reload; next monitor tick will perform a follow-up parse")
                }

                let cursorToPublish = nextAppendCursor
                DispatchQueue.main.async {
                    // Replace in allSessions
                    if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                        let current = self.allSessions[idx]
                        let merged = Self.mergeReloadedSession(
                            current: current,
                            parsed: parsedSession,
                            stage: .full
                        )
                        var updated = self.allSessions
                        updated[idx] = merged
                        self.allSessions = updated
                        // Advance parser state only after the matching event snapshot is
                        // visible. Advancing it on the worker first could let a second
                        // monitor reload combine a new cursor with stale `allSessions`.
                        self.reloadLock.lock()
                        if let cursorToPublish {
                            self.appendCursorsBySessionID[id] = cursorToPublish
                        } else {
                            self.appendCursorsBySessionID.removeValue(forKey: id)
                        }
                        self.reloadLock.unlock()
                        DBG("✅ Reloaded: \(filename) events=\(merged.events.count) nonMeta=\(merged.nonMetaCount) msgCount=\(merged.messageCount)")

                        // Keep first-paint responsive; selection loads should not compete
                        // with the terminal renderer for the same transcript text.
                        let cacheSourceStat = postParseStat ?? preParseStat
                        self.enqueueTranscriptCacheBuild(
                            session: merged,
                            sourceStat: cacheSourceStat,
                            delayForSelection: reason == .selection
                        )

                        if shouldSurfaceLoadingState {
                            // Clear loading state AFTER updating allSessions, with small delay for UI to render.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if self.loadingSessionID == id {
                                    self.isLoadingSession = false
                                    self.loadingSessionID = nil
                                }
                            }
                        }
                    } else {
                        DBG("❌ Failed to find session in allSessions after reload")
                        self.reloadLock.lock()
                        self.appendCursorsBySessionID.removeValue(forKey: id)
                        self.reloadLock.unlock()
                        // Clear loading state on failure
                        if self.loadingSessionID == id {
                            self.isLoadingSession = false
                            self.loadingSessionID = nil
                        }
                    }
                }
            } else {
                DBG("❌ parseFileFull returned nil for \(filename)")
                self.reloadLock.lock()
                self.appendCursorsBySessionID.removeValue(forKey: id)
                self.reloadLock.unlock()
                // Clear loading state on failure
                DispatchQueue.main.async {
                    if self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }
            }
        }
    }

    private func enqueueTranscriptCacheBuild(session: Session,
                                             sourceStat: SessionFileStat?,
                                             delayForSelection: Bool) {
        let request = TranscriptCacheBuildRequest(session: session,
                                                  sourceStat: sourceStat,
                                                  delayForSelection: delayForSelection)
        reloadLock.lock()
        // Serialize invalidation with publication below. Otherwise an older builder
        // could set stale text after a newer enqueue had already removed the cache.
        transcriptCache.remove(session.id)
        pendingTranscriptCacheBuildsBySessionID[session.id] = request
        let shouldStart = activeTranscriptCacheBuilderSessionIDs.insert(session.id).inserted
        reloadLock.unlock()
        guard shouldStart else { return }
        launchTranscriptCacheBuilder(for: session.id)
    }

    private func launchTranscriptCacheBuilder(for sessionID: String) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.runTranscriptCacheBuilds(for: sessionID)
        }
    }

    private func takePendingTranscriptCacheBuild(for sessionID: String) -> TranscriptCacheBuildRequest? {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        guard let request = pendingTranscriptCacheBuildsBySessionID.removeValue(forKey: sessionID) else {
            activeTranscriptCacheBuilderSessionIDs.remove(sessionID)
            reloadLock.broadcast()
            return nil
        }
        return request
    }

#if DEBUG
    private func invokeTranscriptCacheBuildHookForTesting(with session: Session) {
        reloadLock.lock()
        let hook = transcriptCacheBuildHookForTesting
        reloadLock.unlock()
        hook?(session)
    }
#endif

    private func publishTranscriptCacheBuild(_ transcript: String, sessionID: String) {
        reloadLock.lock()
        // Do not publish an older snapshot when another reload arrived while it
        // was building. The same worker will consume the latest pending request.
        if pendingTranscriptCacheBuildsBySessionID[sessionID] == nil {
            transcriptCache.set(sessionID, transcript: transcript)
        }
        reloadLock.unlock()
    }

    private func finishCancelledTranscriptCacheBuilder(for sessionID: String) -> Bool {
        reloadLock.lock()
        activeTranscriptCacheBuilderSessionIDs.remove(sessionID)
        // Reserve a successor before unlocking so a request that arrived as this
        // task observed cancellation cannot be stranded behind a stale marker.
        let shouldRestart = pendingTranscriptCacheBuildsBySessionID[sessionID] != nil
            && activeTranscriptCacheBuilderSessionIDs.insert(sessionID).inserted
        reloadLock.broadcast()
        reloadLock.unlock()
        return shouldRestart
    }

    private func runTranscriptCacheBuilds(for sessionID: String) async {
        while !Task.isCancelled {
            guard let request = takePendingTranscriptCacheBuild(for: sessionID) else { return }

            if request.delayForSelection {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { break }
            }
#if DEBUG
            invokeTranscriptCacheBuildHookForTesting(with: request.session)
#endif
            guard !Task.isCancelled else { break }
            let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                session: request.session,
                filters: filters,
                mode: .normal
            )
            guard !Task.isCancelled else { break }
            if let sourceStat = request.sourceStat,
               Self.fileStat(for: URL(fileURLWithPath: request.session.filePath)) != sourceStat {
                continue
            }
            publishTranscriptCacheBuild(transcript, sessionID: sessionID)
        }

        let shouldRestart = finishCancelledTranscriptCacheBuilder(for: sessionID)
        if shouldRestart { launchTranscriptCacheBuilder(for: sessionID) }
    }

    // Parse all lightweight sessions (for Analytics or full-index use cases)
    func parseAllSessionsFull(progress: @escaping (Int, Int) -> Void) async {
        let lightweightSessions = allSessions.filter { $0.events.isEmpty }
        guard !lightweightSessions.isEmpty else {
            DBG("ℹ️ No lightweight sessions to parse")
            return
        }

        DBG("🔍 Starting full parse of \(lightweightSessions.count) lightweight Codex sessions")

        for (index, session) in lightweightSessions.enumerated() {
            let url = URL(fileURLWithPath: session.filePath)

            // Report progress on main thread
            await MainActor.run {
                progress(index + 1, lightweightSessions.count)
            }

            // Parse on background thread
            let fullSession = await Task.detached(priority: .userInitiated) {
                return self.parseFileFull(at: url, forcedID: session.id)
            }.value

            // Update allSessions on main thread
            if let fullSession = fullSession {
                await MainActor.run {
                    if let idx = self.allSessions.firstIndex(where: { $0.id == session.id }) {
                        var updated = self.allSessions
                        updated[idx] = fullSession
                        self.allSessions = updated

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

        DBG("✅ Completed parsing \(lightweightSessions.count) lightweight Codex sessions")
    }

    // Trigger recompute of filtered sessions using current filters (debounced and off main thread).
    func recomputeNow() {
        recomputeDebouncer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let bgQueue = FeatureFlags.backgroundIngestQueue
            bgQueue.async {
                let filters = Filters(query: self.query, dateFrom: self.dateFrom, dateTo: self.dateTo, model: self.selectedModel, kinds: self.selectedKinds, repoName: self.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(self.allSessions,
                                                         filters: filters,
                                                         transcriptCache: self.transcriptCache,
                                                         allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
                if self.hideZeroMessageSessionsPref { results = results.filter { $0.isSideChat || $0.messageCount > 0 } }
                if self.hideLowMessageSessionsPref { results = results.filter { $0.isSideChat || $0.messageCount == 0 || $0.messageCount > 2 } }
                if !self.showHousekeepingSessionsPref { results = results.filter { !$0.isHousekeeping } }
                // FilterEngine now preserves order, so filtered results maintain allSessions sort order
                DispatchQueue.main.async {
                    self.sessions = results
                }
            }
        }
        recomputeDebouncer = work
        let delay: TimeInterval = FeatureFlags.increaseFilterDebounce ? 0.28 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var modelsSeen: [String] {
        Array(Set(allSessions.compactMap { $0.model })).sorted()
    }

    var canAccessRootDirectory: Bool {
        let root = sessionsRoot()
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    func sessionsRoot() -> URL {
        if !sessionsRootOverride.isEmpty { return URL(fileURLWithPath: sessionsRootOverride) }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    // `FileManager.DirectoryEnumerator` uses APIs marked `noasync` in newer SDKs, so enumerate in a sync context.
    private static func enumerateCodexSessionFiles(root: URL, fileManager: FileManager) -> [URL] {
        var found: [URL] = []
        if let en = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                if url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension.lowercased() == "jsonl" {
                    found.append(url)
                }
            }
        }
        return found
    }

    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(.codex) { return }
        let root = sessionsRoot()
        DBG("\n🔄 INDEXING START: root=\(root.path) mode=\(mode) trigger=\(trigger.rawValue)")
        LaunchProfiler.log("Codex.refresh: start (mode=\(mode), trigger=\(trigger.rawValue))")

        let token = UUID()
        refreshToken = token
        refreshTask?.cancel()
        refreshTask = nil
        sideChatRefreshTask?.cancel()
        sideChatRefreshTask = nil
        transcriptPrewarmTask?.cancel()
        transcriptPrewarmTask = nil
        launchPhase = .hydrating
        isIndexing = true
        isProcessingTranscripts = false
        progressText = "Scanning…"
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        let fm = FileManager.default
        let task = Task.detached(priority: .utility) { [weak self, token, root, mode, trigger, executionProfile] in
            guard let self else { return }

            // Fast path: hydrate from SQLite index if available.
            var indexed: [Session] = []
            do {
                if let hydrated = try await self.hydrateFromIndexDBIfAvailable() {
                    indexed = hydrated
                }
            } catch {
                // Ignore DB errors here; fallback to filesystem-only scan.
            }
	            if indexed.isEmpty {
	                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
	                do {
	                    if let retry = try await self.hydrateFromIndexDBIfAvailable(), !retry.isEmpty {
	                        indexed = retry
	                    }
	                } catch {
	                    // Still no DB hydrate; fall through to filesystem.
	                }
	            }

	            await self.seedKnownFileStatsIfNeeded()

            // Even if we have indexed sessions, scan for NEW/CHANGED files and parse them.
            // If DB hydration succeeded, publish those sessions immediately so the UI is usable
            // while we continue scanning incrementally in the background.
            let existingSessions = indexed
            let presentedHydration = !existingSessions.isEmpty
            self.bootstrapKnownFileStatsIfNeeded(from: existingSessions)
            // Load thread_name lookup once for the entire refresh cycle.
            let threadNames = Self.loadCodexThreadNames(sessionsRoot: self.sessionsRoot())
            let stateThreads = Self.loadCodexStateThreads(sessionsRoot: self.sessionsRoot())

            if presentedHydration {
                // Apply Codex Desktop state metadata early so hydrated sessions show
                // renamed titles and state-backed worktree cwd immediately.
                var hydratedSessions = existingSessions
                Self.applyCodexStateMetadata(&hydratedSessions, from: stateThreads)
                Self.applyCodexThreadNames(&hydratedSessions, from: threadNames)
                let hydratedSnapshot = hydratedSessions
                await MainActor.run {
                    guard self.refreshToken == token else { return }
                    self.allSessions = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: hydratedSnapshot, source: .codex)
                    self.scheduleCodexInternalSessionIDBackfillIfNeeded(in: self.allSessions)
                    self.totalFiles = existingSessions.count
                    self.filesProcessed = existingSessions.count
                    self.progressText = "Scanning for updates…"
                    self.launchPhase = .scanning
                }
            }

            #if DEBUG
            if !existingSessions.isEmpty {
                print("[Launch] Hydrated \(existingSessions.count) Codex sessions from DB, now scanning incrementally...")
            } else {
                print("[Launch] DB hydration returned nil for Codex – scanning all files")
            }
            LaunchProfiler.log("Codex.refresh: DB hydrate complete (existing=\(existingSessions.count))")
            #endif

            // Check if directory exists and is accessible
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                await MainActor.run {
                    guard self.refreshToken == token else { return }
                    self.isIndexing = false
                    self.indexingError = "Sessions directory not found: \(root.path)"
                    self.progressText = "Error"
                    self.launchPhase = .error
                }
                return
            }

            let discovery = CodexSessionDiscovery(customRoot: self.sessionsRootOverride.isEmpty ? nil : self.sessionsRootOverride)
            let deltaScope: SessionDeltaScope = (mode == .fullReconcile || trigger == .manual || trigger == .launch) ? .full : .recent
            let previousStats = self.knownFileStatsSnapshot()
            let delta = discovery.discoverDelta(previousByPath: previousStats, scope: deltaScope)
            let found = delta.currentByPath.keys.map { URL(fileURLWithPath: $0) }
            let foundIsEmpty = found.isEmpty
            let currentStatsByPath = delta.currentByPath
            let removedPaths = delta.removedPaths
            let existingSessionPaths = Set(existingSessions.map(\.filePath))
            let changedOrNewFiles: [URL]
            let missingHydratedCount: Int
            switch mode {
            case .fullReconcile:
                changedOrNewFiles = found
                missingHydratedCount = 0
            case .incremental:
                var combined = delta.changedFiles
                // Supplement: force-parse files on disk but missing from hydrated snapshot.
                // Uses set-difference to detect the exact gap rather than count comparison.
                let diskPaths = Set(currentStatsByPath.keys)
                let changedPaths = Set(delta.changedFiles.map(\.path))
                let gapPaths = diskPaths
                    .subtracting(existingSessionPaths)
                    .subtracting(changedPaths)
                if !gapPaths.isEmpty {
                    combined.append(contentsOf: gapPaths.sorted().map { URL(fileURLWithPath: $0) })
                }
                missingHydratedCount = gapPaths.count
                var seenPaths: Set<String> = []
                changedOrNewFiles = combined.filter { seenPaths.insert($0.path).inserted }
            }

            DBG("📁 Found \(found.count) total files, \(changedOrNewFiles.count) changed/new, \(removedPaths.count) removed")
            os_log("Codex.refresh: found=%d changed=%d gap=%d hydrated=%d removed=%d scope=%{public}@",
                   log: indexLog, type: .info,
                   found.count, delta.changedFiles.count, missingHydratedCount,
                   existingSessions.count, removedPaths.count,
                   deltaScope == .full ? "full" : "recent")
            if missingHydratedCount > 0 {
                LaunchProfiler.log("Codex.refresh: forcing parse for \(missingHydratedCount) files missing from hydrated session snapshot")
            }
            LaunchProfiler.log("Codex.refresh: file enumeration done (found=\(found.count), changed=\(changedOrNewFiles.count), removed=\(removedPaths.count))")

            let sortedFiles = changedOrNewFiles.sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
            await MainActor.run {
                guard self.refreshToken == token else { return }
                self.totalFiles = existingSessions.count + sortedFiles.count
                self.hasEmptyDirectory = foundIsEmpty
                if !presentedHydration {
                    self.progressText = "Scanning \(sortedFiles.count) changed files..."
                    self.launchPhase = .scanning
                }
            }

            let config = SessionIndexingEngine.ScanConfig(
                source: .codex,
                discoverFiles: { sortedFiles },
                parseLightweight: { self.parseFile(at: $0) },
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: self.progressThrottler,
                shouldContinue: { self.refreshToken == token },
                shouldMergeArchives: false,
                workerCount: executionProfile.workerCount,
                sliceSize: executionProfile.sliceSize,
                interSliceYieldNanoseconds: executionProfile.interSliceYieldNanoseconds,
                onProgress: { processed, total in
                    guard self.refreshToken == token else { return }
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            await Task.yield()
                            guard self.refreshToken == token else { return }
                            self.filesProcessed = existingSessions.count + processed
                            if processed > 0 {
                                self.progressText = "Indexed \(self.filesProcessed)/\(self.totalFiles)"
                            }
                        }
                    }
                }
            )

            let scanResult = await SessionIndexingEngine.hydrateOrScan(config: config)
            let changedSessions = scanResult.sessions

            // Merge existing sessions with changed ones, then prune removed and missing files.
            var mergedByPath: [String: Session] = [:]
            mergedByPath.reserveCapacity(existingSessions.count + changedSessions.count)
            for session in existingSessions {
                mergedByPath[session.filePath] = session
            }
            for removed in removedPaths {
                mergedByPath.removeValue(forKey: removed)
            }
            for session in changedSessions {
                if let existing = mergedByPath[session.filePath],
                   !existing.events.isEmpty,
                   session.events.isEmpty {
                    #if DEBUG
                    let filename = session.filePath.components(separatedBy: "/").last ?? "?"
                    DBG("⚠️ Preserve full events during refresh: \(filename)")
                    #endif
                    let merged = Session(
                        id: existing.id,
                        source: existing.source,
                        startTime: existing.startTime ?? session.startTime,
                        endTime: session.endTime ?? existing.endTime,
                        model: session.model ?? existing.model,
                        filePath: existing.filePath,
                        fileSizeBytes: session.fileSizeBytes ?? existing.fileSizeBytes,
                        eventCount: max(existing.eventCount, session.eventCount),
                        events: existing.events,
                        cwd: session.lightweightCwd ?? existing.lightweightCwd,
                        repoName: nil,
                        lightweightTitle: session.lightweightTitle ?? existing.lightweightTitle,
                        lightweightCommands: session.lightweightCommands ?? existing.lightweightCommands,
                        isHousekeeping: existing.isHousekeeping,
                        codexInternalSessionIDHint: session.codexInternalSessionIDHint ?? existing.codexInternalSessionIDHint,
                        parentSessionID: session.parentSessionID ?? existing.parentSessionID,
                        subagentType: session.subagentType ?? existing.subagentType,
                        relationshipKind: session.relationshipKind ?? existing.relationshipKind,
                        customTitle: session.customTitle ?? existing.customTitle,
                        codexOriginator: session.codexOriginator ?? existing.codexOriginator,
                        codexSource: session.codexSource ?? existing.codexSource,
                        codexSurface: session.codexSurface ?? existing.codexSurface,
                        reasoningEffort: session.reasoningEffort ?? existing.reasoningEffort
                    )
                    mergedByPath[session.filePath] = merged
                } else {
                    mergedByPath[session.filePath] = session
                }
            }
            let fmExists: (Session) -> Bool = { s in
                FileManager.default.fileExists(atPath: s.filePath)
            }
            var allParsedSessions = Array(mergedByPath.values).filter(fmExists)

            // Reuse Codex state/thread_name lookups loaded earlier in this refresh cycle.
            Self.applyCodexStateMetadata(&allParsedSessions, from: stateThreads)
            Self.applyCodexThreadNames(&allParsedSessions, from: threadNames)
            let totalParsedCount = allParsedSessions.count

            let hideProbes = !(UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"))
            let sortedSessions = allParsedSessions.sorted { $0.modifiedAt > $1.modifiedAt }
                .filter { hideProbes ? !CodexProbeConfig.isProbeSession($0) : true }
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sortedSessions, source: .codex)
            self.applyKnownFileStatsDelta(scope: deltaScope, currentStatsByPath: currentStatsByPath, removedPaths: removedPaths)
            await self.persistKnownFileStats()

            // Persist lightweight session_meta so subsequent hydration is complete.
            // Excludes probe sessions to match analytics policy.
            let sessionsForMeta = allParsedSessions.filter { !CodexProbeConfig.isProbeSession($0) && !$0.isSideChat }
            if !sessionsForMeta.isEmpty {
                do {
                    let db = try IndexDB()
                    try await db.begin()
                    for session in sessionsForMeta {
                        try? await db.upsertSessionMetaCore(Self.sessionMetaRow(from: session))
                    }
                    try await db.commit()
                    os_log("Codex: wrote %d session_meta rows", log: indexLog, type: .info, sessionsForMeta.count)
                } catch {
                    os_log("Codex: session_meta write failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
                    // Non-fatal: hydration gap will persist until next successful write.
                }
            }
            await MainActor.run {
                guard self.refreshToken == token else { return }
                let priorSideChats = self.allSessions.filter(\.isSideChat)
                let mergedWithPreviousSideChats = Self.sortedByModifiedDescending(
                    Self.appendingCodexSideChats(priorSideChats, to: mergedWithArchives)
                )
                LaunchProfiler.log("Codex.refresh: sessions merged (total=\(mergedWithPreviousSideChats.count))")

                // Preserve in-memory backfilled codex internal IDs if this merged snapshot
                // was assembled from an older session snapshot.
                var priorCodexHintsByID: [String: String] = [:]
                priorCodexHintsByID.reserveCapacity(self.allSessions.count)
                for session in self.allSessions {
                    guard session.source == .codex,
                          let hint = session.codexInternalSessionIDHint,
                          !hint.isEmpty else { continue }
                    priorCodexHintsByID[session.id] = hint
                }

                var missingHintUpdates: [String: String] = [:]
                if !priorCodexHintsByID.isEmpty {
                    missingHintUpdates.reserveCapacity(mergedWithPreviousSideChats.count)
                    for session in mergedWithPreviousSideChats {
                        guard session.source == .codex,
                              (session.codexInternalSessionIDHint?.isEmpty ?? true),
                              let hint = priorCodexHintsByID[session.id] else { continue }
                        missingHintUpdates[session.id] = hint
                    }
                }

                self.allSessions = mergedWithPreviousSideChats
                if !missingHintUpdates.isEmpty {
                    self.applyCodexInternalSessionIDHintUpdates(missingHintUpdates)
                }
                self.scheduleCodexInternalSessionIDBackfillIfNeeded(in: self.allSessions)
                self.isIndexing = false
                let lightCount = changedSessions.filter { $0.events.isEmpty }.count
                let heavyCount = changedSessions.count - lightCount
                if !existingSessions.isEmpty {
                    DBG("✅ INDEXING DONE: total=\(totalParsedCount) (existing=\(existingSessions.count), changed=\(changedSessions.count), removed=\(removedPaths.count), lightweight=\(lightCount), fullParse=\(heavyCount))")
                } else {
                    DBG("✅ INDEXING DONE: total=\(totalParsedCount) changed=\(changedSessions.count) removed=\(removedPaths.count) lightweight=\(lightCount) fullParse=\(heavyCount)")
                }

                if presentedHydration || executionProfile.deferNonCriticalWork {
                    self.transcriptPrewarmTask?.cancel()
                    self.transcriptPrewarmTask = nil
                    self.isProcessingTranscripts = false
                    self.progressText = "Ready"
                    self.launchPhase = .ready
                } else {
                    // Start background transcript indexing for accurate search (delta-based).
                    // Only warm sessions that have real events, are not trivially empty/low,
                    // and whose (size,eventCount) signature changed since last prewarm.
	                    let delta: [Session] = {
	                        let all = mergedWithArchives
	                        var out: [Session] = []
	                        out.reserveCapacity(all.count)
	                        for s in all {
	                            if s.events.isEmpty { continue }
	                            if s.messageCount <= 2 { continue }
	                            if let sizeBytes = s.fileSizeBytes, sizeBytes > FeatureFlags.transcriptPrewarmMaxSessionBytes { continue }
	                            let size = s.fileSizeBytes ?? 0
	                            let sig = size ^ (s.eventCount << 16)
	                            if self.lastPrewarmSignatureByID[s.id] == sig { continue }
	                            self.lastPrewarmSignatureByID[s.id] = sig
	                            out.append(s)
	                            if out.count >= FeatureFlags.transcriptPrewarmMaxSessionsPerRefresh { break } // bound work per refresh
                        }
                        return out
                    }()
                    if !delta.isEmpty {
                        self.isProcessingTranscripts = true
                        self.progressText = "Processing transcripts..."
                        self.launchPhase = .transcripts
                        let cache = self.transcriptCache
                        let deltaToWarm = delta
                        self.transcriptPrewarmTask?.cancel()
                        self.transcriptPrewarmTask = Task.detached(priority: .utility) { [weak self, token] in
                            LaunchProfiler.log("Codex.refresh: transcript prewarm start (delta=\(deltaToWarm.count))")
                            await cache.generateAndCache(sessions: deltaToWarm)
                            if Task.isCancelled { return }
                            guard let strongSelf = self else { return }
                            await MainActor.run {
                                guard strongSelf.refreshToken == token else { return }
                                LaunchProfiler.log("Codex.refresh: transcript prewarm complete")
                                strongSelf.transcriptPrewarmTask = nil
                                strongSelf.isProcessingTranscripts = false
                                strongSelf.progressText = "Ready"
                                strongSelf.launchPhase = .ready
                            }
                        }
                    } else {
                        self.transcriptPrewarmTask = nil
                        self.progressText = "Ready"
                        self.launchPhase = .ready
                    }
                }

                // Show lightweight sessions details (only for changed/newly parsed ones)
                let lightSessions = changedSessions.filter { $0.events.isEmpty }
                for s in lightSessions {
                    DBG("  💡 Lightweight: \(s.filePath.components(separatedBy: "/").last ?? "?") msgCount=\(s.messageCount)")
                }

                // Ensure final progress update is shown
                if FeatureFlags.throttleIndexingUIUpdates {
                    self.filesProcessed = self.totalFiles
                    self.progressText = "Indexed \(self.totalFiles)/\(self.totalFiles)"
                }
                self.scheduleSideChatRefresh(token: token, sessionsRoot: root)

                // Wait a moment for filters to apply, then check what's visible
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let filteredCount = self.sessions.count
                    let lightInFiltered = self.sessions.filter { $0.events.isEmpty }.count
                    DBG("📊 AFTER FILTERS: showing=\(filteredCount) (lightweight=\(lightInFiltered))")

                    if lightInFiltered == 0 && lightCount > 0 {
                        DBG("⚠️ WARNING: All lightweight sessions were filtered out!")
                        DBG("   hideZeroMessageSessionsPref=\(self.hideZeroMessageSessionsPref)")
                    }
                }
            }
        }
        refreshTask = task
    }

    @MainActor
    func cancelInFlightWork() {
        refreshToken = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        sideChatRefreshTask?.cancel()
        sideChatRefreshTask = nil
        codexInternalIDBackfillTask?.cancel()
        codexInternalIDBackfillTask = nil
        transcriptPrewarmTask?.cancel()
        transcriptPrewarmTask = nil
        isIndexing = false
        isProcessingTranscripts = false
        progressText = "Ready"
        if launchPhase != .error {
            launchPhase = .ready
        }
    }

    @MainActor
    private func scheduleSideChatRefresh(token: UUID, sessionsRoot: URL) {
        sideChatRefreshTask?.cancel()
        sideChatRefreshTask = Task.detached(priority: .utility) { [weak self, token, sessionsRoot] in
            let cachedSideChats = CodexSideChatLogReader.loadCachedSideChatSessions(sessionsRoot: sessionsRoot)
            if Task.isCancelled { return }
            if !cachedSideChats.isEmpty {
                await self?.publishSideChats(cachedSideChats, token: token, source: "cache")
            }

            LaunchProfiler.log("Codex.sideChats: refresh start")
            let sideChatSessions = CodexSideChatLogReader.loadSideChatSessions(sessionsRoot: sessionsRoot)
            if Task.isCancelled { return }
            await self?.publishSideChats(sideChatSessions, token: token, source: "sqlite")
        }
    }

    @MainActor
    private func publishSideChats(_ sideChats: [Session], token: UUID, source: String) {
        guard refreshToken == token else { return }
        if source == "sqlite" {
            sideChatRefreshTask = nil
        }

        let existingSideChats = allSessions.filter { $0.isSideChat }
        let sideChatsToPublish = Self.mergingCodexSideChats(sideChats, withExisting: existingSideChats)
        let base = allSessions.filter { !$0.isSideChat }
        let merged = Self.sortedByModifiedDescending(Self.appendingCodexSideChats(sideChatsToPublish, to: base))
        allSessions = merged
        LaunchProfiler.log("Codex.sideChats: \(source) publish (sideChats=\(sideChatsToPublish.count), incoming=\(sideChats.count), total=\(merged.count))")
    }

    private func seedKnownFileStatsIfNeeded() async {
        if hasKnownFileStats() { return }
        do {
            if let persisted = try await loadPersistedKnownFileStats() {
                initializeKnownFileStatsIfNeeded(persisted)
                os_log("Codex: seeded file stats from persisted baseline (%d entries)", log: indexLog, type: .info, persisted.count)
                #if DEBUG
                LaunchProfiler.log("Codex.refresh: known file stats loaded from persisted core baseline (\(persisted.count))")
                #endif
                return
            }
        } catch {
            os_log("Codex: seedKnownFileStats failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
            // Non-fatal. We'll bootstrap from hydrated sessions or runtime deltas.
        }
    }

    static func sessionMetaRow(from s: Session) -> SessionMetaRow {
        SessionMetaRow(
            sessionID: s.id,
            source: s.source.rawValue,
            path: s.filePath,
            mtime: Int64(s.modifiedAt.timeIntervalSince1970),
            size: Int64(s.fileSizeBytes ?? 0),
            startTS: Int64((s.startTime ?? s.modifiedAt).timeIntervalSince1970),
            endTS: Int64((s.endTime ?? s.modifiedAt).timeIntervalSince1970),
            model: s.model,
            cwd: s.lightweightCwd,
            repo: s.rowRepoName,
            title: s.lightweightTitle,
            codexInternalSessionID: s.codexInternalSessionIDHint,
            isHousekeeping: s.isHousekeeping,
            messages: s.eventCount,
            commands: s.lightweightCommands ?? 0,
            parentSessionID: s.parentSessionID,
            subagentType: s.subagentType,
            customTitle: s.customTitle,
            codexOriginator: s.codexOriginator,
            codexSource: s.codexSource,
            codexSurface: s.codexSurface?.rawValue,
            reasoningEffort: s.reasoningEffort,
            originator: s.originator,
            originSource: s.originSource,
            surface: s.surface?.rawValue
        )
    }

    private static func fileStat(for url: URL) -> SessionFileStat? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let mtime = Int64((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        let size = Int64(values?.fileSize ?? 0)
        return SessionFileStat(mtime: mtime, size: size)
    }

    static func additionalChangedFilesForMissingHydratedSessions(
        currentByPath: [String: SessionFileStat],
        existingSessionPaths: Set<String>,
        changedFiles: [URL]
    ) -> [URL] {
        let changedPaths = Set(changedFiles.map(\.path))
        var missing: [URL] = []
        missing.reserveCapacity(currentByPath.count)
        for path in currentByPath.keys {
            if existingSessionPaths.contains(path) { continue }
            if changedPaths.contains(path) { continue }
            missing.append(URL(fileURLWithPath: path))
        }
        return missing.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func bootstrapKnownFileStatsIfNeeded(from sessions: [Session]) {
        if hasKnownFileStats() { return }
        guard !sessions.isEmpty else { return }
        var map: [String: SessionFileStat] = [:]
        map.reserveCapacity(sessions.count)
        for session in sessions {
            let url = URL(fileURLWithPath: session.filePath)
            if let stat = Self.fileStat(for: url) {
                map[session.filePath] = stat
            } else {
                let size = Int64(max(0, session.fileSizeBytes ?? 0))
                let mtime = Int64(max(0, session.modifiedAt.timeIntervalSince1970))
                map[session.filePath] = SessionFileStat(mtime: mtime, size: size)
            }
        }
        initializeKnownFileStatsIfNeeded(map)
        #if DEBUG
        LaunchProfiler.log("Codex.refresh: known file stats bootstrapped from hydrated sessions (\(map.count))")
        #endif
    }

    private func persistKnownFileStats() async {
        let snapshot = knownFileStatsSnapshot()
        guard !snapshot.isEmpty else { return }
        do {
            let payload = PersistedFileStatPayload(
                version: 1,
                stats: snapshot.reduce(into: [:]) { partial, entry in
                    partial[entry.key] = PersistedFileStat(mtime: entry.value.mtime, size: entry.value.size)
                }
            )
            let data = try JSONEncoder().encode(payload)
            guard let json = String(data: data, encoding: .utf8) else { return }
            let db = try IndexDB()
            try await db.setIndexState(key: Self.coreFileStatsStateKey, value: json)
        } catch {
            // Non-fatal. Next run can still bootstrap from DB/filesystem.
        }
    }

    private func loadPersistedKnownFileStats() async throws -> [String: SessionFileStat]? {
        let db = try IndexDB()
        guard let raw = try await db.indexStateValue(for: Self.coreFileStatsStateKey),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        let payload = try JSONDecoder().decode(PersistedFileStatPayload.self, from: data)
        guard payload.version == 1 else { return nil }
        let map = payload.stats.reduce(into: [String: SessionFileStat]()) { partial, entry in
            partial[entry.key] = SessionFileStat(mtime: entry.value.mtime, size: entry.value.size)
        }
        return map.isEmpty ? nil : map
    }

    private func hasKnownFileStats() -> Bool {
        knownFileStatsLock.lock()
        let hasStats = !lastKnownFileStatsByPath.isEmpty
        knownFileStatsLock.unlock()
        return hasStats
    }

    private func initializeKnownFileStatsIfNeeded(_ stats: [String: SessionFileStat]) {
        knownFileStatsLock.lock()
        if lastKnownFileStatsByPath.isEmpty {
            lastKnownFileStatsByPath = stats
        }
        knownFileStatsLock.unlock()
    }

    private func knownFileStatsSnapshot() -> [String: SessionFileStat] {
        knownFileStatsLock.lock()
        let snapshot = lastKnownFileStatsByPath
        knownFileStatsLock.unlock()
        return snapshot
    }

    private func applyKnownFileStatsDelta(scope: SessionDeltaScope,
                                          currentStatsByPath: [String: SessionFileStat],
                                          removedPaths: [String]) {
        knownFileStatsLock.lock()
        if scope == .full {
            lastKnownFileStatsByPath = currentStatsByPath
            knownFileStatsLock.unlock()
            return
        }
        for removed in removedPaths {
            lastKnownFileStatsByPath.removeValue(forKey: removed)
        }
        for (path, stat) in currentStatsByPath {
            lastKnownFileStatsByPath[path] = stat
        }
        knownFileStatsLock.unlock()
    }

	    private func hydrateFromIndexDBIfAvailable() async throws -> [Session]? {
	        // Try to hydrate directly from session_meta. Do not gate on rollups presence.
	        // This avoids a cold-start full scan when the DB has meta rows but rollups are still empty.
	        let db = try IndexDB()
	        let repo = SessionMetaRepository(db: db)
	        let list = try await repo.fetchSessions(for: .codex)
	        guard !list.isEmpty else { return nil }
	        return list.sorted { $0.modifiedAt > $1.modifiedAt }
	    }

    /// Incremental hint backfill for installs that predate `session_meta.codex_internal_session_id`.
    /// Runs in small rotating batches so launch/refresh stays responsive while coverage converges.
    @MainActor
    private func scheduleCodexInternalSessionIDBackfillIfNeeded(in sessions: [Session]) {
        guard !sessions.isEmpty else { return }
        if let task = codexInternalIDBackfillTask, !task.isCancelled { return }

        let defaults = UserDefaults.standard
        let now = Date()
        if let lastRun = defaults.object(forKey: Self.codexInternalIDBackfillLastRunAtKey) as? Date,
           now.timeIntervalSince(lastRun) < Self.codexInternalIDBackfillMinInterval {
            return
        }

        let missing = sessions.filter {
            $0.source == .codex && $0.events.isEmpty && ($0.codexInternalSessionIDHint?.isEmpty ?? true)
        }
        guard !missing.isEmpty else {
            defaults.set(0, forKey: Self.codexInternalIDBackfillCursorKey)
            defaults.removeObject(forKey: Self.codexInternalIDBackfillLastRunAtKey)
            return
        }

        let startIndex = max(0, defaults.integer(forKey: Self.codexInternalIDBackfillCursorKey))
        let selection = Self.selectCodexInternalIDBackfillBatch(from: missing,
                                                                startIndex: startIndex,
                                                                batchSize: Self.codexInternalIDBackfillBatchSize)
        guard !selection.sessions.isEmpty else { return }
        defaults.set(selection.nextIndex, forKey: Self.codexInternalIDBackfillCursorKey)
        defaults.set(now, forKey: Self.codexInternalIDBackfillLastRunAtKey)

        let batch = selection.sessions
        codexInternalIDBackfillTask = Task.detached(priority: .utility) { [weak self] in
            let updatesByID = Self.computeCodexInternalSessionIDHintUpdates(for: batch)
            if !updatesByID.isEmpty, let db = try? IndexDB() {
                for (sessionID, internalID) in updatesByID {
                    try? await db.updateSessionMetaCodexInternalSessionID(
                        sessionID: sessionID,
                        source: SessionSource.codex.rawValue,
                        codexInternalSessionID: internalID
                    )
                }
            }

            let model = self
            await MainActor.run {
                guard let model else { return }
                if !updatesByID.isEmpty {
                    model.applyCodexInternalSessionIDHintUpdates(updatesByID)
                }
                model.codexInternalIDBackfillTask = nil
            }
        }
    }

    private static func selectCodexInternalIDBackfillBatch(from missing: [Session],
                                                           startIndex: Int,
                                                           batchSize: Int) -> (sessions: [Session], nextIndex: Int) {
        guard !missing.isEmpty, batchSize > 0 else { return ([], 0) }
        let safeStart = min(startIndex, max(0, missing.count - 1))
        let count = min(batchSize, missing.count)
        var selected: [Session] = []
        selected.reserveCapacity(count)
        for offset in 0..<count {
            let idx = (safeStart + offset) % missing.count
            selected.append(missing[idx])
        }
        let nextIndex = (safeStart + count) % missing.count
        return (selected, nextIndex)
    }

    private static func computeCodexInternalSessionIDHintUpdates(for sessions: [Session]) -> [String: String] {
        guard !sessions.isEmpty else { return [:] }
        var updatesByID: [String: String] = [:]
        updatesByID.reserveCapacity(sessions.count)

        for session in sessions {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: session.filePath)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (attrs[.modificationDate] as? Date) ?? Date()
            let url = URL(fileURLWithPath: session.filePath)
            guard let parsed = Self.lightweightSession(from: url, size: size, mtime: mtime),
                  let internalID = parsed.codexInternalSessionIDHint ?? parsed.codexInternalSessionID,
                  !internalID.isEmpty else { continue }
            updatesByID[session.id] = internalID
        }
        return updatesByID
    }

    @MainActor
    private func applyCodexInternalSessionIDHintUpdates(_ updatesByID: [String: String]) {
        guard !updatesByID.isEmpty else { return }
        allSessions = allSessions.map { session in
            guard let internalID = updatesByID[session.id] else { return session }
            let rebuilt = Session(
                id: session.id,
                source: session.source,
                startTime: session.startTime,
                endTime: session.endTime,
                model: session.model,
                filePath: session.filePath,
                fileSizeBytes: session.fileSizeBytes,
                eventCount: session.eventCount,
                events: session.events,
                cwd: session.lightweightCwd,
                repoName: nil,
                lightweightTitle: session.lightweightTitle,
                lightweightCommands: session.lightweightCommands,
                isHousekeeping: session.isHousekeeping,
                codexInternalSessionIDHint: internalID,
                parentSessionID: session.parentSessionID,
                subagentType: session.subagentType,
                relationshipKind: session.relationshipKind,
                customTitle: session.customTitle,
                codexOriginator: session.codexOriginator,
                codexSource: session.codexSource,
                codexSurface: session.codexSurface,
                reasoningEffort: session.reasoningEffort
            )
            var enriched = rebuilt
            enriched.isFavorite = session.isFavorite
            return enriched
        }
    }

    // MARK: - Codex thread_name side-channel

    struct CodexStateThread {
        let id: String
        let rolloutPath: String
        let cwd: String?
        let gitBranch: String?
        let gitOriginURL: String?
        let title: String?
        let firstUserMessage: String?

        var bestTitle: String? {
            if let title = Self.nonEmpty(title) { return title }
            return Self.sanitizedFallbackTitle(from: firstUserMessage)
        }

        /// Leading literals the fallback sanitizer can strip at position zero.
        /// The state-db reader mirrors this list to pass scaffolded messages
        /// through complete so whole wrappers reach the sanitizer.
        /// Keep both sides aligned when adding a recognized scaffold form.
        static let codexFallbackScaffoldPrefixes = [
            "# Files pasted by the user:",
            "<app-context>",
            "<environment_context>",
            "<permissions instructions>",
            "<skills_instructions>",
            "<apps_instructions>",
            "<plugins_instructions>",
            "<recommended_plugins>",
            "<collaboration_mode>",
            "<INSTRUCTIONS>",
            "# AGENTS.md instructions for"
        ]

        static func sanitizedFallbackTitle(from raw: String?) -> String? {
            guard var rest = Self.nonEmpty(raw) else { return nil }
            let pairedTags = codexFallbackScaffoldPrefixes
                .filter { $0.hasPrefix("<") && $0.hasSuffix(">") && $0 != "<INSTRUCTIONS>" }
                .map { String($0.dropFirst().dropLast()) }
            var madeProgress = true
            while madeProgress {
                madeProgress = false
                if rest.hasPrefix("# Files pasted by the user:") {
                    let lines = rest.components(separatedBy: "\n")
                    var delimiterIndex: Int?
                    for idx in 1..<lines.count {
                        if lines[idx].trimmingCharacters(in: .whitespacesAndNewlines) == "## My request:" {
                            delimiterIndex = idx
                            break
                        }
                    }
                    guard let delimiter = delimiterIndex else { return boundedTitle(rest) }
                    let after = lines[(delimiter + 1)...].joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if after.isEmpty { return nil }
                    rest = after
                    madeProgress = true
                    continue
                }
                var strippedPaired = false
                for tag in pairedTags {
                    let open = "<\(tag)>"
                    let close = "</\(tag)>"
                    guard rest.hasPrefix(open) else { continue }
                    guard let searchStart = rest.index(rest.startIndex, offsetBy: open.count, limitedBy: rest.endIndex),
                          let closeRange = rest.range(of: close, range: searchStart..<rest.endIndex) else {
                        return boundedTitle(rest)
                    }
                    let after = String(rest[closeRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if after.isEmpty { return nil }
                    rest = after
                    madeProgress = true
                    strippedPaired = true
                    break
                }
                if strippedPaired { continue }
                if rest.hasPrefix("# AGENTS.md instructions for") {
                    guard let openRange = rest.range(of: "<INSTRUCTIONS>"),
                          let closeRange = rest.range(of: "</INSTRUCTIONS>", range: openRange.upperBound..<rest.endIndex) else {
                        return boundedTitle(rest)
                    }
                    let after = String(rest[closeRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if after.isEmpty { return nil }
                    rest = after
                    madeProgress = true
                    continue
                }
            }
            let final = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty else { return nil }
            return boundedTitle(final)
        }

        private static func boundedTitle(_ value: String) -> String {
            if value.count > SessionIndexer.codexStateFirstUserMessageTitleLimit {
                return String(value.prefix(SessionIndexer.codexStateFirstUserMessageTitleLimit))
            }
            return value
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
    }

    struct CodexStateThreadLookup {
        let byID: [String: CodexStateThread]
        let byPath: [String: CodexStateThread]

        var isEmpty: Bool { byID.isEmpty && byPath.isEmpty }
    }

    private static let codexStateFirstUserMessageTitleLimit = 512

    private static func codexStateDirectoryURL(sessionsRoot: URL) -> URL? {
        guard sessionsRoot.lastPathComponent == "sessions" else { return nil }
        return sessionsRoot.deletingLastPathComponent()
    }

    private static func loadCodexStateThreads(sessionsRoot: URL) -> CodexStateThreadLookup {
        guard let stateDir = codexStateDirectoryURL(sessionsRoot: sessionsRoot) else {
            return CodexStateThreadLookup(byID: [:], byPath: [:])
        }
        guard let stateURL = newestCodexStateDB(in: stateDir) else {
            return CodexStateThreadLookup(byID: [:], byPath: [:])
        }
        return readCodexStateThreads(from: stateURL)
    }

    private static func newestCodexStateDB(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let candidates = entries.filter { url in
            url.lastPathComponent.hasPrefix("state_") && url.pathExtension == "sqlite"
        }
        return candidates.max { lhs, rhs in
            let lhsVersion = codexStateDBVersion(lhs)
            let rhsVersion = codexStateDBVersion(rhs)
            if lhsVersion != rhsVersion { return lhsVersion < rhsVersion }
            let lhsMtime = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsMtime = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsMtime < rhsMtime
        }
    }

    private static func codexStateDBVersion(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        guard let suffix = name.split(separator: "_").last, let version = Int(suffix) else { return 0 }
        return version
    }

    static func readCodexStateThreads(from url: URL) -> CodexStateThreadLookup {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return CodexStateThreadLookup(byID: [:], byPath: [:])
        }
        defer { sqlite3_close(db) }

        let columns = codexStateThreadColumns(in: db)
        let gitBranchExpression = columns.contains("git_branch") ? "git_branch" : "NULL"
        let gitOriginExpression = columns.contains("git_origin_url") ? "git_origin_url" : "NULL"
        let scaffoldPredicate = CodexStateThread.codexFallbackScaffoldPrefixes
            .map { prefix in
                let escaped = prefix
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                    .replacingOccurrences(of: "'", with: "''")
                return "first_user_message LIKE '\(escaped)%' ESCAPE '\\'"
            }
            .joined(separator: " OR ")
        let sql = """
        SELECT id, rollout_path, cwd, \(gitBranchExpression), \(gitOriginExpression), title,
               CASE WHEN length(trim(title)) > 0 THEN NULL WHEN \(scaffoldPredicate) THEN first_user_message ELSE substr(first_user_message, 1, ?) END
        FROM threads;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return CodexStateThreadLookup(byID: [:], byPath: [:])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(codexStateFirstUserMessageTitleLimit))

        var byID: [String: CodexStateThread] = [:]
        var byPath: [String: CodexStateThread] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCString = sqlite3_column_text(stmt, 0),
                  let pathCString = sqlite3_column_text(stmt, 1) else { continue }
            let thread = CodexStateThread(
                id: String(cString: idCString),
                rolloutPath: String(cString: pathCString),
                cwd: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 2)),
                gitBranch: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3)),
                gitOriginURL: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4)),
                title: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5)),
                firstUserMessage: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 6))
            )
            byID[thread.id] = thread
            byPath[normalizeCodexRolloutPath(thread.rolloutPath)] = thread
        }
        return CodexStateThreadLookup(byID: byID, byPath: byPath)
    }

    private static func codexStateThreadColumns(in db: OpaquePointer?) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads);", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameCString = sqlite3_column_text(stmt, 1) else { continue }
            columns.insert(String(cString: nameCString))
        }
        return columns
    }

    private static func normalizeCodexRolloutPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private static func applyCodexStateMetadata(_ sessions: inout [Session], from lookup: CodexStateThreadLookup) {
        guard !lookup.isEmpty else { return }
        for i in sessions.indices {
            let thread: CodexStateThread?
            if let hint = sessions[i].codexInternalSessionIDHint {
                thread = lookup.byID[hint] ?? lookup.byPath[normalizeCodexRolloutPath(sessions[i].filePath)]
            } else {
                thread = lookup.byPath[normalizeCodexRolloutPath(sessions[i].filePath)]
            }
            guard let thread else { continue }

            let title = sessions[i].customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? nil
                : thread.bestTitle
            let cwd = nonEmptyCodexStateCwd(thread.cwd) ?? sessions[i].lightweightCwd
            let repoName = ProjectPathNormalizer.codexDesktopProjectNameFromGitMetadata(
                cwd: cwd,
                gitRepositoryURL: thread.gitOriginURL,
                gitBranch: thread.gitBranch
            ) ?? sessions[i].lightweightRepoName
            let titleChanged = title != nil && title != sessions[i].lightweightTitle
            let cwdChanged = cwd != sessions[i].lightweightCwd
            let repoChanged = repoName != sessions[i].lightweightRepoName
            guard titleChanged || cwdChanged || repoChanged else { continue }

            let wasFavorite = sessions[i].isFavorite
            var rebuilt = Session(
                id: sessions[i].id,
                source: sessions[i].source,
                startTime: sessions[i].startTime,
                endTime: sessions[i].endTime,
                model: sessions[i].model,
                filePath: sessions[i].filePath,
                fileSizeBytes: sessions[i].fileSizeBytes,
                eventCount: sessions[i].eventCount,
                events: sessions[i].events,
                cwd: cwd,
                repoName: repoName,
                lightweightTitle: title ?? sessions[i].lightweightTitle,
                lightweightCommands: sessions[i].lightweightCommands,
                isHousekeeping: sessions[i].isHousekeeping,
                codexInternalSessionIDHint: sessions[i].codexInternalSessionIDHint,
                parentSessionID: sessions[i].parentSessionID,
                subagentType: sessions[i].subagentType,
                relationshipKind: sessions[i].relationshipKind,
                customTitle: sessions[i].customTitle,
                codexOriginator: sessions[i].codexOriginator,
                codexSource: sessions[i].codexSource,
                codexSurface: sessions[i].codexSurface,
                originator: sessions[i].originator,
                originSource: sessions[i].originSource,
                surface: sessions[i].surface,
                reasoningEffort: sessions[i].reasoningEffort
            )
            rebuilt.isFavorite = wasFavorite
            sessions[i] = rebuilt
        }
    }

    private static func appendingCodexSideChats(_ sideChats: [Session], to sessions: [Session]) -> [Session] {
        guard !sideChats.isEmpty else { return sessions }
        var merged = sessions
        var existingIDs = Set(sessions.map(\.id))
        merged.reserveCapacity(sessions.count + sideChats.count)
        for sideChat in sideChats {
            guard existingIDs.insert(sideChat.id).inserted else { continue }
            merged.append(sideChat)
        }
        return merged
    }

    private static func mergingCodexSideChats(_ incoming: [Session], withExisting existing: [Session]) -> [Session] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for session in incoming {
            byID[session.id] = session
        }
        return Array(byID.values)
    }

    private static func sortedByModifiedDescending(_ sessions: [Session]) -> [Session] {
        sessions.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt { return lhs.id > rhs.id }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    private static func nonEmptyCodexStateCwd(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Read budget: max bytes of `session_index.jsonl` to load per refresh (2 MB).
    /// For files exceeding this, we read the tail so recent renames are never lost.
    private static let threadNameReadBudget = 2 * 1024 * 1024

    /// Bounded fingerprint segments to detect updates that preserve size/mtime metadata.
    private static let threadNameFingerprintSegmentBytes = 8 * 1024
    /// Force periodic re-parse so unchanged metadata/fingerprint does not live forever.
    private static let threadNameCacheMaxAge: TimeInterval = 120

    /// Lock-protected cache for parsed thread names, invalidated by path+mtime+size+fingerprint+age.
    private static let threadNameCacheLock = NSLock()
    private static var _threadNameCache: (
        path: String,
        mtime: Date,
        size: Int,
        fingerprint: UInt64,
        loadedAt: Date,
        lookup: [String: String]
    )?

    private static func fnv1a64(_ data: Data, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var hash = seed
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Returns `~/.codex/session_index.jsonl` only for verified `.../sessions` layouts.
    /// For non-standard roots (for example imported snapshots), side-channel overrides are disabled.
    private static func codexThreadNameIndexURL(sessionsRoot: URL) -> URL? {
        guard sessionsRoot.lastPathComponent == "sessions" else {
            os_log("Codex thread_name side-channel disabled for non-standard sessions root: %{public}@",
                   log: indexLog, type: .info, sessionsRoot.path)
            return nil
        }
        return sessionsRoot.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
    }

    /// Reads a small head+tail sample to detect same-size updates even on coarse mtime filesystems.
    private static func computeThreadNameFingerprint(fileHandle: FileHandle, size: Int) -> UInt64 {
        let boundedSize = max(0, size)
        let segmentBytes = max(1, threadNameFingerprintSegmentBytes)
        let segmentCount = min(boundedSize, segmentBytes)
        var hash = fnv1a64(Data("\(boundedSize)".utf8))

        do {
            try fileHandle.seek(toOffset: 0)
            let head = try fileHandle.read(upToCount: segmentCount) ?? Data()
            hash = fnv1a64(head, seed: hash)

            if boundedSize > segmentCount {
                let tailOffset = UInt64(boundedSize - segmentCount)
                try fileHandle.seek(toOffset: tailOffset)
                let tail = try fileHandle.read(upToCount: segmentCount) ?? Data()
                hash = fnv1a64(tail, seed: hash)
            }
        } catch {
            // Leave hash as size-only fallback when sampling fails.
        }

        return hash
    }

    /// Reads `~/.codex/session_index.jsonl` and returns a lookup from internal session UUID to user-set thread name.
    /// - Cached by (path, mtime, size, fingerprint) with max age fallback; safe for multi-root and root-switching scenarios.
    /// - For files larger than `threadNameReadBudget`, reads the **tail** so recent appended renames are captured.
    /// - Returns empty on any read failure — never serves stale data from a prior cycle.
    static func loadCodexThreadNames(sessionsRoot: URL) -> [String: String] {
        guard let indexFile = codexThreadNameIndexURL(sessionsRoot: sessionsRoot) else { return [:] }
        let filePath = indexFile.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: filePath)) ?? [:]
        guard let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else {
            return [:]
        }
        guard let fh = try? FileHandle(forReadingFrom: indexFile) else { return [:] }
        defer { try? fh.close() }

        let fingerprint = computeThreadNameFingerprint(fileHandle: fh, size: size)

        // Return cached result if file hasn't changed and cache age is within guard rails.
        let now = Date()
        threadNameCacheLock.lock()
        let cached = _threadNameCache
        threadNameCacheLock.unlock()
        if let cached,
           cached.path == filePath,
           cached.mtime == mtime,
           cached.size == size,
           cached.fingerprint == fingerprint,
           now.timeIntervalSince(cached.loadedAt) <= threadNameCacheMaxAge {
            return cached.lookup
        }
        // For files within budget, read everything. For larger files, read the tail
        // so recently appended renames (which are at the end) are always captured.
        let data: Data
        let skipFirstLine: Bool
        if size <= threadNameReadBudget {
            try? fh.seek(toOffset: 0)
            guard let d = try? fh.read(upToCount: size) else { return [:] }
            data = d
            skipFirstLine = false
        } else {
            let tailOffset = UInt64(size - threadNameReadBudget)
            var shouldSkipFirstLine = true
            if tailOffset > 0 {
                try? fh.seek(toOffset: tailOffset - 1)
                if let previousByteData = (try? fh.read(upToCount: 1)) ?? nil,
                   previousByteData.first == UInt8(ascii: "\n") {
                    // Offset lands on a line boundary: first tail line is complete.
                    shouldSkipFirstLine = false
                }
            }
            try? fh.seek(toOffset: tailOffset)
            guard let d = try? fh.read(upToCount: threadNameReadBudget) else { return [:] }
            data = d
            skipFirstLine = shouldSkipFirstLine
        }
        var lookup: [String: String] = [:]
        var skippedFirstLine = skipFirstLine
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let bytes = UnsafeBufferPointer(start: base, count: buffer.count)
            var lineStart = bytes.startIndex
            while lineStart < bytes.endIndex {
                var lineEnd = lineStart
                while lineEnd < bytes.endIndex && bytes[lineEnd] != UInt8(ascii: "\n") { lineEnd += 1 }
                defer { lineStart = lineEnd + 1 }
                // When reading from a tail offset, the first "line" is likely a partial — skip it.
                if skippedFirstLine {
                    skippedFirstLine = false
                    continue
                }
                guard lineEnd > lineStart,
                      let lineData = String(bytes: bytes[lineStart..<lineEnd], encoding: .utf8)?.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let id = obj["id"] as? String, !id.isEmpty,
                      let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
                lookup[id] = name
            }
        }
        threadNameCacheLock.lock()
        _threadNameCache = (
            path: filePath,
            mtime: mtime,
            size: size,
            fingerprint: fingerprint,
            loadedAt: now,
            lookup: lookup
        )
        threadNameCacheLock.unlock()
        return lookup
    }

    /// Applies thread_name overrides from session_index.jsonl as customTitle on matching sessions.
    /// Overwrites existing customTitle when the lookup value differs, so re-renames propagate.
    static func applyCodexThreadNames(_ sessions: inout [Session], from lookup: [String: String]) {
        guard !lookup.isEmpty else { return }
        for i in sessions.indices {
            guard let hint = sessions[i].codexInternalSessionIDHint,
                  let name = lookup[hint],
                  sessions[i].customTitle != name else { continue }
            let wasFavorite = sessions[i].isFavorite
            var rebuilt = Session(
                id: sessions[i].id,
                source: sessions[i].source,
                startTime: sessions[i].startTime,
                endTime: sessions[i].endTime,
                model: sessions[i].model,
                filePath: sessions[i].filePath,
                fileSizeBytes: sessions[i].fileSizeBytes,
                eventCount: sessions[i].eventCount,
                events: sessions[i].events,
                cwd: sessions[i].lightweightCwd,
                repoName: sessions[i].lightweightRepoName,
                lightweightTitle: sessions[i].lightweightTitle,
                lightweightCommands: sessions[i].lightweightCommands,
                isHousekeeping: sessions[i].isHousekeeping,
                codexInternalSessionIDHint: hint,
                parentSessionID: sessions[i].parentSessionID,
                subagentType: sessions[i].subagentType,
                relationshipKind: sessions[i].relationshipKind,
                customTitle: name,
                codexOriginator: sessions[i].codexOriginator,
                codexSource: sessions[i].codexSource,
                codexSurface: sessions[i].codexSurface,
                reasoningEffort: sessions[i].reasoningEffort
            )
            rebuilt.isFavorite = wasFavorite
            sessions[i] = rebuilt
        }
    }

    // MARK: - Parsing
    // Codex rollout parsing lives in `CodexSessionParser` (UI-free, shared with the Linux
    // CLI). These forwarders keep existing call sites and the DEBUG parse counters intact.

    func parseFile(at url: URL) -> Session? {
        CodexSessionParser.parseLightweight(at: url) ?? parseFileFull(at: url)
    }

    func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        parseFileFullResult(at: url, forcedID: forcedID)?.session
    }

    private func parseFileFullResult(at url: URL, forcedID: String? = nil) -> FullParseResult? {
#if DEBUG
        reloadLock.lock()
        fullParseInvocationCountForTesting += 1
        reloadLock.unlock()
#endif
        return CodexSessionParser.parseFileFullResult(at: url, forcedID: forcedID)
    }

    func makeAppendCursor(at url: URL,
                          lastLineIndex: Int,
                          byteOffset requestedByteOffset: UInt64? = nil) -> CodexAppendCursor? {
        CodexSessionParser.makeAppendCursor(at: url, lastLineIndex: lastLineIndex, byteOffset: requestedByteOffset)
    }

    func parseFileAppend(at url: URL,
                         existing: Session,
                         cursor: CodexAppendCursor) -> CodexAppendParseResult {
#if DEBUG
        reloadLock.lock()
        appendParseInvocationCountForTesting += 1
        reloadLock.unlock()
#endif
        return CodexSessionParser.parseFileAppend(at: url, existing: existing, cursor: cursor)
    }

    func parseFileTail(at url: URL,
                       forcedID: String? = nil,
                       maxBytes: Int = 2_097_152,
                       maxLines: Int = 400) -> Session? {
        CodexSessionParser.parseFileTail(at: url, forcedID: forcedID, maxBytes: maxBytes, maxLines: maxLines)
    }

    static func lightweightSession(from url: URL, size: Int, mtime: Date) -> Session? {
        CodexSessionParser.lightweightSession(from: url, size: size, mtime: mtime)
    }

    static func classifyCodexSurface(originator: String?, source: Any?, sourceString: String?) -> CodexSessionSurface {
        CodexSessionParser.classifyCodexSurface(originator: originator, source: source, sourceString: sourceString)
    }

    static func parseLine(_ line: String, eventID: String) -> (SessionEvent, String?) {
        CodexSessionParser.parseLine(line, eventID: eventID)
    }

    static func eventID(forPath path: String, index: Int) -> String {
        CodexSessionParser.eventID(forPath: path, index: index)
    }

}

// `SessionIndexer` is UI-owned and mutations are funneled back through the main queue/MainActor.
// Mark as unchecked Sendable to allow progress/reporting closures that require `@Sendable`.
extension SessionIndexer: @unchecked Sendable {}
// swiftlint:enable type_body_length

// (Codex picker parity helpers temporarily disabled while focusing on title parity.)

// MARK: - SessionIndexerProtocol Conformance
extension SessionIndexer: SessionIndexerProtocol {
    var requestCopyPlainPublisher: AnyPublisher<Void, Never> {
        $requestCopyPlain.map { _ in () }.eraseToAnyPublisher()
    }

    var requestTranscriptFindFocusPublisher: AnyPublisher<Void, Never> {
        $requestTranscriptFindFocus.map { _ in () }.eraseToAnyPublisher()
    }
}

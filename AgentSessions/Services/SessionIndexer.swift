import Foundation
import Combine
import CryptoKit
import SwiftUI
import os.log

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

    var statusDescription: String {
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
    @AppStorage("SessionsRootOverride") var sessionsRootOverride: String = ""
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
    private let reloadLock = NSLock()
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]
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
            .receive(on: FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] input, kinds, all -> [Session] in
                let (q, from, to, model) = input
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(all,
                                                         filters: filters,
                                                         transcriptCache: self?.transcriptCache,
                                                         allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)

                if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 } }
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
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
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
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

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeNow() }
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

    enum ReloadReason: String {
        case selection
        case focusedSessionMonitor
        case manualRefresh
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

        let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            let loadingTimer: DispatchSourceTimer? = nil
            defer {
                // Always clean up timer and reloading state
                loadingTimer?.cancel()
                self.reloadLock.lock()
                self.reloadingSessionIDs.remove(id)
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

            let hasLoadedEvents = !existing.events.isEmpty
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

            let startTime = Date()

            DBG("  🚀 Starting parseFileFull...")
            // Force full parse by calling parseFile directly (skip lightweight check)
            if let fullSession = self.parseFileFull(at: url, forcedID: id) {
                let elapsed = Date().timeIntervalSince(startTime)
                DBG("  ⏱️ Parse took \(String(format: "%.1f", elapsed))s - events=\(fullSession.events.count)")
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

                DispatchQueue.main.async {
                    // Replace in allSessions
                    if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                        let current = self.allSessions[idx]
                        let merged = Session(
                            id: fullSession.id,
                            source: fullSession.source,
                            startTime: fullSession.startTime ?? current.startTime,
                            endTime: fullSession.endTime ?? current.endTime,
                            model: fullSession.model ?? current.model,
                            filePath: fullSession.filePath,
                            fileSizeBytes: fullSession.fileSizeBytes ?? current.fileSizeBytes,
                            eventCount: max(current.eventCount, fullSession.nonMetaCount),
                            events: fullSession.events,
                            cwd: current.lightweightCwd ?? fullSession.cwd,
                            repoName: current.repoName,
                            lightweightTitle: current.lightweightTitle,
                            lightweightCommands: current.lightweightCommands,
                            parentSessionID: fullSession.parentSessionID ?? current.parentSessionID,
                            subagentType: fullSession.subagentType ?? current.subagentType,
                            customTitle: fullSession.customTitle ?? current.customTitle
                        )
                        var updated = self.allSessions
                        updated[idx] = merged
                        self.allSessions = updated
                        DBG("✅ Reloaded: \(filename) events=\(merged.events.count) nonMeta=\(merged.nonMetaCount) msgCount=\(merged.messageCount)")

                        // Update transcript cache for accurate search
                        let cache = self.transcriptCache
                        cache.remove(merged.id)
                        Task.detached(priority: .utility) {
                            let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                                session: merged,
                                filters: filters,
                                mode: .normal
                            )
                            cache.set(merged.id, transcript: transcript)
                        }

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
                        // Clear loading state on failure
                        if self.loadingSessionID == id {
                            self.isLoadingSession = false
                            self.loadingSessionID = nil
                        }
                    }
                }
            } else {
                DBG("❌ parseFileFull returned nil for \(filename)")
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
            let bgQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
            bgQueue.async {
                let filters = Filters(query: self.query, dateFrom: self.dateFrom, dateTo: self.dateTo, model: self.selectedModel, kinds: self.selectedKinds, repoName: self.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(self.allSessions,
                                                         filters: filters,
                                                         transcriptCache: self.transcriptCache,
                                                         allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
                if self.hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
                if self.hideLowMessageSessionsPref { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
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

            if presentedHydration {
                // Apply thread_name overrides early so hydrated sessions show renamed titles immediately.
                var hydratedSessions = existingSessions
                Self.applyCodexThreadNames(&hydratedSessions, from: threadNames)
                let finalHydratedSessions = hydratedSessions
                await MainActor.run {
                    guard self.refreshToken == token else { return }
                    self.allSessions = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: finalHydratedSessions, source: .codex)
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
                        customTitle: session.customTitle ?? existing.customTitle
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

            // Reuse thread_name lookup loaded earlier in this refresh cycle.
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
            let sessionsForMeta = allParsedSessions.filter { !CodexProbeConfig.isProbeSession($0) }
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
                LaunchProfiler.log("Codex.refresh: sessions merged (total=\(mergedWithArchives.count))")

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
                    missingHintUpdates.reserveCapacity(mergedWithArchives.count)
                    for session in mergedWithArchives {
                        guard session.source == .codex,
                              (session.codexInternalSessionIDHint?.isEmpty ?? true),
                              let hint = priorCodexHintsByID[session.id] else { continue }
                        missingHintUpdates[session.id] = hint
                    }
                }

                self.allSessions = mergedWithArchives
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
            repo: s.repoName,
            title: s.lightweightTitle,
            codexInternalSessionID: s.codexInternalSessionIDHint,
            isHousekeeping: s.isHousekeeping,
            messages: s.eventCount,
            commands: s.lightweightCommands ?? 0,
            parentSessionID: s.parentSessionID,
            subagentType: s.subagentType,
            customTitle: s.customTitle
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
                customTitle: session.customTitle
            )
            var enriched = rebuilt
            enriched.isFavorite = session.isFavorite
            return enriched
        }
    }

    // MARK: - Codex thread_name side-channel

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
                customTitle: name
            )
            rebuilt.isFavorite = wasFavorite
            sessions[i] = rebuilt
        }
    }

	    // MARK: - Parsing

    func parseFile(at url: URL) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        // Prefer lightweight metadata-first parsing for all files at launch.
        // This avoids full JSONL scans during Stage 1 and keeps launch bounded
        // even when many sessions are present.
        if let light = Self.lightweightSession(from: url, size: size, mtime: mtime) {
            DBG("✅ LIGHTWEIGHT: \(url.lastPathComponent) estEvents=\(light.eventCount) messageCount=\(light.messageCount)")
            return light
        }

        // Fallback: full parse only when lightweight path fails.
        return parseFileFull(at: url)
    }

    // Full parse (no lightweight check)
    func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        DBG("    📖 parseFileFull: Getting file attrs...")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        DBG("    📖 parseFileFull: File size = \(size) bytes")

        DBG("    📖 parseFileFull: Creating JSONLReader...")
        let reader = JSONLReader(url: url)
        var events: [SessionEvent] = []
        var modelSeen: String? = nil
        var parentSessionID: String? = nil
        var subagentType: String? = nil
        var idx = 0
        DBG("    📖 parseFileFull: Starting forEachLine...")
        do {
            try reader.forEachLine { rawLine in
                idx += 1
                // Only sanitize very large lines (>100KB) - sanitizeLargeLine has its own guards for smaller lines
                let safeLine = rawLine.utf8.count > 100_000 ? Self.sanitizeLargeLine(rawLine) : rawLine
                let (event, maybeModel) = Self.parseLine(safeLine, eventID: self.eventID(for: url, index: idx))
                if let m = maybeModel, modelSeen == nil { modelSeen = m }

                // Extract subagent info and turn_context model from early lines
                if idx <= 20, let data = safeLine.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let objType = obj["type"] as? String
                    let payload = obj["payload"] as? [String: Any]

                    if parentSessionID == nil, objType == "session_meta", let payload {
                        if let source = payload["source"],
                           let sourceDict = source as? [String: Any],
                           let subagentInfo = sourceDict["subagent"] {
                            if let subStr = subagentInfo as? String {
                                subagentType = subStr
                            } else if let subDict = subagentInfo as? [String: Any],
                                      let threadSpawn = subDict["thread_spawn"] as? [String: Any] {
                                parentSessionID = threadSpawn["parent_thread_id"] as? String
                                subagentType = threadSpawn["agent_role"] as? String
                            }
                        }
                    }

                    if objType == "turn_context", let payload,
                       let turnModel = payload["model"] as? String, !turnModel.isEmpty {
                        modelSeen = turnModel
                    }
                }

                events.append(event)
            }
        } catch {
            // If file can't be read, emit a single error meta event
            let event = SessionEvent(id: eventID(for: url, index: 0), timestamp: Date(), kind: .error, role: "system", text: "Failed to read: \(error.localizedDescription)", toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
            events.append(event)
        }

        let times = events.compactMap { $0.timestamp }
        var start = times.min()
        var end = times.max()
        if start == nil || end == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if start == nil { start = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) }
                if end == nil { end = (attrs[.modificationDate] as? Date) ?? start }
            }
        }
        let id = forcedID ?? Self.hash(path: url.path)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        let isHousekeeping = Session.computeIsHousekeeping(source: .codex, events: events)
        let internalSessionIDHint = Session.deriveCodexInternalSessionID(from: events)
        let session = Session(id: id,
                              source: .codex,
                              startTime: start,
                              endTime: end,
                              model: modelSeen,
                              filePath: url.path,
                              fileSizeBytes: size >= 0 ? size : nil,
                              eventCount: nonMetaCount,
                              events: events,
                              isHousekeeping: isHousekeeping,
                              codexInternalSessionIDHint: internalSessionIDHint,
                              parentSessionID: parentSessionID,
                              subagentType: subagentType)

        if size > 5_000_000 {  // Log full parse of files >5MB
            DBG("  ⚠️ FULL PARSE: \(url.lastPathComponent) size=\(size/1_000_000)MB events=\(events.count) nonMeta=\(session.nonMetaCount)")
        }

        return session
    }

    /// Build a lightweight Session by scanning only head/tail slices for timestamps and model, and estimating event count.
    private static func lightweightSession(from url: URL, size: Int, mtime: Date) -> Session? {
        let headBytesInitial = 256 * 1024
        let headBytesMax = 2 * 1024 * 1024
        let tailBytes = 256 * 1024
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        // Read head lines (newline-bounded) rather than a fixed slice.
        // Newer Codex sessions can have an extremely large first line (session_meta with embedded instructions),
        // which can exceed 256KB and otherwise prevent extracting any usable metadata/title.
        func readHeadLines(initialBytes: Int, maxBytes: Int, maxLines: Int) -> (lines: [String], bytesRead: Int, newlineCount: Int) {
            var out: [String] = []
            out.reserveCapacity(min(maxLines, 300))
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var bytesRead = 0
            var newlineCount = 0

            while bytesRead < maxBytes, out.count < maxLines {
                let remaining = maxBytes - bytesRead
                let chunkSize = min(64 * 1024, remaining)
                let chunk = (try? fh.read(upToCount: chunkSize)) ?? Data()
                if chunk.isEmpty { break }
                bytesRead += chunk.count
                newlineCount += chunk.filter { $0 == 0x0a }.count
                buffer.append(chunk)

                while out.count < maxLines {
                    guard let nl = buffer.firstIndex(of: 0x0a) else { break }
                    let lineData = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(...nl) // remove through newline
                    if let line = String(data: lineData, encoding: .utf8) {
                        out.append(line)
                    }
                }

                // Common case: once we've reached the "old" head slice size and have at least one complete line,
                // stop early to avoid reading megabytes per file during normal indexing.
                if bytesRead >= initialBytes, !out.isEmpty { break }
            }

            // If we never saw a newline but have some content, keep a best-effort first line.
            if out.isEmpty, !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) {
                out.append(s)
            }
            return (out, bytesRead, newlineCount)
        }

        let headRead = readHeadLines(initialBytes: headBytesInitial, maxBytes: headBytesMax, maxLines: 300)

        // Read tail slice
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? size
        var tailData: Data = Data()
        if fileSize > tailBytes {
            let offset = UInt64(fileSize - tailBytes)
            try? fh.seek(toOffset: offset)
            tailData = (try? fh.readToEnd()) ?? Data()
        }

        func lines(from data: Data, keepHead: Bool) -> [String] {
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return [] }
            let parts = s.components(separatedBy: "\n")
            if keepHead {
                return Array(parts.prefix(300))
            } else {
                return Array(parts.suffix(300))
            }
        }

        let headLines = headRead.lines
        let tailLines = lines(from: tailData, keepHead: false)

        var model: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil
        var sampleCount = 0
        var sampleEvents: [SessionEvent] = []
        var cwd: String? = nil
        var parentSessionID: String? = nil
        var subagentType: String? = nil

        func ingest(_ raw: String) {
            let line = sanitizeCodexHugeFields(sanitizeImagePayload(raw))
            let (ev, maybeModel) = parseLine(line, eventID: "light-\(sampleCount)")
            if let ts = ev.timestamp {
                if tmin == nil || ts < tmin! { tmin = ts }
                if tmax == nil || ts > tmax! { tmax = ts }
            }
            if model == nil, let m = maybeModel, !m.isEmpty { model = m }
            // Extract cwd, subagent info, and turn_context model from raw JSON
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let objType = obj["type"] as? String
                let payload = obj["payload"] as? [String: Any]

                // Extract cwd from session_meta or environment_context
                if cwd == nil {
                    if let text = ev.text, text.contains("<cwd>") {
                        if let start = text.range(of: "<cwd>"),
                           let end = text.range(of: "</cwd>", range: start.upperBound..<text.endIndex) {
                            cwd = String(text[start.upperBound..<end.lowerBound])
                        }
                    } else if let payload {
                        if let cwdValue = payload["cwd"] as? String, !cwdValue.isEmpty { cwd = cwdValue }
                    } else if let cwdValue = obj["cwd"] as? String, !cwdValue.isEmpty {
                        cwd = cwdValue
                    }
                }

                // Codex session_meta: detect subagent source
                if parentSessionID == nil, objType == "session_meta", let payload {
                    if let source = payload["source"] {
                        if let sourceDict = source as? [String: Any],
                           let subagentInfo = sourceDict["subagent"] {
                            if let subStr = subagentInfo as? String {
                                // e.g. "review" — no parent thread ID available
                                subagentType = subStr
                            } else if let subDict = subagentInfo as? [String: Any],
                                      let threadSpawn = subDict["thread_spawn"] as? [String: Any] {
                                parentSessionID = threadSpawn["parent_thread_id"] as? String
                                subagentType = threadSpawn["agent_role"] as? String
                            }
                        }
                    }
                }

                // Codex turn_context: extract actual LLM model
                if objType == "turn_context", let payload,
                   let turnModel = payload["model"] as? String, !turnModel.isEmpty {
                    model = turnModel
                }
            } else if cwd == nil, let text = ev.text, text.contains("<cwd>") {
                if let start = text.range(of: "<cwd>"),
                   let end = text.range(of: "</cwd>", range: start.upperBound..<text.endIndex) {
                    cwd = String(text[start.upperBound..<end.lowerBound])
                }
            }
            sampleEvents.append(ev)
            sampleCount += 1
        }

        headLines.forEach(ingest)
        tailLines.forEach(ingest)

        // Estimate event count: count newlines in head slice for more accurate estimate
        let headBytesRead = max(headRead.bytesRead, 1)
        let newlineCount = max(headRead.newlineCount, 1)
        let avgLineLen = max(256, headBytesRead / max(newlineCount, 1))  // Min 256 bytes per line
        let estEvents = max(1, min(1_000_000, fileSize / avgLineLen))

        DBG("  📊 Lightweight estimation: headBytes=\(headBytesRead) newlines=\(newlineCount) avgLineLen=\(avgLineLen) estEvents=\(estEvents)")

        let id = Self.hash(path: url.path)
        let internalSessionIDHint = Session.deriveCodexInternalSessionID(from: sampleEvents)
        // Use sample events for title/cwd extraction, then create lightweight session
        let tempIsHousekeeping = Session.computeIsHousekeeping(source: .codex, events: sampleEvents)
        let tempSession = Session(id: id,
                                  source: .codex,
                                  startTime: tmin,
                                  endTime: tmax,
                                  model: model,
                                  filePath: url.path,
                                  fileSizeBytes: fileSize,
                                  eventCount: estEvents,
                                  events: sampleEvents,
                                  isHousekeeping: tempIsHousekeeping,
                                  codexInternalSessionIDHint: internalSessionIDHint,
                                  parentSessionID: parentSessionID,
                                  subagentType: subagentType)

        // Extract title from sample events using existing logic
        let title = tempSession.codexPreviewTitle ?? tempSession.title

        // Now create final lightweight session with empty events but preserve metadata
        let session = Session(id: id,
                              source: .codex,
                              startTime: tmin ?? (attrsDate(url, key: .creationDate) ?? mtime),
                              endTime: tmax ?? mtime,
                              model: model,
                              filePath: url.path,
                              fileSizeBytes: fileSize,
                              eventCount: estEvents,
                              events: [],
                              cwd: cwd,
                              repoName: nil,  // Will be computed from cwd
                              lightweightTitle: title,
                              isHousekeeping: tempIsHousekeeping || title == "No prompt",
                              codexInternalSessionIDHint: internalSessionIDHint,
                              parentSessionID: parentSessionID,
                              subagentType: subagentType,
                              customTitle: tempSession.customTitle)
        return session
    }

    private static func attrsDate(_ url: URL, key: FileAttributeKey) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[key] as? Date) ?? nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func parseLine(_ line: String, eventID: String) -> (SessionEvent, String?) {
        var timestamp: Date? = nil
        var role: String? = nil
        var type: String? = nil
        var text: String? = nil
        var toolName: String? = nil
        var toolInput: String? = nil
        var toolOutput: String? = nil
        var model: String? = nil
        var messageID: String? = nil
        var parentID: String? = nil
        var isDelta: Bool = false

        if let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // timestamp could be number or string, and under various keys
            let tsKeys = [
                "timestamp", "time", "ts", "created", "created_at", "datetime", "date",
                "event_time", "eventTime", "iso_timestamp", "when", "at"
            ]
            for key in tsKeys {
                if let v = obj[key] { timestamp = timestamp ?? Self.decodeDate(from: v) }
            }

            // Check for nested payload structure (Codex format)
            var workingObj = obj
            if let payload = obj["payload"] as? [String: Any] {
                // Merge payload fields into working object
                workingObj = payload
                // Also check payload for timestamp if not found at top level
                if timestamp == nil {
                    for key in tsKeys {
                        if let v = payload[key] { timestamp = timestamp ?? Self.decodeDate(from: v) }
                    }
                }
            }

            // role / type (now checking in payload if present)
            if let r = workingObj["role"] as? String { role = r }
            if let t = workingObj["type"] as? String { type = t }
            if type == nil, let e = workingObj["event"] as? String { type = e }

            // model (check both top-level and payload)
            if let m = obj["model"] as? String { model = m }
            if model == nil, let m = workingObj["model"] as? String { model = m }

            // delta / chunk identifiers
            if let mid = workingObj["message_id"] as? String { messageID = mid }
            if let pid = workingObj["parent_id"] as? String { parentID = pid }
            if let idFromObj = workingObj["id"] as? String, messageID == nil { messageID = idFromObj }
            if let d = workingObj["delta"] as? Bool { isDelta = isDelta || d }
            if workingObj["delta"] is [String: Any] { isDelta = true }
            if workingObj["chunk"] != nil { isDelta = true }
            if workingObj["delta_index"] != nil { isDelta = true }

            // text content variants
            if let content = workingObj["content"] as? String { text = content }
            if text == nil, let txt = workingObj["text"] as? String { text = txt }
            if text == nil, let msg = workingObj["message"] as? String { text = msg }
            // Assistant content arrays: concatenate text parts
            if text == nil, let arr = workingObj["content"] as? [Any] {
                var pieces: [String] = []
                for el in arr {
                    if let d = el as? [String: Any] {
                        if let t = d["text"] as? String { pieces.append(t) }
                        else if let val = d["value"] as? String { pieces.append(val) }
                        else if let data = d["data"] as? String { pieces.append(data) }
                    } else if let s = el as? String { pieces.append(s) }
                }
                if !pieces.isEmpty { text = pieces.joined() }
            }

            // Heuristic: environment_context appears as an XML-ish block often logged under 'user'.
            // Treat any event whose text contains this block as meta regardless of role/type.
            if let t = text, t.contains("<environment_context>") { type = "environment_context" }

            if text == nil, let t = type?.lowercased(), t == "thread_rolled_back" {
                var numTurns: Int? = nil
                if let n = workingObj["num_turns"] as? Int { numTurns = n }
                if numTurns == nil, let n = workingObj["numTurns"] as? Int { numTurns = n }
                if numTurns == nil, let n = workingObj["num_turns"] as? Double { numTurns = Int(n) }
                if numTurns == nil, let n = workingObj["numTurns"] as? Double { numTurns = Int(n) }
                if numTurns == nil, let n = workingObj["num_turns"] as? String, let parsed = Int(n) { numTurns = parsed }
                if numTurns == nil, let n = workingObj["numTurns"] as? String, let parsed = Int(n) { numTurns = parsed }
                if numTurns == nil, let payload = workingObj["payload"] as? [String: Any] {
                    if let n = payload["num_turns"] as? Int { numTurns = n }
                    if numTurns == nil, let n = payload["numTurns"] as? Int { numTurns = n }
                    if numTurns == nil, let n = payload["num_turns"] as? Double { numTurns = Int(n) }
                    if numTurns == nil, let n = payload["numTurns"] as? Double { numTurns = Int(n) }
                    if numTurns == nil, let n = payload["num_turns"] as? String, let parsed = Int(n) { numTurns = parsed }
                    if numTurns == nil, let n = payload["numTurns"] as? String, let parsed = Int(n) { numTurns = parsed }
                }
                if let n = numTurns {
                    let suffix = (n == 1) ? "" : "s"
                    text = "Thread rollback: removed \(n) user turn\(suffix)"
                } else {
                    text = "Thread rollback"
                }
            }

            // tool fields
            if let t = workingObj["tool"] as? String { toolName = t }
            if toolName == nil, let name = workingObj["name"] as? String { toolName = name }
            if toolName == nil, let fn = (workingObj["function"] as? [String: Any])?["name"] as? String { toolName = fn }

            if let input = workingObj["input"] as? String { toolInput = input }
            if toolInput == nil, let args = workingObj["arguments"] as? String { toolInput = args }
            // Arguments may be non-string; minify to single-line JSON
            if toolInput == nil, let argsObj = workingObj["arguments"] {
                if let s = Self.stringifyJSON(argsObj, pretty: false) { toolInput = s }
            }

            // Outputs: stdout, stderr, result, output (in this stable order)
            var outputs: [String] = []
            if let stdout = workingObj["stdout"] { outputs.append(Self.stringifyJSON(stdout, pretty: true) ?? String(describing: stdout)) }
            if let stderr = workingObj["stderr"] { outputs.append(Self.stringifyJSON(stderr, pretty: true) ?? String(describing: stderr)) }
            if let result = workingObj["result"] { outputs.append(Self.stringifyJSON(result, pretty: true) ?? String(describing: result)) }
            if let output = workingObj["output"] { outputs.append(Self.stringifyJSON(output, pretty: true) ?? String(describing: output)) }
            if !outputs.isEmpty {
                toolOutput = outputs.joined(separator: "\n")
            }
            // Back-compat if values above were strings only
            if toolOutput == nil, let out = workingObj["output"] as? String { toolOutput = out }
            if toolOutput == nil, let res = workingObj["result"] as? String { toolOutput = res }
        }

        let kind = SessionEventKind.from(role: role, type: type)
        let event = SessionEvent(
            id: eventID,
            timestamp: timestamp,
            kind: kind,
            role: role,
            text: text,
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: toolOutput,
            messageID: messageID,
            parentID: parentID,
            isDelta: isDelta,
            rawJSON: line
        )
        return (event, model)
    }
    
    // MARK: - Sanitizers
    /// Replace very large JSON string fields that can balloon memory or slow down parsing.
    ///
    /// Primarily for newer Codex CLI sessions which can include:
    /// - `payload.encrypted_content` (reasoning) which can be very large
    /// - `payload.instructions` (session_meta) which can also be very large
    private static func sanitizeCodexHugeFields(_ line: String) -> String {
        guard line.contains("\"encrypted_content\"") || line.contains("\"instructions\"") else { return line }
        var s = line
        s = sanitizeJSONStringValue(in: s, key: "\"encrypted_content\"", placeholder: "[ENCRYPTED_OMITTED]")
        s = sanitizeJSONStringValue(in: s, key: "\"instructions\"", placeholder: "[INSTRUCTIONS_OMITTED]")
        return s
    }

    /// Sanitizes a JSON string value for a given `"key"` by replacing its value with `placeholder`.
    /// Byte-scanning implementation that respects JSON string escaping (\" and \\) and avoids String-index
    /// invalidation issues when mutating the underlying storage.
    private static func sanitizeJSONStringValue(in input: String, key: String, placeholder: String) -> String {
        guard let inputData = input.data(using: .utf8),
              let keyData = key.data(using: .utf8),
              let placeholderData = placeholder.data(using: .utf8) else {
            return input
        }

        let bytes = Array(inputData)
        let needle = Array(keyData)
        let replacement = Array(placeholderData)

        func findSubsequence(_ haystack: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
            guard !needle.isEmpty, start >= 0 else { return nil }
            if needle.count > haystack.count { return nil }
            var i = start
            while i + needle.count <= haystack.count {
                if haystack[i] == needle[0] {
                    var match = true
                    if needle.count > 1 {
                        for j in 1..<needle.count where haystack[i + j] != needle[j] {
                            match = false
                            break
                        }
                    }
                    if match { return i }
                }
                i += 1
            }
            return nil
        }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)

        var i = 0
        while let keyStart = findSubsequence(bytes, needle, from: i) {
            let keyEnd = keyStart + needle.count
            out.append(contentsOf: bytes[i..<keyStart])
            out.append(contentsOf: bytes[keyStart..<keyEnd])

            // Find the ':' following the key.
            var j = keyEnd
            while j < bytes.count, bytes[j] != 0x3A { j += 1 } // ':'
            if j >= bytes.count {
                out.append(contentsOf: bytes[keyEnd..<bytes.count])
                return String(bytes: out, encoding: .utf8) ?? input
            }

            // Include everything up to and including the ':'.
            out.append(contentsOf: bytes[keyEnd...j])
            j += 1

            // Preserve whitespace after ':'.
            while j < bytes.count {
                let b = bytes[j]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    out.append(b)
                    j += 1
                    continue
                }
                break
            }

            // Only handle string values. If not a string, continue scanning.
            guard j < bytes.count, bytes[j] == 0x22 else { // '"'
                i = j
                continue
            }

            // Copy opening quote.
            out.append(0x22)
            j += 1

            // Scan to closing quote, respecting escapes.
            var escaped = false
            while j < bytes.count {
                let b = bytes[j]
                if escaped {
                    escaped = false
                    j += 1
                    continue
                }
                if b == 0x5C { // '\\'
                    escaped = true
                    j += 1
                    continue
                }
                if b == 0x22 { break } // '"'
                j += 1
            }

            // If we never found a closing quote (truncated), fall back to original input.
            guard j < bytes.count, bytes[j] == 0x22 else { return input }

            // Replace contents with placeholder, then copy closing quote.
            out.append(contentsOf: replacement)
            out.append(0x22)
            j += 1

            // Continue after the replaced value.
            i = j
        }

        if i < bytes.count {
            out.append(contentsOf: bytes[i..<bytes.count])
        }
        return String(bytes: out, encoding: .utf8) ?? input
    }

    /// Replace any inline base64 image data URLs with a short placeholder to avoid huge allocations and slow JSON parsing.
    private static func sanitizeImagePayload(_ line: String) -> String {
        // Fast path: nothing to do
        guard line.contains("data:image") || line.contains("\"input_image\"") else { return line }
        var s = line
        // Replace data:image..." up to the closing quote with a compact token
        // This is a simple, robust scan that avoids heavy regex backtracking on very long lines.
        let needle = "data:image"
        if let range = s.range(of: needle) {
            // Find the next quote after the scheme
            if let q = s[range.upperBound...].firstIndex(of: "\"") {
                let replaceRange = range.lowerBound..<q
                s.replaceSubrange(replaceRange, with: "data:image/omitted")
            }
        }
        return s
    }

    /// Aggressively strip ALL embedded images from a line (for lazy load performance).
    /// Uses regex for 50-100x speedup vs string manipulation.
    private static func sanitizeAllImages(_ line: String) -> String {
        guard line.contains("data:image") else { return line }

        // Fast byte-level check before expensive string operations
        // For extremely long lines (>5MB UTF-8 bytes), skip entirely
        let utf8Count = line.utf8.count
        if utf8Count > 5_000_000 {
            // Just return a minimal JSON stub - the line is too large to parse usefully anyway
            return #"{"type":"omitted","text":"[Large event omitted - \#(utf8Count/1_000_000)MB]"}"#
        }

        // For moderately large lines (1-5MB), use a simpler/faster approach
        if utf8Count > 1_000_000 {
            // Simple string split approach - faster than regex on huge strings
            let parts = line.components(separatedBy: "data:image")
            if parts.count <= 1 { return line }

            var result = parts[0]
            for i in 1..<parts.count {
                // Find the closing quote and skip everything up to it
                if let quoteIdx = parts[i].firstIndex(of: "\"") {
                    result += "[IMG]"
                    result += String(parts[i][quoteIdx...])
                } else {
                    result += "[IMG]" + parts[i]
                }
            }
            return result
        }

        // For normal lines (<1MB), use fast string scanning (avoids slow regex backtracking)
        var result = line
        while let dataIdx = result.range(of: "data:image") {
            // Find the closing quote (end of data URL)
            if let endQuote = result[dataIdx.upperBound...].firstIndex(of: "\"") {
                // Replace everything from "data:image" to quote with placeholder that doesn't contain "data:image"
                result.replaceSubrange(dataIdx.lowerBound..<endQuote, with: "[IMG_OMITTED]")
            } else {
                // No closing quote found, replace to end and break
                result.replaceSubrange(dataIdx.lowerBound..., with: "[IMG_OMITTED]")
                break
            }
        }

        return result
    }

    /// Composite sanitizer for unusually large JSONL lines.
    /// Intentionally conservative: only used for very large lines in full-parse paths.
    private static func sanitizeLargeLine(_ line: String) -> String {
        var s = line
        s = sanitizeAllImages(s)
        s = sanitizeCodexHugeFields(s)
        return s
    }

    private func eventID(for url: URL, index: Int) -> String {
        let base = Self.hash(path: url.path)
        return base + String(format: "-%04d", index)
    }

    static func eventID(forPath path: String, index: Int) -> String {
        let base = hash(path: path)
        return base + String(format: "-%04d", index)
    }

    private static func hash(path: String) -> String {
        let d = SHA256.hash(data: Data(path.utf8))
        return d.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func decodeDate(from any: Any) -> Date? {
        // Numeric (seconds, ms, µs)
        if let d = any as? Double {
            let secs = normalizeEpochSeconds(d)
            return Date(timeIntervalSince1970: secs)
        }
        if let i = any as? Int {
            let secs = normalizeEpochSeconds(Double(i))
            return Date(timeIntervalSince1970: secs)
        }
        if let s = any as? String {
            // Digits-only string → numeric epoch
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: s)) {
                if let val = Double(s) { return Date(timeIntervalSince1970: normalizeEpochSeconds(val)) }
            }
            // ISO8601 with or without fractional seconds (cached, lock-protected)
            Self.dateFormatterLock.lock()
            defer { Self.dateFormatterLock.unlock() }
            if let d = Self.isoFracFormatter.date(from: s) { return d }
            if let d = Self.isoNoFracFormatter.date(from: s) { return d }
            for fmt in Self.fallbackDateFormatters {
                if let d = fmt.date(from: s) { return d }
            }
        }
        return nil
    }

    private static let dateFormatterLock = NSLock()

    // Cached date formatters — allocation is expensive, reuse across all parse calls
    private static let isoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fallbackDateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss",
         "yyyy/MM/dd HH:mm:ssZZZZZ", "yyyy/MM/dd HH:mm:ss"].map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            return df
        }
    }()

    private static func normalizeEpochSeconds(_ value: Double) -> Double {
        // Heuristic: >1e14 → microseconds; >1e11 → milliseconds; else seconds
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1_000 }
        return value
    }

    private static func stringifyJSON(_ any: Any, pretty: Bool) -> String? {
        // If it's already a String, return as-is
        if let s = any as? String { return s }
        // Numbers, bools, arrays, dicts → JSON text
        if JSONSerialization.isValidJSONObject(any) {
            if let data = try? JSONSerialization.data(withJSONObject: any, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]) {
                return String(data: data, encoding: .utf8)
            }
        } else {
            // Wrap simple types into JSON-compatible representation
            if let n = any as? NSNumber { return n.stringValue }
            if let b = any as? Bool { return b ? "true" : "false" }
        }
        return nil
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

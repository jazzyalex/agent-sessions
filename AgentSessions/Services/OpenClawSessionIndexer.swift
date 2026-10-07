import Foundation
import Combine
import SwiftUI
import os.log

private let indexLog = OSLog(subsystem: "com.triada.AgentSessions", category: "OpenClawIndexing")

/// Session indexer for OpenClaw / Clawdbot sessions.
///
/// Refresh work is detached for parsing throughput. The object is audited as
/// `@unchecked Sendable`: generation handoff and SQLite publication are guarded
/// by `IndexDBCommitGate`, file/reload maps have their dedicated locks, and all
/// published state is written from MainActor turns. Refresh captures the
/// immutable discovery and progress snapshots below instead of reading mutable
/// provider configuration from the detached task.
final class OpenClawSessionIndexer: ObservableObject, @unchecked Sendable {
    private struct PersistedFileStat: Codable {
        let mtime: Int64
        let size: Int64
    }

    private struct PersistedFileStatPayload: Codable {
        let version: Int
        let stats: [String: PersistedFileStat]
    }

    private static let coreFileStatsStateKey = "core_file_stats_v1:openclaw"

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
    @Published var unreadableSessionIDs: Set<String> = []

    // Focus coordination for transcript vs list searches
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    // Search cache parity with other providers (prewarm is optional)
    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    private var discovery: OpenClawSessionDiscovery
    private var lastIncludeDeleted: Bool = false
    private var lastCustomRootOverride: String = ""
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var previewMTimeByID: [String: Date] = [:]
    /// File proof associated with the events currently held in a JSONL row.
    /// A later lightweight scan may observe a different file version; it must
    /// not reuse those events or bind the new stat to the old transcript.
    private var previewFileStatByID: [String: SessionFileStat] = [:]
    private var previewRevisionByID: [String: SessionTelemetryRevision] = [:]
    @Published private(set) var previewStaleByID: [String: Bool] = [:]
    private var previewStalenessChecksInFlight: Set<String> = []
    private var refreshPreviewGenerationBySessionID: [String: UInt64] = [:]
    /// The gate makes generation handoff and the final SQLite COMMIT one
    /// synchronous critical section without holding a lock across await.
    private let refreshCommitGate = IndexDBCommitGate()
    private let fileStatsLock = NSLock()
    private var lastKnownFileStatsByPath: [String: SessionFileStat] = [:]
    private struct InFlightReload {
        let refreshToken: UUID
        let storagePath: String
        let storageVersion: UInt64
        let publicationEpoch: UInt64
        let generation: UUID
        let force: Bool
        let reason: ReloadReason
    }

    private struct PendingReload {
        let ownerGeneration: UUID
        let force: Bool
        let reason: ReloadReason
    }

    private struct PublishedSessionSnapshot: Sendable {
        let sessionsByID: [String: Session]
        let publicationEpochByID: [String: UInt64]
        let fileStatsByID: [String: SessionFileStat]
    }

    private struct RevalidatedSQLitePublication: Sendable {
        let publicationEpoch: UInt64
        let sourceStorageRevision: String
        let databaseVersion: String
    }

    private struct RevalidatedJSONLPublication: Sendable {
        let publicationEpoch: UInt64
        let fileStat: SessionFileStat
    }
    private var inFlightReloadsBySessionID: [String: InFlightReload] = [:]
    private var pendingReloadsBySessionID: [String: PendingReload] = [:]
    private let reloadLock = NSLock()
    private var publishedStoragePathBySessionID: [String: String] = [:]
    private var storageVersionBySessionID: [String: UInt64] = [:]
    private var publicationEpochBySessionID: [String: UInt64] = [:]
    private var reloadBeforeParseHookForTesting: (() -> Void)?
    private var reloadBeforePublicationHookForTesting: (() -> Void)?
    private var reloadBeforePublicationCommitHookForTesting: (() -> Void)?
    private var reloadBeforeRegistrationHookForTesting: (() -> Void)?
    private var reloadPendingRecordedHookForTesting: (() -> Void)?
    private var reloadBeforeTerminalCleanupHookForTesting: (() -> Void)?
    private var refreshBeforeHydrationPublicationHookForTesting: (() -> Void)?
    private var refreshBeforeFinalStatsHookForTesting: (() -> Void)?
    private var refreshBeforeFinalPublicationHookForTesting: (() -> Void)?
    private var previewStalenessBeforePublicationHookForTesting: (() -> Void)?
    private var refreshPreviewAfterProofHookForTesting: (() -> Void)?
    private var refreshAfterHandoffSnapshotHookForTesting: (() -> Void)?
    private var reloadTerminalHookForTesting: (() -> Void)?
    private var refreshPreviewTerminalHookForTesting: (() -> Void)?
    private var previewStalenessTerminalHookForTesting: (() -> Void)?
    private var loadingSessionToken: UUID?
    private var latestReloadGenerationBySessionID: [String: UUID] = [:]
    private var lastFullReloadFileStatsBySessionID: [String: SessionFileStat] = [:]
    private var lastFullReloadRevisionsBySessionID: [String: SessionTelemetryRevision] = [:]
    private(set) var searchIdentitySnapshot: SearchIngestService.IdentitySnapshot?
    /// Key-filtered observer: the raw `didChangeNotification` fires on every
    /// process-wide defaults write (incl. AppKit window/splitview bookkeeping);
    /// narrowing to these two keys avoids re-running discovery/refresh on
    /// unrelated writes. See AgentSessions/Support/FilteredDefaultsObserver.swift.
    private var rootOverrideDefaultsObserver: FilteredDefaultsObserver?
    /// HideZero/HideLow/ShowHousekeeping are read inline in the $allSessions
    /// filter pipeline and in recomputeNow() below — this observer tracks
    /// exactly those three keys so toggling them re-fires the pipeline instead
    /// of waiting for an unrelated input to change first.
    private var recomputeDefaultsObserver: FilteredDefaultsObserver?

    private func beginRefreshToken() -> UUID {
        refreshCommitGate.beginGeneration()
    }

    private func currentRefreshToken() -> UUID {
        // Kept as a separate helper for call sites that need to capture the
        // current generation for diagnostics.
        return refreshCommitGate.current()
    }

    private func isCurrentRefresh(_ token: UUID) -> Bool {
        refreshCommitGate.isCurrent(token)
    }

    /// Serialize the final generation check with COMMIT inside IndexDB's
    /// synchronous actor-isolated method. No thread-owned lock crosses await.
    private func commitIndexDBIfCurrent(_ db: IndexDB, token: UUID) async throws -> Bool {
        try await db.commitIfCurrent(token, gate: refreshCommitGate)
    }

    /// `ScanConfig.onProgress` is MainActor-isolated. Keep the generation
    /// check and every `@Published` write in this one actor turn so an old
    /// detached scan cannot repaint progress after a newer refresh begins.
    @MainActor
    private func publishProgressIfCurrent(token: UUID,
                                          existingCount: Int,
                                          processed: Int,
                                          total: Int) {
        guard isCurrentRefresh(token) else { return }
        totalFiles = existingCount + total
        hasEmptyDirectory = existingCount == 0 && total == 0
        filesProcessed = existingCount + processed
        if processed > 0 {
            progressText = "Indexed \(processed)/\(total)"
        }
        if launchPhase == .hydrating {
            launchPhase = .scanning
        }
    }

    private static let originProjectLabels: Set<String> = [
        "telegram",
        "cron",
        "tui",
        "whatsapp",
        "discord",
        "imessage",
        "webchat",
        "system"
    ]

    init(discovery injectedDiscovery: OpenClawSessionDiscovery? = nil) {
        UserDefaults.standard.register(defaults: [
            PreferencesKey.Advanced.includeOpenClawDeletedSessions: true
        ])
        let customRoot = UserDefaults.standard.string(forKey: PreferencesKey.Paths.openClawSessionsRootOverride) ?? ""
        let includeDeleted = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions)
        self.lastCustomRootOverride = customRoot
        self.lastIncludeDeleted = includeDeleted
        self.discovery = injectedDiscovery ?? OpenClawSessionDiscovery(
            customRoot: customRoot.isEmpty ? nil : customRoot,
            includeDeleted: includeDeleted)

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
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(all, filters: filters, transcriptCache: self?.transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
                let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
                let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true
                if hideZero { results = results.filter { $0.messageCount > 0 } }
                if hideLow { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
                let showHousekeeping = UserDefaults.standard.bool(forKey: PreferencesKey.showHousekeepingSessions)
                if !showHousekeeping { results = results.filter { !$0.isHousekeeping } }
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)

        if injectedDiscovery == nil {
            let rootOverrideObserver = FilteredDefaultsObserver(keys: [
                PreferencesKey.Paths.openClawSessionsRootOverride,
                PreferencesKey.Advanced.includeOpenClawDeletedSessions
            ])
            self.rootOverrideDefaultsObserver = rootOverrideObserver
            rootOverrideObserver.publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self else { return }
                    let customRoot = UserDefaults.standard.string(forKey: PreferencesKey.Paths.openClawSessionsRootOverride) ?? ""
                    let includeDeleted = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions)
                    if includeDeleted != self.lastIncludeDeleted || customRoot != self.lastCustomRootOverride {
                        self.lastCustomRootOverride = customRoot
                        self.lastIncludeDeleted = includeDeleted
                        self.discovery = OpenClawSessionDiscovery(customRoot: customRoot.isEmpty ? nil : customRoot,
                                                                  includeDeleted: includeDeleted)
                        Task { @MainActor [weak self] in
                            self?.refresh()
                        }
                    }
                }
                .store(in: &cancellables)
        } else {
            // Tests and deterministic callers may provide a discovery snapshot.
            // Do not let process-wide defaults mutate that isolated source.
            self.rootOverrideDefaultsObserver = nil
        }

        // recomputeNow() -> the filter pipeline above both consult HideZero/
        // HideLow/ShowHousekeeping via raw UserDefaults reads; track exactly
        // those three keys so toggling any of them refreshes the visible list.
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
    }

    var canAccessRootDirectory: Bool {
        let root = discovery.sessionsRoot()
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    @MainActor
    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(.openclaw) { return }
        let root = discovery.sessionsRoot()
        #if DEBUG
        print("\n🔵 OPENCLAW INDEXING START: root=\(root.path) mode=\(mode) trigger=\(trigger.rawValue)")
        #endif
        LaunchProfiler.log("OpenClaw.refresh: start (mode=\(mode), trigger=\(trigger.rawValue))")

        let token = beginRefreshToken()
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
        let refreshDiscovery = discovery
        let refreshProgressThrottler = progressThrottler
        // Capture the hydration epoch before the detached IndexDB read starts.
        // The read itself constructs the candidate source, so a publication
        // that lands while it is in flight must not be folded into the
        // candidate's baseline.
        let refreshPublicationBaseline = publishedSessionSnapshot()
        Task.detached(priority: prio) { [weak self, refreshDiscovery, refreshProgressThrottler, refreshPublicationBaseline, token, mode, executionProfile] in
            guard let self else { return }

            // ── Phase 1: Hydrate from IndexDB ──
            var indexed: [Session] = []
            do {
                if let hydrated = try await self.hydrateFromIndexDBIfAvailable() {
                    indexed = hydrated
                }
            } catch {
                // DB errors are non-fatal; fall back to filesystem.
            }
            if indexed.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                do {
                    if let retry = try await self.hydrateFromIndexDBIfAvailable(), !retry.isEmpty {
                        indexed = retry
                    }
                } catch {}
            }

            await self.seedKnownFileStatsIfNeeded()
            let fm = FileManager.default
            let exists: (Session) -> Bool = { s in fm.fileExists(atPath: s.filePath) }
            // A legacy SQLite row can retain a symlink alias that has become
            // temporarily unresolvable while the physical database is still
            // present but unreadable. Preserve SQLite hydration until the
            // complete provider snapshot proves the row stale.
            let existingSessions = Self.stampSQLiteStorageIdentities(indexed.filter { session in
                Self.isSQLiteSession(session) || exists(session)
            })
            // A preview/search publication that lands while this refresh is
            // building its hydration candidate must be treated as newer than
            // that candidate, even if the final actor turn happens later.
            let hydrationPublicationBaseline = refreshPublicationBaseline
            let hydratedSessions = existingSessions
            let hasLegacyOriginProjects = hydratedSessions.contains { Self.needsOriginProjectReparse($0) }
            self.bootstrapKnownFileStatsIfNeeded(from: existingSessions)

            // Do not publish a hydrated SQLite row if the store changed between
            // IndexDB hydration and this refresh. The captured token stays on
            // the row; a fresh observation is only a proof check, never a new
            // label for an old transcript.
            let hydratedSorted = hydratedSessions.sorted { $0.modifiedAt > $1.modifiedAt }
            let hydratedStorageProof = Self.stampSQLiteStorageVersionsForPublishedCurrent(
                candidates: SessionArchiveManager.shared.mergePinnedArchiveFallbacks(
                    into: hydratedSorted, source: .openclaw))

            // ── Phase 2: Publish hydrated sessions immediately ──
            let presentedHydration = !hydratedSessions.isEmpty
                && !hasLegacyOriginProjects
                && hydratedStorageProof.mismatchedIdentities.isEmpty
            if presentedHydration {
                // Archive fallbacks merged here for immediate display; re-merged on the final
                // complete list at end of Phase 7 to avoid duplication from delta slices.
                let hydratedWithArchives = hydratedStorageProof.candidates
                let hydratedTranscripts = Self.transcriptCacheEntries(for: hydratedWithArchives)

                var hydratedPreviewTimes: [String: Date] = [:]
                var hydratedPreviewStats: [String: SessionFileStat] = [:]
                hydratedPreviewTimes.reserveCapacity(hydratedWithArchives.count)
                hydratedPreviewStats.reserveCapacity(hydratedWithArchives.count)
                for s in hydratedWithArchives {
                    let url = URL(fileURLWithPath: s.filePath)
                    if s.events.isEmpty, let stat = Self.fileStat(for: url) {
                        hydratedPreviewStats[s.id] = stat
                    }
                    if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                       let m = rv.contentModificationDate {
                        hydratedPreviewTimes[s.id] = m
                    }
                }
                let capturedPreviewTimes = hydratedPreviewTimes
                let capturedPreviewStats = hydratedPreviewStats
                let hydrationSnapshot = hydrationPublicationBaseline
                let hydrationSnapshotTranscripts = Self.transcriptCacheEntries(
                    for: Array(hydrationSnapshot.sessionsByID.values))

                self.hydrationPublicationHookForTesting()?()

                await MainActor.run {
                    guard self.isCurrentRefresh(token) else { return }
                    let currentByID = self.allSessions.reduce(into: [String: Session]()) {
                        $0[$1.id] = $1
                    }
                    let sessionsToPublish = self.preservingNewerPublications(
                        in: hydratedWithArchives,
                        currentByID: currentByID,
                        baseEpochs: hydrationSnapshot.publicationEpochByID)
                    let stalePreviewIDs = Set(sessionsToPublish.compactMap { session -> String? in
                        guard let current = currentByID[session.id],
                              self.previewStaleByID[session.id] == true,
                              Self.publishedStorageMatches(current, session) else {
                            return nil
                        }
                        return session.id
                    })
                    let preservedTranscripts = sessionsToPublish.reduce(into: [String: String]()) { result, session in
                        guard let previous = currentByID[session.id],
                              !stalePreviewIDs.contains(session.id),
                              previous.events == session.events else { return }
                        if let cached = self.transcriptCache.getCached(session.id) {
                            result[session.id] = cached
                            return
                        }
                        // The refresh-entry fallback is valid only when the
                        // preserved row is the same full snapshot that was
                        // captured at refresh entry. A row published during
                        // hydration may have different events; reinstalling
                        // its older transcript would make the cache stale.
                        guard hydrationSnapshot.sessionsByID[session.id]?.events == session.events,
                              let snapshotTranscript = hydrationSnapshotTranscripts[session.id] else {
                            return
                        }
                        result[session.id] = snapshotTranscript
                    }
                    let hydratedTranscriptsForPublication = hydratedTranscripts.filter {
                        !stalePreviewIDs.contains($0.key)
                    }
                    let transcriptsToInstall = hydratedTranscriptsForPublication.merging(preservedTranscripts) {
                        _, preserved in preserved
                    }
                    self.notePublishedStoragePaths(sessionsToPublish, completeSnapshot: true)
                    self.installTranscriptCacheEntries(transcriptsToInstall)
                    self.allSessions = sessionsToPublish
                    let existingPreviewStats = self.previewFileStatByID
                    self.previewFileStatByID = sessionsToPublish.reduce(into: capturedPreviewStats) { result, session in
                        guard !session.events.isEmpty else {
                            result.removeValue(forKey: session.id)
                            return
                        }
                        if let existingStat = existingPreviewStats[session.id] {
                            result[session.id] = existingStat
                        }
                    }
                    self.previewStaleByID = sessionsToPublish.reduce(into: [:]) { result, session in
                        result[session.id] = stalePreviewIDs.contains(session.id)
                            ? true
                            : false
                    }
                    self.previewMTimeByID = sessionsToPublish.reduce(into: capturedPreviewTimes) { result, session in
                        if let existingMTime = self.previewMTimeByID[session.id] {
                            result[session.id] = existingMTime
                        }
                    }
                    self.launchPhase = .scanning
                    self.filesProcessed = hydratedWithArchives.count
                    self.totalFiles = hydratedWithArchives.count
                    self.progressText = "Loaded \(hydratedWithArchives.count) from index"
                }
                #if DEBUG
                print("[Launch] Hydrated \(hydratedSessions.count) OpenClaw sessions from DB, now scanning for changes…")
                #endif
                LaunchProfiler.log("OpenClaw.refresh: DB hydrate published (existing=\(hydratedSessions.count))")
            } else {
                #if DEBUG
                print("[Launch] DB hydration returned nil for OpenClaw – scanning all files")
                #endif
            }

            // The final candidate is assembled by the delta scan and merge
            // below. Establish its epoch baseline before that work starts so
            // a same-storage preview/search publication during scanning or
            // merging cannot be mistaken for part of the candidate itself.
            let finalPublicationBaseline = await self.publishedSessionSnapshot()

            // ── Phase 3: Delta scan (only changed/new files) ──
            let previousStats = self.knownFileStatsSnapshot()
            let delta = refreshDiscovery.discoverDelta(previousByPath: previousStats)

            // Current OpenClaw keeps many sessions in one per-agent SQLite
            // database. Read those identities independently of the JSONL delta
            // so a shared database path cannot collapse multiple sessions into
            // one path-keyed index entry.
            let databaseDiscovery = refreshDiscovery.discoverSessionDatabaseResult()
            let discoveredDatabaseURLs = databaseDiscovery.databases
            let discoveredDatabasePaths = Set(discoveredDatabaseURLs.map {
                Self.canonicalSQLitePath($0.path)
            })
            var databaseSessions: [Session] = []
            var readableDatabasePaths = Set<String>()
            var capturedDatabaseVersionsByPath: [String: String] = [:]
            var currentDatabaseSessionIDsByPath: [String: Set<String>] = [:]
            if databaseDiscovery.isAuthoritative {
                for databaseURL in discoveredDatabaseURLs {
                    guard !databaseDiscovery.isOwnershipAmbiguous(forDatabaseURL: databaseURL) else {
                        // A conflicting explicit owner is not a usable identity
                        // source. Preserve hydrated rows until config ownership
                        // becomes unambiguous instead of minting an arbitrary ID.
                        continue
                    }
                    guard let listResult = OpenClawSqliteReader.listSessionsWithStorageIdentity(
                        databaseURL: databaseURL,
                        agentID: databaseDiscovery.agentID(forDatabaseURL: databaseURL)) else { continue }
                    let sessions = listResult.sessions
                    let databasePath = listResult.storageIdentity
                    readableDatabasePaths.insert(databasePath)
                    capturedDatabaseVersionsByPath[databasePath] = listResult.databaseVersionToken
                    currentDatabaseSessionIDsByPath[databasePath] = Set(sessions.map(\.id))
                    databaseSessions.append(contentsOf: sessions)
                }
            }
            let databaseIdentitySnapshot: SearchIngestService.IdentitySnapshot? = {
                guard databaseDiscovery.isAuthoritative else { return nil }
                if discoveredDatabaseURLs.isEmpty {
                    // A clean, successful empty discovery is authoritative. The
                    // search reconciler will use its previously owned paths to
                    // retire the last live SQLite corpus.
                    return .empty
                }
                guard readableDatabasePaths == discoveredDatabasePaths else { return nil }
                return SearchIngestService.IdentitySnapshot(
                    storagePaths: readableDatabasePaths,
                    sessionIDs: Set(databaseSessions.map(\.id)))
            }()
            let databaseSnapshotIsComplete = databaseIdentitySnapshot != nil

            let files: [URL]
            let missingHydratedCount: Int
            if mode == .fullReconcile || previousStats.isEmpty {
                // First-ever scan or manual full reconcile: parse everything
                files = delta.currentByPath.keys.map { URL(fileURLWithPath: $0) }
                missingHydratedCount = 0
            } else {
                // Supplement: force-parse files on disk but missing from hydrated snapshot.
                let existingPaths = Set(existingSessions.map(\.filePath))
                let changedPaths = Set(delta.changedFiles.map(\.path))
                let missingPaths = Set(delta.currentByPath.keys)
                    .subtracting(existingPaths)
                    .subtracting(changedPaths)
                let staleOriginPaths = Set(existingSessions
                    .filter { Self.needsOriginProjectReparse($0) }
                    .map(\.filePath))
                    .intersection(Set(delta.currentByPath.keys))
                    .subtracting(changedPaths)
                missingHydratedCount = missingPaths.count
                if missingPaths.isEmpty && staleOriginPaths.isEmpty {
                    files = delta.changedFiles
                } else {
                    let combinedPaths = changedPaths
                        .union(missingPaths)
                        .union(staleOriginPaths)
                    files = combinedPaths.sorted().map { URL(fileURLWithPath: $0) }
                }
            }

            #if DEBUG
            print("📁 Found \(files.count) OpenClaw changed/new files (removed=\(delta.removedPaths.count), total_on_disk=\(delta.currentByPath.count))")
            #endif
            LaunchProfiler.log("OpenClaw.refresh: file enumeration done (changed=\(files.count), removed=\(delta.removedPaths.count), gap=\(missingHydratedCount))")

            // shouldMergeArchives: false — we call mergePinnedArchiveFallbacks once below
            // on the complete merged list, preventing duplication from delta slices.
            let config = SessionIndexingEngine.ScanConfig(
                source: .openclaw,
                discoverFiles: { files },
                parseLightweight: { OpenClawSessionParser.parseFile(at: $0) },
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: refreshProgressThrottler,
                shouldContinue: { self.isCurrentRefresh(token) },
                shouldMergeArchives: false,
                workerCount: executionProfile.workerCount,
                sliceSize: executionProfile.sliceSize,
                interSliceYieldNanoseconds: executionProfile.interSliceYieldNanoseconds,
                onProgress: { [weak self] processed, total in
                    guard let self else { return }
                    self.publishProgressIfCurrent(token: token,
                                                  existingCount: existingSessions.count,
                                                  processed: processed,
                                                  total: total)
                }
            )

            let scanResult = await SessionIndexingEngine.hydrateOrScan(config: config)
            let changedSessions = scanResult.sessions

            // Bail early if a newer refresh has started — don't touch shared state.
            guard self.isCurrentRefresh(token) else { return }

            // ── Phase 4: Merge hydrated + scanned ──
            var mergedByKey: [String: Session] = [:]
            mergedByKey.reserveCapacity(existingSessions.count + changedSessions.count + databaseSessions.count)
            for session in existingSessions {
                if Self.isSQLiteSession(session), databaseDiscovery.isAuthoritative {
                    let sessionDatabasePath = Self.canonicalSQLitePath(session.filePath)
                    if readableDatabasePaths.contains(sessionDatabasePath) {
                        // A readable current database replaces its hydrated rows.
                        continue
                    }
                    if databaseSnapshotIsComplete,
                       !discoveredDatabasePaths.contains(sessionDatabasePath) {
                        // The store is no longer configured/discoverable. Do not
                        // resurrect a stale hydrated copy merely because its old
                        // SQLite file still happens to exist on disk.
                        continue
                    }
                    // A currently discovered but unreadable database keeps its
                    // hydrated rows until the source becomes readable again.
                }
                mergedByKey[Self.mergeKey(for: session)] = session
            }
            for removed in delta.removedPaths {
                mergedByKey.removeValue(forKey: "file:\(removed)")
            }
            for session in databaseSessions {
                mergedByKey[Self.mergeKey(for: session)] = session
            }
            for session in changedSessions {
                mergedByKey[Self.mergeKey(for: session)] = session
            }

            // SQLite hydration is retained whenever discovery is incomplete.
            // A lexical path can be a broken alias or an unavailable mount;
            // only the authoritative, complete snapshot above may retire it.
            let merged = Array(mergedByKey.values)
            let sortedSessions = merged.sorted { $0.modifiedAt > $1.modifiedAt }
            // Single archive fallback merge on the complete, deduplicated list.
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(
                into: sortedSessions, source: .openclaw)

            let databaseEnumerationIsStable = capturedDatabaseVersionsByPath.allSatisfy { path, capturedVersion in
                OpenClawSqliteReader.storageRevisionToken(forStorageIdentity: path) == capturedVersion
            }
            guard databaseEnumerationIsStable else {
                await self.finishRefreshWithoutPublication(token: token)
                return
            }

            // ── Phase 5/6: Persist file stats and session_meta atomically ──
            if self.isCurrentRefresh(token) {
                var db: IndexDB?
                do {
                    let openedDB = try IndexDB()
                    db = openedDB
                    try await openedDB.begin()
                    // A newer refresh may have started while BEGIN IMMEDIATE was
                    // waiting for the index database. Do not let this refresh
                    // write obsolete rows after that hand-off.
                    guard self.isCurrentRefresh(token) else {
                        await openedDB.rollbackSilently()
                        return
                    }
                    // Upsert the current identity/path mapping before retiring
                    // undiscovered paths. A session whose SQLite store moved
                    // from A to B must keep its search/tool/day rows: after
                    // this upsert, path retirement at A cannot select it.
                    for session in merged {
                        try await openedDB.upsertSessionMetaCore(SessionIndexer.sessionMetaRow(from: session))
                    }
                    if databaseDiscovery.isAuthoritative, !readableDatabasePaths.isEmpty {
                        // Reconcile each readable path even if another database
                        // could not be read. Unreadable paths are omitted by the
                        // helper and therefore retain their hydrated identities.
                        let staleSessionIDs = try await openedDB.deleteSessionsNotPresentAtPaths(
                            source: SessionSource.openclaw.rawValue,
                            currentSessionIDsByPath: currentDatabaseSessionIDsByPath)
                        if !staleSessionIDs.isEmpty {
                            os_log("OpenClaw: retired %d removed SQLite session identities",
                                   log: indexLog,
                                   type: .info,
                                   staleSessionIDs.count)
                        }
                    }
                    if databaseDiscovery.isAuthoritative, databaseSnapshotIsComplete {
                        let indexedSQLitePaths = try await openedDB.fetchSessionMetaPaths(
                            for: SessionSource.openclaw.rawValue
                        ).filter(OpenClawSqliteReader.isSupportedDatabasePath)
                        let retiredSQLitePaths = indexedSQLitePaths.filter {
                            !discoveredDatabasePaths.contains(Self.canonicalSQLitePath($0))
                        }
                        if !retiredSQLitePaths.isEmpty {
                            let affectedDays = try await openedDB.deleteSessionsForPaths(
                                source: SessionSource.openclaw.rawValue,
                                paths: Array(retiredSQLitePaths))
                            try await openedDB.recomputeRollupsForDays(
                                Set(affectedDays),
                                source: SessionSource.openclaw.rawValue)
                        }
                    }
                    if !delta.driftDetected,
                       let fileStatsJSON = self.persistedFileStatsJSON(for: delta.currentByPath) {
                        // Keep the file-stat baseline in the same transaction
                        // as session_meta. A failed or stale refresh therefore
                        // cannot claim that files are current on the next launch.
                        try await openedDB.setIndexState(
                            key: Self.coreFileStatsStateKey,
                            value: fileStatsJSON)
                    }
                    // Check again immediately before COMMIT. If refreshToken
                    // changed during reconciliation, rollback the whole batch
                    // instead of publishing a partial or stale snapshot.
                    guard try await self.commitIndexDBIfCurrent(openedDB, token: token) else {
                        await openedDB.rollbackSilently()
                        return
                    }
                    os_log("OpenClaw: reconciled %d session_meta rows", log: indexLog, type: .info, merged.count)
                    if !delta.driftDetected, self.isCurrentRefresh(token) {
                        self.applyKnownFileStatsDelta(delta)
                    }
                } catch {
                    if let db {
                        await db.rollbackSilently()
                    }
                    os_log("OpenClaw: session_meta write failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
                }
            }

            // ── Phase 7: Publish final merged sessions ──
            let finalProofSnapshot = await self.publishedSessionSnapshot(
                for: mergedWithArchives.map(\.id))
            // A lightweight SQLite row has no content revision of its own.
            // Stamp only rows whose currently published counterpart is fully
            // loaded; this lets the MainActor handoff distinguish an unchanged
            // lightweight candidate from a database write without scanning
            // every session on every refresh.
            let finalStorageProof = Self.stampSQLiteStorageVersionsForPublishedCurrent(
                candidates: mergedWithArchives)
            guard finalStorageProof.mismatchedIdentities.isEmpty else {
                await self.finishRefreshWithoutPublication(token: token)
                return
            }
            let candidatesForFinalRefresh = finalStorageProof.candidates
            let observedSQLiteStorageVersions = finalStorageProof.versionsByIdentity
            self.reloadLock.lock()
            let finalStatsHook = self.refreshBeforeFinalStatsHookForTesting
            self.reloadLock.unlock()
            finalStatsHook?()
            var previewTimes: [String: Date] = [:]
            var previewStats: [String: SessionFileStat] = [:]
            previewTimes.reserveCapacity(candidatesForFinalRefresh.count)
            previewStats.reserveCapacity(candidatesForFinalRefresh.count)
            for s in candidatesForFinalRefresh {
                let url = URL(fileURLWithPath: s.filePath)
                if let stat = Self.fileStat(for: url) {
                    previewStats[s.id] = stat
                }
                if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let m = rv.contentModificationDate {
                    previewTimes[s.id] = m
                }
            }
            let previewTimesByID = previewTimes
            let previewStatsByID = previewStats
            let candidateTranscripts = Self.transcriptCacheEntries(for: candidatesForFinalRefresh)
            let reloadProtectedIDs = self.reloadProtectedSessionIDs(
                candidates: candidatesForFinalRefresh,
                currentByID: finalProofSnapshot.sessionsByID)
            self.finalPublicationHookForTesting()?()
            var handoffSnapshot = await self.publishedSessionSnapshot(
                for: candidatesForFinalRefresh.map(\.id))
            var revalidatedSQLitePublications = Self.revalidatedNewerSQLitePublications(
                candidates: candidatesForFinalRefresh,
                currentSnapshot: handoffSnapshot,
                baseEpochs: finalProofSnapshot.publicationEpochByID,
                observedSQLiteStorageVersions: observedSQLiteStorageVersions)
            // Re-sample the actor after the off-actor proof pass. If another
            // publication landed in that window, validate the newer snapshot
            // instead of carrying a result for the row that was just replaced.
            let latestHandoffSnapshot = await self.publishedSessionSnapshot(
                for: candidatesForFinalRefresh.map(\.id))
            if latestHandoffSnapshot.publicationEpochByID != handoffSnapshot.publicationEpochByID {
                handoffSnapshot = latestHandoffSnapshot
                revalidatedSQLitePublications = Self.revalidatedNewerSQLitePublications(
                    candidates: candidatesForFinalRefresh,
                    currentSnapshot: handoffSnapshot,
                    baseEpochs: finalProofSnapshot.publicationEpochByID,
                    observedSQLiteStorageVersions: observedSQLiteStorageVersions)
            }
            self.reloadLock.lock()
            let handoffSnapshotHook = self.refreshAfterHandoffSnapshotHookForTesting
            self.reloadLock.unlock()
            handoffSnapshotHook?()
            let postHookHandoffSnapshot = await self.publishedSessionSnapshot(
                for: candidatesForFinalRefresh.map(\.id))
            if postHookHandoffSnapshot.publicationEpochByID
                != handoffSnapshot.publicationEpochByID {
                handoffSnapshot = postHookHandoffSnapshot
                revalidatedSQLitePublications = Self.revalidatedNewerSQLitePublications(
                    candidates: candidatesForFinalRefresh,
                    currentSnapshot: handoffSnapshot,
                    baseEpochs: finalProofSnapshot.publicationEpochByID,
                    observedSQLiteStorageVersions: observedSQLiteStorageVersions)
            }
            let revalidatedJSONLPublications = Self.revalidatedNewerJSONLPublications(
                candidates: candidatesForFinalRefresh,
                currentSnapshot: handoffSnapshot,
                baseEpochs: finalProofSnapshot.publicationEpochByID)
            let finalHandoffSnapshot = handoffSnapshot
            let finalRevalidatedSQLitePublications = revalidatedSQLitePublications

            await MainActor.run {
                guard self.isCurrentRefresh(token) else { return }
                // A selected transcript can finish a full reload while this
                // generation is still scanning. Preserve that successful
                // publication when the candidate still points at the same
                // stable revision; otherwise the final lightweight merge would
                // clobber it without any newer refresh having started.
                let currentByID = self.allSessions.reduce(into: [String: Session]()) {
                    $0[$1.id] = $1
                }
                let sessionsToPublish = self.sessionsForFinalRefresh(
                    candidates: candidatesForFinalRefresh,
                    currentByID: currentByID,
                    baseEpochs: finalPublicationBaseline.publicationEpochByID,
                    reloadProtectedIDs: reloadProtectedIDs,
                    observedSQLiteStorageVersions: observedSQLiteStorageVersions,
                    observedFileStats: previewStatsByID,
                    handoffSnapshot: finalHandoffSnapshot,
                    revalidatedSQLitePublications: finalRevalidatedSQLitePublications,
                    revalidatedJSONLPublications: revalidatedJSONLPublications)
                let stalePreviewIDs = Set(sessionsToPublish.compactMap { session -> String? in
                    guard let current = currentByID[session.id],
                          self.previewStaleByID[session.id] == true,
                          Self.publishedStorageMatches(current, session) else {
                        return nil
                    }
                    return session.id
                })
                let preservedTranscripts = sessionsToPublish.reduce(into: [String: String]()) { result, session in
                    guard let previous = currentByID[session.id],
                          !stalePreviewIDs.contains(session.id),
                          previous.events == session.events,
                          let transcript = self.transcriptCache.getCached(session.id) else { return }
                    result[session.id] = transcript
                }
                let candidateTranscriptsForPublication = candidateTranscripts.filter {
                    !stalePreviewIDs.contains($0.key)
                }
                let transcriptsToInstall = candidateTranscriptsForPublication.merging(preservedTranscripts) {
                    _, preserved in preserved
                }
                let transcriptIDsToRemove = sessionsToPublish.compactMap { session -> String? in
                    guard let previous = currentByID[session.id],
                          !previous.events.isEmpty,
                          session.events.isEmpty else {
                        return nil
                    }
                    return session.id
                }
                LaunchProfiler.log("OpenClaw.refresh: sessions merged (total=\(mergedWithArchives.count))")
                let existingPreviewMTimes = self.previewMTimeByID
                let existingPreviewStats = self.previewFileStatByID
                let previewProofStats = sessionsToPublish.reduce(into: [String: SessionFileStat]()) {
                    result, session in
                    guard !session.events.isEmpty,
                          !Self.isSQLiteSession(session) else { return }
                    if let stat = session.sourceFileStat {
                        result[session.id] = stat
                    } else if let existingStat = existingPreviewStats[session.id] {
                        result[session.id] = existingStat
                    }
                }
                self.previewMTimeByID = sessionsToPublish.reduce(into: previewTimesByID) { result, session in
                    guard !session.events.isEmpty,
                          let previous = currentByID[session.id],
                          previous.events == session.events,
                          let existingStat = existingPreviewStats[session.id],
                          existingStat == previewProofStats[session.id],
                          let existingMTime = existingPreviewMTimes[session.id] else {
                        return
                    }
                    result[session.id] = existingMTime
                }
                self.previewFileStatByID = previewProofStats
                self.notePublishedStoragePaths(sessionsToPublish, completeSnapshot: true)
                for id in transcriptIDsToRemove {
                    self.transcriptCache.remove(id)
                }
                self.installTranscriptCacheEntries(transcriptsToInstall)
                self.allSessions = sessionsToPublish
                self.previewStaleByID = sessionsToPublish.reduce(into: [:]) { result, session in
                    result[session.id] = stalePreviewIDs.contains(session.id)
                        ? true
                        : false
                }
                self.searchIdentitySnapshot = databaseIdentitySnapshot
                self.isIndexing = false
                if FeatureFlags.throttleIndexingUIUpdates {
                    self.filesProcessed = self.totalFiles
                    if self.totalFiles > 0 {
                        self.progressText = "Indexed \(self.totalFiles)/\(self.totalFiles)"
                    }
                }
                #if DEBUG
                print("✅ OPENCLAW INDEXING DONE: total=\(mergedWithArchives.count) (existing=\(existingSessions.count), changed=\(changedSessions.count), removed=\(delta.removedPaths.count))")
                #endif
                self.progressText = "Ready"
                self.launchPhase = .ready
            }
        }
    }

    private func hydrateFromIndexDBIfAvailable() async throws -> [Session]? {
        let db = try IndexDB()
        let repo = SessionMetaRepository(db: db)
        let list = try await repo.fetchSessions(for: .openclaw)
        guard !list.isEmpty else { return nil }
        return list.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @MainActor
    private func finishRefreshWithoutPublication(token: UUID) {
        guard isCurrentRefresh(token) else { return }
        isIndexing = false
        isProcessingTranscripts = false
        progressText = "Ready"
        launchPhase = .ready
    }

    @MainActor
    private func publishedSessionSnapshot(for ids: [String]? = nil) -> PublishedSessionSnapshot {
        let requestedIDs = Set(ids ?? allSessions.map(\.id))
        let sessionsByID = allSessions.reduce(into: [String: Session]()) { result, session in
            guard requestedIDs.contains(session.id) else { return }
            result[session.id] = session
        }
        let publicationEpochByID = Dictionary(uniqueKeysWithValues: requestedIDs.map { id in
            (id, publicationEpochBySessionID[id] ?? 0)
        })
        let fileStatsByID = previewFileStatByID.filter { requestedIDs.contains($0.key) }
        return PublishedSessionSnapshot(
            sessionsByID: sessionsByID,
            publicationEpochByID: publicationEpochByID,
            fileStatsByID: fileStatsByID)
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(allSessions, filters: filters, transcriptCache: transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
        let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
        let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true
        if hideZero { results = results.filter { $0.messageCount > 0 } }
        if hideLow { results = results.filter { $0.messageCount == 0 || $0.messageCount > 2 } }
        let showHousekeeping = UserDefaults.standard.bool(forKey: PreferencesKey.showHousekeepingSessions)
        if !showHousekeeping { results = results.filter { !$0.isHousekeeping } }
        Task { @MainActor [weak self] in
            self?.sessions = results
        }
    }

    enum ReloadReason: String, Equatable {
        case selection
        case focusedSessionMonitor
        case manualRefresh
    }

    func reloadSession(id: String,
                       force: Bool = false,
                       reason: ReloadReason = .selection) {
        let registration: (session: Session?, token: UUID, generation: UUID, publicationEpoch: UInt64) = {
            while true {
                let snapshot = self.reloadSnapshot(id: id)
                self.reloadLock.lock()
                let beforeRegistrationHook = self.reloadBeforeRegistrationHookForTesting
                self.reloadLock.unlock()
                beforeRegistrationHook?()
                let reloadGeneration = UUID()
                self.reloadLock.lock()
                // The session path and its monotonic storage version are read
                // under the same lock used for publication bookkeeping. If a
                // MainActor publication happened after the snapshot, retry
                // instead of allowing a delayed caller to overwrite a newer
                // in-flight request.
                let currentStorageVersion = self.storageVersionBySessionID[id] ?? 0
                let currentPublicationEpoch = self.publicationEpochBySessionID[id] ?? 0
                if currentStorageVersion != snapshot.storageVersion
                    || currentPublicationEpoch != snapshot.publicationEpoch {
                    self.reloadLock.unlock()
                    continue
                }
                let reloadToken = self.currentRefreshToken()
                if let inFlight = self.inFlightReloadsBySessionID[id],
                   inFlight.refreshToken == reloadToken,
                   inFlight.storageVersion == snapshot.storageVersion,
                   inFlight.publicationEpoch == snapshot.publicationEpoch,
                   let requestedStoragePath = snapshot.session?.filePath,
                   Self.storagePathsMatch(inFlight.storagePath, requestedStoragePath) {
                    if inFlight.force == force, inFlight.reason == reason {
                        self.pendingReloadsBySessionID[id] = PendingReload(
                            ownerGeneration: inFlight.generation,
                            force: force,
                            reason: reason)
                        let pendingHook = self.reloadPendingRecordedHookForTesting
                        self.reloadLock.unlock()
                        pendingHook?()
                        return (nil, reloadToken, reloadGeneration, snapshot.publicationEpoch)
                    }
                    if Self.reloadStrength(force: inFlight.force, reason: inFlight.reason)
                        > Self.reloadStrength(force: force, reason: reason) {
                        // A weaker request must not replace a stronger worker
                        // that is already parsing the same storage identity.
                        self.reloadLock.unlock()
                        return (nil, reloadToken, reloadGeneration, snapshot.publicationEpoch)
                    }
                }
                // A new worker supersedes any pending request recorded for an
                // older generation. That request was proven against the old
                // storage/publication snapshot and must not be consumed by
                // the new worker's terminal handoff.
                self.pendingReloadsBySessionID.removeValue(forKey: id)
                self.inFlightReloadsBySessionID[id] = InFlightReload(
                    refreshToken: reloadToken,
                    storagePath: snapshot.session?.filePath ?? "",
                    storageVersion: snapshot.storageVersion,
                    publicationEpoch: snapshot.publicationEpoch,
                    generation: reloadGeneration,
                    force: force,
                    reason: reason)
                self.latestReloadGenerationBySessionID[id] = reloadGeneration
                self.reloadLock.unlock()
                return (snapshot.session, reloadToken, reloadGeneration, snapshot.publicationEpoch)
            }
        }()
        guard let existingSnapshot = registration.session else { return }
        let reloadToken = registration.token
        let reloadGeneration = registration.generation
        let reloadPublicationEpoch = registration.publicationEpoch

        let bgQueue = FeatureFlags.backgroundIngestQueue
        bgQueue.async {
            let existing = existingSnapshot
            guard FileManager.default.fileExists(atPath: existing.filePath) else {
                self.enqueueReloadTerminalHookForTesting(id: id, generation: reloadGeneration)
                return
            }

            let hasLoadedEvents = !existing.events.isEmpty
            if hasLoadedEvents && !force {
                self.enqueueReloadTerminalHookForTesting(id: id, generation: reloadGeneration)
                return
            }

            let url = URL(fileURLWithPath: existing.filePath)
            let isSQLite = OpenClawSqliteReader.isSupportedDatabaseURL(url)
            let preProof = isSQLite ? OpenClawSqliteReader.sessionProof(for: existing) : nil
            let preRevision = preProof?.revision
            let preStorageIdentity = preProof?.storageIdentity
            self.reloadLock.lock()
            let lastReloadRevision = self.lastFullReloadRevisionsBySessionID[id]
            self.reloadLock.unlock()
            let preParseStat = Self.fileStat(for: url)
            self.reloadLock.lock()
            let lastReloadStat = self.lastFullReloadFileStatsBySessionID[id]
            self.reloadLock.unlock()

            if force,
               reason != .manualRefresh,
               hasLoadedEvents {
                if isSQLite {
                    if let preRevision, preRevision == lastReloadRevision {
                        self.enqueueReloadTerminalHookForTesting(id: id, generation: reloadGeneration)
                        return
                    }
                } else if let preParseStat,
                          let lastReloadStat,
                          preParseStat == lastReloadStat {
                    self.enqueueReloadTerminalHookForTesting(id: id, generation: reloadGeneration)
                    return
                }
            }

            let shouldSurfaceLoadingState = reason == .manualRefresh || !hasLoadedEvents
            if shouldSurfaceLoadingState {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isCurrentRefresh(reloadToken),
                          self.isLatestReloadGeneration(id: id, generation: reloadGeneration) else { return }
                    self.isLoadingSession = true
                    self.loadingSessionID = id
                    self.loadingSessionToken = reloadGeneration
                }
            }

            self.reloadLock.lock()
            let reloadHook = self.reloadBeforeParseHookForTesting
            self.reloadLock.unlock()
            reloadHook?()

            let full: Session? = OpenClawSqliteReader.isSupportedDatabaseURL(url)
                ? OpenClawSqliteReader.loadFullSession(databaseURL: url, sessionID: id)
                : OpenClawSessionParser.parseFileFull(at: url, forcedID: id)
            let fullTranscript = full.map { Self.transcriptCacheEntries(for: [$0]) }
            let postProof = isSQLite ? OpenClawSqliteReader.sessionProof(for: existing) : nil
            let postRevision = postProof?.revision
            let postStorageIdentity = postProof?.storageIdentity
            let postParseStat = Self.fileStat(for: url)
            let postParseMTime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let postDatabaseVersion = isSQLite
                ? OpenClawSqliteReader.storageRevisionToken(for: existing)
                : nil
            var validatedJSONLStat: SessionFileStat?
            if isSQLite {
                guard let preRevision,
                      let postRevision,
                      preRevision == postRevision,
                      preStorageIdentity == postStorageIdentity,
                      postProof?.databaseVersionToken == postDatabaseVersion else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer {
                            self.finishReloadTerminalHookForTesting(
                                id: id,
                                generation: reloadGeneration,
                                retryPending: true)
                        }
                        if self.loadingSessionID == id,
                           self.loadingSessionToken == reloadGeneration {
                            self.isLoadingSession = false
                            self.loadingSessionID = nil
                            self.loadingSessionToken = nil
                        }
                    }
                    #if DEBUG
                    print("ℹ️ OpenClaw SQLite session changed or could not be proven stable; stale transcript discarded")
                    #endif
                    return
                }
            } else {
                guard let preParseStat,
                      let postParseStat,
                      preParseStat == postParseStat else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer {
                            self.finishReloadTerminalHookForTesting(
                                id: id,
                                generation: reloadGeneration,
                                retryPending: true)
                        }
                        if self.loadingSessionID == id,
                           self.loadingSessionToken == reloadGeneration {
                            self.isLoadingSession = false
                            self.loadingSessionID = nil
                            self.loadingSessionToken = nil
                        }
                    }
                    #if DEBUG
                    print("ℹ️ OpenClaw JSONL session changed or could not be proven stable; stale transcript discarded")
                    #endif
                    return
                }
                if let full {
                    guard let parserStat = full.sourceFileStat,
                          parserStat == preParseStat,
                          parserStat == postParseStat else {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            defer {
                                self.finishReloadTerminalHookForTesting(
                                    id: id,
                                    generation: reloadGeneration,
                                    retryPending: true)
                            }
                            if self.loadingSessionID == id,
                               self.loadingSessionToken == reloadGeneration {
                                self.isLoadingSession = false
                                self.loadingSessionID = nil
                                self.loadingSessionToken = nil
                            }
                        }
                        #if DEBUG
                        print("ℹ️ OpenClaw JSONL parser proof did not match the reload snapshot; stale transcript discarded")
                        #endif
                        return
                    }
                    validatedJSONLStat = parserStat
                }
            }

            let validatedJSONLStatForPublication = validatedJSONLStat
            self.reloadLock.lock()
            let reloadPublicationHook = self.reloadBeforePublicationHookForTesting
            self.reloadLock.unlock()
            reloadPublicationHook?()

            if full != nil {
                if isSQLite {
                    let publicationProof = OpenClawSqliteReader.sessionProof(for: existing)
                    guard let postProof,
                          let publicationProof,
                          publicationProof.storageIdentity == postProof.storageIdentity,
                          publicationProof.revision == postProof.revision,
                          publicationProof.databaseVersionToken == postProof.databaseVersionToken else {
                        self.enqueueReloadProofFailure(
                            id: id,
                            generation: reloadGeneration)
                        #if DEBUG
                        print("ℹ️ OpenClaw SQLite session changed after proof; stale transcript discarded")
                        #endif
                        return
                    }
                } else {
                    let publicationStat = Self.fileStat(for: url)
                    guard let validatedJSONLStatForPublication,
                          publicationStat == validatedJSONLStatForPublication else {
                        self.enqueueReloadProofFailure(
                            id: id,
                            generation: reloadGeneration)
                        #if DEBUG
                        print("ℹ️ OpenClaw JSONL session changed after proof; stale transcript discarded")
                        #endif
                        return
                    }
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                var retryPending = false
                defer {
                    if shouldSurfaceLoadingState,
                       self.loadingSessionID == id,
                       self.loadingSessionToken == reloadGeneration {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                        self.loadingSessionToken = nil
                    }
                    self.finishReloadTerminalHookForTesting(
                        id: id,
                        generation: reloadGeneration,
                        retryPending: retryPending)
                }
                let currentRefresh = self.isCurrentRefresh(reloadToken)
                let latestGeneration = self.isLatestReloadGeneration(id: id, generation: reloadGeneration)
                if !currentRefresh, latestGeneration {
                    // Refresh invalidation can happen without a superseding
                    // reload worker. Keep an identical pending request alive
                    // so terminal cleanup replays it under the new token.
                    retryPending = true
                }
                guard currentRefresh,
                      latestGeneration,
                      let idx = self.allSessions.firstIndex(where: { $0.id == id }) else {
                    // Discovery may have moved this session to a configured
                    // store while the old path was being parsed. Never let
                    // same-refresh publication resurrect the obsolete path.
                    return
                }
                let current = self.allSessions[idx]
                let publicationEpochMatches = self.publicationEpochBySessionID[id] == reloadPublicationEpoch
                if !publicationEpochMatches {
                    // A refresh can publish a lightweight row after this
                    // reload proves the same SQLite snapshot. Allow the
                    // reload to fill that row, but never overwrite a newer
                    // full publication or cross a database revision.
                    guard isSQLite,
                          let postProof,
                          current.sourceStorageIdentity == postProof.storageIdentity,
                          current.sourceStorageDatabaseVersion == postProof.databaseVersionToken else {
                        retryPending = true
                        return
                    }
                    if let currentRevision = current.sourceStorageRevision {
                        guard let postRevision,
                              currentRevision == Self.sessionRevisionKey(postRevision) else {
                            retryPending = true
                            return
                        }
                    }
                    if !current.events.isEmpty {
                        return
                    }
                }
                if isSQLite {
                    guard let postProof,
                          current.sourceStorageIdentity == postProof.storageIdentity,
                          full?.sourceStorageIdentity == postProof.storageIdentity else {
                        retryPending = true
                        // The alias or its physical target changed after the
                        // parse completed. Do not publish content from the old
                        // target, even if a fresh alias comparison would pass.
                        return
                    }
                } else {
                    guard Self.standardizedStoragePath(current.filePath)
                            == Self.standardizedStoragePath(existing.filePath) else {
                        return
                    }
                }
                if let full {
                    let isSQLite = Self.isSQLiteSession(current)
                    if isSQLite {
                        guard let postProof,
                              let postRevision,
                              full.sourceStorageIdentity == postProof.storageIdentity,
                              full.sourceStorageRevision == Self.sessionRevisionKey(postRevision) else {
                            retryPending = true
                            // The alias may have followed A -> B -> A while
                            // the parser was running. Only publish a full
                            // result whose own snapshot proof matches the
                            // store observed at the publication boundary.
                            return
                        }
                    }
                    var merged = Session(
                        id: current.id,
                        source: .openclaw,
                        startTime: full.startTime ?? current.startTime,
                        endTime: full.endTime ?? current.endTime,
                        model: isSQLite ? full.model : (full.model ?? current.model),
                        // SQLite discovery may publish a canonical target while
                        // an older reload is still reading through a symlink
                        // alias. Preserve the path that won the publication
                        // race; otherwise the old alias can be resurrected.
                        filePath: isSQLite ? current.filePath : full.filePath,
                        fileSizeBytes: full.fileSizeBytes ?? current.fileSizeBytes,
                        eventCount: max(current.eventCount, full.nonMetaCount),
                        events: full.events,
                        cwd: current.lightweightCwd ?? full.cwd,
                        repoName: full.repoName ?? current.repoName,
                        lightweightTitle: isSQLite
                            ? full.lightweightTitle
                            : (current.lightweightTitle ?? full.lightweightTitle),
                        lightweightCommands: current.lightweightCommands,
                        isHousekeeping: full.isHousekeeping,
                        deletedAt: current.deletedAt ?? full.deletedAt
                    )
                    if isSQLite, let postProof, let postRevision {
                        merged.sourceStorageIdentity = full.sourceStorageIdentity ?? postProof.storageIdentity
                        merged.sourceStorageRevision = full.sourceStorageRevision ?? Self.sessionRevisionKey(postRevision)
                        merged.sourceStorageDatabaseVersion = postProof.databaseVersionToken
                    }
                    if !isSQLite {
                        merged.sourceFileStat = validatedJSONLStatForPublication
                    }
                    self.reloadLock.lock()
                    let publicationCommitHook = self.reloadBeforePublicationCommitHookForTesting
                    self.reloadLock.unlock()
                    publicationCommitHook?()
                    guard self.notePublishedStoragePaths(
                        [merged],
                        requiredLatestGeneration: reloadGeneration) else {
                        retryPending = true
                        return
                    }
                    if let fullTranscript {
                        self.installTranscriptCacheEntries(fullTranscript)
                    }
                    self.allSessions[idx] = merged
                    self.previewStaleByID[id] = false
                    if !isSQLite, let validatedJSONLStatForPublication {
                        self.previewFileStatByID[id] = validatedJSONLStatForPublication
                    }
                    self.unreadableSessionIDs.remove(id)
                    self.recordSuccessfulReloadBaseline(
                        id: id,
                        isSQLite: isSQLite,
                        revision: postRevision,
                        fileStat: validatedJSONLStatForPublication)
                    if let stableRevision = postRevision {
                        self.previewRevisionByID[id] = stableRevision
                    }
                    if let m = postParseMTime {
                        self.previewMTimeByID[id] = m
                    }
                } else if full == nil {
                    self.unreadableSessionIDs.insert(id)
                }
            }
        }
    }

    func setReloadBeforeParseHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        reloadBeforeParseHookForTesting = hook
        reloadLock.unlock()
    }

    func setReloadBeforePublicationHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        reloadBeforePublicationHookForTesting = hook
        reloadLock.unlock()
    }

    func setReloadBeforePublicationCommitHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        reloadBeforePublicationCommitHookForTesting = hook
        reloadLock.unlock()
    }

    func setReloadBeforeRegistrationHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        reloadBeforeRegistrationHookForTesting = hook
        reloadLock.unlock()
    }

    func setReloadPendingRecordedHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        reloadPendingRecordedHookForTesting = hook
        reloadLock.unlock()
    }

    func setReloadBeforeTerminalCleanupHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        reloadBeforeTerminalCleanupHookForTesting = hook
        reloadLock.unlock()
    }

    func setReloadTerminalHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        reloadTerminalHookForTesting = hook
        reloadLock.unlock()
    }

    func pendingReloadIsOwnedByLatestGenerationForTesting(id: String) -> Bool {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        guard let pending = pendingReloadsBySessionID[id],
              let latestGeneration = latestReloadGenerationBySessionID[id] else {
            return false
        }
        return pending.ownerGeneration == latestGeneration
    }

    func setRefreshBeforeHydrationPublicationHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        refreshBeforeHydrationPublicationHookForTesting = hook
        reloadLock.unlock()
    }

    func setRefreshBeforeFinalStatsHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        refreshBeforeFinalStatsHookForTesting = hook
        reloadLock.unlock()
    }

    func setRefreshBeforeFinalPublicationHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        refreshBeforeFinalPublicationHookForTesting = hook
        reloadLock.unlock()
    }

    func setPreviewStalenessBeforePublicationHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        previewStalenessBeforePublicationHookForTesting = hook
        reloadLock.unlock()
    }

    func setRefreshPreviewAfterProofHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        refreshPreviewAfterProofHookForTesting = hook
        reloadLock.unlock()
    }

    func setRefreshPreviewTerminalHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        refreshPreviewTerminalHookForTesting = hook
        reloadLock.unlock()
    }

    func setPreviewStalenessTerminalHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        previewStalenessTerminalHookForTesting = hook
        reloadLock.unlock()
    }

    private func enqueueReloadTerminalHookForTesting(id: String, generation: UUID) {
        Task { @MainActor [weak self] in
            self?.finishReloadTerminalHookForTesting(id: id, generation: generation)
        }
    }

    private func enqueueReloadProofFailure(id: String, generation: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.loadingSessionID == id,
               self.loadingSessionToken == generation {
                self.isLoadingSession = false
                self.loadingSessionID = nil
                self.loadingSessionToken = nil
            }
            self.finishReloadTerminalHookForTesting(
                id: id,
                generation: generation,
                retryPending: true)
        }
    }

    private func finishReloadTerminalHookForTesting(
        id: String,
        generation: UUID,
        retryPending: Bool = false
    ) {
        reloadLock.lock()
        let beforeCleanupHook = reloadBeforeTerminalCleanupHookForTesting
        reloadLock.unlock()
        beforeCleanupHook?()

        reloadLock.lock()
        let ownsLatestGeneration = latestReloadGenerationBySessionID[id] == generation
        if inFlightReloadsBySessionID[id]?.generation == generation {
            inFlightReloadsBySessionID.removeValue(forKey: id)
        }
        if ownsLatestGeneration {
            latestReloadGenerationBySessionID.removeValue(forKey: id)
        }
        let pending: PendingReload?
        if ownsLatestGeneration,
           pendingReloadsBySessionID[id]?.ownerGeneration == generation {
            pending = pendingReloadsBySessionID.removeValue(forKey: id)
        } else {
            pending = nil
        }
        let hook = reloadTerminalHookForTesting
        reloadLock.unlock()
        hook?()
        guard retryPending, let pending else { return }
        Task { @MainActor [weak self] in
            self?.reloadSession(id: id, force: pending.force, reason: pending.reason)
        }
    }

    private func signalRefreshPreviewTerminalHookForTesting() {
        reloadLock.lock()
        let hook = refreshPreviewTerminalHookForTesting
        reloadLock.unlock()
        hook?()
    }

    private func signalPreviewStalenessTerminalHookForTesting() {
        reloadLock.lock()
        let hook = previewStalenessTerminalHookForTesting
        reloadLock.unlock()
        hook?()
    }

    func setRefreshAfterHandoffSnapshotHookForTesting(_ hook: (() -> Void)?) {
        reloadLock.lock()
        refreshAfterHandoffSnapshotHookForTesting = hook
        reloadLock.unlock()
    }

    private func hydrationPublicationHookForTesting() -> (() -> Void)? {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        return refreshBeforeHydrationPublicationHookForTesting
    }

    private func finalPublicationHookForTesting() -> (() -> Void)? {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        return refreshBeforeFinalPublicationHookForTesting
    }

    func replaceSessionStoragePathForTesting(id: String, path: String) {
        guard let idx = allSessions.firstIndex(where: { $0.id == id }) else { return }
        let current = allSessions[idx]
        var replacement = Session(
            id: current.id,
            source: current.source,
            startTime: current.startTime,
            endTime: current.endTime,
            model: current.model,
            filePath: path,
            fileSizeBytes: current.fileSizeBytes,
            eventCount: current.eventCount,
            events: current.events,
            isHousekeeping: current.isHousekeeping,
            codexInternalSessionIDHint: current.codexInternalSessionIDHint,
            parentSessionID: current.parentSessionID,
            subagentType: current.subagentType,
            relationshipKind: current.relationshipKind,
            customTitle: current.customTitle,
            codexOriginator: current.codexOriginator,
            codexSource: current.codexSource,
            codexSurface: current.codexSurface,
            originator: current.originator,
            originSource: current.originSource,
            surface: current.surface,
            reasoningEffort: current.reasoningEffort,
            deletedAt: current.deletedAt)
        if Self.isSQLiteSession(replacement) {
            if let proof = OpenClawSqliteReader.sessionProof(for: replacement) {
                replacement.sourceStorageIdentity = proof.storageIdentity
                replacement.sourceStorageRevision = Self.sessionRevisionKey(proof.revision)
                replacement.sourceStorageDatabaseVersion = proof.databaseVersionToken
            } else {
                replacement.sourceStorageIdentity = Self.canonicalSQLitePath(path)
                replacement.sourceStorageRevision = current.sourceStorageRevision
                replacement.sourceStorageDatabaseVersion = current.sourceStorageDatabaseVersion
            }
        } else {
            replacement.sourceFileStat = current.sourceFileStat
        }
        let replacementTranscript = Self.transcriptCacheEntries(for: [replacement])
        notePublishedStoragePaths([replacement])
        installTranscriptCacheEntries(replacementTranscript)
        allSessions[idx] = replacement
        previewStaleByID[current.id] = false
        if !Self.isSQLiteSession(replacement) {
            previewFileStatByID.removeValue(forKey: current.id)
        }
    }

    private func reloadSnapshot(id: String) -> (
        session: Session?,
        storageVersion: UInt64,
        publicationEpoch: UInt64
    ) {
        let read: () -> (
            session: Session?,
            storageVersion: UInt64,
            publicationEpoch: UInt64
        ) = {
            self.reloadLock.lock()
            defer { self.reloadLock.unlock() }
            return (
                self.allSessions.first(where: { $0.id == id }),
                self.storageVersionBySessionID[id] ?? 0,
                self.publicationEpochBySessionID[id] ?? 0)
        }
        if Thread.isMainThread {
            return read()
        }
        return DispatchQueue.main.sync(execute: read)
    }

    @discardableResult
    private func notePublishedStoragePaths(
        _ sessions: [Session],
        completeSnapshot: Bool = false,
        requiredLatestGeneration: UUID? = nil
    ) -> Bool {
        reloadLock.lock()
        if let requiredLatestGeneration {
            guard sessions.count == 1,
                  let sessionID = sessions.first?.id,
                  latestReloadGenerationBySessionID[sessionID] == requiredLatestGeneration else {
                reloadLock.unlock()
                return false
            }
        }
        var invalidatedIDs = Set<String>()
        let currentIDs = Set(sessions.map(\.id))
        // A publication can carry a same-path revision change (including a
        // WAL-only SQLite change), so path equality is not a sufficient cache
        // identity. Evict every transcript whose row was republished;
        // updateSession repopulates the accepted row with its fresh transcript
        // immediately afterward.
        invalidatedIDs.formUnion(currentIDs)
        for session in sessions {
            publicationEpochBySessionID[session.id, default: 0] &+= 1
            if publishedStoragePathBySessionID[session.id] != session.filePath {
                publishedStoragePathBySessionID[session.id] = session.filePath
                storageVersionBySessionID[session.id, default: 0] &+= 1
                invalidatedIDs.insert(session.id)
                lastFullReloadFileStatsBySessionID.removeValue(forKey: session.id)
                lastFullReloadRevisionsBySessionID.removeValue(forKey: session.id)
            }
        }
        if completeSnapshot {
            for id in Array(publishedStoragePathBySessionID.keys) where !currentIDs.contains(id) {
                publishedStoragePathBySessionID.removeValue(forKey: id)
                storageVersionBySessionID[id, default: 0] &+= 1
                publicationEpochBySessionID[id, default: 0] &+= 1
                invalidatedIDs.insert(id)
                lastFullReloadFileStatsBySessionID.removeValue(forKey: id)
                lastFullReloadRevisionsBySessionID.removeValue(forKey: id)
            }
        }
        reloadLock.unlock()
        for id in invalidatedIDs {
            transcriptCache.remove(id)
        }
        return true
    }

    private func installTranscriptCacheEntries(_ entries: [String: String]) {
        for (id, transcript) in entries {
            transcriptCache.set(id, transcript: transcript)
        }
    }

    private static func fileStat(for url: URL) -> SessionFileStat? {
        SessionFileStat.precise(from: url)
    }

    private static func isSQLiteSession(_ session: Session) -> Bool {
        OpenClawSqliteReader.isSupportedDatabasePath(session.filePath)
    }

    private static func reloadStrength(force: Bool, reason: ReloadReason) -> Int {
        if force, reason == .manualRefresh { return 3 }
        if force { return 2 }
        return 1
    }

    private static func session(_ session: Session, retainingFilePath filePath: String) -> Session {
        var retained = Session(
            id: session.id,
            source: session.source,
            startTime: session.startTime,
            endTime: session.endTime,
            model: session.model,
            filePath: filePath,
            fileSizeBytes: session.fileSizeBytes,
            eventCount: session.eventCount,
            events: session.events,
            cwd: session.lightweightCwd,
            repoName: session.lightweightRepoName,
            lightweightTitle: session.lightweightTitle,
            lightweightCommands: session.lightweightCommands,
            isHousekeeping: session.isHousekeeping,
            codexInternalSessionIDHint: session.codexInternalSessionIDHint,
            parentSessionID: session.parentSessionID,
            subagentType: session.subagentType,
            relationshipKind: session.relationshipKind,
            customTitle: session.customTitle,
            codexOriginator: session.codexOriginator,
            codexSource: session.codexSource,
            codexSurface: session.codexSurface,
            originator: session.originator,
            originSource: session.originSource,
            surface: session.surface,
            reasoningEffort: session.reasoningEffort,
            deletedAt: session.deletedAt)
        retained.isFavorite = session.isFavorite
        retained.isPartiallyHydrated = session.isPartiallyHydrated
        retained.sourceStorageIdentity = session.sourceStorageIdentity
        retained.sourceStorageRevision = session.sourceStorageRevision
        retained.sourceStorageDatabaseVersion = session.sourceStorageDatabaseVersion
        retained.sourceFileStat = session.sourceFileStat
        return retained
    }

    private static func canonicalSQLitePath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func isLatestReloadGeneration(id: String, generation: UUID) -> Bool {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        return latestReloadGenerationBySessionID[id] == generation
    }

    @MainActor
    private func markLoadedPreviewStale(_ current: Session, id: String) {
        guard !current.events.isEmpty else { return }
        if previewStaleByID[id] != true {
            notePublishedStoragePaths([current])
            previewStaleByID[id] = true
        }
    }

    private func recordSuccessfulReloadBaseline(
        id: String,
        isSQLite: Bool,
        revision: SessionTelemetryRevision?,
        fileStat: SessionFileStat?
    ) {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        if isSQLite {
            if let revision {
                lastFullReloadRevisionsBySessionID[id] = revision
            }
            lastFullReloadFileStatsBySessionID.removeValue(forKey: id)
        } else if let fileStat {
            lastFullReloadFileStatsBySessionID[id] = fileStat
        } else {
            lastFullReloadFileStatsBySessionID.removeValue(forKey: id)
        }
    }

    private func reloadProtectedSessionIDs(
        candidates: [Session],
        currentByID: [String: Session]
    ) -> Set<String> {
        Set(candidates.compactMap { candidate in
            guard let current = currentByID[candidate.id],
                  !current.events.isEmpty,
                  !Self.isSQLiteSession(current),
                  Self.publishedStorageMatches(current, candidate),
                  successfulReloadIsCurrent(for: candidate) else {
                return nil
            }
            return candidate.id
        })
    }

    @MainActor
    private func preservingNewerPublications(
        in candidates: [Session],
        currentByID: [String: Session],
        baseEpochs: [String: UInt64]
    ) -> [Session] {
        return candidates.map { candidate in
            guard let current = currentByID[candidate.id],
                  let baseEpoch = baseEpochs[candidate.id],
                  Self.publishedStorageMatches(current, candidate) else {
                return candidate
            }
            if previewStaleByID[candidate.id] == true {
                return candidate
            }
            let publicationAdvanced = (publicationEpochBySessionID[candidate.id] ?? 0) != baseEpoch
            guard publicationAdvanced
                    || Self.isSameSQLiteStorageSnapshot(current: current, candidate: candidate) else {
                return candidate
            }
            return Self.session(current, retainingFilePath: candidate.filePath)
        }
    }

    @MainActor
    private func sessionsForFinalRefresh(
        candidates: [Session],
        currentByID: [String: Session],
        baseEpochs: [String: UInt64],
        reloadProtectedIDs: Set<String>,
        observedSQLiteStorageVersions: [String: String],
        observedFileStats: [String: SessionFileStat],
        handoffSnapshot: PublishedSessionSnapshot,
        revalidatedSQLitePublications: [String: RevalidatedSQLitePublication],
        revalidatedJSONLPublications: [String: RevalidatedJSONLPublication]
    ) -> [Session] {
        return candidates.map { candidate in
            guard let current = currentByID[candidate.id],
                  Self.publishedStorageMatches(current, candidate) else {
                return candidate
            }
            let publicationAdvanced = (publicationEpochBySessionID[candidate.id] ?? 0)
                != (baseEpochs[candidate.id] ?? 0)
            if previewStaleByID[candidate.id] == true {
                // A focused proof already found that the loaded transcript is
                // stale. Do not let final discovery re-promote it, regardless
                // of whether the source is SQLite or legacy JSONL.
                return candidate
            }
            if !Self.isSQLiteSession(current), !current.events.isEmpty {
                let publishedStat = previewFileStatByID[candidate.id]
                    ?? current.sourceFileStat
                if let validation = revalidatedJSONLPublications[candidate.id],
                   publicationEpochBySessionID[candidate.id] == validation.publicationEpoch,
                   publishedStat == validation.fileStat {
                    return Self.session(current, retainingFilePath: candidate.filePath)
                }
                guard let publishedStat,
                      publishedStat == observedFileStats[candidate.id] else {
                    if publicationEpochBySessionID[candidate.id]
                        != handoffSnapshot.publicationEpochByID[candidate.id] {
                        // A newer full JSONL publication landed after the last
                        // off-actor proof pass. Preserve it rather than letting
                        // this older candidate downgrade the row; its own
                        // parse-time stat is the authoritative proof.
                        return Self.session(current, retainingFilePath: candidate.filePath)
                    }
                    // A full JSONL publication is preservable only while the
                    // file proof that produced its events is still current.
                    // Otherwise a newer mtime/stat must not be attached to the
                    // older transcript by this lightweight final merge.
                    return candidate
                }
            }
            if Self.isSQLiteSession(current), Self.isSQLiteSession(candidate) {
                guard let storageIdentity = current.sourceStorageIdentity,
                      storageIdentity == candidate.sourceStorageIdentity,
                      let observedVersion = observedSQLiteStorageVersions[storageIdentity] else {
                    return candidate
                }
                if current.sourceStorageDatabaseVersion != observedVersion {
                    // A newer same-generation full publication may have
                    // followed the final token sample. It is safe to retain
                    // only when that one row was revalidated off-actor
                    // against its own physical store and logical revision.
                    guard let validation = revalidatedSQLitePublications[candidate.id],
                          publicationEpochBySessionID[candidate.id] == validation.publicationEpoch,
                          current.sourceStorageRevision == validation.sourceStorageRevision,
                          current.sourceStorageDatabaseVersion == validation.databaseVersion else {
                        if publicationEpochBySessionID[candidate.id]
                            != handoffSnapshot.publicationEpochByID[candidate.id] {
                            // A publication landed after the last off-actor
                            // proof pass. Preserve that current row rather
                            // than downgrading it with this older candidate;
                            // the next refresh can reconcile an unresolved
                            // conflict without losing newer content.
                            return Self.session(current, retainingFilePath: candidate.filePath)
                        }
                        return candidate
                    }
                    return Self.session(current, retainingFilePath: candidate.filePath)
                }
                let sameRevisionHydratedCurrent = Self.isSameSQLiteStorageSnapshot(
                    current: current,
                    candidate: candidate)
                guard publicationAdvanced || sameRevisionHydratedCurrent else {
                    return candidate
                }
                // The current publication owns the content, while discovery
                // owns the current lexical path. Keeping the old alias here
                // would let final refresh resurrect a stale SQLite path.
                return Self.session(current, retainingFilePath: candidate.filePath)
            }
            guard publicationAdvanced || reloadProtectedIDs.contains(candidate.id) else {
                return candidate
            }
            return current
        }
    }

    /// Revalidate only the conflict rows whose full publication advanced after
    /// the final token sample. The MainActor handoff later checks that the
    /// publication epoch and row are still the same before using this result.
    private static func revalidatedNewerSQLitePublications(
        candidates: [Session],
        currentSnapshot: PublishedSessionSnapshot,
        baseEpochs: [String: UInt64],
        observedSQLiteStorageVersions: [String: String]
    ) -> [String: RevalidatedSQLitePublication] {
        var validatedPublications: [String: RevalidatedSQLitePublication] = [:]
        for candidate in candidates {
            guard isSQLiteSession(candidate),
                  let current = currentSnapshot.sessionsByID[candidate.id],
                  isSQLiteSession(current),
                  publishedStorageMatches(current, candidate),
                  let baseEpoch = baseEpochs[candidate.id],
                  currentSnapshot.publicationEpochByID[candidate.id] != baseEpoch,
                  let storageIdentity = current.sourceStorageIdentity,
                  let observedVersion = observedSQLiteStorageVersions[storageIdentity],
                  let currentVersion = current.sourceStorageDatabaseVersion,
                  currentVersion != observedVersion,
                  let expectedRevision = current.sourceStorageRevision,
                  let proof = OpenClawSqliteReader.sessionProof(for: current),
                  proof.storageIdentity == storageIdentity,
                  sessionRevisionKey(proof.revision) == expectedRevision,
                  proof.databaseVersionToken == currentVersion else {
                continue
            }
            guard let publicationEpoch = currentSnapshot.publicationEpochByID[candidate.id] else {
                continue
            }
            validatedPublications[candidate.id] = RevalidatedSQLitePublication(
                publicationEpoch: publicationEpoch,
                sourceStorageRevision: expectedRevision,
                databaseVersion: currentVersion)
        }
        return validatedPublications
    }

    /// Revalidate a newer full JSONL publication after the final handoff
    /// snapshot. Unlike SQLite, a JSONL row carries its parse-time file stat;
    /// compare that proof with a fresh off-actor stat before preserving it.
    private static func revalidatedNewerJSONLPublications(
        candidates: [Session],
        currentSnapshot: PublishedSessionSnapshot,
        baseEpochs: [String: UInt64]
    ) -> [String: RevalidatedJSONLPublication] {
        var validatedPublications: [String: RevalidatedJSONLPublication] = [:]
        for candidate in candidates {
            guard !isSQLiteSession(candidate),
                  let current = currentSnapshot.sessionsByID[candidate.id],
                  !isSQLiteSession(current),
                  !current.events.isEmpty,
                  publishedStorageMatches(current, candidate),
                  let baseEpoch = baseEpochs[candidate.id],
                  currentSnapshot.publicationEpochByID[candidate.id] != baseEpoch,
                  let publishedStat = currentSnapshot.fileStatsByID[candidate.id]
                    ?? current.sourceFileStat,
                  let currentStat = fileStat(for: URL(fileURLWithPath: current.filePath)),
                  publishedStat == currentStat,
                  let publicationEpoch = currentSnapshot.publicationEpochByID[candidate.id] else {
                continue
            }
            validatedPublications[candidate.id] = RevalidatedJSONLPublication(
                publicationEpoch: publicationEpoch,
                fileStat: publishedStat)
        }
        return validatedPublications
    }

    /// Capture one cheap database snapshot per distinct final SQLite store. The
    /// current full row keeps the logical transcript proof; this token rejects
    /// an intervening commit without re-hashing every loaded transcript.
    private struct SQLiteStorageProofStamp {
        let candidates: [Session]
        let versionsByIdentity: [String: String]
        let mismatchedIdentities: Set<String>
    }

    private static func stampSQLiteStorageVersionsForPublishedCurrent(
        candidates: [Session]
    ) -> SQLiteStorageProofStamp {
        var representativesByIdentity: [String: Session] = [:]
        for candidate in candidates where isSQLiteSession(candidate) {
            if let storageIdentity = candidate.sourceStorageIdentity {
                representativesByIdentity[storageIdentity] = candidate
            }
        }

        var observedTokensByIdentity: [String: String] = [:]
        observedTokensByIdentity.reserveCapacity(representativesByIdentity.count)
        for (storageIdentity, representative) in representativesByIdentity {
            if let token = OpenClawSqliteReader.storageRevisionToken(for: representative) {
                observedTokensByIdentity[storageIdentity] = token
            }
        }

        let mismatchedIdentities = Set<String>(representativesByIdentity.compactMap { storageIdentity, representative in
            guard let capturedVersion = representative.sourceStorageDatabaseVersion else {
                return nil
            }
            guard let observedVersion = observedTokensByIdentity[storageIdentity],
                  capturedVersion == observedVersion else {
                return storageIdentity
            }
            return nil
        })

        let stampedCandidates = candidates.map { candidate in
            guard let storageIdentity = candidate.sourceStorageIdentity,
                  candidate.sourceStorageDatabaseVersion == nil,
                  let observedToken = observedTokensByIdentity[storageIdentity] else {
                return candidate
            }
            var stamped = candidate
            stamped.sourceStorageDatabaseVersion = observedToken
            return stamped
        }
        return SQLiteStorageProofStamp(
            candidates: stampedCandidates,
            versionsByIdentity: observedTokensByIdentity,
            mismatchedIdentities: mismatchedIdentities)
    }

    private static func isLoadedSQLiteSession(_ current: Session, _ candidate: Session) -> Bool {
        isSQLiteSession(current)
            && isSQLiteSession(candidate)
            && !current.events.isEmpty
            && candidate.events.isEmpty
    }

    private static func isSameSQLiteStorageSnapshot(current: Session, candidate: Session) -> Bool {
        guard isSQLiteSession(current),
              isSQLiteSession(candidate),
              !current.events.isEmpty,
              candidate.events.isEmpty,
              let currentIdentity = current.sourceStorageIdentity,
              let candidateIdentity = candidate.sourceStorageIdentity,
              currentIdentity == candidateIdentity,
              let currentVersion = current.sourceStorageDatabaseVersion,
              let candidateVersion = candidate.sourceStorageDatabaseVersion else {
            return false
        }
        return currentVersion == candidateVersion
    }

    private func successfulReloadIsCurrent(for session: Session) -> Bool {
        let url = URL(fileURLWithPath: session.filePath)
        reloadLock.lock()
        let baselineRevision = lastFullReloadRevisionsBySessionID[session.id]
        let baselineStat = lastFullReloadFileStatsBySessionID[session.id]
        reloadLock.unlock()

        if OpenClawSqliteReader.isSupportedDatabaseURL(url) {
            guard let baselineRevision,
                  let currentRevision = OpenClawSqliteReader.sessionRevision(for: session) else {
                return false
            }
            return currentRevision == baselineRevision
        }
        guard let baselineStat,
              let currentStat = Self.fileStat(for: url) else {
            return false
        }
        return currentStat == baselineStat
    }

    private static func storagePathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let leftURL = URL(fileURLWithPath: lhs)
        let rightURL = URL(fileURLWithPath: rhs)
        if OpenClawSqliteReader.isSupportedDatabaseURL(leftURL)
            || OpenClawSqliteReader.isSupportedDatabaseURL(rightURL) {
            return canonicalSQLitePath(lhs) == canonicalSQLitePath(rhs)
        }
        return leftURL.standardizedFileURL.path == rightURL.standardizedFileURL.path
    }

    private static func standardizedStoragePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Compare already-proven session identities without touching the file
    /// system. This is the only storage comparison allowed on MainActor
    /// publication paths.
    private static func publishedStorageMatches(_ lhs: Session, _ rhs: Session) -> Bool {
        if isSQLiteSession(lhs) || isSQLiteSession(rhs) {
            guard let leftIdentity = lhs.sourceStorageIdentity,
                  let rightIdentity = rhs.sourceStorageIdentity else {
                return false
            }
            return leftIdentity == rightIdentity
        }
        return standardizedStoragePath(lhs.filePath) == standardizedStoragePath(rhs.filePath)
    }

    private static func stampSQLiteStorageIdentities(_ sessions: [Session]) -> [Session] {
        sessions.map { session in
            guard isSQLiteSession(session), session.sourceStorageIdentity == nil else {
                return session
            }
            var stamped = session
            stamped.sourceStorageIdentity = canonicalSQLitePath(session.filePath)
            return stamped
        }
    }

    private static func mergeKey(for session: Session) -> String {
        isSQLiteSession(session) ? "sqlite:\(session.id)" : "file:\(session.filePath)"
    }

    private static func needsOriginProjectReparse(_ session: Session) -> Bool {
        let label = session.repoName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return !originProjectLabels.contains(label)
    }

    @MainActor
    func isPreviewStale(id: String) -> Bool {
        guard let existing = allSessions.first(where: { $0.id == id }) else { return false }
        let cached = previewStaleByID[id] ?? false
        guard !previewStalenessChecksInFlight.contains(id) else { return cached }

        // SwiftUI asks this synchronously while rendering. Return the last
        // known answer immediately and move all filesystem/SQLite work to the
        // ingest queue; the published map below invalidates the view when the
        // new proof is ready.
        previewStalenessChecksInFlight.insert(id)
        let url = URL(fileURLWithPath: existing.filePath)
        let refreshToken = currentRefreshToken()
        let publicationEpoch = publicationEpochBySessionID[id] ?? 0
        let baselineRevision = previewRevisionByID[id]
        let baselineMTime = previewMTimeByID[id]
        let baselineFileStat = previewFileStatByID[id]
        let hasLoadedEvents = !existing.events.isEmpty
        let isSQLiteDatabase = OpenClawSqliteReader.isSupportedDatabaseURL(url)
        let bgQueue = FeatureFlags.backgroundIngestQueue
        bgQueue.async { [weak self] in
            guard let self else { return }
            let observedStorageIdentity = isSQLiteDatabase
                ? Self.canonicalSQLitePath(existing.filePath)
                : nil
            let currentRevision = isSQLiteDatabase
                ? OpenClawSqliteReader.sessionRevision(for: existing)
                : nil
            let currentMTime = isSQLiteDatabase
                ? nil
                : (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let currentFileStat = isSQLiteDatabase ? nil : Self.fileStat(for: url)
            let stale: Bool
            if isSQLiteDatabase {
                if let currentRevision {
                    if let baselineRevision {
                        stale = currentRevision != baselineRevision
                    } else if let sourceRevision = existing.sourceStorageRevision {
                        // A hydrated/full row may not have an entry in the
                        // sidecar baseline map yet. Its own captured revision
                        // is the only safe baseline to compare against.
                        stale = Self.sessionRevisionKey(currentRevision) != sourceRevision
                    } else {
                        // No row proof means a loaded transcript cannot be
                        // declared fresh. An empty lightweight row has no
                        // transcript to invalidate, so preserve only the
                        // previously published verdict in that case.
                        stale = cached || hasLoadedEvents
                    }
                } else {
                    // An unprovable read is not evidence of freshness. Keep a
                    // confirmed stale verdict and fail closed for a loaded
                    // transcript instead of clearing it during a retry.
                    stale = cached || hasLoadedEvents
                }
            } else {
                if let baselineFileStat, let currentFileStat {
                    stale = currentFileStat != baselineFileStat
                } else if baselineFileStat == nil || currentFileStat == nil {
                    // A full row without an exact parse proof cannot be
                    // declared fresh by a later mtime-only observation.
                    stale = cached || hasLoadedEvents
                } else {
                    stale = cached
                }
            }

            self.reloadLock.lock()
            let previewPublicationHook = self.previewStalenessBeforePublicationHookForTesting
                self.reloadLock.unlock()
                previewPublicationHook?()

            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.signalPreviewStalenessTerminalHookForTesting() }
                self.previewStalenessChecksInFlight.remove(id)
                guard self.isCurrentRefresh(refreshToken),
                      self.publicationEpochBySessionID[id] == publicationEpoch,
                      let current = self.allSessions.first(where: { $0.id == id }),
                      current.filePath == existing.filePath else { return }
                if isSQLiteDatabase {
                    guard let observedStorageIdentity,
                          current.sourceStorageIdentity == observedStorageIdentity else {
                        self.markLoadedPreviewStale(current, id: id)
                        return
                    }
                }
                if let currentRevision,
                   baselineRevision == nil,
                   let sourceRevision = current.sourceStorageRevision,
                   sourceRevision == Self.sessionRevisionKey(currentRevision) {
                    self.previewRevisionByID[id] = currentRevision
                }
                if let currentMTime, baselineMTime == nil {
                    self.previewMTimeByID[id] = currentMTime
                }
                if stale,
                   self.previewStaleByID[id] != true {
                    // A fresh proof that the published transcript is stale is
                    // itself a publication. Invalidate older preview/reload
                    // completions and remove text already known to be stale
                    // before exposing the verdict.
                    self.notePublishedStoragePaths([current])
                }
                if self.previewStaleByID[id] != stale {
                    self.previewStaleByID[id] = stale
                }
            }
        }
        return cached
    }

    @MainActor
    func refreshPreview(id: String) {
        guard let existing = allSessions.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: existing.filePath)
        let previewToken = currentRefreshToken()
        let publicationEpoch = self.publicationEpochBySessionID[id] ?? 0
        let previewGeneration = (refreshPreviewGenerationBySessionID[id] ?? 0) &+ 1
        refreshPreviewGenerationBySessionID[id] = previewGeneration
        let isSQLiteDatabase = OpenClawSqliteReader.isSupportedDatabaseURL(url)
        let databaseAgentID = isSQLiteDatabase ? Self.openClawAgentID(from: existing.id) : nil
        let bgQueue = FeatureFlags.backgroundIngestQueue
        bgQueue.async {
            let observedStorageIdentity = isSQLiteDatabase
                ? Self.canonicalSQLitePath(existing.filePath)
                : nil
            let beforeStat = isSQLiteDatabase ? nil : Self.fileStat(for: url)
            let lightProof = isSQLiteDatabase
                ? OpenClawSqliteReader.listSessionWithProof(
                    databaseURL: url,
                    agentID: databaseAgentID,
                    sessionID: existing.id)
                : nil
            let light = lightProof?.session
                ?? (isSQLiteDatabase ? nil : OpenClawSessionParser.parseFile(at: url, forcedID: existing.id))
            let afterStat = isSQLiteDatabase ? nil : Self.fileStat(for: url)
            let afterMTime = isSQLiteDatabase
                ? nil
                : (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let previewTranscripts = Self.transcriptCacheEntries(for: [existing])
            if isSQLiteDatabase {
                guard let lightProof,
                      let observedStorageIdentity,
                      lightProof.storageIdentity == observedStorageIdentity else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.signalRefreshPreviewTerminalHookForTesting() }
                        guard self.isCurrentRefresh(previewToken),
                              self.publicationEpochBySessionID[id] == publicationEpoch,
                              self.refreshPreviewGenerationBySessionID[id] == previewGeneration,
                              let current = self.allSessions.first(where: { $0.id == id }),
                              current.filePath == existing.filePath else { return }
                        self.markLoadedPreviewStale(current, id: id)
                    }
                    return
                }
            } else {
                guard let beforeStat,
                      let afterStat,
                      let light,
                      let parserStat = light.sourceFileStat,
                      beforeStat == afterStat,
                      parserStat == beforeStat else {
                    Task { @MainActor [weak self] in
                        self?.signalRefreshPreviewTerminalHookForTesting()
                    }
                    return
                }
            }
            self.reloadLock.lock()
            let previewRefreshHook = self.refreshPreviewAfterProofHookForTesting
            self.reloadLock.unlock()
            previewRefreshHook?()
            if let light {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.signalRefreshPreviewTerminalHookForTesting() }
                    guard self.isCurrentRefresh(previewToken),
                          self.publicationEpochBySessionID[id] == publicationEpoch,
                          self.refreshPreviewGenerationBySessionID[id] == previewGeneration,
                          let idx = self.allSessions.firstIndex(where: { $0.id == id }),
                          self.allSessions[idx].filePath == existing.filePath else { return }
                    let current = self.allSessions[idx]
                    let previewWasStale = self.previewStaleByID[id] == true
                    let canRetainJSONLEvents = isSQLiteDatabase
                        || current.events.isEmpty
                        || (!previewWasStale && self.previewFileStatByID[id] == afterStat)
                    if isSQLiteDatabase {
                        guard let lightProof,
                              current.sourceStorageIdentity == lightProof.storageIdentity else {
                            // Reject an A -> B -> A alias cycle and any write
                            // that landed after the focused read. Never stamp
                            // current metadata with a proof from another
                            // physical target.
                            self.markLoadedPreviewStale(current, id: id)
                            return
                        }
                        if !current.events.isEmpty,
                           current.sourceStorageRevision != Self.sessionRevisionKey(lightProof.revision) {
                            // The focused read observed a newer transcript
                            // than the events currently held by this row. Do
                            // not attach that proof to the old transcript.
                            // Publish the stale verdict as a new epoch so an
                            // older freshness scan cannot clear it afterward.
                            self.notePublishedStoragePaths([current])
                            self.previewStaleByID[id] = true
                            return
                        }
                    }
                    var merged = Session(
                        id: current.id,
                        source: .openclaw,
                        startTime: light.startTime ?? current.startTime,
                        endTime: light.endTime ?? current.endTime,
                        model: isSQLiteDatabase ? light.model : (light.model ?? current.model),
                        filePath: current.filePath,
                        fileSizeBytes: light.fileSizeBytes ?? current.fileSizeBytes,
                        eventCount: max(current.eventCount, light.eventCount),
                        events: canRetainJSONLEvents ? current.events : [],
                        cwd: current.lightweightCwd ?? light.lightweightCwd,
                        repoName: current.repoName ?? light.repoName,
                        lightweightTitle: isSQLiteDatabase
                            ? light.lightweightTitle
                            : (current.lightweightTitle ?? light.lightweightTitle),
                        lightweightCommands: current.lightweightCommands ?? light.lightweightCommands,
                        isHousekeeping: current.isHousekeeping,
                        deletedAt: current.deletedAt ?? light.deletedAt)
                    if isSQLiteDatabase, let lightProof {
                        merged.sourceStorageIdentity = lightProof.storageIdentity
                        merged.sourceStorageRevision = Self.sessionRevisionKey(lightProof.revision)
                        merged.sourceStorageDatabaseVersion = lightProof.databaseVersionToken
                    }
                    self.notePublishedStoragePaths([merged])
                    if canRetainJSONLEvents {
                        self.installTranscriptCacheEntries(previewTranscripts)
                    }
                    self.allSessions[idx] = merged
                    let publishedAsStale = !isSQLiteDatabase
                        && !canRetainJSONLEvents
                        && !current.events.isEmpty
                    self.previewStaleByID[id] = previewWasStale || publishedAsStale
                    if let lightProof {
                        self.previewRevisionByID[id] = lightProof.revision
                    }
                    if canRetainJSONLEvents, let afterMTime {
                        self.previewMTimeByID[id] = afterMTime
                    }
                    if canRetainJSONLEvents, !merged.events.isEmpty, let afterStat {
                        self.previewFileStatByID[id] = afterStat
                    } else if !isSQLiteDatabase {
                        self.previewFileStatByID.removeValue(forKey: id)
                    }
                }
            }
        }
    }

    // Update an existing session after full parse (used by SearchCoordinator).
    // SearchCoordinator delivers updates on MainActor, but SQLite proof and
    // transcript construction are deliberately kept off-actor so a search
    // completion cannot block list rendering.
    @MainActor
    func updateSession(_ updated: Session) {
        guard let current = allSessions.first(where: { $0.id == updated.id }) else {
            // Search can finish after an authoritative refresh retires the
            // session. Do not reseed a cache entry for a row that no longer
            // exists; a later reuse of the same logical ID must not see it.
            return
        }
        let refreshToken = currentRefreshToken()
        let publicationEpoch = publicationEpochBySessionID[updated.id] ?? 0
        let currentSnapshot = current
        let bgQueue = FeatureFlags.backgroundIngestQueue
        bgQueue.async { [weak self] in
            guard let self else { return }

            let isSQLite = Self.isSQLiteSession(currentSnapshot)
            let jsonlURL = URL(fileURLWithPath: currentSnapshot.filePath)
            let jsonlStatBefore = isSQLite ? nil : Self.fileStat(for: jsonlURL)
            var validatedJSONLStat: SessionFileStat?
            var accepted = updated
            var validatedSQLiteRevision: SessionTelemetryRevision?
            var validatedSQLiteDatabaseVersion: String?
            let expectedIdentity = updated.sourceStorageIdentity

            if isSQLite {
                guard let expectedIdentity,
                      let expectedRevision = updated.sourceStorageRevision,
                      Self.storagePathsMatch(currentSnapshot.filePath, updated.filePath) else {
                    // A SQLite parse without both same-snapshot proofs cannot
                    // be distinguished from a stale or retargeted alias.
                    return
                }
                let currentIdentity = currentSnapshot.sourceStorageIdentity
                    ?? Self.canonicalSQLitePath(currentSnapshot.filePath)
                guard currentIdentity == expectedIdentity,
                      let currentProof = OpenClawSqliteReader.sessionProof(for: currentSnapshot),
                      currentProof.storageIdentity == expectedIdentity,
                      Self.sessionRevisionKey(currentProof.revision) == expectedRevision else {
                    // Reject closed instead of publishing content or seeding
                    // the transcript cache from an unproven store.
                    return
                }
                validatedSQLiteRevision = currentProof.revision
                validatedSQLiteDatabaseVersion = currentProof.databaseVersionToken
                accepted = Self.session(updated, retainingFilePath: currentSnapshot.filePath)
                accepted.sourceStorageDatabaseVersion = validatedSQLiteDatabaseVersion
            } else {
                guard Self.storagePathsMatch(currentSnapshot.filePath, updated.filePath),
                      let parseTimeJSONLStat = updated.sourceFileStat,
                      let jsonlStatBefore,
                      let jsonlStatAfter = Self.fileStat(for: jsonlURL),
                      parseTimeJSONLStat == jsonlStatBefore,
                      jsonlStatBefore == jsonlStatAfter else {
                    // Search can finish after discovery moves the session to a
                    // different store or after the parser's file version has
                    // been replaced. The parse-time proof, not these later
                    // validation reads, must authorize publication.
                    return
                }
                validatedJSONLStat = parseTimeJSONLStat
            }

            let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                session: accepted,
                filters: filters,
                mode: .normal)
            let prepared = accepted

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentRefresh(refreshToken),
                      self.publicationEpochBySessionID[updated.id] == publicationEpoch,
                      let idx = self.allSessions.firstIndex(where: { $0.id == updated.id }) else {
                    return
                }
                let current = self.allSessions[idx]
                var published = prepared
                if isSQLite {
                    guard let expectedIdentity,
                          current.sourceStorageIdentity == expectedIdentity else {
                        return
                    }
                    published = Self.session(prepared, retainingFilePath: current.filePath)
                } else {
                    guard Self.standardizedStoragePath(current.filePath)
                            == Self.standardizedStoragePath(currentSnapshot.filePath) else {
                        return
                    }
                }
                self.notePublishedStoragePaths([published])
                self.transcriptCache.set(published.id, transcript: transcript)
                self.allSessions[idx] = published
                self.previewStaleByID[published.id] = false
                if let validatedJSONLStat {
                    self.previewFileStatByID[published.id] = validatedJSONLStat
                    self.previewMTimeByID[published.id] = Date(
                        timeIntervalSince1970: Double(validatedJSONLStat.mtime) / 1_000_000_000)
                }
                if let validatedSQLiteRevision {
                    self.previewRevisionByID[accepted.id] = validatedSQLiteRevision
                }
            }
        }
    }

    private static func sessionRevisionKey(_ revision: SessionTelemetryRevision) -> String {
        switch revision {
        case .file(let signature):
            return "file:\(signature.mtime):\(signature.size)"
        case .logical(let value):
            return "logical:\(value)"
        }
    }

    private static func openClawAgentID(from sessionID: String) -> String? {
        guard sessionID.hasPrefix("openclaw:") else { return nil }
        let parts = sessionID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let agentID = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return agentID.isEmpty ? nil : agentID
    }

    private static func transcriptCacheEntries(for sessions: [Session]) -> [String: String] {
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        return sessions.reduce(into: [String: String]()) { result, session in
            guard !session.events.isEmpty else { return }
            result[session.id] = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                session: session,
                filters: filters,
                mode: .normal)
        }
    }

    // MARK: - File Stat Persistence

    private func hasKnownFileStats() -> Bool {
        fileStatsLock.lock()
        let hasStats = !lastKnownFileStatsByPath.isEmpty
        fileStatsLock.unlock()
        return hasStats
    }

    private func initializeKnownFileStatsIfNeeded(_ stats: [String: SessionFileStat]) {
        fileStatsLock.lock()
        if lastKnownFileStatsByPath.isEmpty {
            lastKnownFileStatsByPath = stats
        }
        fileStatsLock.unlock()
    }

    private func knownFileStatsSnapshot() -> [String: SessionFileStat] {
        fileStatsLock.lock()
        let snapshot = lastKnownFileStatsByPath
        fileStatsLock.unlock()
        return snapshot
    }

    private func applyKnownFileStatsDelta(_ delta: SessionDiscoveryDelta) {
        fileStatsLock.lock()
        lastKnownFileStatsByPath = delta.currentByPath
        fileStatsLock.unlock()
    }

    private func bootstrapKnownFileStatsIfNeeded(from sessions: [Session]) {
        if hasKnownFileStats() { return }
        guard !sessions.isEmpty else { return }
        var map: [String: SessionFileStat] = [:]
        map.reserveCapacity(sessions.count)
        for session in sessions {
            let url = URL(fileURLWithPath: session.filePath)
            if let stat = SessionFileStat.from(url) {
                map[session.filePath] = stat
            } else {
                let size = Int64(max(0, session.fileSizeBytes ?? 0))
                let mtime = Int64(max(0, session.modifiedAt.timeIntervalSince1970))
                map[session.filePath] = SessionFileStat(mtime: mtime, size: size)
            }
        }
        initializeKnownFileStatsIfNeeded(map)
    }

    private func seedKnownFileStatsIfNeeded() async {
        if hasKnownFileStats() { return }
        do {
            if let persisted = try await loadPersistedKnownFileStats() {
                initializeKnownFileStatsIfNeeded(persisted)
                os_log("OpenClaw: seeded file stats from persisted baseline (%d entries)", log: indexLog, type: .info, persisted.count)
            }
        } catch {
            os_log("OpenClaw: seedKnownFileStats failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
        }
    }

    private func persistedFileStatsJSON(for stats: [String: SessionFileStat]) -> String? {
        let payload = PersistedFileStatPayload(
            version: 1,
            stats: stats.reduce(into: [:]) { partial, entry in
                partial[entry.key] = PersistedFileStat(mtime: entry.value.mtime, size: entry.value.size)
            }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
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
}

// MARK: - SessionIndexerProtocol Conformance
extension OpenClawSessionIndexer: SessionIndexerProtocol {}

import Foundation
import Combine
import AppKit

// Actor for thread-safe promotion state
private actor PromotionState {
    private var promotedID: String?

    func setPromoted(id: String) {
        promotedID = id
    }

    func consumePromoted() -> String? {
        let id = promotedID
        promotedID = nil
        return id
    }
}

/// Coalesces provider membership/classification bursts into one active-query restart.
/// The view owns one instance and routes every dataset-driven restart through it, so
/// a provider refresh that publishes several intermediate snapshots does not launch
/// and cancel several identical searches.
@MainActor
final class SearchDatasetRestartCoalescer: ObservableObject {
    private var pendingTask: Task<Void, Never>?

    func schedule(after delay: TimeInterval = 0.08, action: @escaping () -> Void) {
        pendingTask?.cancel()
        let delayNanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.pendingTask = nil
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}

final class SearchCoordinator: ObservableObject, @unchecked Sendable {
    struct SessionKey: Hashable, Sendable {
        let source: SessionSource
        let id: String

        init(source: SessionSource, id: String) {
            self.source = source
            self.id = id
        }

        init(_ session: Session) {
            source = session.source
            id = session.id
        }
    }

    struct Progress: Equatable {
        enum Phase {
            case idle
            case indexed
            case legacySmall
            case legacyLarge
            case unindexedSmall
            case unindexedLarge
            case toolOutputsSmall
            case toolOutputsLarge
        }
        var phase: Phase = .idle
        var scannedSmall: Int = 0
        var totalSmall: Int = 0
        var scannedLarge: Int = 0
        var totalLarge: Int = 0
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var wasCanceled: Bool = false
    @Published private(set) var results: [Session] = []
    @Published private(set) var progress: Progress = .init()
    @Published private(set) var deepScanEnabled: Bool = false

    private var currentTask: Task<Void, Never>? = nil
    private var deepScanTask: Task<Void, Never>? = nil
    private let store: SearchSessionStoring
    private let db: IndexDB?
    private let ftsResultLimitForTesting: Int?
    // Promotion support for large-queue preemption
    private let promotionState = PromotionState()
    // Generation token to ignore stale appends after cancel/restart
    private var runID = UUID()
    // When a dataset-triggered refresh preserves old results, this holds the
    // run that owns the single replacing publication. Cleared when that run's
    // first publication replaces (or when a newer run starts).
    private var preservedReplacementRunID: UUID? = nil
    /// Consumes the single replacing publication for `runID`. Returns true
    /// exactly once per preserving run: the caller's publication is the first
    /// and must replace. Later publications append. Stale runs never consume.
    @MainActor
    private func consumePreservedReplacement(for runID: UUID) -> Bool {
        guard preservedReplacementRunID == runID else { return false }
        preservedReplacementRunID = nil
        return true
    }
    private var prewarmInFlight: Set<String> = []
    private var prewarmTasksByID: [String: Task<Void, Never>] = [:]
    private var appIsActive: Bool = true
    // Throttle guards for progress updates
    private var progressThrottleLastFlush = DispatchTime.now()

    init(store: SearchSessionStoring) {
        self.store = store
        // A failed open silently disables DB-backed search (the legacy scan path still
        // runs), and schema migration failure is the way that happens. Surface it instead
        // of swallowing it: loud in DEBUG, logged in release.
        do {
            self.db = try IndexDB()
        } catch {
            self.db = nil
            LaunchProfiler.log("SearchCoordinator: IndexDB unavailable, falling back to legacy search — \(error)")
            assertionFailure("SearchCoordinator could not open IndexDB: \(error)")
        }
        self.ftsResultLimitForTesting = nil
    }

    /// Test seam for exercising the actual FTS/fallback coordinator against an
    /// isolated database rather than the user's application index.
    init(store: SearchSessionStoring, db: IndexDB?, ftsResultLimitForTesting: Int? = nil) {
        self.store = store
        self.db = db
        self.ftsResultLimitForTesting = ftsResultLimitForTesting
    }

    deinit {
        currentTask?.cancel()
        deepScanTask?.cancel()
        prewarmTasksByID.values.forEach { $0.cancel() }
    }

    @MainActor
    func setAppActive(_ active: Bool) {
        appIsActive = active
        if !active {
            cancel(clearResults: false)
            prewarmTasksByID.values.forEach { $0.cancel() }
            prewarmTasksByID.removeAll()
            prewarmInFlight.removeAll()
        }
    }

    // Get appropriate transcript cache based on session source
    private func transcriptCache(for source: SessionSource) -> TranscriptCache? {
        store.transcriptCache(for: source)
    }

    private func deepToolOutputsEnabled() -> Bool {
        // Default OFF unless the user explicitly opts in.
        if UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch) == nil { return false }
        return UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch)
    }

    private func toolIOIndexEnabled() -> Bool {
        // Default OFF unless the user explicitly opts in.
        if UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex)
    }

    func cancel() {
        cancel(clearResults: true)
    }

    private func cancel(clearResults: Bool) {
        currentTask?.cancel()
        currentTask = nil
        deepScanTask?.cancel()
        deepScanTask = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runID = UUID()
            self.isRunning = false
            self.wasCanceled = true
            self.deepScanEnabled = false
            self.progress = .init()
            if clearResults {
                self.results = []
            }
        }
    }

    // Promote a large session to be processed next in the large queue if present.
    func promote(id: String) {
        Task {
            await promotionState.setPromoted(id: id)
        }
    }

    func prewarmTranscriptIfNeeded(for session: Session, allowParsingLightweight: Bool = true) {
        if !allowParsingLightweight, session.events.isEmpty { return }
        if !appIsActive { return }
        if !NSApp.isActive { return }
        guard let cache = transcriptCache(for: session.source) else { return }
        if cache.getCached(session.id) != nil { return }
        if prewarmInFlight.contains(session.id) { return }
        if prewarmTasksByID[session.id] != nil { return }
        prewarmInFlight.insert(session.id)

        let sessionSnapshot = session
        let task = Task.detached(priority: .utility) { [weak self] in
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.prewarmInFlight.remove(sessionSnapshot.id)
                    self?.prewarmTasksByID[sessionSnapshot.id] = nil
                }
            }

            if FeatureFlags.gatePrewarmWhileTyping, TypingActivity.shared.isUserLikelyTyping {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }

            var target = sessionSnapshot
            if target.events.isEmpty, let parsed = await self?.store.parseFull(session: target) {
                target = parsed
                if !FeatureFlags.disableSessionUpdatesDuringSearch {
                    self?.store.updateSession(parsed)
                }
            }

            await cache.generateAndCache(sessions: [target])
        }
        prewarmTasksByID[session.id] = task
    }

    /// Runs a search over `all`, restricted to the sessions whose source is in `allowed`.
    ///
    /// `allowed` used to arrive as twelve hand-maintained `include<Provider>` Bools that this
    /// method funnelled back into exactly this set. Callers now pass the set itself — in the
    /// app, `UnifiedSessionIndexer.allowedSearchSources()` (SPEC §3.5/§8.5), which applies one
    /// enabled-and-included policy to every source instead of per-call-site subsets.
    func start(query: String,
               filters: Filters,
               allowed: Set<SessionSource>,
               enableDeepScan: Bool,
               all: [Session],
               effectiveDisplayTitles: [SessionKey: String] = [:],
               preserveResultsUntilRefreshPublishes: Bool = false) {
        // Cancel any in-flight search
        currentTask?.cancel()
        deepScanTask?.cancel()
        deepScanTask = nil
        wasCanceled = false
        let newRunID = UUID()
        runID = newRunID
        preservedReplacementRunID = preserveResultsUntilRefreshPublishes ? newRunID : nil
        // Immutable snapshot of effective displayed titles for this run. The
        // caller may provide Claude archive sidecar titles; absence falls back
        // to `session.listTitle`. Dictionary capture is a value copy.
        let titleOverrides = effectiveDisplayTitles

        let parsedForMetadata = FilterEngine.parseOperators(filters.query)
        let metadataFreeText = parsedForMetadata.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataRepo = filters.repoName ?? parsedForMetadata.repo
        let metadataPath = filters.pathContains ?? parsedForMetadata.path
        let metadataSideChatsOnly = filters.sideChatsOnly || parsedForMetadata.sideChatsOnly
        let hasMetadataOnlyFilters = filters.model != nil ||
            filters.dateFrom != nil ||
            filters.dateTo != nil ||
            metadataRepo != nil ||
            metadataPath != nil ||
            metadataSideChatsOnly ||
            filters.selectedProjectIdentity != nil
        if metadataFreeText.isEmpty, hasMetadataOnlyFilters {
            let candidates = Self.candidates(from: all, allowed: allowed, filters: filters)
            let out = Self.metadataFilteredCandidates(candidates,
                                                        filters: filters,
                                                        effectiveRepo: metadataRepo,
                                                        effectivePath: metadataPath,
                                                        effectiveSideChatsOnly: metadataSideChatsOnly,
                                                        effectiveProjectIdentity: filters.selectedProjectIdentity)
            Task { @MainActor [weak self] in
                guard let self, self.runID == newRunID else { return }
                self.results = out
                _ = self.consumePreservedReplacement(for: newRunID)
                self.isRunning = false
                self.progress = .init()
            }
            return
        }
        
        // Phase 0: fast path via SQLite FTS if available.
        // NOTE: no standalone clear task here. The running-state clear runs as
        // the first ordered hop inside each worker task below, so the
        // clear-then-seed ordering is deterministic per run: a clear can never
        // land after (and wipe) seeded title results.
        if FeatureFlags.enableFTSSearch, let db = db {
            // Cursor sessions are not indexed in the FTS database — exclude from FTS queries
            // so they fall through to the unindexed/legacy transcript-cache search path.
            let ftsAllowed = allowed.filter { $0 != .cursor }
            let allowedRaw = ftsAllowed.map { $0.rawValue }
            let parsed = FilterEngine.parseOperators(filters.query)
            let freeText = parsed.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveFTSQuery = Self.makeInstantFTSQuery(from: freeText)
            let effectiveRepo = filters.repoName ?? parsed.repo
            let effectivePath = filters.pathContains ?? parsed.path
            let effectiveSideChatsOnly = filters.sideChatsOnly || parsed.sideChatsOnly
            let hasMetaFilters = (filters.model != nil) || (filters.dateFrom != nil) || (filters.dateTo != nil) || (effectiveRepo != nil) || (effectivePath != nil) || effectiveSideChatsOnly || filters.selectedProjectIdentity != nil
            let includeSystemProbes = UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions")

            let prio: TaskPriority = FeatureFlags.lowerQoSForInteractiveSearch ? .utility : .userInitiated
            currentTask = Task.detached(priority: prio) { [weak self, newRunID, titleOverrides] in
                guard let self else { return }
                // Ordered running-state initialization for this run. Every later
                // results write on this task is sequenced after this hop, so the
                // clear cannot race ahead of seeded title results.
                await MainActor.run {
                    guard self.runID == newRunID else { return }
                    self.isRunning = true
                    self.deepScanEnabled = enableDeepScan
                    if self.preservedReplacementRunID != newRunID {
                        self.results = []
                    }
                    self.progress = .init(phase: .indexed, scannedSmall: 0, totalSmall: 0, scannedLarge: 0, totalLarge: 0)
                }
                if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
                let hasData = (try? await db.hasSearchData(sources: allowedRaw)) ?? false
                if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
                guard hasData else {
                    // Fall back to legacy search until the DB is warmed, but seed
                    // cheap effective-title matches so title correctness never
                    // depends on DB warmup. Legacy appends without wiping them.
                    let fallbackCandidates = Self.candidates(from: all, allowed: allowed, filters: filters)
                    let fallbackSearchable = Self.metadataFilteredCandidates(fallbackCandidates,
                                                                              filters: filters,
                                                                              effectiveRepo: effectiveRepo,
                                                                              effectivePath: effectivePath,
                                                                              effectiveSideChatsOnly: effectiveSideChatsOnly,
                                                                              effectiveProjectIdentity: filters.selectedProjectIdentity)
                    let seededTitles = Self.cheapEffectiveTitleMatches(in: fallbackSearchable,
                                                                        freeText: freeText,
                                                                        overrides: titleOverrides)
                    if !seededTitles.isEmpty {
                        await MainActor.run {
                            guard self.runID == newRunID else { return }
                            self.results = seededTitles
                            _ = self.consumePreservedReplacement(for: newRunID)
                        }
                    }
                    if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
                    await self.startLegacySearch(runID: newRunID,
                                                 query: query,
                                                 filters: filters,
                                                 allowed: allowed,
                                                 all: all,
                                                 allowDeepScan: enableDeepScan,
                                                 initialSeen: Set(seededTitles.map(SessionKey.init)),
                                                 replaceFirstPublication: preserveResultsUntilRefreshPublishes && seededTitles.isEmpty)
                    return
                }

                let candidates = Self.candidates(from: all, allowed: allowed, filters: filters)
                let searchableCandidates = Self.metadataFilteredCandidates(candidates,
                                                                            filters: filters,
                                                                            effectiveRepo: effectiveRepo,
                                                                            effectivePath: effectivePath,
                                                                            effectiveSideChatsOnly: effectiveSideChatsOnly,
                                                                            effectiveProjectIdentity: filters.selectedProjectIdentity)
                var byKey: [SessionKey: Session] = [:]
                byKey.reserveCapacity(searchableCandidates.count)
                for session in searchableCandidates { byKey[SessionKey(session)] = session }

                // If there's no free-text component, prefer in-memory filtering for correctness even
                // when the DB is only partially populated.
                if freeText.isEmpty, hasMetaFilters {
                    let out = FilterEngine.filterSessions(candidates, filters: filters, transcriptCache: nil, allowTranscriptGeneration: false)
                    await MainActor.run {
                        guard self.runID == newRunID else { return }
                        self.results = out
                        self.isRunning = false
                        self.progress.phase = .idle
                    }
                    return
                }

                if !freeText.isEmpty {
                    // The analytics-backed DB can be partially populated during warmup.
                    // Use FTS for indexed sessions, then fall back to legacy matching for unindexed ones.
                    // Currency-aware membership (not presence-only): a session counts as "indexed" only
                    // while its `session_search` row still matches the file's current mtime/size. A hot,
                    // actively-appending file whose re-ingest is throttled (quiet gate + size cooldown in
                    // SearchIngestService) drops out of this set, so shouldIncludeUnindexedCandidate lets
                    // the legacy full-scan pick it up and return FRESH text instead of stale FTS rows.
                    var indexedKeys: Set<SessionKey> = []
                    var presentKeys: Set<SessionKey> = []
                    for source in ftsAllowed {
                        let current = (try? await db.indexedSessionIDsCurrent(sources: [source.rawValue])) ?? []
                        indexedKeys.formUnion(current.map { SessionKey(source: source, id: $0) })
                        let present = (try? await db.indexedSessionIDs(sources: [source.rawValue])) ?? []
                        presentKeys.formUnion(present.map { SessionKey(source: source, id: $0) })
                    }
                    // Shared-database sessions use their lightweight per-session update
                    // revision instead of the database file's global stat. Overlay those
                    // identities onto the path-current set so a WAL-only update becomes
                    // stale immediately without invalidating every sibling session.
                    let identitySessions = all.filter { session in
                        guard allowed.contains(session.source) else { return false }
                        let url = URL(fileURLWithPath: session.filePath)
                        let descriptor = session.source.descriptor
                        return descriptor.parseFullByIdentity != nil
                            && descriptor.searchUsesIdentityAtURL?(url) == true
                    }
                    for session in identitySessions { indexedKeys.remove(SessionKey(session)) }
                    for group in Dictionary(grouping: identitySessions, by: \.source) {
                        let states = (try? await db.sessionSearchIdentityStatesByID(for: group.key.rawValue)) ?? [:]
                        for session in group.value
                        where states[session.id]?.storagePath == session.filePath
                            && states[session.id].map({
                                SearchIngestService.contentRevision($0.revision, matches: session)
                            }) == true {
                            indexedKeys.insert(SessionKey(session))
                        }
                    }
                    // Present-but-not-current: sessions with a session_search row whose stored mtime/size
                    // no longer matches the file (re-ingest throttled). These have stale/no FTS coverage and
                    // must be scanned regardless of size (see shouldIncludeUnindexedCandidate).
                    let staleKeys = presentKeys.subtracting(indexedKeys)
                    // In-memory candidate eligible scope: an exact project
                    // selection or an archived-Claude-only search must both bind
                    // the DB result window to the exact metadata-filtered
                    // candidates before FTS LIMIT, or unrelated high-ranked rows
                    // consume it. Out-of-scope present rows join the ineligible
                    // set so the SQL LIMIT bounds the filtered ranking. Uses
                    // only the existing eligible/ineligible coordinator
                    // mechanism; DB.swift is untouched.
                    let needsCandidateScope = filters.selectedProjectIdentity != nil
                        || filters.archivedClaudeDesktopOnly
                    let candidateScopedKeys: Set<SessionKey>? = needsCandidateScope
                        ? Set(searchableCandidates.map(SessionKey.init))
                        : nil
                    var ftsEligibleKeys = indexedKeys
                    var ftsIneligibleKeys = staleKeys
                    if let scoped = candidateScopedKeys {
                        ftsEligibleKeys = ftsEligibleKeys.intersection(scoped)
                        ftsIneligibleKeys = ftsIneligibleKeys.union(presentKeys.subtracting(scoped))
                    }
                    let ftsEligibleIDs = Set(ftsEligibleKeys.map(\.id))
                    let ftsIneligibleIDs = Set(ftsIneligibleKeys.map(\.id))
                    let ftsOwnerByID = Dictionary(uniqueKeysWithValues: presentKeys.map { ($0.id, $0) })
                    // Cheap effective-title matches are correctness results: they
                    // derive only from already metadata-filtered candidates and
                    // never depend on FTS currency, capacity, edits, or reindex.
                    let titleMatches = Self.cheapEffectiveTitleMatches(in: searchableCandidates,
                                                                        freeText: freeText,
                                                                        overrides: titleOverrides)
                    let titleOnlyKeys = Set(titleMatches.map(SessionKey.init))
                    if ftsEligibleKeys.isEmpty {
                        if !titleMatches.isEmpty {
                            await MainActor.run {
                                guard self.runID == newRunID else { return }
                                self.results = titleMatches
                                _ = self.consumePreservedReplacement(for: newRunID)
                            }
                        }
                        if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
                        await self.startLegacySearch(runID: newRunID,
                                                     query: query,
                                                     filters: filters,
                                                     allowed: allowed,
                                                     all: all,
                                                     allowDeepScan: enableDeepScan,
                                                     initialSeen: titleOnlyKeys,
                                                     replaceFirstPublication: preserveResultsUntilRefreshPublishes && titleMatches.isEmpty)
                        return
                    }

                    let dbResultLimit = self.ftsResultLimitForTesting
                        ?? Self.ftsResultLimit(filters: filters,
                                               effectiveRepo: effectiveRepo,
                                               totalSessionCount: all.count)
                    // Filter currency while stepping one SQLite statement. This both fills
                    // the post-filter result window and keeps the scan on one read snapshot,
                    // so concurrent identity cleanup cannot shift an OFFSET between pages.
                    let ids = (try? await db.searchSessionIDsFTS(
                        sources: allowedRaw,
                        model: filters.model,
                        repoSubstr: nil,
                        pathSubstr: effectivePath,
                        dateFrom: filters.dateFrom,
                        dateTo: filters.dateTo,
                        query: effectiveFTSQuery,
                        includeSystemProbes: includeSystemProbes,
                        limit: dbResultLimit,
                        eligibleSessionIDs: ftsEligibleIDs,
                        ineligibleSessionIDs: ftsIneligibleIDs
                    )) ?? []
                    if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }

                    let deepEnabled = enableDeepScan && self.deepToolOutputsEnabled()
                    var mergedKeys = ids.compactMap { ftsOwnerByID[$0] }
                    var mergedSet = Set(mergedKeys)
                    // Title-only hits stay outside FTS capacity accounting so
                    // title correctness never depends on the FTS result limit.
                    // mergedSet stays FTS-only; `seen` tracks the full union.
                    // Dedupe against published FTS sessions (byID-filtered), not
                    // raw FTS IDs, so a title is never dropped when its FTS row
                    // exists but the session fell outside the metadata window.
                    let ftsInitial = mergedKeys.compactMap { byKey[$0] }
                    let ftsInitialKeys = Set(ftsInitial.map(SessionKey.init))
                    let titleOnlyInitial = titleMatches.filter { !ftsInitialKeys.contains(SessionKey($0)) }
                    var out = ftsInitial + titleOnlyInitial
                    var seen = Set(out.map(SessionKey.init))
                    let initialOut = out
                    await MainActor.run {
                        guard self.runID == newRunID else { return }
                        self.results = initialOut
                        _ = self.consumePreservedReplacement(for: newRunID)
                    }
                    if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }

                    // Append tool I/O FTS hits after the initial UI update to keep Instant responsive.
                    if self.toolIOIndexEnabled(), mergedKeys.count < dbResultLimit {
                        var currentToolIOKeys: Set<SessionKey> = []
                        var presentToolIOKeys: Set<SessionKey> = []
                        for source in ftsAllowed {
                            let current = (try? await db.indexedToolIOSessionIDsCurrent(sources: [source.rawValue])) ?? []
                            currentToolIOKeys.formUnion(current.map { SessionKey(source: source, id: $0) })
                            let present = (try? await db.toolIOSessionIDs(sources: [source.rawValue])) ?? []
                            presentToolIOKeys.formUnion(present.map { SessionKey(source: source, id: $0) })
                        }
                        for session in identitySessions { currentToolIOKeys.remove(SessionKey(session)) }
                        for group in Dictionary(grouping: identitySessions, by: \.source) {
                            let states = (try? await db.sessionToolIOIdentityStatesByID(for: group.key.rawValue)) ?? [:]
                            for session in group.value
                            where states[session.id]?.storagePath == session.filePath
                                && states[session.id].map({
                                    SearchIngestService.contentRevision($0.revision, matches: session)
                                }) == true {
                                currentToolIOKeys.insert(SessionKey(session))
                            }
                        }
                        // Present-but-not-current tool I/O rows: the exact complement of the
                        // eligible set inside the tool I/O corpus, so the SQL LIMIT can bound
                        // the filtered ranking instead of the unfiltered one.
                        let staleToolIOKeys = presentToolIOKeys.subtracting(currentToolIOKeys)
                        var toolEligibleKeys = currentToolIOKeys
                        var toolIneligibleKeys = staleToolIOKeys
                        if let scoped = candidateScopedKeys {
                            toolEligibleKeys = toolEligibleKeys.intersection(scoped)
                            toolIneligibleKeys = toolIneligibleKeys.union(presentToolIOKeys.subtracting(scoped))
                        }
                        let toolEligibleIDs = Set(toolEligibleKeys.map(\.id))
                        let toolIneligibleIDs = Set(toolIneligibleKeys.map(\.id))
                        let toolOwnerByID = Dictionary(uniqueKeysWithValues: presentToolIOKeys.map { ($0.id, $0) })
                        let toolResultLimit = dbResultLimit - mergedKeys.count
                        // Exclude ordinary hits before applying capacity; otherwise a top
                        // tool match that is already present consumes the remaining slot and
                        // hides the next unique tool-only result.
                        let toolIDs = (try? await db.searchSessionIDsToolIOFTS(
                            sources: allowedRaw,
                            model: filters.model,
                            repoSubstr: nil,
                            pathSubstr: effectivePath,
                            dateFrom: filters.dateFrom,
                            dateTo: filters.dateTo,
                            query: effectiveFTSQuery,
                            includeSystemProbes: includeSystemProbes,
                            limit: toolResultLimit,
                            eligibleSessionIDs: toolEligibleIDs,
                            ineligibleSessionIDs: toolIneligibleIDs,
                            excludingSessionIDs: Set(mergedKeys.compactMap { key in
                                toolOwnerByID[key.id] == key ? key.id : nil
                            })
                        )) ?? []
                        var addedAny = false
                        for id in toolIDs {
                            if mergedKeys.count >= dbResultLimit { break }
                            guard let key = toolOwnerByID[id] else { continue }
                            if mergedSet.insert(key).inserted {
                                mergedKeys.append(key)
                                addedAny = true
                            }
                        }
                        if addedAny {
                            // Re-union FTS hits (ordinary + tool, ranked) with the
                            // cheap title matches so title correctness never
                            // disappears when tool-I/O results publish.
                            let ftsOut = mergedKeys.compactMap { byKey[$0] }
                            let ftsOutKeys = Set(ftsOut.map(SessionKey.init))
                            let titleOnlyDeduped = titleMatches.filter { !ftsOutKeys.contains(SessionKey($0)) }
                            let updated = ftsOut + titleOnlyDeduped
                            await MainActor.run {
                                guard self.runID == newRunID else { return }
                                self.results = updated
                            }
                            out = updated
                            seen = Set(updated.map(SessionKey.init))
                        }
                    }

                    // Always include Cursor sessions in unindexed candidates (they have no FTS index).
                    // Also include non-large unindexed rows so restored/lightweight sessions remain
                    // content-searchable while their FTS rows are still missing or warming.
                    let smallSearchThreshold = FeatureFlags.searchSmallSizeBytes
                    let unindexedCandidates = searchableCandidates.filter {
                        Self.shouldIncludeUnindexedCandidate($0,
                                                             indexedIDs: indexedKeys,
                                                             seenIDs: seen,
                                                             enableDeepScan: enableDeepScan,
                                                             smallSearchThreshold: smallSearchThreshold,
                                                             staleIDs: staleKeys)
                    }
                    let deepCandidates = deepEnabled
                        ? searchableCandidates.filter {
                            indexedKeys.contains(SessionKey($0))
                                && !seen.contains(SessionKey($0))
                                && Self.shouldDeepScan(session: $0)
                        }
                        : []

                    let shouldRunUnindexed = !unindexedCandidates.isEmpty
                    let shouldRunDeep = !deepCandidates.isEmpty
                    if !shouldRunUnindexed && !shouldRunDeep {
                        await MainActor.run {
                            guard self.runID == newRunID else { return }
                            self.isRunning = false
                            self.progress.phase = .idle
                        }
                        return
                    }

                    self.startBackgroundDeepScan(
                        runID: newRunID,
                        query: query,
                        filters: filters,
                        unindexedCandidates: unindexedCandidates,
                        deepCandidates: deepCandidates,
                        initialSeen: seen
                    )
                    return
                }

                if hasMetaFilters {
                    let ids = (try? await db.prefilterSessionIDs(
                        sources: allowedRaw,
                        model: filters.model,
                        repoSubstr: effectiveRepo,
                        pathSubstr: effectivePath,
                        dateFrom: filters.dateFrom,
                        dateTo: filters.dateTo,
                        limit: FeatureFlags.ftsSearchLimit
                    )) ?? []
                    if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }

                    var byID: [String: Session] = [:]
                    byID.reserveCapacity(all.count)
                    for s in all { byID[s.id] = s }
                    let out = ids.compactMap { byID[$0] }
                    await MainActor.run {
                        guard self.runID == newRunID else { return }
                        self.results = out
                        _ = self.consumePreservedReplacement(for: newRunID)
                        self.isRunning = false
                        self.progress.phase = .idle
                    }
                    return
                }

                // Nothing to search.
                await MainActor.run {
                    guard self.runID == newRunID else { return }
                    self.results = []
                    _ = self.consumePreservedReplacement(for: newRunID)
                    self.isRunning = false
                    self.progress.phase = .idle
                }
            }
            return
        }

        // Launch orchestration (no FTS: feature flag off or no DB). Seed cheap
        // effective-title matches so title correctness never depends on the index.
        Task { [weak self, titleOverrides] in
            guard let self else { return }
            // Same ordered initialization as the FTS path: clear first on this
            // task, so seeded titles below cannot be wiped by a racing clear.
            await MainActor.run {
                guard self.runID == newRunID else { return }
                self.isRunning = true
                self.deepScanEnabled = enableDeepScan
                if self.preservedReplacementRunID != newRunID {
                    self.results = []
                }
                self.progress = .init(phase: .indexed, scannedSmall: 0, totalSmall: 0, scannedLarge: 0, totalLarge: 0)
            }
            if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
            let parsedSeed = FilterEngine.parseOperators(filters.query)
            let freeTextSeed = parsedSeed.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !freeTextSeed.isEmpty {
                let seedCandidates = Self.candidates(from: all, allowed: allowed, filters: filters)
                let seedSearchable = Self.metadataFilteredCandidates(seedCandidates,
                                                                       filters: filters,
                                                                       effectiveRepo: filters.repoName ?? parsedSeed.repo,
                                                                       effectivePath: filters.pathContains ?? parsedSeed.path,
                                                                       effectiveSideChatsOnly: filters.sideChatsOnly || parsedSeed.sideChatsOnly,
                                                                       effectiveProjectIdentity: filters.selectedProjectIdentity)
                let seeded = Self.cheapEffectiveTitleMatches(in: seedSearchable,
                                                              freeText: freeTextSeed,
                                                              overrides: titleOverrides)
                if !seeded.isEmpty {
                    await MainActor.run {
                        guard self.runID == newRunID else { return }
                        self.results = seeded
                        _ = self.consumePreservedReplacement(for: newRunID)
                    }
                }
                if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
                await self.startLegacySearch(runID: newRunID,
                                             query: query,
                                             filters: filters,
                                             allowed: allowed,
                                             all: all,
                                             allowDeepScan: enableDeepScan,
                                             initialSeen: Set(seeded.map(SessionKey.init)),
                                             replaceFirstPublication: preserveResultsUntilRefreshPublishes && seeded.isEmpty)
                return
            }
            await self.startLegacySearch(runID: newRunID,
                                         query: query,
                                         filters: filters,
                                         allowed: allowed,
                                         all: all,
                                         allowDeepScan: enableDeepScan,
                                         replaceFirstPublication: preserveResultsUntilRefreshPublishes)
        }
    }

    private func startLegacySearch(runID: UUID,
                                   query: String,
                                   filters: Filters,
                                   allowed: Set<SessionSource>,
                                   all: [Session],
                                   allowDeepScan: Bool,
                                   initialSeen: Set<SessionKey> = [],
                                   replaceFirstPublication: Bool = false) async {
        let prio: TaskPriority = FeatureFlags.lowerQoSForInteractiveSearch ? .utility : .userInitiated
        currentTask = Task.detached(priority: prio) { [weak self, runID] in
            guard let self else { return }
            // Restore pre-index candidate building: all allowed sessions, no DB/hybrid tiers
            let threshold = FeatureFlags.searchSmallSizeBytes
            let candidates = Self.candidates(from: all, allowed: allowed, filters: filters)

            var nonLarge: [Session] = []
            var large: [Session] = []
            nonLarge.reserveCapacity(candidates.count)
            large.reserveCapacity(max(1, candidates.count / 2))
            for s in candidates {
                let size = Self.sizeBytes(for: s)
                if size >= threshold { large.append(s) } else { nonLarge.append(s) }
            }
            nonLarge.sort { $0.modifiedAt > $1.modifiedAt }
            large.sort { $0.modifiedAt > $1.modifiedAt }

            let nonLargeCount = nonLarge.count
            let largeCount = large.count
            await MainActor.run {
                guard self.runID == runID else { return }
                self.progress = .init(phase: .legacySmall, scannedSmall: 0, totalSmall: nonLargeCount, scannedLarge: 0, totalLarge: largeCount)
            }

            // Phase 1: nonLarge batched
            let batchSize = 64
            // Seeded effective-title IDs are already published; skip them here
            // so the legacy scan unions without duplicating or wiping them.
            var seen = initialSeen
            for start in stride(from: 0, to: nonLarge.count, by: batchSize) {
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }
                let end = min(start + batchSize, nonLarge.count)
                let batch = Array(nonLarge[start..<end])
                let hits = await self.searchBatch(batch: batch,
                                                  query: query,
                                                  filters: filters,
                                                  threshold: threshold,
                                                  textScope: .all,
                                                  allowDeepParse: true,
                                                  allowTranscriptGeneration: false)
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }

                // Filter out duplicates before entering MainActor
                let newHits = hits.filter { !seen.contains(SessionKey($0)) }
                for s in newHits { seen.insert(SessionKey(s)) }

                await MainActor.run {
                    guard self.runID == runID else { return }
                    if replaceFirstPublication, !newHits.isEmpty, self.consumePreservedReplacement(for: runID) {
                        self.results = newHits
                    } else {
                        self.results.append(contentsOf: newHits)
                    }
                    if FeatureFlags.throttleSearchUIUpdates {
                        let now = DispatchTime.now()
                        if now.uptimeNanoseconds - self.progressThrottleLastFlush.uptimeNanoseconds > 100_000_000 { // ~10 Hz
                            self.progress.scannedSmall = min(self.progress.totalSmall, self.progress.scannedSmall + batch.count)
                            self.progressThrottleLastFlush = now
                        }
                    } else {
                        self.progress.scannedSmall = min(self.progress.totalSmall, self.progress.scannedSmall + batch.count)
                    }
                }
                if FeatureFlags.lowerQoSForInteractiveSearch { try? await Task.sleep(nanoseconds: 10_000_000) }
            }

            if Task.isCancelled { await self.finishCanceled(runID: runID); return }

            // Phase 2: large sequential
            await MainActor.run { if self.runID == runID { self.progress.phase = .legacyLarge } }
            var idx = 0
            var staged: [Session] = []
            var lastResultsFlush = DispatchTime.now()
            while idx < large.count {
                // Check for promotion request and reorder so promoted item is next.
                let want = await self.promotionState.consumePromoted()

                if let want, let pos = large[idx...].firstIndex(where: { $0.id == want }) {
                    if pos != idx { large.swapAt(idx, pos) }
                }

                let s = large[idx]
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }
                if let parsed = await self.parseFullIfNeeded(session: s,
                                                             threshold: threshold,
                                                             allowDeepParse: allowDeepScan,
                                                             allowLargePiParse: allowDeepScan) {
                    if Task.isCancelled { await self.finishCanceled(runID: runID); return }

                    // Optionally persist parsed session back to indexers for accuracy outside search
                    if allowDeepScan, !FeatureFlags.disableSessionUpdatesDuringSearch {
                        self.store.updateSession(parsed)
                    }

                    let cache = self.transcriptCache(for: parsed.source)
                    if FilterEngine.sessionMatches(parsed,
                                                  filters: filters,
                                                  transcriptCache: cache,
                                                  allowTranscriptGeneration: false,
                                                  textScope: .all) {
                        // Check and update seen outside MainActor
                        let parsedKey = SessionKey(parsed)
                        let shouldAdd = !seen.contains(parsedKey)
                        if shouldAdd {
                            seen.insert(parsedKey)
                            if FeatureFlags.coalesceSearchResults {
                                staged.append(parsed)
                                let now = DispatchTime.now()
                                if now.uptimeNanoseconds - lastResultsFlush.uptimeNanoseconds > 100_000_000 { // ~10 Hz
                                    let toFlush = staged
                                    staged.removeAll(keepingCapacity: true)
                                    lastResultsFlush = now
                                    await MainActor.run {
                                        guard self.runID == runID else { return }
                                        if replaceFirstPublication, !toFlush.isEmpty, self.consumePreservedReplacement(for: runID) {
                                            self.results = toFlush
                                        } else {
                                            self.results.append(contentsOf: toFlush)
                                        }
                                    }
                                }
                            } else {
                                await MainActor.run {
                                    guard self.runID == runID else { return }
                                    if replaceFirstPublication, self.consumePreservedReplacement(for: runID) {
                                        self.results = [parsed]
                                    } else {
                                        self.results.append(parsed)
                                    }
                                }
                            }
                        }
                    }
                }
                if FeatureFlags.throttleSearchUIUpdates {
                    let now = DispatchTime.now()
                    if now.uptimeNanoseconds - self.progressThrottleLastFlush.uptimeNanoseconds > 100_000_000 {
                        let currentIdx = idx
                        await MainActor.run {
                            if self.runID == runID { self.progress.scannedLarge = currentIdx + 1 }
                            self.progressThrottleLastFlush = now
                        }
                    }
                } else {
                    let currentIdx = idx
                    await MainActor.run { if self.runID == runID { self.progress.scannedLarge = currentIdx + 1 } }
                }
                if FeatureFlags.lowerQoSForInteractiveSearch { try? await Task.sleep(nanoseconds: 10_000_000) }
                idx += 1
            }
            // Final flush of any staged results
            if FeatureFlags.coalesceSearchResults && !staged.isEmpty {
                let toFlush = staged
                staged.removeAll()
                await MainActor.run {
                    guard self.runID == runID else { return }
                    if replaceFirstPublication, self.consumePreservedReplacement(for: runID) {
                        self.results = toFlush
                    } else {
                        self.results.append(contentsOf: toFlush)
                    }
                }
            }

            if Task.isCancelled { await self.finishCanceled(runID: runID); return }
                await MainActor.run {
                    guard self.runID == runID else { return }
                    if replaceFirstPublication, self.consumePreservedReplacement(for: runID) {
                        // Zero-hit refresh must still replace: no legacy batch
                        // published, so clear preserved old rows instead of leaving
                        // deleted rows visible.
                        self.results = []
                    }
                    self.isRunning = false
                    self.progress.phase = .idle
                }
        }
        await currentTask?.value
    }

    /// Internal, not private, so tests can pin the nil-vs-zero distinction in
    /// `lightweightCommands`. This is the only consumer that treats the two
    /// differently — `passesHasCommandsFilter` collapses them with `?? 0` — so
    /// without reaching it, a parser emitting `0` where it means "unknown" is
    /// unfalsifiable by the suite.
    static func shouldDeepScan(session: Session) -> Bool {
        let estimatedCommands: Int = {
            if let c = session.lightweightCommands { return c }
            if session.events.isEmpty { return 0 }
            return session.events.filter { $0.kind == .tool_call }.count
        }()
        return estimatedCommands > 0
    }

    static func shouldIncludeUnindexedCandidate(_ session: Session,
                                                indexedIDs: Set<SessionKey>,
                                                seenIDs: Set<SessionKey>,
                                                enableDeepScan: Bool,
                                                smallSearchThreshold: Int,
                                                staleIDs: Set<SessionKey> = []) -> Bool {
        let key = SessionKey(session)
        guard !indexedIDs.contains(key), !seenIDs.contains(key) else { return false }
        if enableDeepScan { return true }
        if session.source == .cursor { return true }
        // A session whose `session_search` row exists but is out of date (changed-but-not-yet-reingested,
        // held back by SearchIngestService's quiet/cooldown gates) has NO fresh FTS coverage, so it must
        // be scanned even if it is over the small-size threshold — otherwise a large hot transcript stays
        // unfindable for the whole re-ingest delay. `indexedIDs` (currency-aware) already excludes it; this
        // additionally bypasses the size gate that would otherwise drop a large stale file.
        if staleIDs.contains(key) { return true }
        return sizeBytes(for: session) < smallSearchThreshold
    }

    /// Builds an FTS5 query for Instant search.
    ///
    /// We avoid trigram/substr indexing, but we can still improve recall (especially for identifiers)
    /// by using FTS prefix queries when the user's input is a simple space-delimited term list.
    private static func makeInstantFTSQuery(from freeText: String) -> String {
        let q = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return q }

        let explicit = SearchTextMatcher.hasExplicitFTSSyntax(q)

        // Multi-word queries should behave like phrase searches by default (the same semantics
        // used for transcript navigation), so users can distinguish "exit" from "exit code".
        // Power users can still opt into explicit FTS query syntax by using quotes/operators/etc.
        if q.contains(where: \.isWhitespace) {
            // If the user already wrote an explicit FTS query (quotes, boolean ops, prefix, etc),
            // do not rewrite it.
            if explicit { return q }

            let normalized = q.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "\"\(normalized)\""
        }

        // If the user already wrote an explicit FTS query (quotes, boolean ops, prefix, etc),
        // do not rewrite it.
        if explicit { return q }

        let rawTerms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !rawTerms.isEmpty else { return q }

        func isSimpleTerm(_ s: String) -> Bool {
            guard !s.isEmpty else { return false }
            // Restrict to ASCII letters/digits/underscore to avoid breaking FTS syntax.
            for u in s.unicodeScalars {
                let v = u.value
                let isAZ = (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
                let is09 = (v >= 48 && v <= 57)
                let isUnderscore = (v == 95)
                if !(isAZ || is09 || isUnderscore) { return false }
            }
            return true
        }

        // Only auto-prefix longer, simple terms; short prefixes get noisy.
        let rewritten = rawTerms.map { term -> String in
            guard term.count >= 3 else { return term }
            guard isSimpleTerm(term) else { return term }
            return term + "*"
        }
        return rewritten.joined(separator: " ")
    }

    private static func candidates(from all: [Session], allowed: Set<SessionSource>, filters: Filters) -> [Session] {
        let sideChatsOnly = filters.sideChatsOnly || FilterEngine.parseOperators(filters.query).sideChatsOnly
        return all.filter { session in
            guard allowed.contains(session.source) else { return false }
            // Archive filter scopes only Codex; explicit side-chat searches should include
            // recovered log rows even though those rows are not archived JSONL sessions.
            if !sideChatsOnly, filters.archivedCodexDesktopOnly, session.source == .codex, !session.isArchivedCodexDesktopSession {
                return false
            }
            return true
        }
    }

    private static func metadataFilteredCandidates(_ candidates: [Session],
                                                    filters: Filters,
                                                    effectiveRepo: String?,
                                                    effectivePath: String?,
                                                    effectiveSideChatsOnly: Bool? = nil,
                                                    effectiveProjectIdentity: ProjectIdentity? = nil) -> [Session] {
        let metadataFilters = Filters(query: "",
                                       dateFrom: filters.dateFrom,
                                       dateTo: filters.dateTo,
                                       model: filters.model,
                                       kinds: filters.kinds,
                                       repoName: effectiveRepo,
                                       pathContains: effectivePath,
                                       archivedCodexDesktopOnly: filters.archivedCodexDesktopOnly,
                                       archivedClaudeDesktopOnly: filters.archivedClaudeDesktopOnly,
                                       archivedClaudeSessionIDs: filters.archivedClaudeSessionIDs,
                                       sideChatsOnly: effectiveSideChatsOnly ?? filters.sideChatsOnly,
                                       selectedProjectIdentity: effectiveProjectIdentity ?? filters.selectedProjectIdentity)
        return FilterEngine.filterSessions(candidates,
                                           filters: metadataFilters,
                                           transcriptCache: nil,
                                           allowTranscriptGeneration: false)
    }

    /// The effective row title for search: a caller-provided immutable snapshot
    /// (e.g. Claude archive sidecar titles) wins when present for the session identity;
    /// otherwise the model-level row title is used. No DB migration or reindex.
    private static func effectiveSearchTitle(for session: Session,
                                             overrides: [SessionKey: String]) -> String {
        if let override = overrides[SessionKey(session)] {
            return override
        }
        return session.listTitle
    }

    /// Cheap title-only matches for a non-empty free-text query, derived only from
    /// candidates that already pass allowed-source and all metadata filters.
    /// Uses `SearchTextMatcher.hasMatch` for the same matching semantics.
    /// Empty free text never produces title matches.
    private static func cheapEffectiveTitleMatches(in candidates: [Session],
                                                   freeText: String,
                                                   overrides: [SessionKey: String]) -> [Session] {
        let q = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return candidates.filter { session in
            let title = effectiveSearchTitle(for: session, overrides: overrides)
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            return SearchTextMatcher.hasMatch(in: title, query: q)
        }
    }

    private static func ftsResultLimit(filters: Filters,
                                        effectiveRepo: String?,
                                        totalSessionCount: Int) -> Int {
        if filters.archivedCodexDesktopOnly || effectiveRepo != nil || filters.selectedProjectIdentity != nil || filters.archivedClaudeDesktopOnly {
            return max(FeatureFlags.ftsSearchLimit, totalSessionCount)
        }
        return FeatureFlags.ftsSearchLimit
    }

    private func startBackgroundDeepScan(runID: UUID,
                                         query: String,
                                         filters: Filters,
                                         unindexedCandidates: [Session],
                                         deepCandidates: [Session],
                                         initialSeen: Set<SessionKey>) {
        deepScanTask?.cancel()
        deepScanTask = Task.detached(priority: .utility) { [weak self, runID] in
            guard let self else { return }
            guard self.runID == runID else { return }
            defer {
                DispatchQueue.main.async { [weak self] in
                    if self?.runID == runID {
                        self?.deepScanTask = nil
                    }
                }
            }
            var seen = initialSeen

            if !unindexedCandidates.isEmpty {
                await self.runDeepSearchAppend(
                    runID: runID,
                    query: query,
                    filters: filters,
                    candidates: unindexedCandidates,
                    initialSeen: seen,
                    finishWhenDone: deepCandidates.isEmpty,
                    progressPhases: (.unindexedSmall, .unindexedLarge),
                    textScope: .all
                )
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }
                seen = await MainActor.run { Set(self.results.map(SessionKey.init)) }
            }

            if !deepCandidates.isEmpty {
                await self.runDeepSearchAppend(
                    runID: runID,
                    query: query,
                    filters: filters,
                    candidates: deepCandidates,
                    initialSeen: seen,
                    finishWhenDone: true,
                    progressPhases: (.toolOutputsSmall, .toolOutputsLarge),
                    textScope: .toolOutputsOnly
                )
            }
        }
    }

    private func runDeepSearchAppend(runID: UUID,
                                     query: String,
                                     filters: Filters,
                                     candidates: [Session],
                                     initialSeen: Set<SessionKey>,
                                     finishWhenDone: Bool,
                                     progressPhases: (Progress.Phase, Progress.Phase),
                                     textScope: FilterEngine.TextScope) async {
        let threshold = FeatureFlags.searchSmallSizeBytes
        var nonLarge: [Session] = []
        var large: [Session] = []
        nonLarge.reserveCapacity(candidates.count)
        large.reserveCapacity(max(1, candidates.count / 2))
        for s in candidates {
            let size = Self.sizeBytes(for: s)
            if size >= threshold { large.append(s) } else { nonLarge.append(s) }
        }
        nonLarge.sort { $0.modifiedAt > $1.modifiedAt }
        large.sort { $0.modifiedAt > $1.modifiedAt }

        let nonLargeCount = nonLarge.count
        let largeCount = large.count
        await MainActor.run {
            guard self.runID == runID else { return }
            self.progress = .init(phase: progressPhases.0, scannedSmall: 0, totalSmall: nonLargeCount, scannedLarge: 0, totalLarge: largeCount)
        }

        var seen = initialSeen

        // Phase 1: nonLarge batched
        let batchSize = 64
        for start in stride(from: 0, to: nonLarge.count, by: batchSize) {
            if Task.isCancelled { await self.finishCanceled(runID: runID); return }
            let end = min(start + batchSize, nonLarge.count)
            let batch = Array(nonLarge[start..<end])
            let hits = await self.searchBatch(batch: batch,
                                              query: query,
                                              filters: filters,
                                              threshold: threshold,
                                              textScope: textScope,
                                              allowDeepParse: true,
                                              allowTranscriptGeneration: false)
            if Task.isCancelled { await self.finishCanceled(runID: runID); return }

            let newHits = hits.filter { !seen.contains(SessionKey($0)) }
            for s in newHits { seen.insert(SessionKey(s)) }

            await MainActor.run {
                guard self.runID == runID else { return }
                self.results.append(contentsOf: newHits)
                if FeatureFlags.throttleSearchUIUpdates {
                    let now = DispatchTime.now()
                    if now.uptimeNanoseconds - self.progressThrottleLastFlush.uptimeNanoseconds > 100_000_000 { // ~10 Hz
                        self.progress.scannedSmall = min(self.progress.totalSmall, self.progress.scannedSmall + batch.count)
                        self.progressThrottleLastFlush = now
                    }
                } else {
                    self.progress.scannedSmall = min(self.progress.totalSmall, self.progress.scannedSmall + batch.count)
                }
            }
            if FeatureFlags.lowerQoSForInteractiveSearch { try? await Task.sleep(nanoseconds: 10_000_000) }
        }

        if Task.isCancelled { await self.finishCanceled(runID: runID); return }

        // Phase 2: large sequential
        await MainActor.run { if self.runID == runID { self.progress.phase = progressPhases.1 } }
        var idx = 0
        var staged: [Session] = []
        var lastResultsFlush = DispatchTime.now()
        while idx < large.count {
            let want = await self.promotionState.consumePromoted()
            if let want, let pos = large[idx...].firstIndex(where: { $0.id == want }) {
                if pos != idx { large.swapAt(idx, pos) }
            }

            let s = large[idx]
            if Task.isCancelled { await self.finishCanceled(runID: runID); return }
            if let parsed = await self.parseFullIfNeeded(session: s,
                                                         threshold: threshold,
                                                         allowDeepParse: true,
                                                         allowLargePiParse: true) {
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }

                if !FeatureFlags.disableSessionUpdatesDuringSearch {
                    self.store.updateSession(parsed)
                }

                if textScope == .all {
                    let cache = self.transcriptCache(for: parsed.source)
                    if FilterEngine.sessionMatches(parsed,
                                                  filters: filters,
                                                  transcriptCache: cache,
                                                  allowTranscriptGeneration: false,
                                                  textScope: .all) {
                        let parsedKey = SessionKey(parsed)
                        let shouldAdd = !seen.contains(parsedKey)
                        if shouldAdd {
                            seen.insert(parsedKey)
                            if FeatureFlags.coalesceSearchResults {
                                staged.append(parsed)
                                let now = DispatchTime.now()
                                if now.uptimeNanoseconds - lastResultsFlush.uptimeNanoseconds > 100_000_000 { // ~10 Hz
                                    let toFlush = staged
                                    staged.removeAll(keepingCapacity: true)
                                    lastResultsFlush = now
                                    await MainActor.run {
                                        guard self.runID == runID else { return }
                                        self.results.append(contentsOf: toFlush)
                                    }
                                }
                            } else {
                                await MainActor.run {
                                    guard self.runID == runID else { return }
                                    self.results.append(parsed)
                                }
                            }
                        }
                    }
                } else {
                    if FilterEngine.sessionMatches(parsed, filters: filters, transcriptCache: nil, allowTranscriptGeneration: false, textScope: .toolOutputsOnly) {
                        let parsedKey = SessionKey(parsed)
                        let shouldAdd = !seen.contains(parsedKey)
                        if shouldAdd {
                            seen.insert(parsedKey)
                            if FeatureFlags.coalesceSearchResults {
                                staged.append(parsed)
                                let now = DispatchTime.now()
                                if now.uptimeNanoseconds - lastResultsFlush.uptimeNanoseconds > 100_000_000 { // ~10 Hz
                                    let toFlush = staged
                                    staged.removeAll(keepingCapacity: true)
                                    lastResultsFlush = now
                                    await MainActor.run {
                                        guard self.runID == runID else { return }
                                        self.results.append(contentsOf: toFlush)
                                    }
                                }
                            } else {
                                await MainActor.run {
                                    guard self.runID == runID else { return }
                                    self.results.append(parsed)
                                }
                            }
                        }
                    }
                }
            }

            if FeatureFlags.throttleSearchUIUpdates {
                let now = DispatchTime.now()
                if now.uptimeNanoseconds - self.progressThrottleLastFlush.uptimeNanoseconds > 100_000_000 {
                    let currentIdx = idx
                    await MainActor.run {
                        if self.runID == runID { self.progress.scannedLarge = currentIdx + 1 }
                        self.progressThrottleLastFlush = now
                    }
                }
            } else {
                let currentIdx = idx
                await MainActor.run { if self.runID == runID { self.progress.scannedLarge = currentIdx + 1 } }
            }
            if FeatureFlags.lowerQoSForInteractiveSearch { try? await Task.sleep(nanoseconds: 10_000_000) }
            idx += 1
        }

        if FeatureFlags.coalesceSearchResults && !staged.isEmpty {
            let toFlush = staged
            staged.removeAll()
            await MainActor.run {
                guard self.runID == runID else { return }
                self.results.append(contentsOf: toFlush)
            }
        }

        if Task.isCancelled { await self.finishCanceled(runID: runID); return }
        if finishWhenDone {
            await MainActor.run {
                guard self.runID == runID else { return }
                self.isRunning = false
                self.progress.phase = .idle
            }
        }
    }

    private func finishCanceled(runID expected: UUID) async {
        await MainActor.run {
            if self.runID == expected {
                self.isRunning = false
                self.wasCanceled = true
                self.progress.phase = .idle
            }
        }
    }

    private func searchBatch(batch: [Session],
                             query: String,
                             filters: Filters,
                             threshold: Int,
                             textScope: FilterEngine.TextScope,
                             allowDeepParse: Bool,
                             allowTranscriptGeneration: Bool) async -> [Session] {
        var out: [Session] = []
        out.reserveCapacity(batch.count / 4)
        for var s in batch {
            if Task.isCancelled { return out }
            if s.events.isEmpty {
                // For non-large sessions only, parse quickly if needed
                let size = Self.sizeBytes(for: s)
                if size < threshold,
                   let parsed = await parseFullIfNeeded(session: s,
                                                        threshold: threshold,
                                                        allowDeepParse: allowDeepParse) {
                    s = parsed
                    if allowDeepParse, !FeatureFlags.disableSessionUpdatesDuringSearch {
                        self.store.updateSession(parsed)
                    }
                }
            }
            let cache: TranscriptCache? = (textScope == .all) ? self.transcriptCache(for: s.source) : nil
            if FilterEngine.sessionMatches(s,
                                          filters: filters,
                                          transcriptCache: cache,
                                          allowTranscriptGeneration: allowTranscriptGeneration,
                                          textScope: textScope) {
                out.append(s)
            }
        }
        return out
    }

    private func parseFullIfNeeded(session s: Session,
                                   threshold: Int,
                                   allowDeepParse: Bool,
                                   allowLargePiParse: Bool = false) async -> Session? {
        guard !Task.isCancelled else { return nil }
        guard allowDeepParse else { return s }
        if s.source == .pi,
           Self.sizeBytes(for: s) >= threshold,
           !allowLargePiParse {
            return s
        }
        if s.source == .pi, allowLargePiParse {
            return PiSessionParser.parseFileFull(at: URL(fileURLWithPath: s.filePath), allowLargeFile: true)
        }
        return await store.parseFull(session: s)
    }

    private static func sizeBytes(for s: Session) -> Int {
        if let b = s.fileSizeBytes { return b }
        let p = s.filePath
        if let num = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.intValue { return num }
        return 0
    }
}

extension Array {
    func chunks(of n: Int) -> [ArraySlice<Element>] {
        guard n > 0 else { return [self[...]] }
        return stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}

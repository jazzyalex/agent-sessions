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

    @Published private(set) var queryError: String?
    @Published private(set) var eligibleCount = 0
    @Published private(set) var completeCount = 0
    @Published private(set) var incompleteCount = 0
    @Published private(set) var unresolvedCount = 0
    @Published private(set) var verifiedKeys: Set<SessionKey> = []
    @Published private(set) var snippets: [SessionKey: String] = [:]

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
    private var cancelledVerificationRunID: UUID?
    private var metricOperation: SearchResponsivenessOperationID?
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

    func cancel() { cancel(clearResults: false) }
    func clear() { cancel(clearResults: true) }

    private func cancel(clearResults: Bool) {
        SearchResponsivenessMetrics.shared.record(.searchCancelRequested, operationID: metricOperation, status: .cancelled)
        currentTask?.cancel()
        currentTask = nil
        deepScanTask?.cancel()
        deepScanTask = nil
        cancelledVerificationRunID = clearResults ? nil : runID
        let cancellationRun = UUID()
        runID = cancellationRun
        DispatchQueue.main.async { [weak self] in
            guard let self, self.runID == cancellationRun else { return }
            self.isRunning = false
            self.wasCanceled = true
            self.deepScanEnabled = false
            self.progress = .init()
            if clearResults {
                self.results = []
                self.queryError = nil
                self.eligibleCount = 0
                self.completeCount = 0
                self.incompleteCount = 0
                self.unresolvedCount = 0
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
        currentTask?.cancel()
        deepScanTask?.cancel()
        let currentRun = UUID()
        runID = currentRun
        cancelledVerificationRunID = nil
        let metrics = SearchResponsivenessMetrics.shared
        let operation = metrics.newOperationID()
        metricOperation = operation
        metrics.record(.searchRequestAccepted, operationID: operation, status: .accepted)
        wasCanceled = false
        queryError = nil
        completeCount = 0
        incompleteCount = 0
        unresolvedCount = 0
        eligibleCount = 0
        verifiedKeys = []
        snippets = [:]
        deepScanEnabled = enableDeepScan
        isRunning = true
        if !preserveResultsUntilRefreshPublishes { results = [] }
        let store = self.store
        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let terminal = metrics.beginSpan(.searchTerminal, operationID: operation)
            defer { if let terminal { Task.isCancelled ? metrics.cancel(terminal) : metrics.end(terminal) } }
            do {
                let (metadata, _) = try SearchQuery.metadataTokens(SearchQuery.lex(filters.query))
                let candidates = Self.metadataFilteredCandidates(
                    Self.candidates(from: all, allowed: allowed, filters: filters), filters: filters,
                    effectiveRepo: filters.repoName ?? metadata.repo,
                    effectivePath: filters.pathContains ?? metadata.path,
                    effectiveSideChatsOnly: filters.sideChatsOnly || metadata.sideChatsOnly,
                    effectiveProjectIdentity: filters.selectedProjectIdentity)
                let eligible = candidates.map { Self.searchRow($0, title: effectiveDisplayTitles[SessionKey($0)]) }
                metrics.record(.searchEligibleCount, operationID: operation, counters: [.eligibleSessions: Int64(eligible.count)])
                let exact = Self.exactIdentityMatches(metadata.freeText, sessions: eligible)
                if metadata.freeText.isEmpty || !exact.isEmpty {
                    let rows = metadata.freeText.isEmpty ? eligible : exact
                    await MainActor.run {
                        guard self.runID == currentRun else { return }
                        self.results = rows
                        self.verifiedKeys = Set(rows.map(SessionKey.init))
                        self.eligibleCount = rows.count
                        self.completeCount = rows.count
                        self.isRunning = false
                        self.progress = .init()
                    }
                    return
                }

                let tokenizer = try SearchTokenizer()
                let compiled = try SearchQuery(filters.query, tokenizer: tokenizer)
                var hits: [SessionKey: Session] = [:]
                for session in eligible {
                    try Task.checkCancellation()
                    let predicate = SearchPredicateAccumulator(query: compiled, tokenizer: tokenizer)
                    for field in [session.listTitle, session.lightweightCwd ?? "", session.lightweightRepoName ?? ""] {
                        try predicate.consume(field: field)
                    }
                    if predicate.truth(complete: false) == .yes { hits[SessionKey(session)] = session }
                }
                if FeatureFlags.enableFTSSearch, let db = self.db, let fts = compiled.ftsCandidate {
                    // Scope each source and every metadata predicate before capacity. Source-qualified
                    // keys also avoid dictionary traps when two providers use the same raw ID.
                    for source in allowed {
                        try Task.checkCancellation()
                        let scoped = eligible.filter { $0.source == source }
                        let originals = candidates.filter { $0.source == source }
                        let ids = await Self.indexedCandidates(originals, db: db, toolIO: false)
                        guard !ids.isEmpty else { continue }
                        let limit = self.ftsResultLimitForTesting ?? FeatureFlags.ftsSearchLimit
                        let ordinary = (try? await db.searchSessionIDsFTS(
                            sources: [source.rawValue], model: nil, repoSubstr: nil, pathSubstr: nil,
                            dateFrom: nil, dateTo: nil, query: fts,
                            includeSystemProbes: UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"),
                            limit: limit, eligibleSessionIDs: ids)) ?? []
                        var found = Set(ordinary)
                        if self.toolIOIndexEnabled() {
                            let tool = (try? await db.searchSessionIDsToolIOFTS(
                                sources: [source.rawValue], model: nil, repoSubstr: nil, pathSubstr: nil,
                                dateFrom: nil, dateTo: nil, query: fts,
                                includeSystemProbes: UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions"),
                                limit: max(0, limit - found.count), eligibleSessionIDs: await Self.indexedCandidates(originals, db: db, toolIO: true),
                                excludingSessionIDs: found)) ?? []
                            found.formUnion(tool)
                        }
                        for session in scoped where found.contains(session.id) { hits[SessionKey(session)] = session }
                    }
                }
                try Task.checkCancellation()
                let instantRows = eligible.filter { hits[SessionKey($0)] != nil }
                await MainActor.run {
                    guard self.runID == currentRun else { return }
                    metrics.record(.searchInstantFirstPublication, operationID: operation, status: .published, counters: [.resultCount: Int64(instantRows.count)])
                    self.results = instantRows
                    self.eligibleCount = eligible.count
                    self.unresolvedCount = eligible.count
                    self.progress = .init(phase: enableDeepScan ? .legacySmall : .indexed,
                                          scannedSmall: 0, totalSmall: eligible.count)
                    self.isRunning = enableDeepScan
                }
                guard enableDeepScan else { return }
                var complete = 0, incomplete = 0, unresolved = 0
                var verified: Set<SessionKey> = []
                var snippets: [SessionKey: String] = [:]
                var lastPublication = ContinuousClock.now
                var visited = 0
                for (index, session) in eligible.enumerated() {
                    if Task.isCancelled { break }
                    let result = await SearchMetricScope.$requestID.withValue(operation) {
                        await store.scan(session: session, query: compiled)
                    }
                    if Task.isCancelled { break }
                    visited = index + 1
                    if result.summary.complete { complete += 1 } else { incomplete += 1 }
                    switch result.truth {
                    case .yes:
                        verified.insert(result.key)
                        hits[result.key] = session
                        snippets[result.key] = result.snippet
                    case .no: hits[result.key] = nil
                    case .unknown: unresolved += 1
                    }
                    if ContinuousClock.now - lastPublication >= .milliseconds(100) || index == eligible.count - 1 {
                        let rows = eligible.filter { hits[SessionKey($0)] != nil }
                        let counts = (complete, incomplete, unresolved + eligible.count - index - 1)
                        let verifiedSnapshot = verified, snippetSnapshot = snippets
                        await MainActor.run {
                            guard self.runID == currentRun else { return }
                            self.results = rows
                            metrics.record(.searchCoverageCounters, operationID: operation, status: .published, counters: [.completeSessions: Int64(counts.0), .incompleteSessions: Int64(counts.1), .verifiedResults: Int64(verifiedSnapshot.count)])
                            self.verifiedKeys = verifiedSnapshot
                            self.snippets = snippetSnapshot
                            self.completeCount = counts.0
                            self.incompleteCount = counts.1
                            self.unresolvedCount = counts.2
                            self.progress.scannedSmall = index + 1
                        }
                        lastPublication = .now
                    }
                }
                let finalRows = eligible.filter { hits[SessionKey($0)] != nil }
                let finalVerified = verified, finalSnippets = snippets
                let finalCounts = (complete, incomplete, unresolved + eligible.count - visited)
                await MainActor.run {
                    guard self.runID == currentRun || self.cancelledVerificationRunID == currentRun else { return }
                    self.results = finalRows
                    self.verifiedKeys = finalVerified
                    self.snippets = finalSnippets
                    self.completeCount = finalCounts.0
                    self.incompleteCount = finalCounts.1
                    self.unresolvedCount = finalCounts.2
                    self.isRunning = false
                    self.progress.phase = .idle
                    self.cancelledVerificationRunID = nil
                }
            } catch is CancellationError {
                await self.finishCanceled(runID: currentRun)
            } catch {
                await MainActor.run {
                    guard self.runID == currentRun else { return }
                    self.queryError = error.localizedDescription
                    self.results = []
                    self.isRunning = false
                }
            }
        }
    }

    static func exactIdentityMatches(_ freeText: String, sessions: [Session]) -> [Session] {
        guard let tokens = try? SearchQuery.lex(freeText), tokens.count == 1 else { return [] }
        let raw = tokens[0].value
        guard !raw.contains("*") else { return [] }
        func normalized(_ value: String) -> String { UUID(uuidString: value)?.uuidString.lowercased() ?? value }
        let wanted = normalized(raw)
        return sessions.filter { session in
            var aliases = [session.id]
            if session.source == .codex || session.source == .claude {
                if let hint = session.codexInternalSessionIDHint { aliases.append(hint) }
                let basename = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
                let candidate = session.source == .codex ? String(basename.suffix(36)) : basename
                if let id = UUID(uuidString: candidate) { aliases.append(id.uuidString) }
            }
            return aliases.contains { normalized($0) == wanted }
        }
    }

    private static func indexedCandidates(_ sessions: [Session], db: IndexDB, toolIO: Bool) async -> Set<String> {
        guard let source = sessions.first?.source else { return [] }
        let present = Set(toolIO
            ? ((try? await db.toolIOSessionIDs(sources: [source.rawValue])) ?? [])
            : ((try? await db.indexedSessionIDs(sources: [source.rawValue])) ?? []))
        var current = Set(toolIO
            ? ((try? await db.indexedToolIOSessionIDsCurrent(sources: [source.rawValue])) ?? [])
            : ((try? await db.indexedSessionIDsCurrent(sources: [source.rawValue])) ?? []))
        let identities = sessions.filter {
            $0.source.descriptor.searchUsesIdentityAtURL?(URL(fileURLWithPath: $0.filePath)) == true
        }
        if !identities.isEmpty {
            let states = toolIO
                ? ((try? await db.sessionToolIOIdentityStatesByID(for: source.rawValue)) ?? [:])
                : ((try? await db.sessionSearchIdentityStatesByID(for: source.rawValue)) ?? [:])
            for session in identities {
                current.remove(session.id)
                if let state = states[session.id], state.storagePath == session.filePath,
                   SearchIngestService.contentRevision(state.revision, matches: session) { current.insert(session.id) }
            }
        }
        return Set(sessions.map(\.id)).subtracting(present.subtracting(current))
    }

    static func searchRow(_ session: Session, title: String? = nil, path: String? = nil, parsedMetadata: Bool = false, id: String? = nil) -> Session {
        var row = Session(id: id ?? session.id, source: session.source, startTime: session.startTime,
            endTime: session.endTime, model: session.model, filePath: path ?? session.filePath,
            fileSizeBytes: session.fileSizeBytes, eventCount: session.eventCount, events: [],
            cwd: parsedMetadata ? session.cwd : session.lightweightCwd, repoName: parsedMetadata ? session.repoName : session.lightweightRepoName,
            lightweightTitle: title ?? session.listTitle, lightweightCommands: parsedMetadata ? session.events.filter { $0.kind == .tool_call }.count : session.lightweightCommands,
            isHousekeeping: session.isHousekeeping, codexInternalSessionIDHint: parsedMetadata ? session.codexInternalSessionID : session.codexInternalSessionIDHint,
            parentSessionID: session.parentSessionID, subagentType: session.subagentType,
            relationshipKind: session.relationshipKind, customTitle: title ?? session.customTitle,
            codexOriginator: session.codexOriginator, codexSource: session.codexSource,
            codexSurface: session.codexSurface, originator: session.originator,
            originSource: session.originSource, surface: session.surface,
            reasoningEffort: session.reasoningEffort, deletedAt: session.deletedAt)
        row.isFavorite = session.isFavorite
        row.sourceStorageIdentity = session.sourceStorageIdentity
        row.sourceStorageRevision = session.sourceStorageRevision
        row.sourcePreviewDigest = session.sourcePreviewDigest
        return row
    }

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
                                       selectedProjectIdentity: effectiveProjectIdentity ?? filters.selectedProjectIdentity,
                                       hiddenProjectRoots: filters.hiddenProjectRoots)
        return FilterEngine.filterSessions(candidates,
                                           filters: metadataFilters,
                                           transcriptCache: nil,
                                           allowTranscriptGeneration: false)
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

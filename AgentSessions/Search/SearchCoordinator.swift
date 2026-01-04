import Foundation
import Combine

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

final class SearchCoordinator: ObservableObject {
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

    private var currentTask: Task<Void, Never>? = nil
    private let store: SearchSessionStoring
    private let db: IndexDB? = try? IndexDB()
    // Promotion support for large-queue preemption
    private let promotionState = PromotionState()
    // Generation token to ignore stale appends after cancel/restart
    private var runID = UUID()
    // Throttle guards for progress updates
    private var progressThrottleLastFlush = DispatchTime.now()

    init(store: SearchSessionStoring) {
        self.store = store
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
        // Default ON unless the user explicitly opts out.
        if UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex)
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runID = UUID()
            self.isRunning = false
            self.wasCanceled = true
            self.progress = .init()
            self.results = []
        }
    }

    // Promote a large session to be processed next in the large queue if present.
    func promote(id: String) {
        Task {
            await promotionState.setPromoted(id: id)
        }
    }

    func start(query: String,
               filters: Filters,
               includeCodex: Bool,
               includeClaude: Bool,
               includeGemini: Bool,
               includeOpenCode: Bool,
               includeCopilot: Bool,
               includeDroid: Bool,
               all: [Session]) {
        // Cancel any in-flight search
        currentTask?.cancel()
        wasCanceled = false
        let newRunID = UUID()
        runID = newRunID

        let allowed: Set<SessionSource> = {
            var set = Set<SessionSource>()
            if includeCodex { set.insert(.codex) }
            if includeClaude { set.insert(.claude) }
            if includeGemini { set.insert(.gemini) }
            if includeOpenCode { set.insert(.opencode) }
            if includeCopilot { set.insert(.copilot) }
            if includeDroid { set.insert(.droid) }
            return set
        }()
        
        // Flip running state immediately for early user feedback
        Task { @MainActor [weak self] in
            guard let self, self.runID == newRunID else { return }
            self.isRunning = true
            self.results = []
            self.progress = .init(phase: .indexed, scannedSmall: 0, totalSmall: 0, scannedLarge: 0, totalLarge: 0)
        }

        // Phase 0: fast path via SQLite FTS if available.
        if FeatureFlags.enableFTSSearch, let db = db {
            let allowedRaw = allowed.map { $0.rawValue }
            let parsed = FilterEngine.parseOperators(filters.query)
            let freeText = parsed.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveFTSQuery = Self.makeInstantFTSQuery(from: freeText)
            let effectiveRepo = filters.repoName ?? parsed.repo
            let effectivePath = filters.pathContains ?? parsed.path
            let hasMetaFilters = (filters.model != nil) || (filters.dateFrom != nil) || (filters.dateTo != nil) || (effectiveRepo != nil) || (effectivePath != nil)
            let includeSystemProbes = UserDefaults.standard.bool(forKey: "ShowSystemProbeSessions")

            let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
            currentTask = Task.detached(priority: prio) { [weak self, newRunID] in
                guard let self else { return }
                let hasData = (try? await db.hasSearchData(sources: allowedRaw)) ?? false
                if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
                guard hasData else {
                    // Fall back to legacy search until the DB is warmed.
                    await self.startLegacySearch(runID: newRunID, query: query, filters: filters, allowed: allowed, all: all)
                    return
                }

                let candidates = all.filter { allowed.contains($0.source) }
                var byID: [String: Session] = [:]
                byID.reserveCapacity(candidates.count)
                for s in candidates { byID[s.id] = s }

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
                    let indexedIDs = Set((try? await db.indexedSessionIDs(sources: allowedRaw)) ?? [])
                    if indexedIDs.isEmpty {
                        await self.startLegacySearch(runID: newRunID, query: query, filters: filters, allowed: allowed, all: all)
                        return
                    }

                    let ids = (try? await db.searchSessionIDsFTS(
                        sources: allowedRaw,
                        model: filters.model,
                        repoSubstr: effectiveRepo,
                        pathSubstr: effectivePath,
                        dateFrom: filters.dateFrom,
                        dateTo: filters.dateTo,
                        query: effectiveFTSQuery,
                        includeSystemProbes: includeSystemProbes,
                        limit: FeatureFlags.ftsSearchLimit
                    )) ?? []
                    if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }

                    let deepEnabled = self.deepToolOutputsEnabled()
	                    var mergedIDs = ids
	                    var mergedSet = Set(ids)
	                    var out = mergedIDs.compactMap { byID[$0] }
	                    var seen = Set(out.map(\.id))
	                    let needsUnindexedScan = candidates.contains(where: { !indexedIDs.contains($0.id) })
	                    let initialOut = out
	                    await MainActor.run {
	                        guard self.runID == newRunID else { return }
	                        self.results = initialOut
	                    }
	                    if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }

                    // Append tool I/O FTS hits after the initial UI update to keep Instant responsive.
                    if self.toolIOIndexEnabled(), mergedIDs.count < FeatureFlags.ftsSearchLimit {
                        let toolIDs = (try? await db.searchSessionIDsToolIOFTS(
                            sources: allowedRaw,
                            model: filters.model,
                            repoSubstr: effectiveRepo,
                            pathSubstr: effectivePath,
                            dateFrom: filters.dateFrom,
                            dateTo: filters.dateTo,
                            query: effectiveFTSQuery,
                            includeSystemProbes: includeSystemProbes,
                            limit: FeatureFlags.ftsSearchLimit
                        )) ?? []
                        var addedAny = false
                        for id in toolIDs {
                            if mergedIDs.count >= FeatureFlags.ftsSearchLimit { break }
                            if mergedSet.insert(id).inserted {
                                mergedIDs.append(id)
                                addedAny = true
                            }
                        }
                        if addedAny {
                            let updated = mergedIDs.compactMap { byID[$0] }
                            await MainActor.run {
                                guard self.runID == newRunID else { return }
                                self.results = updated
                            }
                            out = updated
                            seen = Set(updated.map(\.id))
                        }
                    }

                    if !deepEnabled && !needsUnindexedScan {
                        await MainActor.run {
                            guard self.runID == newRunID else { return }
                            self.isRunning = false
                            self.progress.phase = .idle
                        }
                        return
                    }
                    if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }

                    let unindexedCandidates = candidates.filter { !indexedIDs.contains($0.id) && !seen.contains($0.id) }
                    if !unindexedCandidates.isEmpty {
                        await self.runDeepSearchAppend(
                            runID: newRunID,
                            query: query,
                            filters: filters,
                            candidates: unindexedCandidates,
                            initialSeen: seen,
                            finishWhenDone: !deepEnabled,
                            progressPhases: (.unindexedSmall, .unindexedLarge),
                            textScope: .all
                        )
                        if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
                        seen = await MainActor.run { Set(self.results.map(\.id)) }
                    }

                    if Task.isCancelled { await self.finishCanceled(runID: newRunID); return }
                    guard deepEnabled else { return }

                    let deepCandidates = candidates.filter { indexedIDs.contains($0.id) && !seen.contains($0.id) && Self.shouldDeepScan(session: $0) }
                    if deepCandidates.isEmpty {
                        await MainActor.run {
                            guard self.runID == newRunID else { return }
                            self.isRunning = false
                            self.progress.phase = .idle
                        }
                        return
                    }

                    await self.runDeepSearchAppend(
                        runID: newRunID,
                        query: query,
                        filters: filters,
                        candidates: deepCandidates,
                        initialSeen: seen,
                        finishWhenDone: true,
                        progressPhases: (.toolOutputsSmall, .toolOutputsLarge),
                        textScope: .toolOutputsOnly
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
                        self.isRunning = false
                        self.progress.phase = .idle
                    }
                    return
                }

                // Nothing to search.
                await MainActor.run {
                    guard self.runID == newRunID else { return }
                    self.results = []
                    self.isRunning = false
                    self.progress.phase = .idle
                }
            }
            return
        }

        // Launch orchestration
        Task { [weak self] in
            guard let self else { return }
            await self.startLegacySearch(runID: newRunID, query: query, filters: filters, allowed: allowed, all: all)
        }
    }

    private func startLegacySearch(runID: UUID, query: String, filters: Filters, allowed: Set<SessionSource>, all: [Session]) async {
        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
        currentTask = Task.detached(priority: prio) { [weak self, runID] in
            guard let self else { return }
            // Restore pre-index candidate building: all allowed sessions, no DB/hybrid tiers
            let threshold = FeatureFlags.searchSmallSizeBytes
            let candidates = all.filter { allowed.contains($0.source) }

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
            var seen = Set<String>()
            for start in stride(from: 0, to: nonLarge.count, by: batchSize) {
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }
                let end = min(start + batchSize, nonLarge.count)
                let batch = Array(nonLarge[start..<end])
                let hits = await self.searchBatch(batch: batch, query: query, filters: filters, threshold: threshold, textScope: .all)
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }

                // Filter out duplicates before entering MainActor
                let newHits = hits.filter { !seen.contains($0.id) }
                for s in newHits { seen.insert(s.id) }

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
                if FeatureFlags.lowerQoSForHeavyWork { try? await Task.sleep(nanoseconds: 10_000_000) }
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
                if let parsed = await self.parseFullIfNeeded(session: s, threshold: threshold) {
                    if Task.isCancelled { await self.finishCanceled(runID: runID); return }

                    // Optionally persist parsed session back to indexers for accuracy outside search
                    if !FeatureFlags.disableSessionUpdatesDuringSearch {
                        self.store.updateSession(parsed)
                    }

                    let cache = self.transcriptCache(for: parsed.source)
                    if FilterEngine.sessionMatches(parsed, filters: filters, transcriptCache: cache) {
                        // Check and update seen outside MainActor
                        let shouldAdd = !seen.contains(parsed.id)
                        if shouldAdd {
                            seen.insert(parsed.id)
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
                if FeatureFlags.lowerQoSForHeavyWork { try? await Task.sleep(nanoseconds: 10_000_000) }
                idx += 1
            }
            // Final flush of any staged results
            if FeatureFlags.coalesceSearchResults && !staged.isEmpty {
                let toFlush = staged
                staged.removeAll()
                await MainActor.run {
                    guard self.runID == runID else { return }
                    self.results.append(contentsOf: toFlush)
                }
            }

            if Task.isCancelled { await self.finishCanceled(runID: runID); return }
            await MainActor.run {
                guard self.runID == runID else { return }
                self.isRunning = false
                self.progress.phase = .idle
            }
        }
        await currentTask?.value
    }

    private static func shouldDeepScan(session: Session) -> Bool {
        let estimatedCommands: Int = {
            if let c = session.lightweightCommands { return c }
            if session.events.isEmpty { return 0 }
            return session.events.filter { $0.kind == .tool_call }.count
        }()
        return estimatedCommands > 0
    }

    /// Builds an FTS5 query for Instant search.
    ///
    /// We avoid trigram/substr indexing, but we can still improve recall (especially for identifiers)
    /// by using FTS prefix queries when the user's input is a simple space-delimited term list.
    private static func makeInstantFTSQuery(from freeText: String) -> String {
        let q = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return q }

        // If the user already wrote an explicit FTS query (quotes, boolean ops, prefix, etc),
        // do not rewrite it.
        let lower = q.lowercased()
        if q.contains("\"") { return q }
        if q.contains("*") { return q }
        if q.contains("(") || q.contains(")") { return q }
        if q.contains(":") { return q }
        if lower.contains(" near ") || lower.hasPrefix("near ") || lower.hasSuffix(" near") { return q }
        if lower.contains(" and ") || lower.contains(" or ") || lower.contains(" not ") { return q }

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

    private func runDeepSearchAppend(runID: UUID,
                                     query: String,
                                     filters: Filters,
                                     candidates: [Session],
                                     initialSeen: Set<String>,
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
            let hits = await self.searchBatch(batch: batch, query: query, filters: filters, threshold: threshold, textScope: textScope)
            if Task.isCancelled { await self.finishCanceled(runID: runID); return }

            let newHits = hits.filter { !seen.contains($0.id) }
            for s in newHits { seen.insert(s.id) }

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
            if FeatureFlags.lowerQoSForHeavyWork { try? await Task.sleep(nanoseconds: 10_000_000) }
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
            if let parsed = await self.parseFullIfNeeded(session: s, threshold: threshold) {
                if Task.isCancelled { await self.finishCanceled(runID: runID); return }

                if !FeatureFlags.disableSessionUpdatesDuringSearch {
                    self.store.updateSession(parsed)
                }

                if textScope == .all {
                    let cache = self.transcriptCache(for: parsed.source)
                    if FilterEngine.sessionMatches(parsed, filters: filters, transcriptCache: cache) {
                        let shouldAdd = !seen.contains(parsed.id)
                        if shouldAdd {
                            seen.insert(parsed.id)
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
                        let shouldAdd = !seen.contains(parsed.id)
                        if shouldAdd {
                            seen.insert(parsed.id)
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
            if FeatureFlags.lowerQoSForHeavyWork { try? await Task.sleep(nanoseconds: 10_000_000) }
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
                             textScope: FilterEngine.TextScope) async -> [Session] {
        var out: [Session] = []
        out.reserveCapacity(batch.count / 4)
        for var s in batch {
            if Task.isCancelled { return out }
            if s.events.isEmpty {
                // For non-large sessions only, parse quickly if needed
                let size = Self.sizeBytes(for: s)
                if size < threshold, let parsed = await parseFullIfNeeded(session: s, threshold: threshold) {
                    s = parsed
                    if !FeatureFlags.disableSessionUpdatesDuringSearch {
                        self.store.updateSession(parsed)
                    }
                }
            }
            let cache: TranscriptCache? = (textScope == .all) ? self.transcriptCache(for: s.source) : nil
            if FilterEngine.sessionMatches(s,
                                          filters: filters,
                                          transcriptCache: cache,
                                          allowTranscriptGeneration: textScope == .all,
                                          textScope: textScope) {
                out.append(s)
            }
        }
        return out
    }

    private func parseFullIfNeeded(session s: Session, threshold: Int) async -> Session? {
        await store.parseFull(session: s)
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

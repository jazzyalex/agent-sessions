import Foundation

/// Dedicated search-corpus ingest. Serial, .utility, yields between files.
///
/// Mirrors the transaction shape of the deleted `AnalyticsIndexer.indexFileIfNeeded`
/// (removed in 31f6a619 when analytics moved to a session_meta-derived pipeline) but
/// is scoped to only the search-corpus writes: `upsertFile` + `upsertSessionMeta` +
/// `upsertSessionSearch` (+ `upsertSessionToolIO` when enabled and recent). Analytics
/// (`session_days`/rollups) are out of scope here; they are derived separately from
/// `session_meta` by `AnalyticsIndexer`.
///
/// Skip-gated by `fetchSearchReadyPaths` (mtime+size+format_version), so steady-state
/// incremental runs touch only new/changed files.
actor SearchIngestService {
    struct FileRef {
        let path: String
        let mtime: Int64
        let size: Int64
    }

    struct Progress {
        let processed: Int
        let total: Int
        let skipped: Int
    }

    /// Cheap per-source aggregate of an incoming `[FileRef]` list, used to detect
    /// "nothing changed since the last completed pass" without touching SQLite.
    /// Not a substitute for the real per-file mtime/size skip-gate below — just a
    /// fast early-out for the common steady-state kick where the caller's freshly
    /// re-stat'd file list is byte-for-byte identical to what it was last time.
    private struct IngestAggregate: Equatable {
        let fileCount: Int
        let maxMtime: Int64
        let totalSize: Int64
        // Included so toggling the tool-IO preference between calls (same files,
        // same mtimes/sizes) busts the early-out and falls through to the real
        // per-file gate, which is what actually backfills the missing toolIO rows.
        let toolIOEnabled: Bool

        init(files: [FileRef], toolIOEnabled: Bool) {
            fileCount = files.count
            maxMtime = files.map(\.mtime).max() ?? 0
            totalSize = files.reduce(0) { $0 + $1.size }
            self.toolIOEnabled = toolIOEnabled
        }
    }

    private let db: IndexDB

    /// Remembered aggregate from the last ingest pass that ran to completion (no
    /// throw, no cancellation) for each source. Only ever read/written from within
    /// `ingest`, which is safe since this is an actor. Cleared implicitly by simply
    /// never being set for a source that has never completed a clean pass, which is
    /// exactly the "never ingested / last pass was interrupted" case that must always
    /// fall through to the full check rather than early-out.
    private var lastCleanAggregateBySource: [String: IngestAggregate] = [:]

    /// Test-only observability: incremented each time the aggregate early-out fires
    /// (i.e. `ingest` returned before touching `fetchIndexedFiles`/`fetchSearchReadyPaths`
    /// /`sessionSearchUpdatedAt`/toolIO map reads). Harmless in production — just a
    /// counter nobody else reads — but gives tests a way to prove the early-out path
    /// was actually taken rather than inferring it indirectly from `Progress` alone.
    private(set) var earlyOutHitCountForTesting = 0

    init(db: IndexDB) {
        self.db = db
    }

    /// Re-ingest cooldown tiers: a changed-but-quiet file is re-ingested at most
    /// this often. Big files cost a full parse to refresh a 48k-char sampled
    /// text — throttle hard; the deep-scan tier covers staleness in between.
    static func reingestCooldown(forFileSize size: Int64) -> TimeInterval {
        switch size {
        case ..<2_000_000:    return 0           // small: quiet gate alone suffices
        case ..<20_000_000:   return 15 * 60     // medium: 15 min
        default:              return 45 * 60     // large: 45 min
        }
    }

    /// Ingest one source's files. `files` comes from the caller's discovery
    /// (path+mtime+size). Returns final Progress. Cancellable between files.
    ///
    /// Caller contract (QoS): this actor does NOT downgrade its own priority — it
    /// inherits whatever priority the caller's `Task` runs at. Full parses here are
    /// exactly as expensive as the ones on the interactive refresh path (parseFileFull
    /// per file), so calling this from anything above `.utility` will contend with
    /// interactive work. Every caller MUST wrap this call in `Task(priority: .utility)`
    /// (or lower) — see `UnifiedSessionIndexer.kickSearchIngest(source:)` for the
    /// reference wiring. Do not call `ingest` directly from a `.userInitiated` or
    /// default-priority context.
    /// - Parameter quietSeconds: Re-ingest quiet-period gate (see `ingest` body comment
    ///   at the skip-check for the tradeoff this encodes). Callers should keep the
    ///   default unless a test needs a different window.
    /// - Parameter reingestCooldownOverride: Test-only override for the size-tiered
    ///   re-ingest cooldown (`reingestCooldown(forFileSize:)`). Production callers must
    ///   pass `nil` (the default) so real callers get the size-derived tiers; tests use
    ///   this to exercise the cooldown gate against tiny fixtures that would otherwise
    ///   always land in the zero-cooldown small-file tier.
    func ingest(source: SessionSource,
                files: [FileRef],
                toolIOEnabled: Bool,
                yieldNanoseconds: UInt64 = 40_000_000,
                toolIOOldBytesCap: Int64 = FeatureFlags.toolIOIndexOldBytesCap,
                quietSeconds: TimeInterval = 120,
                reingestCooldownOverride: TimeInterval? = nil) async throws -> Progress {
        let sourceRaw = source.rawValue

        // Cheap early-out, before any of the per-source SQLite map reads below: if the
        // caller's freshly re-stat'd file list is aggregate-identical to what it was on
        // the last pass that ran to completion for this source, there is nothing new to
        // ingest — every file would fall through the per-file skip-gate anyway, just
        // after paying for fetchIndexedFiles/fetchSearchReadyPaths/sessionSearchUpdatedAt
        // (+ toolIO variants). This is an optimization, not a correctness gate: a source
        // with no recorded clean pass (never ingested, or its last pass threw/was
        // cancelled) always falls through to the full check below.
        //
        // Safety valve: the quiet-period and re-ingest-cooldown gates below are
        // time-dependent (they compare `nowTS` against a stored timestamp), so a file
        // can flip from "gated" to "eligible" purely because wall-clock time passed,
        // with its FileRef (mtime/size) never changing. An aggregate match alone can't
        // see that. So the early-out additionally requires every incoming file to be
        // older than the widest possible gate window (quietSeconds and the largest
        // re-ingest cooldown tier) — i.e. no file could plausibly still be waiting out
        // a gate — before trusting "identical aggregate" to mean "nothing to do".
        let nowTS = Date().timeIntervalSince1970
        let widestGateWindow = max(quietSeconds, reingestCooldownOverride ?? Self.reingestCooldown(forFileSize: .max))
        let noFileInDangerZone = files.allSatisfy { nowTS - Double($0.mtime) >= widestGateWindow }
        let incomingAggregate = IngestAggregate(files: files, toolIOEnabled: toolIOEnabled)
        if noFileInDangerZone,
           let lastClean = lastCleanAggregateBySource[sourceRaw],
           lastClean == incomingAggregate {
            earlyOutHitCountForTesting += 1
            return Progress(processed: 0, total: files.count, skipped: files.count)
        }

        // `fetchSearchReadyPaths`/`fetchToolIOReadyPaths` only tell us the path's row is
        // format-current relative to whatever mtime/size the DB already has on file — they
        // don't compare against the caller's freshly-stat'd FileRef. Pair them with
        // `fetchIndexedFiles` (the actual stored mtime/size) so a changed file (same path,
        // new mtime) is correctly treated as not-ready rather than blindly skipped.
        var indexedByPath: [String: IndexedFileRow] = [:]
        do {
            let rows = (try? await db.fetchIndexedFiles(for: sourceRaw)) ?? []
            indexedByPath.reserveCapacity(rows.count)
            for row in rows { indexedByPath[row.path] = row }
        }
        let searchReadyPaths = (try? await db.fetchSearchReadyPaths(for: sourceRaw)) ?? []
        let toolIOReadyPaths = toolIOEnabled
            ? ((try? await db.fetchToolIOReadyPaths(for: sourceRaw)) ?? [])
            : []
        // Persistent re-ingest cooldown source of truth: `session_search.updated_at`,
        // keyed by path. Replaces the old in-memory `lastReingestAt` map (which forgot
        // on every relaunch, so the first kick after a restart re-parsed every changed
        // big file regardless of how recently it had actually been re-ingested). A path
        // absent from this map has no `session_search` row yet — same never-ingested
        // exemption as before, just backed by the DB instead of process memory.
        let updatedAtByPath = (try? await db.sessionSearchUpdatedAt(for: sourceRaw)) ?? [:]
        let toolIOCutoffTS = Int64(Date().addingTimeInterval(-Double(FeatureFlags.toolIOIndexRecentDays) * 24 * 60 * 60).timeIntervalSince1970)
        // refTS (COALESCE(end_ts, mtime)) per path, fetched once per ingest call — mirrors
        // the deleted `AnalyticsIndexer.indexFileIfNeeded`'s per-file `sessionRefTSForPath`
        // read (git show 31f6a619^), but batched. Used at the skip-gate below to tell
        // whether a file is inside or outside the toolIO recency window WITHOUT re-parsing
        // it: `ingestFile` never writes a `session_tool_io` row for a file outside the
        // window (see its `refTS >= toolIOCutoffTS` guard), so the gate must not demand one
        // for such a file either — otherwise it can never be skipped again.
        let refTSByPath = toolIOEnabled ? ((try? await db.sessionRefTSByPath(for: sourceRaw)) ?? [:]) : [:]

        var processed = 0
        var skipped = 0
        let total = files.count

        for (idx, file) in files.enumerated() {
            try Task.checkCancellation()

            let isCurrent = indexedByPath[file.path].map { $0.mtime == file.mtime && $0.size == file.size } ?? false
            if isCurrent, searchReadyPaths.contains(file.path) {
                // toolIO readiness is only a requirement for files that would actually
                // receive a toolIO row. A file whose refTS is older than the toolIO
                // recency window (`toolIOCutoffTS`) never gets one — `ingestFile` skips
                // writing `session_tool_io` for it by design (see its own `refTS >=
                // toolIOCutoffTS` guard) — so demanding `toolIOReadyPaths.contains` for
                // such a file makes it permanently un-skippable. Fall back to `file.mtime`
                // when the path has no `session_meta` row yet (refTSByPath lookup miss);
                // `isCurrent`/`searchReadyPaths` already guarantee a row exists in that
                // case in practice, but the fallback keeps this branch safe regardless.
                let refTS = refTSByPath[file.path] ?? file.mtime
                let outsideToolIOWindow = refTS < toolIOCutoffTS
                if !toolIOEnabled || toolIOReadyPaths.contains(file.path) || outsideToolIOWindow {
                    skipped += 1
                    if idx < files.count - 1 {
                        try? await Task.sleep(nanoseconds: yieldNanoseconds)
                    }
                    continue
                }
            }

            // Quiet-period gate: actively-appending session files (an agent still
            // running) get restat'd as "changed" on essentially every refresh cycle,
            // which — pre-gate — meant a hot 100MB+ transcript got fully re-parsed
            // (parseFileFull) and its search text rebuilt on every single kick, for as
            // long as the session stayed open. That's the CPU burn this gate exists to
            // stop. We only apply it to RE-ingest: a file that already has a
            // current-or-stale row in `searchReadyPaths`/`indexedByPath` (i.e. it has
            // been ingested at least once before). A file with NO existing row — first
            // time we've ever seen this path, e.g. a fresh backfill — is exempt and
            // ingests immediately regardless of how recently it was written, so initial
            // indexing is never delayed.
            //
            // Tradeoff: content appended to an in-progress session reaches the FTS
            // index within ~quietSeconds of the session going quiet (plus the size-tiered
            // re-ingest cooldown below), not instantly. Freshness during that gap is NOT
            // provided by the opt-in `.toolOutputsOnly` deep-scan tier (an earlier comment
            // claimed it was — that was wrong; deep scan is off by default and only reads
            // tool output). Instead, the SEARCH path covers the gap: `indexedSessionIDsCurrent`
            // compares each `session_search` row's stored mtime/size against the file's current
            // values, so a changed-but-not-yet-reingested session is treated as unindexed and
            // the legacy full-scan (SearchCoordinator.shouldIncludeUnindexedCandidate, which
            // bypasses the size gate for such stale rows) reads it directly and returns fresh
            // results until this service catches up.
            let hasExistingRow = indexedByPath[file.path] != nil || searchReadyPaths.contains(file.path)
            if hasExistingRow {
                // Clamp to zero: a future mtime (clock skew, or a test/fixture that
                // deliberately sets mtime slightly ahead of "now") is "as hot as it
                // gets", not exempt from the gate via a spuriously-negative age.
                let age = max(0, nowTS - Double(file.mtime))
                if age < quietSeconds {
                    skipped += 1
                    if idx < files.count - 1 {
                        try? await Task.sleep(nanoseconds: yieldNanoseconds)
                    }
                    continue
                }

                // Size-aware re-ingest cooldown: a file that has already cleared the
                // quiet gate (i.e. it looks stable right now) can still be a
                // multi-hundred-MB session that changes all day, crossing quiet->changed
                // repeatedly. Each crossing costs a full parseFileFull + a 48k-char
                // sampled-text rebuild — throttle those refreshes independently of
                // quietSeconds, scaled by file size. Persisted in `session_search.updated_at`
                // (via `updatedAtByPath`, read once above) rather than in-memory, so the
                // cooldown survives app relaunch: same never-ingested exemption as the quiet
                // gate — a path with no row (nil lookup) always proceeds.
                let cooldown = reingestCooldownOverride ?? Self.reingestCooldown(forFileSize: file.size)
                if cooldown > 0, let lastTS = updatedAtByPath[file.path], nowTS - Double(lastTS) < cooldown {
                    skipped += 1
                    if idx < files.count - 1 {
                        try? await Task.sleep(nanoseconds: yieldNanoseconds)
                    }
                    continue
                }
            }

            let didIngest = await ingestFile(file, source: source, sourceRaw: sourceRaw,
                                              toolIOEnabled: toolIOEnabled, toolIOCutoffTS: toolIOCutoffTS)
            if didIngest {
                processed += 1
            } else {
                skipped += 1
            }

            if idx < files.count - 1 {
                try Task.checkCancellation()
                try? await Task.sleep(nanoseconds: yieldNanoseconds)
            }
        }

        // Retention housekeeping: mirrors the deleted `AnalyticsIndexer.refreshDelta`/
        // `indexAll` prune calls (git show 31f6a619) — run once per completed ingest
        // pass, not per file, and only when tool-IO indexing is on. `pruneOldToolIO`
        // itself is a cheap no-op when the corpus is already under cap, so calling it
        // unconditionally here (rather than only on `processed > 0`) is fine and also
        // catches drift caused by the passage of time alone (the recent-days window
        // sliding past previously-recent rows even with no new files).
        if toolIOEnabled {
            let _span = Perf.begin("searchIngestPrune", thresholdMs: 200, "source=\(sourceRaw)")
            defer { Perf.end(_span) }
            try? await db.pruneOldToolIO(cutoffTS: toolIOCutoffTS, oldBytesCap: toolIOOldBytesCap)
        }

        // Reaching here means the pass ran to completion (no throw/cancellation
        // propagated out of the loop above) — safe to remember this source's
        // aggregate as the early-out baseline for the next kick.
        lastCleanAggregateBySource[sourceRaw] = incomingAggregate

        return Progress(processed: processed, total: total, skipped: skipped)
    }

    // MARK: - Per-file ingest

    /// Full-parses one file, builds search text, and upserts everything in a single
    /// transaction. Parsed session lifetime is scoped to this call: it is released once
    /// the function returns. Returns true if the file was ingested, false if parsing failed
    /// (in which case the file is counted as skipped rather than processed).
    private func ingestFile(_ file: FileRef,
                             source: SessionSource,
                             sourceRaw: String,
                             toolIOEnabled: Bool,
                             toolIOCutoffTS: Int64) async -> Bool {
        let url = URL(fileURLWithPath: file.path)
        let _span = Perf.begin("searchIngestFile", thresholdMs: 200, "path=\(url.lastPathComponent)")
        defer { Perf.end(_span) }

        guard let session = Self.parseFileFull(url: url, source: source) else { return false }

        let times = session.events.compactMap { $0.timestamp }
        let start = session.startTime ?? times.min() ?? Date(timeIntervalSince1970: TimeInterval(file.mtime))
        let end = session.endTime ?? times.max() ?? Date(timeIntervalSince1970: TimeInterval(file.mtime))
        let refTS = Int64(end.timeIntervalSince1970)
        let messages = session.events.filter { $0.kind != .meta }.count
        let commands = session.events.filter { $0.kind == .tool_call }.count

        let meta = SessionMetaRow(
            sessionID: session.id,
            source: sourceRaw,
            path: session.filePath,
            mtime: file.mtime,
            size: file.size,
            startTS: Int64(start.timeIntervalSince1970),
            endTS: Int64(end.timeIntervalSince1970),
            model: session.model,
            cwd: session.cwd,
            repo: session.repoName,
            title: session.title,
            codexInternalSessionID: session.codexInternalSessionIDHint ?? session.codexInternalSessionID,
            isHousekeeping: session.isHousekeeping,
            messages: messages,
            commands: commands,
            parentSessionID: session.parentSessionID,
            subagentType: session.subagentType,
            customTitle: session.customTitle
        )

        let searchText = SessionSearchTextBuilder.build(session: session)
        let toolIOText: String? = {
            guard toolIOEnabled else { return nil }
            guard refTS >= toolIOCutoffTS else { return nil }
            return SessionSearchTextBuilder.buildToolIO(session: session)
        }()

        do {
            try await db.begin()
            try await db.upsertFile(path: session.filePath, mtime: file.mtime, size: file.size, source: sourceRaw)
            try await db.upsertSessionMeta(meta)
            try await db.upsertSessionSearch(sessionID: session.id, source: sourceRaw, mtime: file.mtime, size: file.size, text: searchText)
            if let toolIOText {
                try await db.upsertSessionToolIO(sessionID: session.id, source: sourceRaw, mtime: file.mtime, size: file.size, refTS: refTS, text: toolIOText)
            }
            try await db.commit()
            return true
        } catch {
            await db.rollbackSilently()
            return false
        }
    }

    // MARK: - Parser dispatch

    /// Mirrors the deleted `AnalyticsIndexer.parseSession(url:source:)` dispatch
    /// (git show 31f6a619). Each branch instantiates a throwaway parser exactly as the
    /// deleted code did.
    private static func parseFileFull(url: URL, source: SessionSource) -> Session? {
        switch source {
        case .codex:
            return SessionIndexer().parseFileFull(at: url)
        case .claude:
            return ClaudeSessionParser.parseFileFull(at: url)
        case .opencode:
            return OpenCodeSessionParser.parseFileFull(at: url)
        case .copilot:
            return CopilotSessionParser.parseFileFull(at: url)
        case .droid:
            return DroidSessionParser.parseFileFull(at: url)
        case .antigravity:
            return AntigravitySessionParser.parseFileFull(at: url)
        case .hermes:
            return HermesSessionParser.parseFileFull(at: url)
        case .openclaw:
            return OpenClawSessionParser.parseFileFull(at: url)
        case .cursor:
            return CursorSessionParser.parseFileFull(at: url)
        case .pi:
            return PiSessionParser.parseFileFull(at: url)
        }
    }
}

/// Pure per-source single-flight + coalesce state machine for search-ingest triggers.
///
/// Mirrors the in-flight/pending idiom of `UnifiedSessionIndexer.ProviderRefreshCoordinator`
/// (same file, `request`/`finish` shape) but drops the coalesce-window delay: an ingest
/// request for a source that is not currently running starts immediately; a request that
/// arrives while that source's ingest is in flight is coalesced into a single pending
/// re-run (not queued per-request — a burst of N requests during one ingest still yields
/// exactly one follow-up run once the in-flight run finishes).
///
/// Deliberately free of `IndexDB`/`SearchIngestService`/actor isolation so the state
/// transitions can be unit-tested in isolation from the database and file I/O.
struct SearchIngestCoordinator {
    enum RequestDecision: Equatable {
        /// No ingest is running for this source: caller should start one now.
        case startNow
        /// An ingest is already running for this source: caller should do nothing:
        /// the in-flight run's `finish()` will report a follow-up is needed.
        case coalesced
    }

    private struct State {
        var inFlight: Bool = false
        var pending: Bool = false
    }

    private var states: [SessionSource: State] = [:]

    init() {}

    /// Call when a source's refresh completes and search-ingest should run for it.
    mutating func request(source: SessionSource) -> RequestDecision {
        var state = states[source] ?? State()
        if state.inFlight {
            state.pending = true
            states[source] = state
            return .coalesced
        }
        state.inFlight = true
        state.pending = false
        states[source] = state
        return .startNow
    }

    /// Call when an in-flight ingest for `source` finishes (success, failure, or
    /// cancellation). Returns `true` if a request coalesced while it was running,
    /// meaning the caller should immediately start exactly one follow-up run.
    mutating func finish(source: SessionSource) -> Bool {
        var state = states[source] ?? State()
        state.inFlight = false
        let shouldRunAgain = state.pending
        state.pending = false
        states[source] = state
        return shouldRunAgain
    }

    /// True if `source` currently has an ingest running (test/debug convenience).
    func isInFlight(source: SessionSource) -> Bool {
        states[source]?.inFlight ?? false
    }
}

/// Actor wrapper giving `SearchIngestCoordinator`'s pure state machine safe concurrent
/// access from any caller context (mirrors how `UnifiedSessionIndexer.ProviderRefreshCoordinator`
/// is itself an actor). The state-transition logic lives in the wrapped struct so it can be
/// unit-tested without actor isolation getting in the way.
actor SearchIngestCoordinatorBox {
    private var coordinator = SearchIngestCoordinator()
    private var tasksBySource: [SessionSource: Task<Void, Never>] = [:]

    func request(source: SessionSource) -> SearchIngestCoordinator.RequestDecision {
        coordinator.request(source: source)
    }

    func finish(source: SessionSource) -> Bool {
        let shouldRunAgain = coordinator.finish(source: source)
        if !shouldRunAgain {
            tasksBySource[source] = nil
        }
        return shouldRunAgain
    }

    /// Creates the ingest task for `source` at `.utility` and records it under
    /// `tasksBySource` in one actor-isolated step, so `cancelAll()` can never observe a
    /// running-but-untracked task. Creation and storage have no suspension point between
    /// them, so any later actor method (`cancelAll`, `finish`) is guaranteed to see the
    /// task. Crucially, `operation` needs no reference to its own `Task`: this removes the
    /// self-reference race a caller-side `var task: Task! = Task { track(task) }` hits, where
    /// the detached body can read the still-nil implicitly-unwrapped optional before the
    /// assignment lands and trap on the force-unwrap.
    func startTracked(source: SessionSource, _ operation: @escaping @Sendable () async -> Void) {
        let task = Task.detached(priority: .utility) {
            await operation()
        }
        tasksBySource[source] = task
    }

    /// Cancels every in-flight (and any not-yet-started coalesced) ingest task. Call from
    /// the owning indexer's `deinit` / app-quit path for DB/process-teardown safety.
    func cancelAll() {
        for task in tasksBySource.values { task.cancel() }
        tasksBySource.removeAll()
    }
}

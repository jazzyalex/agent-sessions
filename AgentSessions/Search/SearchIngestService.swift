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

    private let db: IndexDB

    init(db: IndexDB) {
        self.db = db
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
    func ingest(source: SessionSource,
                files: [FileRef],
                toolIOEnabled: Bool,
                yieldNanoseconds: UInt64 = 40_000_000,
                toolIOOldBytesCap: Int64 = FeatureFlags.toolIOIndexOldBytesCap,
                quietSeconds: TimeInterval = 120) async throws -> Progress {
        let sourceRaw = source.rawValue
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
        let toolIOCutoffTS = Int64(Date().addingTimeInterval(-Double(FeatureFlags.toolIOIndexRecentDays) * 24 * 60 * 60).timeIntervalSince1970)

        var processed = 0
        var skipped = 0
        let total = files.count
        let nowTS = Date().timeIntervalSince1970

        for (idx, file) in files.enumerated() {
            try Task.checkCancellation()

            let isCurrent = indexedByPath[file.path].map { $0.mtime == file.mtime && $0.size == file.size } ?? false
            if isCurrent, searchReadyPaths.contains(file.path) {
                if !toolIOEnabled || toolIOReadyPaths.contains(file.path) {
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
            // index within ~quietSeconds of the session going quiet (not instantly).
            // The deep-scan search tier (which reads files directly, uninfluenced by
            // this cache) covers that gap in the meantime.
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

    /// Records the running task for `source` so `cancelAll()` can stop it on teardown.
    func track(_ task: Task<Void, Never>, for source: SessionSource) {
        tasksBySource[source] = task
    }

    /// Cancels every in-flight (and any not-yet-started coalesced) ingest task. Call from
    /// the owning indexer's `deinit` / app-quit path for DB/process-teardown safety.
    func cancelAll() {
        for task in tasksBySource.values { task.cancel() }
        tasksBySource.removeAll()
    }
}

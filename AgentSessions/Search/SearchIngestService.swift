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
    /// Authoritative identity view produced by the provider's just-completed refresh.
    /// nil at the call site means enumeration failed, which must never be interpreted
    /// as an empty database.
    struct IdentitySnapshot: Equatable, Sendable {
        let storagePaths: Set<String>
        let sessionIDs: Set<String>

        static let empty = IdentitySnapshot(storagePaths: [], sessionIDs: [])

        /// Authoritative absence of identities at a provider-owned live database path.
        /// Keeping the path is what lets cleanup remove rows from a database that was
        /// deleted or replaced by a legacy backend without claiming archive copies.
        static func authoritativeEmpty(storagePath: String) -> IdentitySnapshot {
            IdentitySnapshot(storagePaths: [storagePath], sessionIDs: [])
        }

        /// Safe constructor for the "database is gone" case. Cleanup reads an empty
        /// snapshot as *delete every identity row for this path*, so a bare
        /// `fileExists == false` is not enough evidence: the same false is returned when
        /// the enclosing directory is missing or momentarily unreachable (unmounted
        /// volume, revoked sandbox access, a root override pointing somewhere not yet
        /// created). Absence is only authoritative when the directory that would contain
        /// the database is itself present. Otherwise this returns nil — unknown — and the
        /// caller makes no claim, exactly like a failed enumeration.
        static func authoritativeAbsence(ofDatabaseAt url: URL,
                                         fileProbe: any FileProbing = DefaultFileProbe()) -> IdentitySnapshot? {
            guard !fileProbe.fileExists(atPath: url.path) else { return nil }
            let container = url.deletingLastPathComponent()
            guard fileProbe.directoryExists(atPath: container.path) else { return nil }
            return .authoritativeEmpty(storagePath: url.path)
        }
    }

    /// Opaque per-session content revision for sources whose sessions share one storage URL.
    /// `updatedMillis` comes from the lightweight session row; `extent` catches
    /// same-timestamp message-count changes.
    struct ContentRevision: Equatable, Hashable, Sendable {
        let updatedMillis: Int64
        let extent: Int64
    }

    struct FileRef {
        let path: String
        let mtime: Int64
        let size: Int64
        /// Stable identity for sources where multiple sessions share one storage path.
        /// nil preserves the path-identified behavior used by ordinary transcript files.
        let sessionID: String?
        let contentRevision: ContentRevision?

        init(path: String,
             mtime: Int64,
             size: Int64,
             sessionID: String? = nil,
             contentRevision: ContentRevision? = nil) {
            self.path = path
            self.mtime = mtime
            self.size = size
            self.sessionID = sessionID
            self.contentRevision = contentRevision
        }

        var searchMtime: Int64 { contentRevision?.updatedMillis ?? mtime }
        var searchSize: Int64 { contentRevision?.extent ?? size }
        var activityTimestamp: TimeInterval {
            contentRevision.map { TimeInterval($0.updatedMillis) / 1_000.0 } ?? TimeInterval(mtime)
        }
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
        struct FileIdentity: Equatable {
            let path: String
            let mtime: Int64
            let size: Int64
            let sessionID: String?
            let contentRevision: ContentRevision?
        }

        /// Preserve the caller's complete ordered input. In particular, a shared-DB
        /// identity can move from a live database to a pinned archive with the exact
        /// same revision and caller-supplied stat; its path is still lifecycle state.
        let files: [FileIdentity]
        /// nil is a failed provider read, while an empty/non-empty value is authoritative.
        /// That distinction must participate in the early-out just like the file refs.
        let identitySnapshot: IdentitySnapshot?
        // Included so toggling the tool-IO preference between calls (same files,
        // same mtimes/sizes) busts the early-out and falls through to the real
        // per-file gate, which is what actually backfills the missing toolIO rows.
        let toolIOEnabled: Bool

        init(files: [FileRef], identitySnapshot: IdentitySnapshot?, toolIOEnabled: Bool) {
            self.files = files.map { file in
                FileIdentity(path: file.path,
                             mtime: file.mtime,
                             size: file.size,
                             sessionID: file.sessionID,
                             contentRevision: file.contentRevision)
            }
            self.identitySnapshot = identitySnapshot
            self.toolIOEnabled = toolIOEnabled
        }
    }

    private struct CleanIngestState {
        let aggregate: IngestAggregate
        let dbGeneration: Int64
    }

    nonisolated static func contentRevision(for session: Session) -> ContentRevision {
        let updated = session.endTime ?? session.startTime ?? Date(timeIntervalSince1970: 0)
        return ContentRevision(updatedMillis: Int64((updated.timeIntervalSince1970 * 1_000.0).rounded()),
                               extent: Int64(session.eventCount))
    }

    /// Hydration replaces a DB-backed lightweight session's provider message count with
    /// a rendered event count. The latter is not the identity revision's logical extent,
    /// so compare it only while the session is still lightweight. The provider refresh
    /// replaces hydrated rows with fresh lightweight rows, restoring the full two-part
    /// comparison whenever the authoritative database snapshot changes.
    nonisolated static func contentRevision(_ stored: ContentRevision, matches session: Session) -> Bool {
        let current = contentRevision(for: session)
        guard stored.updatedMillis == current.updatedMillis else { return false }
        return !session.events.isEmpty || stored.extent == current.extent
    }

    private let db: IndexDB

    /// Remembered aggregate from the last ingest pass that ran to completion (no
    /// throw, no cancellation) for each source. Only ever read/written from within
    /// `ingest`, which is safe since this is an actor. Cleared implicitly by simply
    /// never being set for a source that has never completed a clean pass, which is
    /// exactly the "never ingested / last pass was interrupted" case that must always
    /// fall through to the full check rather than early-out.
    private var lastCleanAggregateBySource: [String: CleanIngestState] = [:]

    /// Test-only observability: incremented each time the aggregate early-out fires
    /// (i.e. `ingest` returned after the cheap generation check but before touching
    /// `fetchIndexedFiles`/`fetchSearchReadyPaths`/`sessionSearchUpdatedAt`/toolIO
    /// maps). Harmless in production — just a
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
                identitySnapshot: IdentitySnapshot? = nil,
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
        let noFileInDangerZone = files.allSatisfy { nowTS - $0.activityTimestamp >= widestGateWindow }
        let incomingAggregate = IngestAggregate(files: files,
                                                identitySnapshot: identitySnapshot,
                                                toolIOEnabled: toolIOEnabled)
        // Rebuild Core Index advances this DB-backed token in the purge transaction.
        // A read failure disables the optimization for this pass; it is never treated
        // as a matching generation.
        let dbGenerationAtStart = try? await db.searchIngestGeneration(source: sourceRaw)
        if noFileInDangerZone,
           let lastClean = lastCleanAggregateBySource[sourceRaw],
           let dbGenerationAtStart,
           lastClean.dbGeneration == dbGenerationAtStart,
           lastClean.aggregate == incomingAggregate {
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
        let descriptor = source.descriptor
        let usesSessionIdentity = descriptor.parseFullByIdentity != nil
            && descriptor.searchUsesIdentityAtURL != nil
        let searchIdentityStatesBySessionID = usesSessionIdentity
            ? ((try? await db.sessionSearchIdentityStatesByID(for: sourceRaw)) ?? [:])
            : [:]
        let toolIOReadyPaths = toolIOEnabled
            ? ((try? await db.fetchToolIOReadyPaths(for: sourceRaw)) ?? [])
            : []
        let toolIOIdentityStatesBySessionID = toolIOEnabled && usesSessionIdentity
            ? ((try? await db.sessionToolIOIdentityStatesByID(for: sourceRaw)) ?? [:])
            : [:]
        // Persistent re-ingest cooldown source of truth: `session_search.updated_at`,
        // keyed by path. Replaces the old in-memory `lastReingestAt` map (which forgot
        // on every relaunch, so the first kick after a restart re-parsed every changed
        // big file regardless of how recently it had actually been re-ingested). A path
        // absent from this map has no `session_search` row yet — same never-ingested
        // exemption as before, just backed by the DB instead of process memory.
        let updatedAtByPath = (try? await db.sessionSearchUpdatedAt(for: sourceRaw)) ?? [:]
        let updatedAtBySessionID = usesSessionIdentity
            ? ((try? await db.sessionSearchUpdatedAtByID(for: sourceRaw)) ?? [:])
            : [:]
        let toolIOCutoffTS = Int64(Date().addingTimeInterval(-Double(FeatureFlags.toolIOIndexRecentDays) * 24 * 60 * 60).timeIntervalSince1970)
        // refTS (COALESCE(end_ts, mtime)) per path, fetched once per ingest call — mirrors
        // the deleted `AnalyticsIndexer.indexFileIfNeeded`'s per-file `sessionRefTSForPath`
        // read (git show 31f6a619^), but batched. Used at the skip-gate below to tell
        // whether a file is inside or outside the toolIO recency window WITHOUT re-parsing
        // it: `ingestFile` never writes a `session_tool_io` row for a file outside the
        // window (see its `refTS >= toolIOCutoffTS` guard), so the gate must not demand one
        // for such a file either — otherwise it can never be skipped again.
        let refTSByPath = toolIOEnabled ? ((try? await db.sessionRefTSByPath(for: sourceRaw)) ?? [:]) : [:]
        let refTSBySessionID = toolIOEnabled && usesSessionIdentity
            ? ((try? await db.sessionRefTSByID(for: sourceRaw)) ?? [:])
            : [:]

        var processed = 0
        var skipped = 0
        var hadIngestFailure = false
        let total = files.count

        for (idx, file) in files.enumerated() {
            try Task.checkCancellation()

            let pathIsCurrent = indexedByPath[file.path].map { $0.mtime == file.mtime && $0.size == file.size } ?? false
            let identityIsCurrent = file.sessionID.flatMap { id in
                file.contentRevision.map {
                    searchIdentityStatesBySessionID[id]?.storagePath == file.path
                        && searchIdentityStatesBySessionID[id]?.revision == $0
                }
            }
            let isCurrent = identityIsCurrent ?? pathIsCurrent
            let searchIsReady = identityIsCurrent ?? searchReadyPaths.contains(file.path)
            if isCurrent, searchIsReady {
                // toolIO readiness is only a requirement for files that would actually
                // receive a toolIO row. A file whose refTS is older than the toolIO
                // recency window (`toolIOCutoffTS`) never gets one — `ingestFile` skips
                // writing `session_tool_io` for it by design (see its own `refTS >=
                // toolIOCutoffTS` guard) — so demanding `toolIOReadyPaths.contains` for
                // such a file makes it permanently un-skippable. Fall back to `file.mtime`
                // when the path has no `session_meta` row yet (refTSByPath lookup miss);
                // `isCurrent`/`searchReadyPaths` already guarantee a row exists in that
                // case in practice, but the fallback keeps this branch safe regardless.
                let refTS = file.sessionID.flatMap { refTSBySessionID[$0] }
                    ?? refTSByPath[file.path]
                    ?? file.mtime
                let outsideToolIOWindow = refTS < toolIOCutoffTS
                let toolIOIsReady = file.sessionID.flatMap { id in
                    file.contentRevision.map {
                        toolIOIdentityStatesBySessionID[id]?.storagePath == file.path
                            && toolIOIdentityStatesBySessionID[id]?.revision == $0
                    }
                } ?? toolIOReadyPaths.contains(file.path)
                if !toolIOEnabled || toolIOIsReady || outsideToolIOWindow {
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
            let hasExistingRow = file.sessionID.map {
                searchIdentityStatesBySessionID[$0]?.storagePath == file.path
                    && updatedAtBySessionID[$0] != nil
            }
                ?? (indexedByPath[file.path] != nil || searchReadyPaths.contains(file.path))
            if hasExistingRow {
                // Clamp to zero: a future mtime (clock skew, or a test/fixture that
                // deliberately sets mtime slightly ahead of "now") is "as hot as it
                // gets", not exempt from the gate via a spuriously-negative age.
                let age = max(0, nowTS - file.activityTimestamp)
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
                let lastTS = file.sessionID.flatMap { updatedAtBySessionID[$0] }
                    ?? updatedAtByPath[file.path]
                if cooldown > 0, let lastTS, nowTS - Double(lastTS) < cooldown {
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
                hadIngestFailure = true
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

        // A shared database can lose every session while its storage path remains. Reconcile
        // identities per explicitly owned path: current identity FileRefs cover both live and
        // pinned archive databases, while the provider snapshot keeps its configured live path
        // authoritative even when empty. Previously owned paths are loaded from index_state so
        // a root override or unpinned archive is retired on the next authoritative pass. Never use
        // arbitrary paths from session_meta/files as ownership evidence.
        if usesSessionIdentity {
            if let identitySnapshot {
                do {
                    var currentIDsByPath: [String: Set<String>] = [:]
                    for file in files {
                        if let sessionID = file.sessionID {
                            currentIDsByPath[file.path, default: []].insert(sessionID)
                        }
                    }
                    for path in identitySnapshot.storagePaths {
                        currentIDsByPath[path, default: []].formUnion(identitySnapshot.sessionIDs)
                    }
                    try await db.reconcileSearchIdentityStorage(
                        source: sourceRaw,
                        currentIDsByPath: currentIDsByPath
                    )
                } catch {
                    hadIngestFailure = true
                }
            } else {
                // A failed provider-live read cannot authorize deletion or retirement.
                // Current identity FileRefs (notably pinned archives) are still trustworthy
                // path ownership, so persist those additions for a later authoritative pass.
                let currentPaths = Set(files.compactMap { file in
                    file.sessionID == nil ? nil : file.path
                })
                do {
                    try await db.preserveSearchIdentityStoragePaths(
                        source: sourceRaw,
                        additionalPaths: currentPaths
                    )
                } catch {
                    hadIngestFailure = true
                }
                // Keep retrying after a provider read failure. Remembering this aggregate
                // as clean would strand the persisted corpus indefinitely.
                hadIngestFailure = true
            }
        }

        // Reaching here means the pass ran to completion (no throw/cancellation
        // propagated out of the loop above) — safe to remember this source's
        // aggregate as the early-out baseline for the next kick.
        if !hadIngestFailure,
           let dbGenerationAtStart,
           let dbGenerationAtEnd = try? await db.searchIngestGeneration(source: sourceRaw),
           dbGenerationAtStart == dbGenerationAtEnd {
            lastCleanAggregateBySource[sourceRaw] = CleanIngestState(
                aggregate: incomingAggregate,
                dbGeneration: dbGenerationAtEnd
            )
        } else {
            lastCleanAggregateBySource[sourceRaw] = nil
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

        guard let session = Self.parseFileFull(url: url,
                                               source: source,
                                               sessionID: file.sessionID) else { return false }

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
            // For shared SQLite storage, analytics freshness must follow the logical
            // session revision rather than the database file stat (which can remain
            // unchanged while writes live in the WAL). Ordinary files still resolve
            // these accessors to their physical mtime/size.
            mtime: file.searchMtime,
            size: file.searchSize,
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
            try await db.upsertSessionSearch(sessionID: session.id,
                                             source: sourceRaw,
                                             mtime: file.searchMtime,
                                             size: file.searchSize,
                                             text: searchText)
            if let toolIOText {
                try await db.upsertSessionToolIO(sessionID: session.id,
                                                 source: sourceRaw,
                                                 mtime: file.searchMtime,
                                                 size: file.searchSize,
                                                 refTS: refTS,
                                                 text: toolIOText)
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
    /// (git show 31f6a619). The twelve-arm switch that used to live here is now the
    /// `parseFullByPath` closure on each source's descriptor — same throwaway-parser bodies,
    /// arm for arm. A source whose descriptor declines path-identified parsing (`nil`, e.g. a
    /// future DB-backed source where every session shares one path — SPEC §4) yields no
    /// session, exactly as an unhandled source would have.
    private static func parseFileFull(url: URL,
                                      source: SessionSource,
                                      sessionID: String?) -> Session? {
        let descriptor = SessionSourceRegistry.descriptor(for: source)
        if let sessionID, let parseFullByIdentity = descriptor.parseFullByIdentity {
            return parseFullByIdentity(url, sessionID)
        }
        return descriptor.parseFullByPath?(url)
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

    /// Call when an in-flight ingest pass for `source` finishes. Returns `true` if a
    /// request coalesced while it was running, meaning the same tracked task should
    /// immediately perform exactly one follow-up pass. `inFlight` stays true across
    /// that hand-off so another kick cannot start an overlapping task in the gap.
    mutating func finish(source: SessionSource) -> Bool {
        var state = states[source] ?? State()
        let shouldRunAgain = state.pending
        state.inFlight = shouldRunAgain
        state.pending = false
        states[source] = state
        return shouldRunAgain
    }

    mutating func cancelAll() {
        states.removeAll()
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
    private var acceptsRequests = true

    func finish(source: SessionSource) -> Bool {
        let shouldRunAgain = coordinator.finish(source: source)
        if !shouldRunAgain {
            tasksBySource[source] = nil
        }
        return shouldRunAgain
    }

    /// Makes the single-flight decision and, only for `.startNow`, creates and records the
    /// ingest task in one actor-isolated step. A coalesced kick therefore cannot replace
    /// the handle of the task that is actually ingesting. Creation and storage have no
    /// suspension point between them, so a later `cancelAll()` always sees that task.
    ///
    /// `nil` means teardown won the race with a caller-side request task. Once teardown
    /// starts this box never accepts another ingest, preventing a request that was queued
    /// just before owner deinitialization from installing work after `cancelAll()`.
    @discardableResult
    func requestTracked(source: SessionSource,
                        _ operation: @escaping @Sendable () async -> Void) -> SearchIngestCoordinator.RequestDecision? {
        guard acceptsRequests else { return nil }
        let decision = coordinator.request(source: source)
        guard decision == .startNow else { return decision }
        let task = Task.detached(priority: .utility) {
            await operation()
        }
        tasksBySource[source] = task
        return decision
    }

    /// Cancels every in-flight (and any not-yet-started coalesced) ingest task. Call from
    /// the owning indexer's `deinit` / app-quit path for DB/process-teardown safety.
    func cancelAll() {
        acceptsRequests = false
        for task in tasksBySource.values { task.cancel() }
        tasksBySource.removeAll()
        coordinator.cancelAll()
    }
}

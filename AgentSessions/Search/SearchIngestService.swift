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
    func ingest(source: SessionSource,
                files: [FileRef],
                toolIOEnabled: Bool,
                yieldNanoseconds: UInt64 = 40_000_000) async throws -> Progress {
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

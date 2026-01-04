import Foundation

/// Background indexer that discovers session files, parses them, and updates the rollup database.
/// Designed for minimal main-thread work and efficient refreshes.
actor AnalyticsIndexer {
    struct Progress: Equatable { let processed: Int; let total: Int; let phase: String }

    private let db: IndexDB
    private let enabledSources: Set<String>
    private let codex = CodexSessionDiscovery()
    private let claude = ClaudeSessionDiscovery()
    private let gemini = GeminiSessionDiscovery()
    private let opencode = OpenCodeSessionDiscovery()
    private let copilot = CopilotSessionDiscovery()
    private let droid = DroidSessionDiscovery()

    init(db: IndexDB, enabledSources: Set<String>) {
        self.db = db
        self.enabledSources = enabledSources
    }

    // MARK: - Public API
    func fullBuild() async {
        await indexAll(incremental: false)
    }

    func refresh() async {
        await indexAll(incremental: true)
    }

    // MARK: - Core
    private func indexAll(incremental: Bool) async {
        LaunchProfiler.log("Analytics.indexAll start (incremental=\(incremental))")
        let toolIOEnabled = toolIOIndexEnabled()
        let toolIOCutoffTS = Int64(Date().addingTimeInterval(-Double(FeatureFlags.toolIOIndexRecentDays) * 24 * 60 * 60).timeIntervalSince1970)
        // One-time migration: switch Claude sessions to stable logical IDs based on in-file sessionId.
        // Purge old Claude rows (which used path-hash IDs) once, then rebuild.
        // No destructive purges at startup; rely on refresh to reconcile

        let sources: [(String, () -> [URL])] = [
            ("codex", { self.codex.discoverSessionFiles() }),
            ("claude", { self.claude.discoverSessionFiles() }),
            ("gemini", { self.gemini.discoverSessionFiles() }),
            ("opencode", { self.opencode.discoverSessionFiles() }),
            ("copilot", { self.copilot.discoverSessionFiles() }),
            ("droid", { self.droid.discoverSessionFiles() })
        ]

        for (source, enumerate) in sources {
            if !enabledSources.contains(source) { continue }
            var files = enumerate()
            if source == "claude" {
                // Never index Agent Sessions' Claude probe project sessions; they are hidden by default
                // and contain large synthetic payloads that slow search and grow the DB.
                files.removeAll { $0.path.contains("AgentSessions-ClaudeProbeProject") }
            }
            if !incremental {
                // Full rebuild: purge everything for the source and reindex.
                do { try await db.purgeSource(source) } catch { /* non-fatal */ }
            }
            if files.isEmpty { continue }

            // Incremental refresh: skip unchanged files and delete rows for removed files.
            var indexedByPath: [String: IndexedFileRow] = [:]
            var searchReadyPaths = Set<String>()
            var toolIOReadyPaths = Set<String>()
            if incremental {
                let indexed = (try? await db.fetchIndexedFiles(for: source)) ?? []
                indexedByPath.reserveCapacity(indexed.count)
                for row in indexed { indexedByPath[row.path] = row }
                searchReadyPaths = (try? await db.fetchSearchReadyPaths(for: source, formatVersion: FeatureFlags.sessionSearchFormatVersion)) ?? []
                if toolIOEnabled {
                    toolIOReadyPaths = (try? await db.fetchToolIOReadyPaths(for: source, formatVersion: FeatureFlags.sessionToolIOFormatVersion)) ?? []
                }

                let currentPaths = Set(files.map(\.path))
                // Clean up any stale DB rows even if they predate the `files` table (e.g., older index versions).
                let knownMetaPaths = Set((try? await db.fetchSessionMetaPaths(for: source)) ?? [])
                let stalePaths = Array(knownMetaPaths.subtracting(currentPaths))
                if !stalePaths.isEmpty {
                    do {
                        try await db.begin()
                        let affectedDays = try await db.deleteSessionsForPaths(source: source, paths: stalePaths)
                        for day in Set(affectedDays) {
                            try await db.recomputeRollups(day: day, source: source)
                        }
                        try await db.commit()
                    } catch {
                        await db.rollbackSilently()
                    }
                }
            }

            // Bound concurrency to keep CPU/IO modest
            let chunk = 8
            for slice in stride(from: 0, to: files.count, by: chunk).map({ Array(files[$0..<min($0+chunk, files.count)]) }) {
                await withTaskGroup(of: Void.self) { group in
                    for url in slice {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            await self.indexFileIfNeeded(url: url,
                                                         source: source,
                                                         incremental: incremental,
                                                         indexedByPath: indexedByPath,
                                                         searchReadyPaths: searchReadyPaths,
                                                         toolIOReadyPaths: toolIOReadyPaths,
                                                         toolIOEnabled: toolIOEnabled,
                                                         toolIOCutoffTS: toolIOCutoffTS)
                        }
                    }
                    await group.waitForAll()
                }
            }
        }

        if toolIOEnabled {
            try? await db.pruneOldToolIO(cutoffTS: toolIOCutoffTS, oldBytesCap: FeatureFlags.toolIOIndexOldBytesCap)
        }
        LaunchProfiler.log("Analytics.indexAll complete (incremental=\(incremental))")
    }

    private func indexFileIfNeeded(url: URL,
                                   source: String,
                                   incremental: Bool,
                                   indexedByPath: [String: IndexedFileRow],
                                   searchReadyPaths: Set<String>,
                                   toolIOReadyPaths: Set<String>,
                                   toolIOEnabled: Bool,
                                   toolIOCutoffTS: Int64) async {
        // Stat
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        let mtime = Int64(((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)

        if incremental,
           let existing = indexedByPath[url.path],
           existing.mtime == mtime,
           existing.size == size,
           searchReadyPaths.contains(url.path) {
            if !toolIOEnabled { return }
            if toolIOReadyPaths.contains(url.path) { return }
            let refTS = (try? await db.sessionRefTSForPath(source: source, path: url.path)) ?? nil
            if let refTS, refTS < toolIOCutoffTS { return }
        }

        // Codex JSONL is append-only and can be "hot" while the CLI is actively running.
        // Instead of skipping indefinitely, throttle updates so search/index data stays fresh
        // without constantly re-parsing the active file.
        if incremental, source == "codex" {
            let now = Int64(Date().timeIntervalSince1970)
            let age = now - mtime
            if age < 60 {
                // Avoid reading while the file may still be mid-write.
                if age < 3 { return }
                // Reindex hot files at most once every ~30s.
                let lastIndexedAt = indexedByPath[url.path]?.indexedAt ?? 0
                if now - lastIndexedAt < 30 { return }
            }
        }

        // Parse fully on a background task
        guard let session = await parseSession(url: url, source: source) else { return }
        if source == "codex" && CodexProbeConfig.isProbeSession(session) { return }
        // Skip Agent Sessions' Claude probe sessions to keep analytics clean
        if source == "claude" && ClaudeProbeConfig.isProbeSession(session) { return }
        let messages = session.events.filter { $0.kind != .meta }.count
        let commands = session.events.filter { $0.kind == .tool_call }.count
        let start = session.startTime ?? session.events.compactMap { $0.timestamp }.min() ?? Date(timeIntervalSince1970: TimeInterval(mtime))
        let end = session.endTime ?? session.events.compactMap { $0.timestamp }.max() ?? Date(timeIntervalSince1970: TimeInterval(mtime))
        let refTS = Int64(end.timeIntervalSince1970)

        // Per-day splits
        let dayRows = Self.splitIntoDays(session: session, start: start, end: end)
        let meta = SessionMetaRow(
            sessionID: session.id,
            source: source,
            path: session.filePath,
            mtime: mtime,
            size: size,
            startTS: Int64(start.timeIntervalSince1970),
            endTS: Int64(end.timeIntervalSince1970),
            model: session.model,
            cwd: session.cwd,
            repo: session.repoName,
            title: session.title,
            messages: messages,
            commands: commands
        )
        let searchText = SessionSearchTextBuilder.build(session: session)
        let toolIOText: String? = {
            guard toolIOEnabled else { return nil }
            guard refTS >= toolIOCutoffTS else { return nil }
            return SessionSearchTextBuilder.buildToolIO(session: session)
        }()

        // Commit to DB atomically
        do {
            try await db.begin()
            try await db.upsertFile(path: session.filePath, mtime: mtime, size: size, source: source)
            try await db.upsertSessionMeta(meta)
            try await db.upsertSessionSearch(sessionID: session.id, source: source, mtime: mtime, size: size, text: searchText)
            if let toolIOText {
                try await db.upsertSessionToolIO(sessionID: session.id, source: source, mtime: mtime, size: size, refTS: refTS, text: toolIOText)
            }
            try await db.deleteSessionDays(sessionID: session.id, source: source)
            try await db.insertSessionDayRows(dayRows)
            // Recompute rollups for affected days
            for d in Set(dayRows.map { $0.day }) { try await db.recomputeRollups(day: d, source: source) }
            try await db.commit()
        } catch {
            await db.rollbackSilently()
        }
    }

    private func toolIOIndexEnabled() -> Bool {
        // Default ON unless the user explicitly opts out.
        if UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex)
    }

    // MARK: - Parsers
    private func parseSession(url: URL, source: String) async -> Session? {
        switch source {
        case "codex":
            // Use existing parsing logic from SessionIndexer
            let idx = SessionIndexer()
            return await Task.detached(priority: .utility) { idx.parseFileFull(at: url) }.value
        case "claude":
            return await Task.detached(priority: .utility) { ClaudeSessionParser.parseFileFull(at: url) }.value
        case "gemini":
            return await Task.detached(priority: .utility) { GeminiSessionParser.parseFileFull(at: url) }.value
        case "opencode":
            return await Task.detached(priority: .utility) { OpenCodeSessionParser.parseFileFull(at: url) }.value
        case "copilot":
            return await Task.detached(priority: .utility) { CopilotSessionParser.parseFileFull(at: url) }.value
        case "droid":
            return await Task.detached(priority: .utility) { DroidSessionParser.parseFileFull(at: url) }.value
        default:
            return nil
        }
    }

    // MARK: - Day splitting
    static func splitIntoDays(session: Session, start: Date, end: Date) -> [SessionDayRow] {
        let cal = Calendar.current
        let source = session.source.rawValue
        let model = session.model

        // Prefer event-aware buckets for messages/commands and duration; fall back to span split
        let events = session.events
        if !events.isEmpty {
            // Previous-only fill for missing timestamps:
            // assign an event to the most recent known timestamp's day; do not look ahead.
            var buckets: [String: (msgs: Int, cmds: Int, tmin: Date, tmax: Date)] = [:]
            var lastTS: Date? = nil
            for e in events {
                if let t = e.timestamp { lastTS = t }
                let tEff = e.timestamp ?? lastTS
                guard let t = tEff else { continue }
                let day = Self.dayString(t)
                let isMsg = (e.kind != .meta)
                let isCmd = (e.kind == .tool_call)
                if buckets[day] == nil { buckets[day] = (0, 0, t, t) }
                if isMsg { buckets[day]!.msgs += 1 }
                if isCmd { buckets[day]!.cmds += 1 }
                if t < buckets[day]!.tmin { buckets[day]!.tmin = t }
                if t > buckets[day]!.tmax { buckets[day]!.tmax = t }
            }
            return buckets.map { (day, agg) in
                let dur = max(0, agg.tmax.timeIntervalSince(agg.tmin))
                return SessionDayRow(day: day, source: source, sessionID: session.id, model: model, messages: agg.msgs, commands: agg.cmds, durationSec: dur)
            }
        }

        // No events – split span by calendar day
        var rows: [SessionDayRow] = []
        var cursor = cal.startOfDay(for: start)
        let endDayStart = cal.startOfDay(for: end)
        while cursor <= endDayStart {
            let next = cal.date(byAdding: .day, value: 1, to: cursor) ?? end
            let a = max(start, cursor)
            let b = min(end, next)
            if b > a {
                let day = Self.dayString(cursor)
                let dur = b.timeIntervalSince(a)
                rows.append(SessionDayRow(day: day, source: source, sessionID: session.id, model: model, messages: session.messageCount, commands: session.events.filter { $0.kind == .tool_call }.count, durationSec: dur))
            }
            cursor = next
        }
        return rows
    }

    private static func dayString(_ date: Date) -> String {
        let f = dayFormatter
        return f.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}

import Foundation

/// Background indexer that discovers session files, parses them, and updates the rollup database.
/// Designed for minimal main-thread work and efficient refreshes.
actor AnalyticsIndexer {
    struct Progress: Equatable { let processed: Int; let total: Int; let phase: String }

    private let db: IndexDB
    private let codex = CodexSessionDiscovery()
    private let claude = ClaudeSessionDiscovery()
    private let gemini = GeminiSessionDiscovery()

    init(db: IndexDB) {
        self.db = db
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
        // One-time migration: if legacy unstable IDs are detected for Claude, purge Claude data
        do {
            if try await db.hasUnstableIDs(for: SessionSource.claude.rawValue) {
                try await db.purgeSource(SessionSource.claude.rawValue)
            }
        } catch {
            // Non-fatal; continue indexing
        }

        let sources: [(String, () -> [URL])] = [
            ("codex", { self.codex.discoverSessionFiles() }),
            ("claude", { self.claude.discoverSessionFiles() }),
            ("gemini", { self.gemini.discoverSessionFiles() })
        ]

        for (source, enumerate) in sources {
            let files = enumerate()
            if files.isEmpty { continue }
            // Bound concurrency to keep CPU/IO modest
            let chunk = 8
            for slice in stride(from: 0, to: files.count, by: chunk).map({ Array(files[$0..<min($0+chunk, files.count)]) }) {
                await withTaskGroup(of: Void.self) { group in
                    for url in slice {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            await self.indexFileIfNeeded(url: url, source: source, incremental: incremental)
                        }
                    }
                    await group.waitForAll()
                }
            }
        }
    }

    private func indexFileIfNeeded(url: URL, source: String, incremental: Bool) async {
        // Stat
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        let mtime = Int64(((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)

        // For incremental pass, we still re-parse because we don't have file diffing here.
        // A simple 60s stability guard for append-only Codex JSONL (skip very hot file)
        if source == "codex" {
            let now = Int64(Date().timeIntervalSince1970)
            if now - mtime < 60 { return }
        }

        // Parse fully on a background task
        guard let session = await parseSession(url: url, source: source) else { return }
        let messages = session.events.filter { $0.kind != .meta }.count
        let commands = session.events.filter { $0.kind == .tool_call }.count
        let start = session.startTime ?? session.events.compactMap { $0.timestamp }.min() ?? Date(timeIntervalSince1970: TimeInterval(mtime))
        let end = session.endTime ?? session.events.compactMap { $0.timestamp }.max() ?? Date(timeIntervalSince1970: TimeInterval(mtime))

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

        // Commit to DB atomically
        do {
            try await db.begin()
            try await db.upsertFile(path: session.filePath, mtime: mtime, size: size, source: source)
            try await db.upsertSessionMeta(meta)
            try await db.deleteSessionDays(sessionID: session.id, source: source)
            try await db.insertSessionDayRows(dayRows)
            // Recompute rollups for affected days
            for d in Set(dayRows.map { $0.day }) { try await db.recomputeRollups(day: d, source: source) }
            try await db.commit()
        } catch {
            await db.rollbackSilently()
        }
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
            // Group events by local day string
            var buckets: [String: (msgs: Int, cmds: Int, tmin: Date, tmax: Date)] = [:]
            for e in events {
                guard let t = e.timestamp else { continue }
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

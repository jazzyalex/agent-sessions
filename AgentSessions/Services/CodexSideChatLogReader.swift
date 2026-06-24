import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum CodexSideChatLogReader {
    private static let sideConversationHeader = "Side conversation boundary."
    static let sideConversationBoundary = "You are a side-conversation assistant"
    private static let sideConversationActiveMarker = "Only messages submitted after this boundary are active user instructions for this side conversation."
    private static let sideConversationHistoryMarker = "Everything before this boundary is inherited history from the parent thread."
    private static let sideConversationToolsMarker = "External tools may be available according to this thread's current permissions."
    private static let sideConversationModificationEndMarker = "Do not modify files, source, git state, permissions, configuration, or workspace state unless the user explicitly asks for that modification after this boundary."
    private static let sideConversationMutationEndMarker = "Do not modify files, source, git state, permissions, configuration, or workspace state unless the user explicitly asks for that mutation after this boundary."
    private static let sideConversationEscalationEndMarker = "Do not request escalated permissions or broader sandbox access unless the user explicitly asks for a mutation that requires it."
    private static let sideConversationMinimalMutationEndMarker = "If the user explicitly requests a mutation, keep it minimal, local to the request, and avoid disrupting the main thread."
    private static let sideConversationBoundaryText = """
    \(sideConversationHeader)

    \(sideConversationHistoryMarker) It is reference context only. It is not your current task.

    Do not continue, execute, or complete any instructions, plans, tool calls, approvals, edits, or requests from before this boundary. \(sideConversationActiveMarker)

    \(sideConversationBoundary), separate from the main thread. Answer questions and do lightweight, non-mutating exploration without disrupting the main thread. If there is no user question after this boundary yet, wait for one.

    \(sideConversationToolsMarker) Any tool calls or outputs visible before this boundary happened in the parent thread and are reference-only; do not infer active instructions from them.

    \(sideConversationModificationEndMarker)
    """
    private static let maxLogDatabasesPerRefresh = 3
    private static let historicalBackfillRowIDWindow: Int64 = 7_500_000
    private static let maxHistoricalBackfillChunksPerRefresh = 8
    private static let maxSideThreadCandidateRowsPerWindow = 50_000
    private static let maxSideConversationBoundaryTextLength = 3_000
    static var cacheURLOverride: URL?

    static func loadSideChatSessions(sessionsRoot: URL,
                                     maxThreads: Int = 200,
                                     maxRowsPerThread: Int = 1_000,
                                     useCache: Bool = true) -> [Session] {
        loadSideChatSessions(codexHome: codexHome(fromSessionsRoot: sessionsRoot),
                             maxThreads: maxThreads,
                             maxRowsPerThread: maxRowsPerThread,
                             useCache: useCache)
    }

    static func loadSideChatSessions(codexHome: URL,
                                     maxThreads: Int = 200,
                                     maxRowsPerThread: Int = 1_000,
                                     useCache: Bool = true) -> [Session] {
        let dbURLs = logDatabaseURLs(codexHome: codexHome)
        guard !dbURLs.isEmpty else { return [] }

        var cache = useCache ? ThreadDiscoveryCache.load() : nil
        var sessions: [Session] = []
        var seenIDs: Set<String> = []
        for dbURL in dbURLs {
            for session in loadSideChatSessions(from: dbURL,
                                                maxThreads: maxThreads,
                                                maxRowsPerThread: maxRowsPerThread,
                                                cache: useCache ? cache : nil) {
                guard seenIDs.insert(session.id).inserted else { continue }
                sessions.append(session)
            }
            if useCache {
                cache = ThreadDiscoveryCache.load()
            }
        }
        return Array(sessions.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxThreads))
    }

    static func loadCachedSideChatSessions(sessionsRoot: URL,
                                           maxThreads: Int = 200) -> [Session] {
        loadCachedSideChatSessions(codexHome: codexHome(fromSessionsRoot: sessionsRoot),
                                   maxThreads: maxThreads)
    }

    static func loadCachedSideChatSessions(codexHome: URL,
                                           maxThreads: Int = 200) -> [Session] {
        let dbURLs = logDatabaseURLs(codexHome: codexHome)
        guard !dbURLs.isEmpty else { return [] }

        let cache = ThreadDiscoveryCache.load()
        var sessions: [Session] = []
        var seenIDs: Set<String> = []
        for dbURL in dbURLs {
            guard let entry = cache.entry(for: dbURL),
                  fileSizeBytes(dbURL) >= entry.fileSizeBytes,
                  let cachedSessions = entry.sideChatSessions else {
                continue
            }
            for session in cachedSessions {
                guard seenIDs.insert(session.id).inserted else { continue }
                sessions.append(session)
            }
        }
        return Array(sessions.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxThreads))
    }

    private static func codexHome(fromSessionsRoot sessionsRoot: URL) -> URL {
        let standardized = sessionsRoot.standardizedFileURL
        if standardized.lastPathComponent == "sessions" {
            return standardized.deletingLastPathComponent()
        }
        return standardized
    }

    private static func logDatabaseURLs(codexHome: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for directory in [codexHome.appendingPathComponent("sqlite", isDirectory: true), codexHome] {
            guard let directoryURLs = try? fm.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles]) else {
                continue
            }
            urls.append(contentsOf: directoryURLs
                .filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" }
                .sorted {
                    let lhsVersion = logDBVersion($0)
                    let rhsVersion = logDBVersion($1)
                    if lhsVersion != rhsVersion { return lhsVersion > rhsVersion }
                    let lhsSize = fileSizeBytes($0)
                    let rhsSize = fileSizeBytes($1)
                    if lhsSize != rhsSize { return lhsSize < rhsSize }
                    let lhsMtime = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsMtime = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsMtime > rhsMtime
                })
        }

        var seenPaths: Set<String> = []
        return urls
            .filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
            .prefix(maxLogDatabasesPerRefresh)
            .map { $0 }
    }

    private static func logDBVersion(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        guard let suffix = name.split(separator: "_").last, let version = Int(suffix) else { return 0 }
        return version
    }

    private static func loadSideChatSessions(from dbURL: URL,
                                             maxThreads: Int,
                                             maxRowsPerThread: Int,
                                             cache: ThreadDiscoveryCache?) -> [Session] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return []
        }
        sqlite3_busy_timeout(db, 2_000)
        defer { sqlite3_close(db) }

        let sideThreadIDs = discoverSideThreadIDs(db: db,
                                                  dbURL: dbURL,
                                                  maxThreads: maxThreads,
                                                  cache: cache)
        guard !sideThreadIDs.isEmpty else { return [] }

        var sessions: [Session] = []
        sessions.reserveCapacity(sideThreadIDs.count)
        for threadID in sideThreadIDs {
            if let session = buildSession(db: db,
                                          dbURL: dbURL,
                                          threadID: threadID,
                                          maxRows: maxRowsPerThread) {
                sessions.append(session)
            }
        }
        if cache != nil {
            var cache = ThreadDiscoveryCache.load()
            cache.update(dbURL: dbURL,
                         fileSizeBytes: fileSizeBytes(dbURL),
                         highWater: nil,
                         threadIDs: sideThreadIDs,
                         sideChatSessions: sessions)
            cache.save()
        }
        return sessions
    }

    private static func discoverSideThreadIDs(db: OpaquePointer?,
                                              dbURL: URL,
                                              maxThreads: Int,
                                              cache: ThreadDiscoveryCache?) -> [String] {
        guard let latest = latestLogPositionByRowID(db: db) else {
            return []
        }
        let newestRowID = latest.id
        let fileSize = fileSizeBytes(dbURL)
        let cached = cache?.entry(for: dbURL)
        var ids: [String] = []
        var oldestScannedRowID: Int64?
        var completedHistoricalBackfill = false
        var highWaterForCache: LogPosition? = latest
        if let cached,
           let highWater = cached.highWater,
           cached.fileSizeBytes <= fileSize,
           highWater.id <= newestRowID {
            ids = cached.threadIDs
            oldestScannedRowID = cached.oldestScannedRowID
            completedHistoricalBackfill = cached.completedHistoricalBackfill
            if highWater.id < newestRowID {
                let recentRead = readSideThreadIDs(db: db,
                                                   maxThreads: maxThreads,
                                                   lowerBoundExclusive: highWater.id,
                                                   upperBoundInclusive: nil)
                ids = mergeThreadIDs(recentRead.ids,
                                     withCached: ids)
                if recentRead.hitCandidateLimit {
                    highWaterForCache = highWater
                }
            }
        }

        if !completedHistoricalBackfill, ids.count < maxThreads {
            var upperBound = oldestScannedRowID ?? newestRowID
            var chunksScanned = 0
            var hitCandidateLimit = false
            while upperBound > 0,
                  chunksScanned < maxHistoricalBackfillChunksPerRefresh,
                  ids.count < maxThreads {
                let lowerBound = max(0, upperBound - historicalBackfillRowIDWindow)
                let olderRead = readSideThreadIDs(db: db,
                                                  maxThreads: maxThreads,
                                                  lowerBoundExclusive: lowerBound,
                                                  upperBoundInclusive: upperBound)
                ids = mergeThreadIDs(ids, withCached: olderRead.ids)
                if olderRead.hitCandidateLimit {
                    hitCandidateLimit = true
                    break
                }
                upperBound = lowerBound
                chunksScanned += 1
            }
            oldestScannedRowID = upperBound
            completedHistoricalBackfill = upperBound == 0 && !hitCandidateLimit
        }

        let capped = Array(ids.prefix(maxThreads))
        if cache != nil {
            var currentCache = ThreadDiscoveryCache.load()
            currentCache.update(dbURL: dbURL,
                                fileSizeBytes: fileSize,
                                highWater: highWaterForCache,
                                threadIDs: capped,
                                oldestScannedRowID: oldestScannedRowID,
                                completedHistoricalBackfill: completedHistoricalBackfill,
                                sideChatSessions: nil)
            currentCache.save()
        }
        return capped
    }

    private static func readSideThreadIDs(db: OpaquePointer?,
                                          maxThreads: Int,
                                          lowerBoundExclusive: Int64,
                                          upperBoundInclusive: Int64?) -> ThreadIDReadResult {
        var sql = """
        SELECT thread_id, feedback_log_body
        FROM logs
        WHERE thread_id IS NOT NULL
          AND target = 'codex_api::endpoint::responses_websocket'
          AND feedback_log_body LIKE '%websocket request:%'
          AND feedback_log_body LIKE ?
          AND id > ?
        """
        if upperBoundInclusive != nil {
            sql += "\n  AND id <= ?"
        }
        sql += """

        ORDER BY id DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return ThreadIDReadResult(ids: [], hitCandidateLimit: false)
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        sqlite3_bind_text(stmt, bindIndex, "%\(sideConversationHeader)%", -1, SQLITE_TRANSIENT)
        bindIndex += 1
        sqlite3_bind_int64(stmt, bindIndex, lowerBoundExclusive)
        bindIndex += 1
        if let upperBoundInclusive {
            sqlite3_bind_int64(stmt, bindIndex, upperBoundInclusive)
            bindIndex += 1
        }
        let candidateLimit = max(maxThreads * 250, maxSideThreadCandidateRowsPerWindow)
        sqlite3_bind_int(stmt, bindIndex, Int32(candidateLimit + 1))

        var ids: [String] = []
        var seen: Set<String> = []
        var candidateRowsRead = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            candidateRowsRead += 1
            if candidateRowsRead > candidateLimit {
                return ThreadIDReadResult(ids: ids, hitCandidateLimit: true)
            }
            guard let cString = sqlite3_column_text(stmt, 0),
                  let bodyCString = sqlite3_column_text(stmt, 1) else { continue }
            let threadID = String(cString: cString)
            guard !seen.contains(threadID) else { continue }
            let body = String(cString: bodyCString)
            guard let json = extractWebsocketRequestJSON(from: body),
                  containsSideConversationBoundaryMessage(in: json) else { continue }
            seen.insert(threadID)
            ids.append(threadID)
            if ids.count >= maxThreads { break }
        }
        return ThreadIDReadResult(ids: ids, hitCandidateLimit: false)
    }

    private static func mergeThreadIDs(_ newIDs: [String], withCached cachedIDs: [String]) -> [String] {
        var merged: [String] = []
        var seen: Set<String> = []
        for id in newIDs + cachedIDs where seen.insert(id).inserted {
            merged.append(id)
        }
        return merged
    }

    private static func latestLogPositionByRowID(db: OpaquePointer?) -> LogPosition? {
        let sql = """
        SELECT ts, ts_nanos, id
        FROM logs
        ORDER BY id DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return LogPosition(ts: sqlite3_column_int64(stmt, 0),
                           tsNanos: sqlite3_column_int64(stmt, 1),
                           id: sqlite3_column_int64(stmt, 2))
    }

    private static func fileSizeBytes(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func buildSession(db: OpaquePointer?,
                                     dbURL: URL,
                                     threadID: String,
                                     maxRows: Int) -> Session? {
        let rows = readRows(db: db, threadID: threadID, maxRows: maxRows)
        let request = readSideConversationRequest(db: db,
                                                  threadID: threadID,
                                                  maxRows: 20)
        guard !rows.isEmpty || !request.events.isEmpty else { return nil }

        var events: [SessionEvent] = []
        var seenAssistantText: Set<String> = []
        var model: String? = request.model
        var cwd: String? = request.cwd

        for row in rows {
            model = model ?? extractSpanValue(named: "model", from: row.body)
            cwd = cwd ?? extractSpanValue(named: "cwd", from: row.body)

            if let userText = extractUserSubmissionText(from: row.body) {
                events.append(event(row: row, kind: .user, role: "user", text: userText))
                continue
            }
            if let assistantText = extractAssistantText(from: row.body) {
                let normalized = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, seenAssistantText.insert(normalized).inserted else { continue }
                events.append(event(row: row, kind: .assistant, role: "assistant", text: normalized))
            }
        }

        if !events.contains(where: { $0.kind == .user }) {
            events.append(contentsOf: request.events)
        }
        events.sort {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast)
        }

        guard !events.isEmpty else { return nil }
        let start = events.compactMap(\.timestamp).min()
        let end = events.compactMap(\.timestamp).max()
        let bytes = events.reduce(0) { partial, event in
            partial + (event.text?.utf8.count ?? 0) + (event.rawJSON.utf8.count)
        }
        let firstUserTitle = events.first(where: { $0.kind == .user })?.text.map(collapsedWhitespace)
        let title = firstUserTitle

        return Session(
            id: sideChatSessionID(threadID: threadID),
            source: .codex,
            startTime: start,
            endTime: end,
            model: model,
            filePath: sideChatSessionPath(threadID: threadID),
            fileSizeBytes: max(bytes, 1),
            eventCount: events.count,
            events: events,
            cwd: cwd,
            repoName: projectName(from: cwd),
            lightweightTitle: title,
            codexInternalSessionIDHint: threadID,
            parentSessionID: request.parentThreadID,
            relationshipKind: .sideChat,
            codexOriginator: "Codex Desktop",
            codexSource: "side_chat",
            codexSurface: .desktop,
            originator: "Codex Desktop",
            originSource: "side_chat",
            surface: .desktop
        )
    }

    static func sideChatSessionID(threadID: String) -> String {
        "codex-side-chat-\(threadID)"
    }

    static func sideChatSessionPath(threadID: String) -> String {
        "codex-side-chat://\(threadID)"
    }

    private static func projectName(from cwd: String?) -> String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return nil
        }
        let name = URL(fileURLWithPath: cwd).standardizedFileURL.lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private struct LogRow {
        let id: Int64
        let ts: Int64
        let tsNanos: Int64
        let body: String

        var timestamp: Date {
            Date(timeIntervalSince1970: TimeInterval(ts) + (TimeInterval(tsNanos) / 1_000_000_000))
        }
    }

    private struct LogPosition: Codable, Comparable {
        let ts: Int64
        let tsNanos: Int64
        let id: Int64

        static func < (lhs: LogPosition, rhs: LogPosition) -> Bool {
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
            if lhs.tsNanos != rhs.tsNanos { return lhs.tsNanos < rhs.tsNanos }
            return lhs.id < rhs.id
        }
    }

    private struct ThreadIDReadResult {
        let ids: [String]
        let hitCandidateLimit: Bool
    }

    private struct ThreadDiscoveryCache: Codable {
        private static let currentSchemaVersion = 13
        private static let cacheIOLock = NSLock()

        var schemaVersion: Int = currentSchemaVersion
        var databases: [String: CachedDatabase] = [:]

        static func load() -> ThreadDiscoveryCache {
            for url in cacheReadURLs() {
                guard let data = try? Data(contentsOf: url),
                      let cache = try? JSONDecoder().decode(ThreadDiscoveryCache.self, from: data),
                      cache.schemaVersion == currentSchemaVersion else {
                    continue
                }
                return cache
            }
            return ThreadDiscoveryCache()
        }

        func entry(for dbURL: URL) -> CachedDatabase? {
            databases[Self.cacheKey(for: dbURL)]
        }

        mutating func update(dbURL: URL,
                             fileSizeBytes: Int64,
                             highWater: LogPosition?,
                             threadIDs: [String],
                             oldestScannedRowID: Int64? = nil,
                             completedHistoricalBackfill: Bool? = nil,
                             sideChatSessions: [Session]?) {
            let key = Self.cacheKey(for: dbURL)
            let existing = databases[key]
            databases[key] = CachedDatabase(fileSizeBytes: fileSizeBytes,
                                            highWater: highWater ?? existing?.highWater,
                                            threadIDs: threadIDs,
                                            oldestScannedRowID: oldestScannedRowID ?? existing?.oldestScannedRowID,
                                            completedHistoricalBackfill: completedHistoricalBackfill ?? existing?.completedHistoricalBackfill ?? false,
                                            sideChatSessions: sideChatSessions ?? existing?.sideChatSessions)
        }

        func save() {
            guard let url = Self.cacheURL() else { return }
            Self.cacheIOLock.lock()
            defer { Self.cacheIOLock.unlock() }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                var cacheToWrite = self
                if let existingData = try? Data(contentsOf: url),
                   var existing = try? JSONDecoder().decode(ThreadDiscoveryCache.self, from: existingData),
                   existing.schemaVersion == Self.currentSchemaVersion {
                    for (key, value) in cacheToWrite.databases {
                        existing.databases[key] = value
                    }
                    cacheToWrite = existing
                }
                let data = try JSONEncoder().encode(cacheToWrite)
                try data.write(to: url, options: [.atomic])
            } catch {
                return
            }
        }

        private static func cacheURL() -> URL? {
            if let override = CodexSideChatLogReader.cacheURLOverride {
                return override
            }
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask).first else {
                return nil
            }
            return appSupport
                .appendingPathComponent("AgentSessions", isDirectory: true)
                .appendingPathComponent("codex-side-chat-cache-v2.json")
        }

        private static func cacheReadURLs() -> [URL] {
            guard let primary = cacheURL() else { return [] }
            if CodexSideChatLogReader.cacheURLOverride != nil {
                return [primary]
            }
            let legacy = primary
                .deletingLastPathComponent()
                .appendingPathComponent("codex-side-chat-thread-cache-v1.json")
            return [primary, legacy]
        }

        private static func cacheKey(for url: URL) -> String {
            url.standardizedFileURL.path
        }
    }

    private struct CachedDatabase: Codable {
        let fileSizeBytes: Int64
        let highWater: LogPosition?
        let threadIDs: [String]
        let oldestScannedRowID: Int64?
        let completedHistoricalBackfill: Bool
        let sideChatSessions: [Session]?
    }

    private static func readRows(db: OpaquePointer?, threadID: String, maxRows: Int) -> [LogRow] {
        let sql = """
        SELECT id, ts, ts_nanos, feedback_log_body
        FROM logs
        WHERE thread_id = ?
          AND (
            feedback_log_body LIKE '%Submission sub=Submission%'
            OR feedback_log_body LIKE '%websocket event:%response.output_text.done%'
            OR feedback_log_body LIKE '%OutputText { text:%'
          )
        ORDER BY ts ASC, ts_nanos ASC, id ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, threadID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(maxRows))

        var rows: [LogRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bodyCString = sqlite3_column_text(stmt, 3) else {
                continue
            }
            rows.append(LogRow(id: sqlite3_column_int64(stmt, 0),
                               ts: sqlite3_column_int64(stmt, 1),
                               tsNanos: sqlite3_column_int64(stmt, 2),
                               body: String(cString: bodyCString)))
        }
        return rows
    }

    private struct SideConversationRequestRead {
        let events: [SessionEvent]
        let model: String?
        let cwd: String?
        let parentThreadID: String?
    }

    private static func readSideConversationRequest(db: OpaquePointer?,
                                                    threadID: String,
                                                    maxRows: Int) -> SideConversationRequestRead {
        let sql = """
        SELECT id, ts, ts_nanos, feedback_log_body
        FROM logs
        WHERE thread_id = ?
          AND target = 'codex_api::endpoint::responses_websocket'
          AND feedback_log_body LIKE '%websocket request:%'
          AND feedback_log_body LIKE ?
        ORDER BY ts ASC, ts_nanos ASC, id ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return SideConversationRequestRead(events: [], model: nil, cwd: nil, parentThreadID: nil)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, threadID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, "%\(sideConversationHeader)%", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(maxRows))

        var events: [SessionEvent] = []
        var seenTexts: Set<String> = []
        var model: String?
        var cwd: String?
        var parentThreadID: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bodyCString = sqlite3_column_text(stmt, 3) else { continue }
            let row = LogRow(id: sqlite3_column_int64(stmt, 0),
                             ts: sqlite3_column_int64(stmt, 1),
                             tsNanos: sqlite3_column_int64(stmt, 2),
                             body: String(cString: bodyCString))
            model = model ?? extractSpanValue(named: "model", from: row.body)
            cwd = cwd ?? extractSpanValue(named: "cwd", from: row.body)
            guard let json = extractWebsocketRequestJSON(from: row.body) else { continue }
            parentThreadID = parentThreadID ?? extractForkedFromThreadID(in: json)
            let userTexts = sideConversationUserTexts(in: json)
            for (index, text) in userTexts.enumerated() {
                let normalized = collapsedWhitespace(text)
                guard !normalized.isEmpty, seenTexts.insert(normalized).inserted else { continue }
                events.append(event(row: row,
                                    kind: .user,
                                    role: "user",
                                    text: text,
                                    idSuffix: "side-request-\(index)",
                                    rawJSON: #"{"source":"websocket_request_side_prompt"}"#))
            }
        }
        return SideConversationRequestRead(events: events, model: model, cwd: cwd, parentThreadID: parentThreadID)
    }

    private static func event(row: LogRow,
                              kind: SessionEventKind,
                              role: String,
                              text: String,
                              idSuffix: String? = nil,
                              rawJSON: String? = nil) -> SessionEvent {
        let suffix = idSuffix ?? kind.rawValue
        return SessionEvent(id: "log-\(row.id)-\(suffix)",
                     timestamp: row.timestamp,
                     kind: kind,
                     role: role,
                     text: text,
                     toolName: nil,
                     toolInput: nil,
                     toolOutput: nil,
                     messageID: nil,
                     parentID: nil,
                     isDelta: false,
                     rawJSON: rawJSON ?? row.body)
    }

    private static func extractUserSubmissionText(from body: String) -> String? {
        guard body.contains("Submission sub=Submission") else { return nil }
        return extractRustQuotedString(after: #"Text { text: ""#, in: body)
    }

    private static func extractAssistantText(from body: String) -> String? {
        if let json = extractWebsocketEventJSON(from: body),
           json["type"] as? String == "response.output_text.done",
           let text = json["text"] as? String {
            return text
        }
        if body.contains("OutputText { text: ") {
            return extractRustQuotedString(after: #"OutputText { text: ""#, in: body)
        }
        return nil
    }

    private static func extractWebsocketEventJSON(from body: String) -> [String: Any]? {
        extractWebsocketJSON(after: "websocket event: ", from: body)
    }

    private static func extractWebsocketRequestJSON(from body: String) -> [String: Any]? {
        extractWebsocketJSON(after: "websocket request: ", from: body)
    }

    private static func extractWebsocketJSON(after marker: String, from body: String) -> [String: Any]? {
        guard let range = body.range(of: marker) else { return nil }
        guard let json = firstBalancedJSONObject(in: String(body[range.upperBound...])) else {
            return nil
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func firstBalancedJSONObject(in value: String) -> String? {
        guard let start = value.firstIndex(of: "{") else { return nil }
        var index = start
        var depth = 0
        var inString = false
        var escaping = false
        while index < value.endIndex {
            let char = value[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(value[start...index])
                    }
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func containsSideConversationBoundaryMessage(in json: [String: Any]) -> Bool {
        !sideConversationUserTexts(in: json).isEmpty
    }

    private static func extractForkedFromThreadID(in json: [String: Any]) -> String? {
        guard let clientMetadata = json["client_metadata"] as? [String: Any] else { return nil }
        if let id = nonEmptyString(clientMetadata["forked_from_thread_id"]) {
            return id
        }
        guard let metadataJSON = nonEmptyString(clientMetadata["x-codex-turn-metadata"]),
              let data = metadataJSON.data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return nonEmptyString(metadata["forked_from_thread_id"])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sideConversationUserTexts(in json: [String: Any]) -> [String] {
        guard let input = json["input"] as? [Any] else { return [] }
        var foundBoundary = false
        var userTexts: [String] = []
        for item in input {
            guard let message = item as? [String: Any],
                  message["type"] as? String == "message",
                  message["role"] as? String == "user" else {
                continue
            }
            if foundBoundary {
                userTexts.append(contentsOf: messageContentTexts(message).compactMap { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                })
                continue
            }
            let isBoundaryMessage = messageContentTexts(message).contains { text in
                isSideConversationBoundaryText(text)
            }
            if isBoundaryMessage {
                foundBoundary = true
            }
        }
        return userTexts
    }

    private static func isSideConversationBoundaryText(_ text: String) -> Bool {
        let normalized = collapsedWhitespace(text)
        let canonical = collapsedWhitespace(sideConversationBoundaryText)
        if normalized == canonical {
            return true
        }
        guard normalized.hasPrefix(sideConversationHeader),
              normalized.count <= maxSideConversationBoundaryTextLength else {
            return false
        }
        guard normalized.contains(sideConversationHistoryMarker),
              normalized.contains(sideConversationActiveMarker),
              normalized.contains(sideConversationBoundary),
              normalized.contains(sideConversationToolsMarker) else {
            return false
        }
        return [
            sideConversationModificationEndMarker,
            sideConversationMutationEndMarker,
            sideConversationEscalationEndMarker,
            sideConversationMinimalMutationEndMarker
        ].contains { marker in
            normalized.hasSuffix(marker)
        }
    }

    private static func messageContentTexts(_ message: [String: Any]) -> [String] {
        if let text = message["content"] as? String {
            return [text]
        }
        guard let content = message["content"] as? [Any] else { return [] }
        return content.compactMap { item in
            if let text = item as? String {
                return text
            }
            if let block = item as? [String: Any],
               block["type"] as? String == "input_text",
               let text = block["text"] as? String {
                return text
            }
            return nil
        }
    }

    private static func extractSpanValue(named name: String, from body: String) -> String? {
        guard let range = body.range(of: "\(name)=") else { return nil }
        var index = range.upperBound
        var value = ""
        while index < body.endIndex {
            let ch = body[index]
            if ch == " " || ch == "}" || ch == ":" { break }
            value.append(ch)
            index = body.index(after: index)
        }
        return value.isEmpty ? nil : value
    }

    private static func extractRustQuotedString(after marker: String, in body: String) -> String? {
        guard let markerRange = body.range(of: marker) else { return nil }
        var index = markerRange.upperBound
        var result = ""
        var escaping = false

        while index < body.endIndex {
            let ch = body[index]
            index = body.index(after: index)

            if escaping {
                switch ch {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default:
                    result.append("\\")
                    result.append(ch)
                }
                escaping = false
                continue
            }

            if ch == "\\" {
                escaping = true
                continue
            }
            if ch == "\"" {
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            result.append(ch)
        }
        return nil
    }
}

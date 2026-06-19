import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum CodexSideChatLogReader {
    private static let sideConversationHeader = "Side conversation boundary."
    static let sideConversationBoundary = "You are a side-conversation assistant"
    private static let sideConversationActiveMarker = "Only messages submitted after this boundary are active user instructions for this side conversation."
    private static let maxLogDatabasesPerRefresh = 3
    private static let coldSideChatDiscoveryRowIDWindow: Int64 = 7_500_000
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
                if sessions.count >= maxThreads { return sessions.sorted { $0.modifiedAt > $1.modifiedAt } }
            }
            if useCache {
                cache = ThreadDiscoveryCache.load()
            }
        }
        return sessions.sorted { $0.modifiedAt > $1.modifiedAt }
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
                if sessions.count >= maxThreads { return sessions.sorted { $0.modifiedAt > $1.modifiedAt } }
            }
        }
        return sessions.sorted { $0.modifiedAt > $1.modifiedAt }
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
        guard let urls = try? fm.contentsOfDirectory(at: codexHome,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" }
            .sorted {
                let lhsVersion = logDBVersion($0)
                let rhsVersion = logDBVersion($1)
                if lhsVersion != rhsVersion { return lhsVersion > rhsVersion }
                let lhsMtime = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsMtime = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsMtime > rhsMtime
            }
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
        if var cache {
            let latest = latestLogPositionByRowID(db: db)
            cache.update(dbURL: dbURL,
                         fileSizeBytes: fileSizeBytes(dbURL),
                         highWater: latest,
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
        if let cached,
           let highWater = cached.highWater,
           cached.fileSizeBytes <= fileSize,
           highWater.id <= newestRowID {
            ids = cached.threadIDs
            if highWater.id < newestRowID {
                ids = mergeThreadIDs(readSideThreadIDs(db: db,
                                                       maxThreads: maxThreads,
                                                       after: highWater,
                                                       newestRowID: newestRowID),
                                     withCached: ids)
            }
        } else {
            ids = readSideThreadIDs(db: db, maxThreads: maxThreads, after: nil, newestRowID: newestRowID)
        }

        let capped = Array(ids.prefix(maxThreads))
        if var cache {
            cache.update(dbURL: dbURL,
                         fileSizeBytes: fileSize,
                         highWater: latest,
                         threadIDs: capped,
                         sideChatSessions: nil)
            cache.save()
        }
        return capped
    }

    private static func readSideThreadIDs(db: OpaquePointer?,
                                          maxThreads: Int,
                                          after position: LogPosition?,
                                          newestRowID: Int64) -> [String] {
        let minimumRowID = position?.id ?? max(0, newestRowID - coldSideChatDiscoveryRowIDWindow)
        let sql = """
        SELECT thread_id, feedback_log_body
        FROM logs
        WHERE thread_id IS NOT NULL
          AND target = 'codex_api::endpoint::responses_websocket'
          AND feedback_log_body LIKE '%websocket request:%'
          AND feedback_log_body LIKE ?
          AND id > ?
        ORDER BY id DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        sqlite3_bind_text(stmt, bindIndex, "%\(sideConversationHeader)%", -1, SQLITE_TRANSIENT)
        bindIndex += 1
        sqlite3_bind_int64(stmt, bindIndex, minimumRowID)
        bindIndex += 1
        sqlite3_bind_int(stmt, bindIndex, Int32(maxThreads * 10))

        var ids: [String] = []
        var seen: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
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
        return ids
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
        guard !rows.isEmpty else { return nil }

        var events: [SessionEvent] = []
        var seenAssistantText: Set<String> = []
        var model: String?
        var cwd: String?

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

        guard !events.isEmpty else { return nil }
        let start = events.compactMap(\.timestamp).min()
        let end = events.compactMap(\.timestamp).max()
        let bytes = events.reduce(0) { partial, event in
            partial + (event.text?.utf8.count ?? 0) + (event.rawJSON.utf8.count)
        }
        let firstUserTitle = events.first(where: { $0.kind == .user })?.text.map(collapsedWhitespace)
        let title = firstUserTitle.map { "Side: \($0)" }

        return Session(
            id: sideChatSessionID(threadID: threadID),
            source: .codex,
            startTime: start,
            endTime: end,
            model: model,
            filePath: dbURL.path,
            fileSizeBytes: max(bytes, 1),
            eventCount: events.count,
            events: events,
            cwd: cwd,
            repoName: projectName(from: cwd),
            lightweightTitle: title,
            codexInternalSessionIDHint: threadID,
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

    private struct ThreadDiscoveryCache: Codable {
        private static let currentSchemaVersion = 2

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
                             sideChatSessions: [Session]?) {
            let key = Self.cacheKey(for: dbURL)
            let existing = databases[key]
            databases[key] = CachedDatabase(fileSizeBytes: fileSizeBytes,
                                            highWater: highWater ?? existing?.highWater,
                                            threadIDs: threadIDs,
                                            sideChatSessions: sideChatSessions ?? existing?.sideChatSessions)
        }

        func save() {
            guard let url = Self.cacheURL() else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(self)
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

    private static func event(row: LogRow,
                              kind: SessionEventKind,
                              role: String,
                              text: String) -> SessionEvent {
        SessionEvent(id: "log-\(row.id)-\(kind.rawValue)",
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
                     rawJSON: row.body)
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
        let jsonStart = range.upperBound
        let json = String(body[jsonStart...])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func containsSideConversationBoundaryMessage(in json: [String: Any]) -> Bool {
        guard let input = json["input"] as? [Any] else { return false }
        for (index, item) in input.enumerated() {
            guard let message = item as? [String: Any],
                  message["type"] as? String == "message",
                  message["role"] as? String == "user" else {
                continue
            }
            let isBoundaryMessage = messageContentTexts(message).contains { text in
                text.hasPrefix(sideConversationHeader)
                    && text.contains(sideConversationActiveMarker)
                    && text.contains(sideConversationBoundary)
            }
            guard isBoundaryMessage else { continue }
            return input.suffix(from: input.index(after: index)).contains { later in
                guard let laterMessage = later as? [String: Any],
                      laterMessage["type"] as? String == "message",
                      laterMessage["role"] as? String == "user" else {
                    return false
                }
                return messageContentTexts(laterMessage).contains { text in
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
        }
        return false
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

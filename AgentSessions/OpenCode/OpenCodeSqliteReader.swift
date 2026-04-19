import Foundation
import SQLite3

/// Read-only adapter for OpenCode's opencode.db SQLite database (v1.2+).
///
/// Opens the database per call using SQLITE_OPEN_READONLY to avoid WAL lock
/// contention with the running OpenCode process. No writes, no migrations.
struct OpenCodeSqliteReader {

    // MARK: - Session list (lightweight, no events)

    /// Returns all non-archived sessions ordered by time_updated descending.
    static func listSessions(customRoot: String?) -> [Session] {
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        return querySessionList(db: db, dbPath: url.path)
    }

    // MARK: - Full session (with transcript events)

    /// Returns a Session with fully loaded events for the given session ID.
    static func loadFullSession(customRoot: String?, sessionID: String) -> Session? {
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return queryFullSession(db: db, sessionID: sessionID, dbPath: url.path)
    }

    // MARK: - Internal query helpers

    private static func querySessionList(db: OpaquePointer?, dbPath: String) -> [Session] {
        let hasParent = tableHasColumn(db, table: "session", column: "parent_id")
        let sql: String
        if hasParent {
            sql = """
                SELECT id, title, directory, time_created, time_updated, parent_id
                FROM session
                WHERE time_archived IS NULL
                ORDER BY time_updated DESC;
                """
        } else {
            sql = """
                SELECT id, title, directory, time_created, time_updated
                FROM session
                WHERE time_archived IS NULL
                ORDER BY time_updated DESC;
                """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var sessions: [Session] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(stmt, 0)
            guard !id.isEmpty else { continue }
            let title = text(stmt, 1)
            let directory = text(stmt, 2)
            let timeCreated = sqlite3_column_int64(stmt, 3)
            let timeUpdated = sqlite3_column_int64(stmt, 4)
            let parentID: String? = hasParent && sqlite3_column_type(stmt, 5) != SQLITE_NULL ? text(stmt, 5) : nil

            let startDate = timeCreated > 0 ? Date(timeIntervalSince1970: Double(timeCreated) / 1000.0) : nil
            let endDate = timeUpdated > 0 ? Date(timeIntervalSince1970: Double(timeUpdated) / 1000.0) : nil

            // Fetch message count and first model in a separate quick query
            let (msgCount, modelID) = lightweightMessageMeta(db: db, sessionID: id)

            let sessionTitle = OpenCodeSessionParser.normalizedSessionTitle(title)
            let subagentType = OpenCodeSessionParser.deriveSubagentTypeFromTitle(sessionTitle)
            sessions.append(Session(
                id: id,
                source: .opencode,
                startTime: startDate,
                endTime: endDate,
                model: modelID,
                filePath: dbPath,
                fileSizeBytes: nil,
                eventCount: msgCount,
                events: [],
                cwd: directory.isEmpty ? nil : directory,
                repoName: nil,
                lightweightTitle: sessionTitle,
                lightweightCommands: nil,
                parentSessionID: parentID,
                subagentType: subagentType,
                customTitle: sessionTitle
            ))
        }
        return sessions
    }

    private static func lightweightMessageMeta(db: OpaquePointer?, sessionID: String) -> (count: Int, modelID: String?) {
        let sql = "SELECT data FROM message WHERE session_id = ? ORDER BY time_created LIMIT 20;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var count = 0
        var modelID: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            count += 1
            if modelID == nil, let dataStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
               let data = dataStr.data(using: .utf8),
               let msg = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data) {
                modelID = msg.model?.modelID ?? msg.modelID
            }
        }
        // Get actual total count
        let countSQL = "SELECT COUNT(*) FROM message WHERE session_id = ?;"
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(countStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(countStmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(countStmt, 0))
            }
            sqlite3_finalize(countStmt)
        }
        return (count, modelID)
    }

    private static func queryFullSession(db: OpaquePointer?, sessionID: String, dbPath: String) -> Session? {
        // 1. Session metadata
        let hasParent = tableHasColumn(db, table: "session", column: "parent_id")
        let sesSQL = hasParent
            ? "SELECT id, title, directory, time_created, time_updated, parent_id FROM session WHERE id = ? LIMIT 1;"
            : "SELECT id, title, directory, time_created, time_updated FROM session WHERE id = ? LIMIT 1;"
        var sesStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sesSQL, -1, &sesStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(sesStmt) }
        sqlite3_bind_text(sesStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(sesStmt) == SQLITE_ROW else { return nil }

        let id = text(sesStmt, 0)
        let title = text(sesStmt, 1)
        let directory = text(sesStmt, 2)
        let timeCreated = sqlite3_column_int64(sesStmt, 3)
        let timeUpdated = sqlite3_column_int64(sesStmt, 4)
        let parentID: String? = hasParent && sqlite3_column_type(sesStmt, 5) != SQLITE_NULL ? text(sesStmt, 5) : nil
        let startDate = timeCreated > 0 ? Date(timeIntervalSince1970: Double(timeCreated) / 1000.0) : nil
        let endDate = timeUpdated > 0 ? Date(timeIntervalSince1970: Double(timeUpdated) / 1000.0) : nil

        // 2. Load all messages ordered by time_created
        let msgSQL = "SELECT id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created;"
        var msgStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, msgSQL, -1, &msgStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(msgStmt) }
        sqlite3_bind_text(msgStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var events: [SessionEvent] = []
        var modelID: String?
        var commandCount = 0

        while sqlite3_step(msgStmt) == SQLITE_ROW {
            let msgID = text(msgStmt, 0)
            let msgTimeMs = sqlite3_column_int64(msgStmt, 1)
            guard let dataStr = sqlite3_column_text(msgStmt, 2).map({ String(cString: $0) }) else { continue }
            let rawJSON = dataStr

            guard let data = dataStr.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data) else {
                continue
            }

            let ts = msgTimeMs > 0 ? Date(timeIntervalSince1970: Double(msgTimeMs) / 1000.0) : nil
            if modelID == nil, let mid = msg.model?.modelID ?? msg.modelID, !mid.isEmpty {
                modelID = mid
            }

            // 3. Load parts for this message
            let partDicts = loadPartDicts(db: db, messageID: msgID)
            let hasTools = (msg.tools?.todowrite ?? false) || (msg.tools?.todoread ?? false) || (msg.tools?.task ?? false)
            if hasTools { commandCount += 1 }

            let partEvents = OpenCodeSessionParser.buildPartEvents(
                for: msg,
                effectiveMsgID: msgID,
                parts: partDicts,
                fallbackTimestamp: ts
            )
            commandCount += partEvents.tool.filter { $0.kind == .tool_call }.count

            // Meta event for the raw message
            let messageMetaEvent = SessionEvent(
                id: msgID + "-meta",
                timestamp: ts,
                kind: .meta,
                role: msg.role,
                text: nil,
                toolName: nil,
                toolInput: nil,
                toolOutput: nil,
                messageID: msgID,
                parentID: nil,
                isDelta: false,
                rawJSON: rawJSON
            )
            events.append(messageMetaEvent)

            if !partEvents.text.isEmpty {
                events.append(contentsOf: partEvents.text)
            } else {
                // Fallback: render from message summary fields
                let baseKind = SessionEventKind.from(role: msg.role, type: nil)
                let normalizedRole = msg.role?.lowercased()
                var text: String?
                if normalizedRole == "user" {
                    text = msg.summary?.title
                    if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        text = msg.summary?.body
                    }
                } else {
                    text = msg.summary?.body
                    if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                       let t = msg.summary?.title, !t.isEmpty {
                        text = t
                    }
                }
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isUser = normalizedRole == "user"
                let hasToolParts = !partEvents.tool.isEmpty
                if trimmed.isEmpty && (hasTools || hasToolParts) && !isUser {
                    // no-op: tool-call wrapper with no display text
                } else if trimmed.isEmpty && !isUser {
                    // Drop completely empty non-user messages to avoid blank rows.
                } else {
                    events.append(SessionEvent(
                        id: msgID,
                        timestamp: ts,
                        kind: baseKind,
                        role: msg.role,
                        text: text,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: msgID,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSON
                    ))
                }
            }
            events.append(contentsOf: partEvents.tool)
            events.append(contentsOf: partEvents.meta)
        }

        let nonMetaCount = events.filter { $0.kind != .meta }.count
        let sessionTitle = OpenCodeSessionParser.normalizedSessionTitle(title)
        let subagentType = OpenCodeSessionParser.deriveSubagentTypeFromTitle(sessionTitle)
        return Session(
            id: id,
            source: .opencode,
            startTime: startDate,
            endTime: endDate,
            model: modelID,
            filePath: dbPath,
            fileSizeBytes: nil,
            eventCount: nonMetaCount,
            events: events,
            cwd: directory.isEmpty ? nil : directory,
            repoName: nil,
            lightweightTitle: sessionTitle,
            lightweightCommands: commandCount > 0 ? commandCount : nil,
            parentSessionID: parentID,
            subagentType: subagentType,
            customTitle: sessionTitle
        )
    }

    private static func loadPartDicts(db: OpaquePointer?, messageID: String) -> [(id: String, dict: [String: Any], rawJSON: String)] {
        let sql = "SELECT id, data FROM part WHERE message_id = ? ORDER BY time_created;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (messageID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [(id: String, dict: [String: Any], rawJSON: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let partID = text(stmt, 0)
            guard let dataStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let data = dataStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rawJSON = OpenCodeSessionParser.cappedPartJSON(obj: obj, source: dataStr.data(using: .utf8))
            results.append((id: partID, dict: obj, rawJSON: rawJSON))
        }
        return results
    }

    // MARK: - SQLite helpers

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    private static func tableHasColumn(_ db: OpaquePointer?, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }), name == column {
                return true
            }
        }
        return false
    }
}

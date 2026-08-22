import Foundation
import SQLite3

/// Reads the Devin CLI session store, a single SQLite database at
/// `~/.local/share/devin/cli/sessions.db`.
///
/// `message_nodes` is a *forest*, not a list: every row carries `node_id` and
/// `parent_node_id`, and `sessions.main_chain_id` names the tip of the live
/// conversation. Branches are retries and edits, so replaying every row would
/// render abandoned turns interleaved with the real ones. Across the 253
/// sessions surveyed, the main chains hold 49,891 of 394,399 nodes — **87% of
/// the table is off-chain** — which is also why the database reaches 5.4 GB.
///
/// Both entry points therefore walk `parent_node_id` back from `main_chain_id`
/// and render that chain in root-to-tip order.
enum DevinSqliteReader {
    /// Opened read-only and without a mutex: the CLI may hold the same file open.
    private static func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    // MARK: - Session list

    /// Lists every visible session. `nil` means the database could not be
    /// opened (missing file, lock, corrupt header); `[]` means it opened
    /// cleanly and has no sessions. Search ingest keeps those states distinct,
    /// so the indexer uses this form and only a clean read may retire rows.
    static func listSessionsIfReadable(databasePath: String) -> [Session]? {
        guard let db = open(databasePath) else { return nil }
        defer { sqlite3_close(db) }

        let chainCounts = mainChainCounts(db: db)

        // `hidden` marks sessions the CLI has retired; they stay in the table
        // but never appear in `devin list`, so they are excluded here too.
        let sql = """
            SELECT id, title, working_directory, model, created_at, last_activity_at, agent_mode
            FROM sessions
            WHERE hidden = 0
            ORDER BY last_activity_at DESC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var sessions: [Session] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(stmt, 0)
            guard !id.isEmpty else { continue }
            let title = text(stmt, 1)
            let cwd = text(stmt, 2)
            let model = text(stmt, 3)
            // Devin stores epoch *seconds*, unlike OpenCode's milliseconds.
            let created = sqlite3_column_int64(stmt, 4)
            let lastActivity = sqlite3_column_int64(stmt, 5)
            let agentMode = text(stmt, 6)

            sessions.append(makeSession(id: id,
                                        title: title,
                                        cwd: cwd,
                                        model: model,
                                        created: created,
                                        lastActivity: lastActivity,
                                        agentMode: agentMode,
                                        eventCount: chainCounts[id] ?? 0,
                                        events: [],
                                        databasePath: databasePath))
        }
        return sessions
    }

    /// Convenience wrapper: `nil` collapses to an empty list.
    static func listSessions(databasePath: String) -> [Session] {
        listSessionsIfReadable(databasePath: databasePath) ?? []
    }

    /// Main-chain length for every visible session in one recursive pass.
    ///
    /// Per-session walks would issue one query per session; this resolves all
    /// 247 visible chains in ~2s on a 5.4 GB store. The count matters because
    /// a raw `COUNT(*)` over `message_nodes` would overstate a session's length
    /// roughly eightfold.
    private static func mainChainCounts(db: OpaquePointer?) -> [String: Int] {
        let sql = """
            WITH RECURSIVE chain(session_id, node_id, parent_node_id) AS (
                SELECT s.id, m.node_id, m.parent_node_id
                FROM sessions s
                JOIN message_nodes m ON m.session_id = s.id AND m.node_id = s.main_chain_id
                WHERE s.hidden = 0
              UNION ALL
                SELECT c.session_id, m.node_id, m.parent_node_id
                FROM chain c
                JOIN message_nodes m ON m.session_id = c.session_id AND m.node_id = c.parent_node_id
            )
            SELECT session_id, COUNT(*) FROM chain GROUP BY session_id;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            counts[text(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1))
        }
        return counts
    }

    // MARK: - Full session

    static func loadFullSession(databasePath: String, sessionID: String) -> Session? {
        guard let db = open(databasePath) else { return nil }
        defer { sqlite3_close(db) }

        let header = """
            SELECT title, working_directory, model, created_at, last_activity_at, agent_mode, main_chain_id
            FROM sessions WHERE id = ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, header, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return nil
        }
        let title = text(stmt, 0)
        let cwd = text(stmt, 1)
        let model = text(stmt, 2)
        let created = sqlite3_column_int64(stmt, 3)
        let lastActivity = sqlite3_column_int64(stmt, 4)
        let agentMode = text(stmt, 5)
        let mainChainID = sqlite3_column_int64(stmt, 6)
        sqlite3_finalize(stmt)

        let events = mainChainEvents(db: db, sessionID: sessionID, mainChainID: mainChainID)
        return makeSession(id: sessionID,
                           title: title,
                           cwd: cwd,
                           model: model,
                           created: created,
                           lastActivity: lastActivity,
                           agentMode: agentMode,
                           eventCount: events.filter { $0.kind != .meta }.count,
                           events: events,
                           databasePath: databasePath)
    }

    /// Walks `main_chain_id` back to its root, then renders root-to-tip.
    private static func mainChainEvents(db: OpaquePointer?, sessionID: String, mainChainID: Int64) -> [SessionEvent] {
        let sql = """
            WITH RECURSIVE chain(node_id, parent_node_id, chat_message, created_at) AS (
                SELECT node_id, parent_node_id, chat_message, created_at
                FROM message_nodes WHERE session_id = ?1 AND node_id = ?2
              UNION ALL
                SELECT m.node_id, m.parent_node_id, m.chat_message, m.created_at
                FROM chain c
                JOIN message_nodes m ON m.session_id = ?1 AND m.node_id = c.parent_node_id
            )
            SELECT node_id, chat_message, created_at FROM chain;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, transient)
        sqlite3_bind_int64(stmt, 2, mainChainID)

        // The recursion yields tip-first; collect then reverse into reading order.
        var rows: [(nodeID: Int64, json: String, createdAt: Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0), text(stmt, 1), sqlite3_column_int64(stmt, 2)))
        }
        rows.reverse()

        var events: [SessionEvent] = []
        for row in rows {
            let time = row.createdAt > 0 ? Date(timeIntervalSince1970: Double(row.createdAt)) : nil
            events.append(contentsOf: DevinSessionParser.events(fromChatMessage: row.json,
                                                                nodeID: row.nodeID,
                                                                time: time))
        }
        return events
    }

    private static func makeSession(id: String,
                                    title: String,
                                    cwd: String,
                                    model: String,
                                    created: Int64,
                                    lastActivity: Int64,
                                    agentMode: String,
                                    eventCount: Int,
                                    events: [SessionEvent],
                                    databasePath: String) -> Session {
        let start = created > 0 ? Date(timeIntervalSince1970: Double(created)) : nil
        let end = lastActivity > 0 ? Date(timeIntervalSince1970: Double(lastActivity)) : nil
        let trimmedCwd = cwd.isEmpty ? nil : cwd
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        return Session(id: id,
                       source: .devin,
                       startTime: start,
                       endTime: end,
                       model: model.isEmpty ? nil : model,
                       // Every session lives in the one database, so they all
                       // share its path. Matches how OpenCode's SQLite backend
                       // reports `filePath`.
                       filePath: databasePath,
                       fileSizeBytes: nil,
                       eventCount: eventCount,
                       events: events,
                       cwd: trimmedCwd,
                       repoName: trimmedCwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: trimmedTitle.isEmpty ? nil : trimmedTitle,
                       lightweightCommands: nil,
                       surface: .cli,
                       reasoningEffort: agentMode.isEmpty ? nil : agentMode)
    }
}

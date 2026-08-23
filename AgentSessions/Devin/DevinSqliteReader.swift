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
    ///
    /// The busy timeout matters more here than for a file-per-session source. This
    /// database is written by the live CLI, and a `SQLITE_BUSY` partway through the
    /// session scan is not a harmless retry-later: it ends the read early, and the
    /// caller has no way to tell a short database from a short read. Waiting briefly
    /// turns almost every contended read into a successful one; the terminal-status
    /// check in `listSessionsIfReadable` catches the rest.
    private static func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2_000)
        return db
    }

    /// Upper bound on a `parent_node_id` walk.
    ///
    /// `message_nodes` is a forest and nothing in the schema forbids a cycle, so a
    /// recursive CTE walking parents has no natural terminator on corrupt or
    /// rewound data — it spins `sqlite3_step` forever at 100% CPU, and for the
    /// all-sessions count query one bad row would wedge the whole refresh. The
    /// survey behind this reader saw 49,891 main-chain nodes across 253 sessions, so
    /// this bound is two orders of magnitude above any real conversation while still
    /// terminating a loop in well under a second. `scripts/devin_sessions_schema_probe.py`
    /// guards its own walk with a visited set for the same reason.
    private static let maxChainDepth = 50_000

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

        guard let chainCounts = mainChainCounts(db: db) else { return nil }

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
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            // Advance in a `defer` so every exit from the body — including the
            // `continue` below — moves the cursor. Advancing only on the happy
            // path turns a single unusable row into an infinite loop.
            defer { step = sqlite3_step(stmt) }
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
        // A lock or IO error ends the loop exactly like SQLITE_DONE, and the rows
        // read so far are indistinguishable from a complete answer. Returning them
        // would be reported as a clean read, and search reconciliation retires every
        // identity missing from a clean read — so a contended database would delete
        // the corpus it could not finish listing. Same guard as
        // OpenCodeSqliteReader and HermesStateDBReader.
        guard step == SQLITE_DONE else { return nil }
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
    private static func mainChainCounts(db: OpaquePointer?) -> [String: Int]? {
        let sql = """
            WITH RECURSIVE chain(session_id, node_id, parent_node_id, depth) AS (
                SELECT s.id, m.node_id, m.parent_node_id, 0
                FROM sessions s
                JOIN message_nodes m ON m.session_id = s.id AND m.node_id = s.main_chain_id
                WHERE s.hidden = 0
              UNION ALL
                SELECT c.session_id, m.node_id, m.parent_node_id, c.depth + 1
                FROM chain c
                JOIN message_nodes m ON m.session_id = c.session_id AND m.node_id = c.parent_node_id
                WHERE c.depth < \(maxChainDepth)
            )
            SELECT session_id, COUNT(*) FROM chain GROUP BY session_id;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var counts: [String: Int] = [:]
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            counts[text(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1))
            step = sqlite3_step(stmt)
        }
        // Same contract as the session scan: a partial count set is not a
        // smaller answer, it is no answer. Returning it would give every
        // unreached session eventCount 0, which `hideZeroMessageSessions`
        // hides — an empty Devin list with no error anywhere.
        guard step == SQLITE_DONE else { return nil }
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

        guard let events = mainChainEvents(db: db, sessionID: sessionID, mainChainID: mainChainID) else { return nil }
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
    private static func mainChainEvents(db: OpaquePointer?, sessionID: String, mainChainID: Int64) -> [SessionEvent]? {
        let sql = """
            WITH RECURSIVE chain(node_id, parent_node_id, chat_message, created_at, depth) AS (
                SELECT node_id, parent_node_id, chat_message, created_at, 0
                FROM message_nodes WHERE session_id = ?1 AND node_id = ?2
              UNION ALL
                SELECT m.node_id, m.parent_node_id, m.chat_message, m.created_at, c.depth + 1
                FROM chain c
                JOIN message_nodes m ON m.session_id = ?1 AND m.node_id = c.parent_node_id
                WHERE c.depth < \(maxChainDepth)
            )
            SELECT node_id, chat_message, created_at FROM chain ORDER BY depth DESC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, transient)
        sqlite3_bind_int64(stmt, 2, mainChainID)

        // The recursion walks tip-to-root, so `depth` counts backwards through the
        // conversation and `ORDER BY depth DESC` is reading order. Sorting in SQL
        // rather than reversing the array afterwards means the order is a property
        // of the query instead of an assumption about CTE emission order, which is
        // not guaranteed and broke on duplicate `node_id` rows.
        var rows: [(nodeID: Int64, json: String, createdAt: Int64)] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0), text(stmt, 1), sqlite3_column_int64(stmt, 2)))
            step = sqlite3_step(stmt)
        }
        // Same contract as the session scan, and it matters more here: a truncated
        // chain is a plausible-looking transcript, `reloadSession` treats a
        // successful reload as authoritative and overwrites the complete one, and
        // search ingest would record the short text under the current revision — so
        // for a session that never changes again the truncation sticks.
        guard step == SQLITE_DONE else { return nil }

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

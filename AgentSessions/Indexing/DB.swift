import Foundation
import SQLite3

/// Lightweight SQLite helper wrapped in an actor for thread-safety.
/// Schema stores file scan state, per-session daily metrics and day rollups.
actor IndexDB {
    enum DBError: Error { case openFailed(String), execFailed(String), prepareFailed(String) }

    private var handle: OpaquePointer?

    // MARK: - Init / Open
    init() throws {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AgentSessions", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("index.db", isDirectory: false)

        var db: OpaquePointer?
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open error"
            throw DBError.openFailed(msg)
        }
        // Apply pragmas and bootstrap schema using local db pointer (allowed during init)
        try Self.applyPragmas(db)
        #if DEBUG
        print("[IndexDB] Opened at: \(dbURL.path)")
        #endif
        try Self.bootstrap(db)
        handle = db
    }

    deinit {
        if let db = handle { sqlite3_close(db) }
    }

    // MARK: - Schema (static helpers usable during init)
    private static func applyPragmas(_ db: OpaquePointer?) throws {
        try exec(db, "PRAGMA journal_mode=WAL;")
        try exec(db, "PRAGMA synchronous=NORMAL;")
    }

    private static func bootstrap(_ db: OpaquePointer?) throws {
        // files table tracks which files we indexed and their mtimes/sizes
        try exec(db,
            """
            CREATE TABLE IF NOT EXISTS files (
              path TEXT PRIMARY KEY,
              mtime INTEGER NOT NULL,
              size INTEGER NOT NULL,
              source TEXT NOT NULL,
              indexed_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_files_source ON files(source);
            """
        )

        // session_meta provides fast startup and search prefiltering
        try exec(db,
            """
            CREATE TABLE IF NOT EXISTS session_meta (
              session_id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              path TEXT NOT NULL,
              mtime INTEGER,
              size INTEGER,
              start_ts INTEGER,
              end_ts INTEGER,
              model TEXT,
              cwd TEXT,
              repo TEXT,
              title TEXT,
              messages INTEGER DEFAULT 0,
              commands INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_session_meta_source ON session_meta(source);
            CREATE INDEX IF NOT EXISTS idx_session_meta_model ON session_meta(model);
            CREATE INDEX IF NOT EXISTS idx_session_meta_time ON session_meta(start_ts, end_ts);
            """
        )

        // session_days keeps per-session contributions split by day
        try exec(db,
            """
            CREATE TABLE IF NOT EXISTS session_days (
              day TEXT NOT NULL,              -- YYYY-MM-DD local time
              source TEXT NOT NULL,
              session_id TEXT NOT NULL,
              model TEXT,
              messages INTEGER DEFAULT 0,
              commands INTEGER DEFAULT 0,
              duration_sec REAL DEFAULT 0.0,
              PRIMARY KEY(day, source, session_id)
            );
            CREATE INDEX IF NOT EXISTS idx_session_days_source_day ON session_days(source, day);
            """
        )

        // rollups_daily is derived from session_days for instant analytics
        try exec(db,
            """
            CREATE TABLE IF NOT EXISTS rollups_daily (
              day TEXT NOT NULL,
              source TEXT NOT NULL,
              model TEXT,
              sessions INTEGER DEFAULT 0,
              messages INTEGER DEFAULT 0,
              commands INTEGER DEFAULT 0,
              duration_sec REAL DEFAULT 0.0,
              PRIMARY KEY(day, source, model)
            );
            CREATE INDEX IF NOT EXISTS idx_rollups_daily_source_day ON rollups_daily(source, day);
            """
        )

        // Heatmap buckets (3-hour) – optional; kept for future analytics wiring
        try exec(db,
            """
            CREATE TABLE IF NOT EXISTS rollups_tod (
              dow INTEGER NOT NULL,
              bucket INTEGER NOT NULL,
              messages INTEGER DEFAULT 0,
              PRIMARY KEY(dow, bucket)
            );
            """
        )

        // Per-session search corpus (stored even if FTS is unavailable).
        try exec(db,
            """
            CREATE TABLE IF NOT EXISTS session_search (
              session_id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              mtime INTEGER,
              size INTEGER,
              updated_at INTEGER NOT NULL,
              text TEXT NOT NULL,
              format_version INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_session_search_source ON session_search(source);
            """
        )

        // Best-effort migration for existing installs.
        // If the column already exists, SQLite will throw and we can ignore it.
        do {
            try exec(db, "ALTER TABLE session_search ADD COLUMN format_version INTEGER NOT NULL DEFAULT 1;")
        } catch { }

        // Full-text search (FTS5) over per-session searchable text.
        // External content table lets us upsert via regular SQL + triggers.
        do {
            try exec(db,
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS session_search_fts
                USING fts5(
                  text,
                  content='session_search',
                  content_rowid='rowid',
                  tokenize='unicode61'
                );

                CREATE TRIGGER IF NOT EXISTS session_search_ai AFTER INSERT ON session_search BEGIN
                  INSERT INTO session_search_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                CREATE TRIGGER IF NOT EXISTS session_search_ad AFTER DELETE ON session_search BEGIN
                  INSERT INTO session_search_fts(session_search_fts, rowid, text) VALUES('delete', old.rowid, old.text);
                END;
                CREATE TRIGGER IF NOT EXISTS session_search_au AFTER UPDATE ON session_search BEGIN
                  INSERT INTO session_search_fts(session_search_fts, rowid, text) VALUES('delete', old.rowid, old.text);
                  INSERT INTO session_search_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                """
            )
        } catch {
            // FTS is optional. If unavailable, search falls back to the legacy transcript-based path.
        }

        // Per-session tool IO corpus (inputs + outputs), used to make tool matches show up instantly.
        try exec(db,
            """
            CREATE TABLE IF NOT EXISTS session_tool_io (
              session_id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              mtime INTEGER,
              size INTEGER,
              ref_ts INTEGER,
              updated_at INTEGER NOT NULL,
              text TEXT NOT NULL,
              format_version INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_session_tool_io_source ON session_tool_io(source);
            CREATE INDEX IF NOT EXISTS idx_session_tool_io_ref_ts ON session_tool_io(ref_ts);
            """
        )

        // Tool IO full-text search (FTS5). Optional, same rationale as session_search_fts.
        do {
            try exec(db,
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS session_tool_io_fts
                USING fts5(
                  text,
                  content='session_tool_io',
                  content_rowid='rowid',
                  tokenize='unicode61'
                );

                CREATE TRIGGER IF NOT EXISTS session_tool_io_ai AFTER INSERT ON session_tool_io BEGIN
                  INSERT INTO session_tool_io_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                CREATE TRIGGER IF NOT EXISTS session_tool_io_ad AFTER DELETE ON session_tool_io BEGIN
                  INSERT INTO session_tool_io_fts(session_tool_io_fts, rowid, text) VALUES('delete', old.rowid, old.text);
                END;
                CREATE TRIGGER IF NOT EXISTS session_tool_io_au AFTER UPDATE ON session_tool_io BEGIN
                  INSERT INTO session_tool_io_fts(session_tool_io_fts, rowid, text) VALUES('delete', old.rowid, old.text);
                  INSERT INTO session_tool_io_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                """
            )
        } catch {
            // Optional.
        }
    }

    // MARK: - Exec helpers
    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard let db else { throw DBError.openFailed("db closed") }
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg: String
            if let e = err { msg = String(cString: e); sqlite3_free(e) } else { msg = "exec failed" }
            throw DBError.execFailed(msg)
        }
    }

    func exec(_ sql: String) throws {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg: String
            if let e = err { msg = String(cString: e); sqlite3_free(e) } else { msg = "unknown" }
            throw DBError.execFailed(msg)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DBError.prepareFailed(msg)
        }
        return stmt
    }

    func begin() throws { try exec("BEGIN IMMEDIATE;") }
    func commit() throws { try exec("COMMIT;") }
    func rollbackSilently() { try? exec("ROLLBACK;") }

    // MARK: - Simple query helpers
    private func queryOneInt64(_ sql: String) throws -> Int64 {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DBError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }

    /// Returns true when no rollups are present (first run)
    func isEmpty() throws -> Bool {
        // Prefer rollups_daily presence; fallback to session_days
        let has = try queryOneInt64("SELECT EXISTS(SELECT 1 FROM rollups_daily LIMIT 1);")
        if has == 1 { return false }
        let hasDays = try queryOneInt64("SELECT EXISTS(SELECT 1 FROM session_days LIMIT 1);")
        return hasDays == 0
    }

    /// Fetch indexed file records for a source from the files table.
    /// Used by launch-time indexers to avoid reprocessing files that analytics
    /// has already seen (even when they are filtered out of session_meta).
    func fetchIndexedFiles(for source: String) throws -> [IndexedFileRow] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = """
        SELECT path, mtime, size, indexed_at
        FROM files
        WHERE source = ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DBError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        var out: [IndexedFileRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row = IndexedFileRow(
                path: String(cString: sqlite3_column_text(stmt, 0)),
                mtime: sqlite3_column_int64(stmt, 1),
                size: sqlite3_column_int64(stmt, 2),
                indexedAt: sqlite3_column_int64(stmt, 3)
            )
            out.append(row)
        }
        return out
    }

    /// Fetch file paths that are fully populated for search (files + session_meta + session_search).
    /// Used to avoid skipping stale file rows left behind by previous builds where files were tracked
    /// but session meta/search were not.
    func fetchSearchReadyPaths(for source: String, formatVersion: Int = FeatureFlags.sessionSearchFormatVersion) throws -> Set<String> {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = """
        SELECT f.path
        FROM files f
        JOIN session_meta m ON m.source = f.source AND m.path = f.path
        JOIN session_search s ON s.source = m.source AND s.session_id = m.session_id
        WHERE f.source = ?
          AND s.mtime = f.mtime
          AND s.size = f.size
          AND s.format_version = ?;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(formatVersion))
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                out.insert(String(cString: c))
            }
        }
        return out
    }

    // Fetch session_meta rows for a source (used to hydrate sessions list quickly)
    func fetchSessionMeta(for source: String) throws -> [SessionMetaRow] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = """
        SELECT session_id, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title, messages, commands
        FROM session_meta
        WHERE source = ?
        ORDER BY COALESCE(end_ts, mtime) DESC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DBError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        var out: [SessionMetaRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row = SessionMetaRow(
                sessionID: String(cString: sqlite3_column_text(stmt, 0)),
                source: String(cString: sqlite3_column_text(stmt, 1)),
                path: String(cString: sqlite3_column_text(stmt, 2)),
                mtime: sqlite3_column_int64(stmt, 3),
                size: sqlite3_column_int64(stmt, 4),
                startTS: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 5),
                endTS: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 6),
                model: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 7)),
                cwd: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 8)),
                repo: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 9)),
                title: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 10)),
                messages: Int(sqlite3_column_int64(stmt, 11)),
                commands: Int(sqlite3_column_int64(stmt, 12))
            )
            out.append(row)
        }
        return out
    }

    /// Fetch COALESCE(end_ts, mtime) for a session identified by its file path.
    /// Used to gate date-based behaviors without re-parsing the raw session file.
    func sessionRefTSForPath(source: String, path: String) throws -> Int64? {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = "SELECT COALESCE(end_ts, mtime) FROM session_meta WHERE source=? AND path=? LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0)
        }
        return nil
    }

    // Prefilter by metadata to reduce search candidates
    func prefilterSessionIDs(sources: [String], model: String?, repoSubstr: String?, dateFrom: Date?, dateTo: Date?) throws -> [String] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let m = model, !m.isEmpty { clauses.append("model = ?"); binds.append(m) }
        if let r = repoSubstr, !r.isEmpty { clauses.append("(repo LIKE ? OR cwd LIKE ?)"); let like = "%\(r)%"; binds.append(like); binds.append(like) }
        if let df = dateFrom { clauses.append("COALESCE(end_ts, mtime) >= ?"); binds.append(Int64(df.timeIntervalSince1970)) }
        if let dt = dateTo { clauses.append("COALESCE(end_ts, mtime) <= ?"); binds.append(Int64(dt.timeIntervalSince1970)) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT session_id FROM session_meta\(whereSQL);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DBError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        // Bind parameters
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            else if let i = b as? Int64 { sqlite3_bind_int64(stmt, idx, i) }
            idx += 1
        }
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    // MARK: - Analytics rollup queries
    func countDistinctSessions(sources: [String], dayStart: String?, dayEnd: String?) throws -> Int {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT COUNT(DISTINCT session_id) FROM session_days\(whereSQL);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        return 0
    }

    /// Count distinct sessions with a minimum total messages threshold across the selected period.
    func countDistinctSessionsFiltered(sources: [String], dayStart: String?, dayEnd: String?, minMessages: Int) throws -> Int {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = """
        SELECT COUNT(*) FROM (
            SELECT session_id
            FROM session_days\(whereSQL)
            GROUP BY session_id
            HAVING SUM(messages) >= ?
        )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(minMessages))
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        return 0
    }

    /// Sum of messages across sessions that meet a minimum messages threshold across the period.
    func sumMessagesFiltered(sources: [String], dayStart: String?, dayEnd: String?, minMessages: Int) throws -> Int {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = """
        SELECT COALESCE(SUM(msgs), 0) FROM (
            SELECT session_id, SUM(messages) AS msgs
            FROM session_days\(whereSQL)
            GROUP BY session_id
            HAVING SUM(messages) >= ?
        )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(minMessages))
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        return 0
    }

    /// Sum of duration across sessions that meet a minimum messages threshold.
    func sumDurationFiltered(sources: [String], dayStart: String?, dayEnd: String?, minMessages: Int) throws -> TimeInterval {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = """
        SELECT COALESCE(SUM(dur), 0.0) FROM (
            SELECT session_id, SUM(duration_sec) AS dur, SUM(messages) AS msgs
            FROM session_days\(whereSQL)
            GROUP BY session_id
            HAVING msgs >= ?
        )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(minMessages))
        if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_double(stmt, 0) }
        return 0.0
    }

    /// Sum of commands across sessions that meet a minimum messages threshold.
    func sumCommandsFiltered(sources: [String], dayStart: String?, dayEnd: String?, minMessages: Int) throws -> Int {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = """
        SELECT COALESCE(SUM(cmds), 0) FROM (
            SELECT session_id, SUM(commands) AS cmds, SUM(messages) AS msgs
            FROM session_days\(whereSQL)
            GROUP BY session_id
            HAVING msgs >= ?
        )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(minMessages))
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        return 0
    }

    func sumRollups(sources: [String], dayStart: String?, dayEnd: String?) throws -> (Int, Int, TimeInterval) {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT COALESCE(SUM(messages),0), COALESCE(SUM(commands),0), COALESCE(SUM(duration_sec),0.0) FROM rollups_daily\(whereSQL);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let m = Int(sqlite3_column_int64(stmt, 0))
            let c = Int(sqlite3_column_int64(stmt, 1))
            let d = sqlite3_column_double(stmt, 2)
            return (m, c, d)
        }
        return (0, 0, 0)
    }

    func distinctSessionsBySource(sources: [String], dayStart: String?, dayEnd: String?) throws -> [String: Int] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT source, COUNT(DISTINCT session_id) FROM session_days\(whereSQL) GROUP BY source;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let src = String(cString: sqlite3_column_text(stmt, 0))
            let cnt = Int(sqlite3_column_int64(stmt, 1))
            out[src] = cnt
        }
        return out
    }

    func durationBySource(sources: [String], dayStart: String?, dayEnd: String?) throws -> [String: TimeInterval] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT source, COALESCE(SUM(duration_sec),0.0) FROM rollups_daily\(whereSQL) GROUP BY source;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        var out: [String: TimeInterval] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let src = String(cString: sqlite3_column_text(stmt, 0))
            let dur = sqlite3_column_double(stmt, 1)
            out[src] = dur
        }
        return out
    }

    func messagesBySource(sources: [String], dayStart: String?, dayEnd: String?) throws -> [String: Int] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT source, COALESCE(SUM(messages),0) FROM rollups_daily\(whereSQL) GROUP BY source;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let src = String(cString: sqlite3_column_text(stmt, 0))
            let messages = Int(sqlite3_column_int64(stmt, 1))
            out[src] = messages
        }
        return out
    }

    func avgSessionDuration(sources: [String], dayStart: String?, dayEnd: String?) throws -> TimeInterval {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        // Calculate total duration per session, then average across sessions
        let sql = """
        SELECT COALESCE(AVG(session_duration), 0.0)
        FROM (
            SELECT session_id, SUM(duration_sec) as session_duration
            FROM session_days\(whereSQL)
            GROUP BY session_id
        )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return 0.0
    }

    /// Average session duration with a minimum message threshold per session across the period.
    /// Sessions whose total messages across the selected bounds are below `minMessages` are excluded.
    func avgSessionDurationFiltered(sources: [String], dayStart: String?, dayEnd: String?, minMessages: Int) throws -> TimeInterval {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let s = dayStart { clauses.append("day >= ?"); binds.append(s) }
        if let e = dayEnd { clauses.append("day <= ?"); binds.append(e) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = """
        SELECT COALESCE(AVG(session_duration), 0.0)
        FROM (
            SELECT session_id,
                   SUM(duration_sec) AS session_duration,
                   SUM(messages)     AS msgs
            FROM session_days\(whereSQL)
            GROUP BY session_id
            HAVING msgs >= ?
        )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(minMessages))
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return 0.0
    }

    // Detect legacy unstable IDs (e.g., Swift hashValue) for a given source
    func hasUnstableIDs(for source: String) throws -> Bool {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        // session_id should be 64 hex chars for SHA-256; anything else is unstable
        let sql = "SELECT EXISTS(SELECT 1 FROM session_meta WHERE source=? AND (length(session_id) <> 64 OR session_id GLOB '*[^0-9a-f]*'))"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_int(stmt, 0) == 1 }
        return false
    }

    // Purge all rows for a source (meta + per-day + rollups) to allow clean rebuild
    func purgeSource(_ source: String) throws {
        try exec("DELETE FROM rollups_daily WHERE source='\(source)'")
        try exec("DELETE FROM session_days WHERE source='\(source)'")
        try exec("DELETE FROM session_meta WHERE source='\(source)'")
        try exec("DELETE FROM session_search WHERE source='\(source)'")
        try exec("DELETE FROM session_tool_io WHERE source='\(source)'")
        try exec("DELETE FROM files WHERE source='\(source)'")
    }

    /// Delete DB rows for sessions whose file paths were removed.
    /// Returns the distinct days affected (so callers can recompute rollups).
    func deleteSessionsForPaths(source: String, paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { return [] }
        guard let db = handle else { throw DBError.openFailed("db closed") }

        var affectedDays = Set<String>()

        // Chunk to stay under SQLite variable limits.
        let chunkSize = 200
        var i = 0
        while i < paths.count {
            let end = min(i + chunkSize, paths.count)
            let slice = Array(paths[i..<end])
            i = end

            let inSQL = Array(repeating: "?", count: slice.count).joined(separator: ",")

            // Capture affected days before deleting.
            let daysSQL = """
            SELECT DISTINCT day
            FROM session_days
            WHERE source = ?
              AND session_id IN (
                SELECT session_id
                FROM session_meta
                WHERE source = ? AND path IN (\(inSQL))
              );
            """
            var daysStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, daysSQL, -1, &daysStmt, nil) != SQLITE_OK {
                throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(daysStmt) }
            var bindIdx: Int32 = 1
            sqlite3_bind_text(daysStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            sqlite3_bind_text(daysStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            for p in slice {
                sqlite3_bind_text(daysStmt, bindIdx, p, -1, SQLITE_TRANSIENT)
                bindIdx += 1
            }
            while sqlite3_step(daysStmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(daysStmt, 0) {
                    affectedDays.insert(String(cString: c))
                }
            }

            // Delete per-day contributions.
            let delDaysSQL = """
            DELETE FROM session_days
            WHERE source = ?
              AND session_id IN (
                SELECT session_id
                FROM session_meta
                WHERE source = ? AND path IN (\(inSQL))
              );
            """
            let delDaysStmt = try prepare(delDaysSQL)
            defer { sqlite3_finalize(delDaysStmt) }
            bindIdx = 1
            sqlite3_bind_text(delDaysStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            sqlite3_bind_text(delDaysStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            for p in slice {
                sqlite3_bind_text(delDaysStmt, bindIdx, p, -1, SQLITE_TRANSIENT)
                bindIdx += 1
            }
            if sqlite3_step(delDaysStmt) != SQLITE_DONE { throw DBError.execFailed("delete session_days by path") }

            // Delete search corpus.
            let delSearchSQL = """
            DELETE FROM session_search
            WHERE source = ?
              AND session_id IN (
                SELECT session_id
                FROM session_meta
                WHERE source = ? AND path IN (\(inSQL))
              );
            """
            let delSearchStmt = try prepare(delSearchSQL)
            defer { sqlite3_finalize(delSearchStmt) }
            bindIdx = 1
            sqlite3_bind_text(delSearchStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            sqlite3_bind_text(delSearchStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            for p in slice {
                sqlite3_bind_text(delSearchStmt, bindIdx, p, -1, SQLITE_TRANSIENT)
                bindIdx += 1
            }
            if sqlite3_step(delSearchStmt) != SQLITE_DONE { throw DBError.execFailed("delete session_search by path") }

            // Delete tool corpus.
            let delToolSQL = """
            DELETE FROM session_tool_io
            WHERE source = ?
              AND session_id IN (
                SELECT session_id
                FROM session_meta
                WHERE source = ? AND path IN (\(inSQL))
              );
            """
            let delToolStmt = try prepare(delToolSQL)
            defer { sqlite3_finalize(delToolStmt) }
            bindIdx = 1
            sqlite3_bind_text(delToolStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            sqlite3_bind_text(delToolStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            for p in slice {
                sqlite3_bind_text(delToolStmt, bindIdx, p, -1, SQLITE_TRANSIENT)
                bindIdx += 1
            }
            if sqlite3_step(delToolStmt) != SQLITE_DONE { throw DBError.execFailed("delete session_tool_io by path") }

            // Delete meta and file tracking rows.
            let delMetaSQL = "DELETE FROM session_meta WHERE source = ? AND path IN (\(inSQL));"
            let delMetaStmt = try prepare(delMetaSQL)
            defer { sqlite3_finalize(delMetaStmt) }
            bindIdx = 1
            sqlite3_bind_text(delMetaStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            for p in slice {
                sqlite3_bind_text(delMetaStmt, bindIdx, p, -1, SQLITE_TRANSIENT)
                bindIdx += 1
            }
            if sqlite3_step(delMetaStmt) != SQLITE_DONE { throw DBError.execFailed("delete session_meta by path") }

            let delFilesSQL = "DELETE FROM files WHERE source = ? AND path IN (\(inSQL));"
            let delFilesStmt = try prepare(delFilesSQL)
            defer { sqlite3_finalize(delFilesStmt) }
            bindIdx = 1
            sqlite3_bind_text(delFilesStmt, bindIdx, source, -1, SQLITE_TRANSIENT); bindIdx += 1
            for p in slice {
                sqlite3_bind_text(delFilesStmt, bindIdx, p, -1, SQLITE_TRANSIENT)
                bindIdx += 1
            }
            if sqlite3_step(delFilesStmt) != SQLITE_DONE { throw DBError.execFailed("delete files by path") }
        }

        return Array(affectedDays)
    }

    /// Fetch file paths that are fully populated for tool IO search (files + session_meta + session_tool_io).
    func fetchToolIOReadyPaths(for source: String, formatVersion: Int = FeatureFlags.sessionToolIOFormatVersion) throws -> Set<String> {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = """
        SELECT f.path
        FROM files f
        JOIN session_meta m ON m.source = f.source AND m.path = f.path
        JOIN session_tool_io t ON t.source = m.source AND t.session_id = m.session_id
        WHERE f.source = ?
          AND t.mtime = f.mtime
          AND t.size = f.size
          AND t.format_version = ?;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(formatVersion))
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                out.insert(String(cString: c))
            }
        }
        return out
    }

    // MARK: - Upserts
    func upsertFile(path: String, mtime: Int64, size: Int64, source: String) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let sql = "INSERT INTO files(path, mtime, size, source, indexed_at) VALUES(?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, size=excluded.size, source=excluded.source, indexed_at=excluded.indexed_at;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, mtime)
        sqlite3_bind_int64(stmt, 3, size)
        sqlite3_bind_text(stmt, 4, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, now)
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("upsert files") }
    }

    func upsertSessionMeta(_ m: SessionMetaRow) throws {
        let sql = """
        INSERT INTO session_meta(session_id, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title, messages, commands)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          source=excluded.source, path=excluded.path, mtime=excluded.mtime, size=excluded.size,
          start_ts=excluded.start_ts, end_ts=excluded.end_ts, model=excluded.model, cwd=excluded.cwd,
          repo=excluded.repo, title=excluded.title, messages=excluded.messages, commands=excluded.commands;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, m.sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, m.source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, m.path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, m.mtime)
        sqlite3_bind_int64(stmt, 5, m.size)
        sqlite3_bind_int64(stmt, 6, m.startTS)
        sqlite3_bind_int64(stmt, 7, m.endTS)
        if let model = m.model { sqlite3_bind_text(stmt, 8, model, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 8) }
        if let cwd = m.cwd { sqlite3_bind_text(stmt, 9, cwd, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
        if let repo = m.repo { sqlite3_bind_text(stmt, 10, repo, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 10) }
        if let title = m.title { sqlite3_bind_text(stmt, 11, title, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 11) }
        sqlite3_bind_int64(stmt, 12, Int64(m.messages))
        sqlite3_bind_int64(stmt, 13, Int64(m.commands))
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("upsert session_meta") }
    }

    func upsertSessionSearch(sessionID: String, source: String, mtime: Int64, size: Int64, text: String, formatVersion: Int = FeatureFlags.sessionSearchFormatVersion) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
        INSERT INTO session_search(session_id, source, mtime, size, updated_at, text, format_version)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          source=excluded.source,
          mtime=excluded.mtime,
          size=excluded.size,
          updated_at=excluded.updated_at,
          text=excluded.text,
          format_version=excluded.format_version;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, mtime)
        sqlite3_bind_int64(stmt, 4, size)
        sqlite3_bind_int64(stmt, 5, now)
        sqlite3_bind_text(stmt, 6, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, Int32(formatVersion))
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("upsert session_search") }
    }

    func upsertSessionToolIO(sessionID: String, source: String, mtime: Int64, size: Int64, refTS: Int64, text: String, formatVersion: Int = FeatureFlags.sessionToolIOFormatVersion) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
        INSERT INTO session_tool_io(session_id, source, mtime, size, ref_ts, updated_at, text, format_version)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          source=excluded.source,
          mtime=excluded.mtime,
          size=excluded.size,
          ref_ts=excluded.ref_ts,
          updated_at=excluded.updated_at,
          text=excluded.text,
          format_version=excluded.format_version;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, mtime)
        sqlite3_bind_int64(stmt, 4, size)
        sqlite3_bind_int64(stmt, 5, refTS)
        sqlite3_bind_int64(stmt, 6, now)
        sqlite3_bind_text(stmt, 7, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 8, Int32(formatVersion))
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("upsert session_tool_io") }
    }

    func hasSearchData(sources: [String]) throws -> Bool {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT EXISTS(SELECT 1 FROM session_search\(whereSQL) LIMIT 1);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) == 1
        }
        return false
    }

    func indexedSessionIDs(sources: [String]) throws -> [String] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT session_id FROM session_search\(whereSQL);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            idx += 1
        }

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    func fetchSessionMetaPaths(for source: String) throws -> [String] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = "SELECT path FROM session_meta WHERE source = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    func searchSessionIDsFTS(
        sources: [String],
        model: String?,
        repoSubstr: String?,
        pathSubstr: String?,
        dateFrom: Date?,
        dateTo: Date?,
        query: String,
        includeSystemProbes: Bool,
        limit: Int
    ) throws -> [String] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []

        clauses.append("session_search_fts MATCH ?")
        binds.append(query)

        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("sm.source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let m = model, !m.isEmpty { clauses.append("sm.model = ?"); binds.append(m) }
        if let r = repoSubstr, !r.isEmpty { clauses.append("sm.repo LIKE ?"); binds.append("%\(r)%") }
        if let p = pathSubstr, !p.isEmpty { clauses.append("sm.cwd LIKE ?"); binds.append("%\(p)%") }
        if let df = dateFrom { clauses.append("COALESCE(sm.end_ts, sm.mtime) >= ?"); binds.append(Int64(df.timeIntervalSince1970)) }
        if let dt = dateTo { clauses.append("COALESCE(sm.end_ts, sm.mtime) <= ?"); binds.append(Int64(dt.timeIntervalSince1970)) }
        if !includeSystemProbes {
            // Exclude Agent Sessions' Claude probe sessions; these are hidden by default in the UI.
            clauses.append("NOT (sm.source = 'claude' AND sm.path LIKE ?)")
            binds.append("%AgentSessions-ClaudeProbeProject%")
        }

        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = """
        SELECT sm.session_id
        FROM session_search_fts f
        JOIN session_search s ON s.rowid = f.rowid
        JOIN session_meta sm ON sm.session_id = s.session_id
        \(whereSQL)
        ORDER BY bm25(session_search_fts)
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            else if let i = b as? Int64 { sqlite3_bind_int64(stmt, idx, i) }
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    func searchSessionIDsToolIOFTS(
        sources: [String],
        model: String?,
        repoSubstr: String?,
        pathSubstr: String?,
        dateFrom: Date?,
        dateTo: Date?,
        query: String,
        includeSystemProbes: Bool,
        limit: Int
    ) throws -> [String] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []

        clauses.append("session_tool_io_fts MATCH ?")
        binds.append(query)

        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("sm.source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let m = model, !m.isEmpty { clauses.append("sm.model = ?"); binds.append(m) }
        if let r = repoSubstr, !r.isEmpty { clauses.append("sm.repo LIKE ?"); binds.append("%\(r)%") }
        if let p = pathSubstr, !p.isEmpty { clauses.append("sm.cwd LIKE ?"); binds.append("%\(p)%") }
        if let df = dateFrom { clauses.append("COALESCE(sm.end_ts, sm.mtime) >= ?"); binds.append(Int64(df.timeIntervalSince1970)) }
        if let dt = dateTo { clauses.append("COALESCE(sm.end_ts, sm.mtime) <= ?"); binds.append(Int64(dt.timeIntervalSince1970)) }
        if !includeSystemProbes {
            clauses.append("NOT (sm.source = 'claude' AND sm.path LIKE ?)")
            binds.append("%AgentSessions-ClaudeProbeProject%")
        }

        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = """
        SELECT sm.session_id
        FROM session_tool_io_fts f
        JOIN session_tool_io t ON t.rowid = f.rowid
        JOIN session_meta sm ON sm.session_id = t.session_id
        \(whereSQL)
        ORDER BY bm25(session_tool_io_fts)
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            else if let i = b as? Int64 { sqlite3_bind_int64(stmt, idx, i) }
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    func pruneOldToolIO(cutoffTS: Int64, oldBytesCap: Int64, batchSize: Int = 64) throws {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        guard oldBytesCap > 0 else { return }

        func oldBytes() -> Int64 {
            let sql = "SELECT COALESCE(SUM(length(CAST(text AS BLOB))), 0) FROM session_tool_io WHERE COALESCE(ref_ts, 0) < ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cutoffTS)
            if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_int64(stmt, 0) }
            return 0
        }

        var currentOldBytes = oldBytes()
        if currentOldBytes <= oldBytesCap { return }

        do {
            try begin()
            var iterations = 0
            while currentOldBytes > oldBytesCap {
                if iterations > 200 { break }
                iterations += 1

                let delSQL = """
                DELETE FROM session_tool_io
                WHERE rowid IN (
                  SELECT rowid
                  FROM session_tool_io
                  WHERE COALESCE(ref_ts, 0) < ?
                  ORDER BY COALESCE(ref_ts, 0) ASC
                  LIMIT ?
                );
                """
                let stmt = try prepare(delSQL)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, cutoffTS)
                sqlite3_bind_int(stmt, 2, Int32(batchSize))
                if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("prune session_tool_io") }

                currentOldBytes = oldBytes()
                if sqlite3_changes(db) == 0 { break }
            }
            try commit()
        } catch {
            rollbackSilently()
            throw error
        }
    }

    func prefilterSessionIDs(
        sources: [String],
        model: String?,
        repoSubstr: String?,
        pathSubstr: String?,
        dateFrom: Date?,
        dateTo: Date?,
        limit: Int?
    ) throws -> [String] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [Any] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        if let m = model, !m.isEmpty { clauses.append("model = ?"); binds.append(m) }
        if let r = repoSubstr, !r.isEmpty { clauses.append("repo LIKE ?"); binds.append("%\(r)%") }
        if let p = pathSubstr, !p.isEmpty { clauses.append("cwd LIKE ?"); binds.append("%\(p)%") }
        if let df = dateFrom { clauses.append("COALESCE(end_ts, mtime) >= ?"); binds.append(Int64(df.timeIntervalSince1970)) }
        if let dt = dateTo { clauses.append("COALESCE(end_ts, mtime) <= ?"); binds.append(Int64(dt.timeIntervalSince1970)) }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let limitSQL = limit == nil ? "" : " LIMIT ?"
        let sql = "SELECT session_id FROM session_meta\(whereSQL) ORDER BY COALESCE(end_ts, mtime) DESC\(limitSQL);"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for b in binds {
            if let s = b as? String { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            else if let i = b as? Int64 { sqlite3_bind_int64(stmt, idx, i) }
            idx += 1
        }
        if let limit {
            sqlite3_bind_int(stmt, idx, Int32(limit))
        }

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    func updateSessionMetaTitle(sessionID: String, source: String, title: String?) throws {
        let sql = "UPDATE session_meta SET title=? WHERE session_id=? AND source=?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let title {
            sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, source, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("update session_meta title") }
    }

    func deleteSessionDays(sessionID: String, source: String) throws {
        let sql = "DELETE FROM session_days WHERE session_id=? AND source=?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("delete session_days") }
    }

    func insertSessionDayRows(_ rows: [SessionDayRow]) throws {
        guard !rows.isEmpty else { return }
        let sql = "INSERT OR REPLACE INTO session_days(day, source, session_id, model, messages, commands, duration_sec) VALUES(?,?,?,?,?,?,?);"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for r in rows {
            sqlite3_bind_text(stmt, 1, r.day, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, r.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, r.sessionID, -1, SQLITE_TRANSIENT)
            if let model = r.model { sqlite3_bind_text(stmt, 4, model, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_int64(stmt, 5, Int64(r.messages))
            sqlite3_bind_int64(stmt, 6, Int64(r.commands))
            sqlite3_bind_double(stmt, 7, r.durationSec)
            if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("insert session_days") }
            sqlite3_reset(stmt)
        }
    }

    // Recompute rollups for a specific (day, source) from session_days
    func recomputeRollups(day: String, source: String) throws {
        // Delete existing rows for day+source to avoid stale aggregates
        let del = try prepare("DELETE FROM rollups_daily WHERE day=? AND source=?;")
        defer { sqlite3_finalize(del) }
        sqlite3_bind_text(del, 1, day, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(del, 2, source, -1, SQLITE_TRANSIENT)
        if sqlite3_step(del) != SQLITE_DONE { throw DBError.execFailed("delete rollups_daily") }

        let ins = """
        INSERT INTO rollups_daily(day, source, model, sessions, messages, commands, duration_sec)
        SELECT day, source, model, COUNT(DISTINCT session_id), SUM(messages), SUM(commands), SUM(duration_sec)
        FROM session_days
        WHERE day=? AND source=?
        GROUP BY day, source, model;
        """
        let stmt = try prepare(ins)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, day, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("insert rollups_daily") }
    }
}

// MARK: - DTOs
struct SessionMetaRow {
    let sessionID: String
    let source: String
    let path: String
    let mtime: Int64
    let size: Int64
    let startTS: Int64
    let endTS: Int64
    let model: String?
    let cwd: String?
    let repo: String?
    let title: String?
    let messages: Int
    let commands: Int
}

struct SessionDayRow {
    let day: String
    let source: String
    let sessionID: String
    let model: String?
    let messages: Int
    let commands: Int
    let durationSec: Double
}

struct IndexedFileRow {
    let path: String
    let mtime: Int64
    let size: Int64
    let indexedAt: Int64
}

// MARK: - SQLite helper
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

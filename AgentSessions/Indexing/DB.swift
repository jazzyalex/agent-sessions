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

// MARK: - SQLite helper
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

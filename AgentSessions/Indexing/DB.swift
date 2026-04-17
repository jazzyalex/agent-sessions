import Foundation
import SQLite3

#if DEBUG
enum IndexDBTestHooks {
    static var applicationSupportDirectoryProvider: (() -> URL?)?
}
#endif

/// Lightweight SQLite helper wrapped in an actor for thread-safety.
/// Schema stores file scan state, per-session daily metrics and day rollups.
actor IndexDB {
    enum DBError: Error { case openFailed(String), execFailed(String), prepareFailed(String) }

    private var handle: OpaquePointer?

    // MARK: - Init / Open
    init() throws {
        let fm = FileManager.default
        guard let appSupport = Self.resolveApplicationSupportDirectoryURL(fileManager: fm) else {
            throw DBError.openFailed("Application Support directory unavailable")
        }
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

    private static func resolveApplicationSupportDirectoryURL(fileManager: FileManager) -> URL? {
#if DEBUG
        if let provider = IndexDBTestHooks.applicationSupportDirectoryProvider {
            return provider()
        }
#endif
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    // MARK: - Schema (static helpers usable during init)
    private static func applyPragmas(_ db: OpaquePointer?) throws {
        try exec(db, "PRAGMA journal_mode=WAL;")
        try exec(db, "PRAGMA synchronous=NORMAL;")
        try exec(db, "PRAGMA busy_timeout = 5000;")
    }

    private static func bootstrap(_ db: OpaquePointer?) throws {
        try exec(db, "BEGIN IMMEDIATE;")
        do {
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
              codex_internal_session_id TEXT,
              is_housekeeping INTEGER NOT NULL DEFAULT 0,
              messages INTEGER DEFAULT 0,
              commands INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_session_meta_source ON session_meta(source);
            CREATE INDEX IF NOT EXISTS idx_session_meta_model ON session_meta(model);
            CREATE INDEX IF NOT EXISTS idx_session_meta_time ON session_meta(start_ts, end_ts);
            """
        )

        // Best-effort migration for existing installs.
        // Guard the ALTER with schema introspection to avoid duplicate-column warnings.
        if !tableHasColumn(db, table: "session_meta", column: "is_housekeeping") {
            do {
                try exec(db, "ALTER TABLE session_meta ADD COLUMN is_housekeeping INTEGER NOT NULL DEFAULT 0;")
            } catch {
                // Another process/instance can win the race after our precheck.
                if !isDuplicateColumnError(error) { throw error }
            }
        }

        if !tableHasColumn(db, table: "session_meta", column: "codex_internal_session_id") {
            do {
                try exec(db, "ALTER TABLE session_meta ADD COLUMN codex_internal_session_id TEXT;")
            } catch {
                // Another process/instance can win the race after our precheck.
                if !isDuplicateColumnError(error) { throw error }
            }
        }

        // Create this index only after the column exists (older installs won't have it yet).
        if tableHasColumn(db, table: "session_meta", column: "is_housekeeping") {
            try exec(db, "CREATE INDEX IF NOT EXISTS idx_session_meta_housekeeping ON session_meta(is_housekeeping);")
        }

        // Subagent hierarchy columns.
        if !tableHasColumn(db, table: "session_meta", column: "parent_session_id") {
            do {
                try exec(db, "ALTER TABLE session_meta ADD COLUMN parent_session_id TEXT;")
            } catch {
                if !isDuplicateColumnError(error) { throw error }
            }
        }

        if !tableHasColumn(db, table: "session_meta", column: "subagent_type") {
            do {
                try exec(db, "ALTER TABLE session_meta ADD COLUMN subagent_type TEXT;")
            } catch {
                if !isDuplicateColumnError(error) { throw error }
            }
        }

        if !tableHasColumn(db, table: "session_meta", column: "custom_title") {
            do {
                try exec(db, "ALTER TABLE session_meta ADD COLUMN custom_title TEXT;")
            } catch {
                if !isDuplicateColumnError(error) { throw error }
            }
        }

        if tableHasColumn(db, table: "session_meta", column: "parent_session_id") {
            try exec(db, "CREATE INDEX IF NOT EXISTS idx_session_meta_parent ON session_meta(parent_session_id);")
        }

        // One-time migration marker table for schema changes that require a full reindex.
        try exec(db, "CREATE TABLE IF NOT EXISTS schema_migrations (key TEXT PRIMARY KEY);")

        // Generic key-value state table for lightweight persistent markers (e.g. backfill tracking).
        try exec(db, "CREATE TABLE IF NOT EXISTS index_state (key TEXT PRIMARY KEY, value TEXT);")

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
        // Guard the ALTER with schema introspection to avoid duplicate-column warnings.
        if !tableHasColumn(db, table: "session_search", column: "format_version") {
            do {
                try exec(db, "ALTER TABLE session_search ADD COLUMN format_version INTEGER NOT NULL DEFAULT 1;")
            } catch {
                // Another process/instance can win the race after our precheck.
                if !isDuplicateColumnError(error) { throw error }
            }
        }

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

        // Force full reindex to populate parent_session_id and subagent_type for all sessions.
        // v2: extract agent_role from Codex thread_spawn instead of hardcoding "thread_spawn".
        // Runs after all CREATE TABLE statements so fresh databases don't hit "no such table".
        let migrationKey = "subagent_reindex_v2"
        if !migrationApplied(db, key: migrationKey) {
            try exec(db, "DELETE FROM files;")
            try exec(db, "DELETE FROM session_meta;")
            try exec(db, "DELETE FROM session_search;")
            try exec(db, "DELETE FROM session_tool_io;")
            try exec(db, "DELETE FROM session_days;")
            try exec(db, "DELETE FROM rollups_daily;")
            try execBind(db, "INSERT OR IGNORE INTO schema_migrations(key) VALUES(?);", migrationKey)
        }

        // Backfill custom_title for already-indexed sessions by forcing a full reindex.
        let customTitleMigration = "custom_title_reindex_v1"
        if !migrationApplied(db, key: customTitleMigration) {
            try exec(db, "DELETE FROM files;")
            try exec(db, "DELETE FROM session_meta;")
            try exec(db, "DELETE FROM session_search;")
            try exec(db, "DELETE FROM session_tool_io;")
            try exec(db, "DELETE FROM session_days;")
            try exec(db, "DELETE FROM rollups_daily;")
            try execBind(db, "INSERT OR IGNORE INTO schema_migrations(key) VALUES(?);", customTitleMigration)
        }

        // Analytics now derives session_days from session_meta instead of file parsing.
        // Clear stale analytics data so the first build re-derives everything.
        // v2: adds meta_mtime column for change detection.
        let analyticsMetaDerive = "analytics_meta_derive_v2"
        if !migrationApplied(db, key: analyticsMetaDerive) {
            try exec(db, "DELETE FROM session_days;")
            try exec(db, "DELETE FROM rollups_daily;")
            try exec(db, "DELETE FROM index_state WHERE key LIKE 'analytics_backfill_done:%';")
            // Add meta_mtime column for tracking derivation freshness.
            if !tableHasColumn(db, table: "session_days", column: "meta_mtime") {
                do {
                    try exec(db, "ALTER TABLE session_days ADD COLUMN meta_mtime INTEGER DEFAULT 0;")
                } catch {
                    if !isDuplicateColumnError(error) { throw error }
                }
            }
            try execBind(db, "INSERT OR IGNORE INTO schema_migrations(key) VALUES(?);", analyticsMetaDerive)
        }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    // MARK: - Exec helpers
    private static func migrationApplied(_ db: OpaquePointer?, key: String) -> Bool {
        guard let db else { return false }
        let sql = "SELECT 1 FROM schema_migrations WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func tableHasColumn(_ db: OpaquePointer?, table: String, column: String) -> Bool {
        guard let db else { return false }
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let sql = "PRAGMA table_info('\(escapedTable)');"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: name) == column { return true }
        }
        return false
    }

    private static func isDuplicateColumnError(_ error: Error) -> Bool {
        guard case let DBError.execFailed(message) = error else { return false }
        return message.localizedCaseInsensitiveContains("duplicate column name")
    }

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

    /// Execute a single-parameter text-bind statement, throwing on prepare or step failure.
    private static func execBind(_ db: OpaquePointer?, _ sql: String, _ value: String) throws {
        guard let db else { throw DBError.openFailed("db closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, value, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.execFailed(String(cString: sqlite3_errmsg(db)))
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

    // MARK: - Analytics Backfill State

    /// Record that a full analytics backfill completed for `source` at the given schema version.
    func setAnalyticsBackfillComplete(source: String, version: Int) throws {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let key = "analytics_backfill_done:\(source):\(version)"
        let sql = "INSERT OR REPLACE INTO index_state(key, value) VALUES(?, '1');"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw DBError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Returns the set of source names that have a backfill-complete marker for `version`.
    func analyticsBackfillCompleteSources(version: Int) throws -> Set<String> {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let prefix = "analytics_backfill_done:"
        let expectedSuffix = ":\(version)"
        let sql = "SELECT key FROM index_state WHERE key LIKE ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "\(prefix)%", -1, SQLITE_TRANSIENT)
        var sources = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: cStr)
            // Key format: "analytics_backfill_done:<source>:<version>"
            guard key.hasSuffix(expectedSuffix) else { continue }
            let inner = key.dropFirst(prefix.count).dropLast(expectedSuffix.count)
            if !inner.isEmpty {
                sources.insert(String(inner))
            }
        }
        return sources
    }

    /// Remove all analytics backfill markers (all sources, all versions).
    func clearAnalyticsBackfillState() throws {
        try exec("DELETE FROM index_state WHERE key LIKE 'analytics_backfill_done:%';")
    }

    // MARK: - Generic Index State

    /// Store an arbitrary string value in index_state under a key.
    func setIndexState(key: String, value: String) throws {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = "INSERT OR REPLACE INTO index_state(key, value) VALUES(?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw DBError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Fetch an arbitrary string value from index_state by key.
    func indexStateValue(for key: String) throws -> String? {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = "SELECT value FROM index_state WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
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
        SELECT session_id, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title, codex_internal_session_id, is_housekeeping, messages, commands, parent_session_id, subagent_type, custom_title
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
                codexInternalSessionID: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 11)),
                isHousekeeping: sqlite3_column_int64(stmt, 12) != 0,
                messages: Int(sqlite3_column_int64(stmt, 13)),
                commands: Int(sqlite3_column_int64(stmt, 14)),
                parentSessionID: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 15)),
                subagentType: sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 16)),
                customTitle: sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 17))
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
    func analyticsSessionDaySpan(sources: [String]) throws -> (String?, String?) {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        var clauses: [String] = []
        var binds: [String] = []
        if !sources.isEmpty {
            let qs = Array(repeating: "?", count: sources.count).joined(separator: ",")
            clauses.append("source IN (\(qs))")
            binds.append(contentsOf: sources)
        }
        let whereSQL = clauses.isEmpty ? "" : (" WHERE " + clauses.joined(separator: " AND "))
        let sql = "SELECT MIN(day), MAX(day) FROM session_days\(whereSQL);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for source in binds {
            sqlite3_bind_text(stmt, idx, source, -1, SQLITE_TRANSIENT)
            idx += 1
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let minDay = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 0))
            let maxDay = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 1))
            return (minDay, maxDay)
        }
        return (nil, nil)
    }

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

    /// Count distinct sessions while respecting message-count preferences.
    ///
    /// Semantics:
    /// - hideZero: exclude sessions whose total messages across the period is 0
    /// - hideLow: exclude sessions whose total messages across the period is 1–2 (but keep 0-message sessions unless hideZero is also enabled)
    func countDistinctSessionsFiltered(sources: [String], dayStart: String?, dayEnd: String?, hideZero: Bool, hideLow: Bool) throws -> Int {
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
            HAVING (? = 0 OR SUM(messages) >= 1)
               AND (? = 0 OR SUM(messages) = 0 OR SUM(messages) >= 3)
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
        sqlite3_bind_int(stmt, idx, hideZero ? 1 : 0)
        idx += 1
        sqlite3_bind_int(stmt, idx, hideLow ? 1 : 0)
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        return 0
    }

    /// Sum of messages across sessions that pass the message-count preferences across the period.
    func sumMessagesFiltered(sources: [String], dayStart: String?, dayEnd: String?, hideZero: Bool, hideLow: Bool) throws -> Int {
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
            HAVING (? = 0 OR msgs >= 1)
               AND (? = 0 OR msgs = 0 OR msgs >= 3)
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
        sqlite3_bind_int(stmt, idx, hideZero ? 1 : 0)
        idx += 1
        sqlite3_bind_int(stmt, idx, hideLow ? 1 : 0)
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        return 0
    }

    /// Sum of duration across sessions that pass the message-count preferences across the period.
    func sumDurationFiltered(sources: [String], dayStart: String?, dayEnd: String?, hideZero: Bool, hideLow: Bool) throws -> TimeInterval {
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
            HAVING (? = 0 OR msgs >= 1)
               AND (? = 0 OR msgs = 0 OR msgs >= 3)
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
        sqlite3_bind_int(stmt, idx, hideZero ? 1 : 0)
        idx += 1
        sqlite3_bind_int(stmt, idx, hideLow ? 1 : 0)
        if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_double(stmt, 0) }
        return 0.0
    }

    /// Sum of commands across sessions that pass the message-count preferences across the period.
    func sumCommandsFiltered(sources: [String], dayStart: String?, dayEnd: String?, hideZero: Bool, hideLow: Bool) throws -> Int {
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
            HAVING (? = 0 OR msgs >= 1)
               AND (? = 0 OR msgs = 0 OR msgs >= 3)
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
        sqlite3_bind_int(stmt, idx, hideZero ? 1 : 0)
        idx += 1
        sqlite3_bind_int(stmt, idx, hideLow ? 1 : 0)
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

    /// Average session duration while respecting message-count preferences.
    func avgSessionDurationFiltered(sources: [String], dayStart: String?, dayEnd: String?, hideZero: Bool, hideLow: Bool) throws -> TimeInterval {
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
            HAVING (? = 0 OR msgs >= 1)
               AND (? = 0 OR msgs = 0 OR msgs >= 3)
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
        sqlite3_bind_int(stmt, idx, hideZero ? 1 : 0)
        idx += 1
        sqlite3_bind_int(stmt, idx, hideLow ? 1 : 0)
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
        // Clear analytics backfill markers for this source (all versions).
        // Note: source values are controlled ASCII identifiers (e.g. "codex"); interpolation is safe here.
        try exec("DELETE FROM index_state WHERE key LIKE 'analytics_backfill_done:\(source):%'")
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
        INSERT INTO session_meta(session_id, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title, codex_internal_session_id, is_housekeeping, messages, commands, parent_session_id, subagent_type, custom_title)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          source=excluded.source, path=excluded.path, mtime=excluded.mtime, size=excluded.size,
          start_ts=excluded.start_ts, end_ts=excluded.end_ts, model=excluded.model, cwd=excluded.cwd,
          repo=excluded.repo, title=excluded.title, codex_internal_session_id=excluded.codex_internal_session_id,
          is_housekeeping=excluded.is_housekeeping, messages=excluded.messages, commands=excluded.commands,
          parent_session_id=excluded.parent_session_id, subagent_type=excluded.subagent_type, custom_title=excluded.custom_title;
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
        if let codexInternal = m.codexInternalSessionID { sqlite3_bind_text(stmt, 12, codexInternal, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 12) }
        sqlite3_bind_int64(stmt, 13, m.isHousekeeping ? 1 : 0)
        sqlite3_bind_int64(stmt, 14, Int64(m.messages))
        sqlite3_bind_int64(stmt, 15, Int64(m.commands))
        if let pid = m.parentSessionID { sqlite3_bind_text(stmt, 16, pid, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 16) }
        if let sat = m.subagentType { sqlite3_bind_text(stmt, 17, sat, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 17) }
        if let ct = m.customTitle { sqlite3_bind_text(stmt, 18, ct, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 18) }
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("upsert session_meta") }
    }

    /// Lightweight upsert for core indexers. Preserves `messages` and `commands` set by the
    /// analytics indexer (which produces higher-quality values). Uses COALESCE for
    /// `custom_title` and `codex_internal_session_id` so non-NULL parsed values update the DB
    /// while NULL values (from lightweight parses that missed the record) preserve existing data.
    func upsertSessionMetaCore(_ m: SessionMetaRow) throws {
        let sql = """
        INSERT INTO session_meta(session_id, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title, codex_internal_session_id, is_housekeeping, messages, commands, parent_session_id, subagent_type, custom_title)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          source=excluded.source, path=excluded.path, mtime=excluded.mtime, size=excluded.size,
          start_ts=excluded.start_ts, end_ts=excluded.end_ts, model=excluded.model, cwd=excluded.cwd,
          repo=excluded.repo, title=excluded.title,
          is_housekeeping=excluded.is_housekeeping,
          parent_session_id=excluded.parent_session_id, subagent_type=excluded.subagent_type,
          custom_title=COALESCE(excluded.custom_title, session_meta.custom_title),
          codex_internal_session_id=CASE WHEN session_meta.codex_internal_session_id IS NULL THEN excluded.codex_internal_session_id ELSE session_meta.codex_internal_session_id END;
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
        if let codexInternal = m.codexInternalSessionID { sqlite3_bind_text(stmt, 12, codexInternal, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 12) }
        sqlite3_bind_int64(stmt, 13, m.isHousekeeping ? 1 : 0)
        sqlite3_bind_int64(stmt, 14, Int64(m.messages))
        sqlite3_bind_int64(stmt, 15, Int64(m.commands))
        if let pid = m.parentSessionID { sqlite3_bind_text(stmt, 16, pid, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 16) }
        if let sat = m.subagentType { sqlite3_bind_text(stmt, 17, sat, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 17) }
        if let ct = m.customTitle { sqlite3_bind_text(stmt, 18, ct, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 18) }
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("upsert session_meta core") }
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

    func updateSessionMetaCodexInternalSessionID(sessionID: String, source: String, codexInternalSessionID: String?) throws {
        let sql = "UPDATE session_meta SET codex_internal_session_id=? WHERE session_id=? AND source=?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let codexInternalSessionID, !codexInternalSessionID.isEmpty {
            sqlite3_bind_text(stmt, 1, codexInternalSessionID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, source, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("update session_meta codex_internal_session_id") }
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
        let sql = "INSERT OR REPLACE INTO session_days(day, source, session_id, model, messages, commands, duration_sec, meta_mtime) VALUES(?,?,?,?,?,?,?,?);"
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
            sqlite3_bind_int64(stmt, 8, r.metaMtime)
            if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("insert session_days") }
            sqlite3_reset(stmt)
        }
    }

    // MARK: - Analytics derivation from session_meta

    /// Purge session_meta rows for a source whose path no longer exists in the files table.
    /// This reconciles ghost sessions left by deleted/moved files before analytics derivation.
    /// Returns the number of rows purged.
    @discardableResult
    func purgeOrphanedSessionMeta(for source: String) throws -> Int {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = """
        DELETE FROM session_meta WHERE source=? AND path NOT IN (
            SELECT path FROM files WHERE source=?
        );
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("purge orphaned session_meta") }
        return Int(sqlite3_changes(db))
    }

    /// Derive session_days rows from session_meta for a source (no file I/O).
    /// Returns the number of sessions processed.
    @discardableResult
    func populateSessionDaysFromMeta(for source: String) throws -> Int {
        let metas = try fetchSessionMeta(for: source)
        guard !metas.isEmpty else { return 0 }
        let rows = Self.deriveSessionDayRows(from: metas)
        try insertSessionDayRows(rows)
        return metas.count
    }

    /// Incremental variant: derive session_days for specific session IDs.
    /// Returns the affected day strings (for rollup recomputation).
    @discardableResult
    func populateSessionDaysFromMetaIncremental(sessionIDs: [String], source: String) throws -> Set<String> {
        guard !sessionIDs.isEmpty else { return [] }
        guard let db = handle else { throw DBError.openFailed("db closed") }

        // Delete old session_days for these sessions
        let chunkSize = 200
        for chunk in stride(from: 0, to: sessionIDs.count, by: chunkSize).map({ Array(sessionIDs[$0..<min($0+chunkSize, sessionIDs.count)]) }) {
            let qs = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "DELETE FROM session_days WHERE source=? AND session_id IN (\(qs));"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
            for (i, sid) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(2 + i), sid, -1, SQLITE_TRANSIENT)
            }
            if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("delete session_days incremental") }
        }

        // Fetch meta rows for the specific session IDs and derive new day rows
        var metas: [SessionMetaRow] = []
        for chunk in stride(from: 0, to: sessionIDs.count, by: chunkSize).map({ Array(sessionIDs[$0..<min($0+chunkSize, sessionIDs.count)]) }) {
            let qs = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
            SELECT session_id, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title,
                   codex_internal_session_id, is_housekeeping, messages, commands,
                   parent_session_id, subagent_type, custom_title
            FROM session_meta WHERE source=? AND session_id IN (\(qs));
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
            for (i, sid) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(2 + i), sid, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                metas.append(SessionMetaRow(
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
                    codexInternalSessionID: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 11)),
                    isHousekeeping: sqlite3_column_int64(stmt, 12) != 0,
                    messages: Int(sqlite3_column_int64(stmt, 13)),
                    commands: Int(sqlite3_column_int64(stmt, 14)),
                    parentSessionID: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 15)),
                    subagentType: sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 16)),
                    customTitle: sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 17))
                ))
            }
        }

        let rows = Self.deriveSessionDayRows(from: metas)
        try insertSessionDayRows(rows)
        return Set(rows.map(\.day))
    }

    /// Derive SessionDayRow entries from session_meta timestamps (no file parsing).
    /// Single-day sessions produce one row; multi-day sessions use largest-remainder
    /// distribution to ensure per-day integer counts sum exactly to session totals.
    static func deriveSessionDayRows(from metas: [SessionMetaRow]) -> [SessionDayRow] {
        let cal = Calendar.current
        let f = dayFormatter
        var allRows: [SessionDayRow] = []
        allRows.reserveCapacity(metas.count)

        for m in metas {
            let start = Date(timeIntervalSince1970: TimeInterval(m.startTS))
            let end = Date(timeIntervalSince1970: TimeInterval(m.endTS))
            let startDay = cal.startOfDay(for: start)
            let endDay = cal.startOfDay(for: end)

            if startDay == endDay {
                // Single-day session (vast majority)
                let day = f.string(from: startDay)
                let dur = max(0, end.timeIntervalSince(start))
                allRows.append(SessionDayRow(day: day, source: m.source, sessionID: m.sessionID,
                                             model: m.model, messages: m.messages,
                                             commands: m.commands, durationSec: dur,
                                             metaMtime: m.mtime))
            } else {
                // Multi-day session: collect day spans, then distribute counts
                let totalDur = max(1, end.timeIntervalSince(start))
                var spans: [(day: String, dur: Double, frac: Double)] = []
                var cursor = startDay
                while cursor <= endDay {
                    let next = cal.date(byAdding: .day, value: 1, to: cursor) ?? end
                    let a = max(start, cursor)
                    let b = min(end, next)
                    if b > a {
                        let day = f.string(from: cursor)
                        let dur = b.timeIntervalSince(a)
                        spans.append((day: day, dur: dur, frac: dur / totalDur))
                    }
                    cursor = next
                }

                let msgDist = largestRemainderDistribute(total: m.messages, fractions: spans.map(\.frac))
                let cmdDist = largestRemainderDistribute(total: m.commands, fractions: spans.map(\.frac))

                for (i, span) in spans.enumerated() {
                    allRows.append(SessionDayRow(day: span.day, source: m.source, sessionID: m.sessionID,
                                                 model: m.model, messages: msgDist[i],
                                                 commands: cmdDist[i], durationSec: span.dur,
                                                 metaMtime: m.mtime))
                }
            }
        }
        return allRows
    }

    /// Distribute an integer total across buckets proportionally, preserving the exact sum.
    /// Uses the largest-remainder method: assign floors first, then give +1 to buckets
    /// with the largest fractional remainders until the total is met.
    private static func largestRemainderDistribute(total: Int, fractions: [Double]) -> [Int] {
        guard !fractions.isEmpty else { return [] }
        if fractions.count == 1 { return [total] }

        let exact = fractions.map { Double(total) * $0 }
        var floors = exact.map { Int($0) }
        var remainders = exact.enumerated().map { (idx: $0.offset, rem: $0.element - Double(floors[$0.offset])) }
        let deficit = total - floors.reduce(0, +)

        // Sort by descending remainder, distribute the deficit
        remainders.sort { $0.rem > $1.rem }
        for i in 0..<min(deficit, remainders.count) {
            floors[remainders[i].idx] += 1
        }
        return floors
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// Batch-recompute all rollups for a source from session_days.
    func recomputeAllRollups(for source: String) throws {
        try exec("DELETE FROM rollups_daily WHERE source='\(source)';")
        let sql = """
        INSERT INTO rollups_daily(day, source, model, sessions, messages, commands, duration_sec)
        SELECT day, source, model, COUNT(DISTINCT session_id), SUM(messages), SUM(commands), SUM(duration_sec)
        FROM session_days
        WHERE source=?
        GROUP BY day, source, model;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("batch insert rollups_daily") }
    }

    /// Recompute rollups for specific days only (incremental).
    func recomputeRollupsForDays(_ days: Set<String>, source: String) throws {
        for day in days {
            try recomputeRollups(day: day, source: source)
        }
    }

    /// Find session IDs that need session_days (re-)derivation:
    /// - sessions in session_meta with no session_days rows (new)
    /// - sessions whose session_meta.mtime changed since session_days were derived
    ///   (detected via the meta_mtime column stored during derivation)
    func findSessionsNeedingDayUpdate(source: String) throws -> [String] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = """
        SELECT m.session_id FROM session_meta m
        LEFT JOIN (
            SELECT DISTINCT session_id, meta_mtime
            FROM session_days WHERE source=?
        ) d ON m.session_id = d.session_id
        WHERE m.source=?
          AND (d.session_id IS NULL OR d.meta_mtime != m.mtime);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    /// Find session_days rows whose session no longer exists in session_meta.
    func findStaleDayRows(source: String) throws -> [String] {
        guard let db = handle else { throw DBError.openFailed("db closed") }
        let sql = """
        SELECT DISTINCT d.session_id FROM session_days d
        LEFT JOIN session_meta m ON d.session_id = m.session_id AND d.source = m.source
        WHERE d.source=? AND m.session_id IS NULL;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    /// Delete session_days rows for specific session IDs.
    /// Returns the affected days for rollup recomputation.
    func deleteSessionDaysForIDs(_ sessionIDs: [String], source: String) throws -> Set<String> {
        guard !sessionIDs.isEmpty else { return [] }
        var affectedDays = Set<String>()
        let chunkSize = 200
        for chunk in stride(from: 0, to: sessionIDs.count, by: chunkSize).map({ Array(sessionIDs[$0..<min($0+chunkSize, sessionIDs.count)]) }) {
            let qs = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            // First collect affected days
            let selSQL = "SELECT DISTINCT day FROM session_days WHERE source=? AND session_id IN (\(qs));"
            let selStmt = try prepare(selSQL)
            defer { sqlite3_finalize(selStmt) }
            sqlite3_bind_text(selStmt, 1, source, -1, SQLITE_TRANSIENT)
            for (i, sid) in chunk.enumerated() {
                sqlite3_bind_text(selStmt, Int32(2 + i), sid, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(selStmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(selStmt, 0) { affectedDays.insert(String(cString: c)) }
            }
            // Then delete
            let delSQL = "DELETE FROM session_days WHERE source=? AND session_id IN (\(qs));"
            let delStmt = try prepare(delSQL)
            defer { sqlite3_finalize(delStmt) }
            sqlite3_bind_text(delStmt, 1, source, -1, SQLITE_TRANSIENT)
            for (i, sid) in chunk.enumerated() {
                sqlite3_bind_text(delStmt, Int32(2 + i), sid, -1, SQLITE_TRANSIENT)
            }
            if sqlite3_step(delStmt) != SQLITE_DONE { throw DBError.execFailed("delete session_days for IDs") }
        }
        return affectedDays
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
    let codexInternalSessionID: String?
    let isHousekeeping: Bool
    let messages: Int
    let commands: Int
    let parentSessionID: String?
    let subagentType: String?
    let customTitle: String?
}

struct SessionDayRow {
    let day: String
    let source: String
    let sessionID: String
    let model: String?
    let messages: Int
    let commands: Int
    let durationSec: Double
    let metaMtime: Int64
}

struct IndexedFileRow {
    let path: String
    let mtime: Int64
    let size: Int64
    let indexedAt: Int64
}

// MARK: - SQLite helper
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

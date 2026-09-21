import Foundation
import SQLite3

// Token usage per session, kept beside the search index so the list can show and sort by
// it without re-reading gigabytes of transcripts. It lives in a table of its own inside
// the CLI's database file; the macOS app's index is never touched, and the app never sees
// this table.
//
// A row is fresh while the session file it was computed from is unchanged (same mtime and
// size as the index recorded) and, for priced rows, the bundled price table has not moved.

/// One stored row. `result == nil` means the file was read and holds no usage records.
struct StoredUsage {
    let mtime: Int64
    let size: Int64
    let result: UsageResult?
    let priceUpdated: String?
}

final class UsageStore {
    private var db: OpaquePointer?

    init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        let ddl = """
        CREATE TABLE IF NOT EXISTS as_core_usage (
          session_id TEXT NOT NULL, source TEXT NOT NULL,
          mtime INTEGER NOT NULL, size INTEGER NOT NULL,
          has_usage INTEGER NOT NULL,
          tokens_total INTEGER NOT NULL DEFAULT 0, tokens_input INTEGER NOT NULL DEFAULT 0,
          cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0, reasoning INTEGER NOT NULL DEFAULT 0,
          has_breakdown INTEGER NOT NULL DEFAULT 0,
          cost_usd REAL, unpriced TEXT NOT NULL DEFAULT '', price_updated TEXT,
          PRIMARY KEY (session_id, source)
        );
        """
        // Another process may be creating the same file at the same moment; retry briefly.
        var created = false
        for _ in 0..<40 {
            if sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK { created = true; break }
            usleep(150_000)
        }
        if !created { sqlite3_close(db); return nil }
    }

    deinit { sqlite3_close(db) }

    /// Every stored row, keyed `source/session_id`.
    func loadAll() -> [String: StoredUsage] {
        var stmt: OpaquePointer?
        let sql = """
        SELECT session_id, source, mtime, size, has_usage, tokens_total, tokens_input, cache_read,
               cache_write, output, reasoning, has_breakdown, cost_usd, unpriced, price_updated
        FROM as_core_usage
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        func text(_ i: Int32) -> String? {
            sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
        var out: [String: StoredUsage] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(0) ?? "", source = text(1) ?? ""
            var result: UsageResult?
            if sqlite3_column_int(stmt, 4) != 0 {
                var r = UsageResult()
                r.total = Int(sqlite3_column_int64(stmt, 5))
                r.input = Int(sqlite3_column_int64(stmt, 6))
                r.cacheRead = Int(sqlite3_column_int64(stmt, 7))
                r.cacheWrite = Int(sqlite3_column_int64(stmt, 8))
                r.output = Int(sqlite3_column_int64(stmt, 9))
                r.reasoning = Int(sqlite3_column_int64(stmt, 10))
                r.hasBreakdown = sqlite3_column_int(stmt, 11) != 0
                if sqlite3_column_type(stmt, 12) != SQLITE_NULL { r.costUSD = sqlite3_column_double(stmt, 12) }
                r.unpricedModels = (text(13) ?? "").split(separator: ",").map(String.init)
                r.priceTableUpdated = text(14)
                result = r
            }
            out["\(source)/\(id)"] = StoredUsage(mtime: sqlite3_column_int64(stmt, 2),
                                                 size: sqlite3_column_int64(stmt, 3),
                                                 result: result, priceUpdated: text(14))
        }
        return out
    }

    func upsert(source: String, sessionID: String, mtime: Int64, size: Int64, result: UsageResult?) {
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO as_core_usage
          (session_id, source, mtime, size, has_usage, tokens_total, tokens_input, cache_read,
           cache_write, output, reasoning, has_breakdown, cost_usd, unpriced, price_updated)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionID, -1, transient)
        sqlite3_bind_text(stmt, 2, source, -1, transient)
        sqlite3_bind_int64(stmt, 3, mtime)
        sqlite3_bind_int64(stmt, 4, size)
        sqlite3_bind_int(stmt, 5, result == nil ? 0 : 1)
        let r = result ?? UsageResult()
        sqlite3_bind_int64(stmt, 6, Int64(r.total))
        sqlite3_bind_int64(stmt, 7, Int64(r.input))
        sqlite3_bind_int64(stmt, 8, Int64(r.cacheRead))
        sqlite3_bind_int64(stmt, 9, Int64(r.cacheWrite))
        sqlite3_bind_int64(stmt, 10, Int64(r.output))
        sqlite3_bind_int64(stmt, 11, Int64(r.reasoning))
        sqlite3_bind_int(stmt, 12, r.hasBreakdown ? 1 : 0)
        if let cost = r.costUSD { sqlite3_bind_double(stmt, 13, cost) } else { sqlite3_bind_null(stmt, 13) }
        sqlite3_bind_text(stmt, 14, r.unpricedModels.joined(separator: ","), -1, transient)
        if let updated = r.priceTableUpdated { sqlite3_bind_text(stmt, 15, updated, -1, transient) } else { sqlite3_bind_null(stmt, 15) }
        _ = sqlite3_step(stmt)
    }
}

/// Computes usage for the source's top-level sessions that have none stored, or whose file
/// changed since, and stores it. Returns how many were computed and how many were current.
func refreshUsage(db: IndexDB, store: UsageStore, source: SessionSource) async -> (computed: Int, current: Int) {
    guard supportsUsage(source) else { return (0, 0) }
    let table = RunwayPriceTable(loadBundled: true, readCache: false)
    let stored = store.loadAll()
    let rows = ((try? await db.fetchSessionMeta(for: source.rawValue)) ?? [])
        .filter { !$0.isHousekeeping && !isSubagent($0) }
    var computed = 0, current = 0
    for row in rows {
        if let have = stored["\(source.rawValue)/\(row.sessionID)"],
           have.mtime == row.mtime, have.size == row.size,
           have.result == nil || have.priceUpdated == table.updatedDate {
            current += 1
            continue
        }
        switch computeUsage(source: source, url: URL(fileURLWithPath: row.path), table: table) {
        case .ready(let result):
            store.upsert(source: source.rawValue, sessionID: row.sessionID, mtime: row.mtime, size: row.size, result: result)
            computed += 1
        case .none:
            store.upsert(source: source.rawValue, sessionID: row.sessionID, mtime: row.mtime, size: row.size, result: nil)
            computed += 1
        case .unreadable, .unsupported:
            continue
        }
    }
    return (computed, current)
}

/// How a session's usage looks to a reader of `list` or `search`.
enum UsageState: String {
    case ready        // tokens known
    case none         // file read, no usage recorded
    case pending      // supported source, not computed yet (the index pass is still running)
    case unsupported  // this agent does not record usage
}

func usageState(source: String, stored: StoredUsage?) -> UsageState {
    guard let src = SessionSource(rawValue: source), supportsUsage(src) else { return .unsupported }
    guard let stored else { return .pending }
    return stored.result == nil ? .none : .ready
}

/// The `usage` object of a `list`/`search` row.
func usageJSON(_ r: UsageResult) -> [String: Any] {
    [
        "total": r.total, "input": r.input, "cacheRead": r.cacheRead, "cacheWrite": r.cacheWrite,
        "output": r.output, "reasoning": r.reasoning, "hasBreakdown": r.hasBreakdown,
        "costUSD": orNull(r.costUSD), "unpricedModels": r.unpricedModels,
    ]
}

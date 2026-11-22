import Foundation
import SQLite3
import CryptoKit

/// One read transaction, bounded row payloads, no collected row array.
final class SearchSQLiteReader {
    private let sourceURL: URL
    private let resolvedPath: String
    private let physicalIdentity: String?
    let db: OpaquePointer
    private var digest = SHA256()
    private var retainedCharges: [Int] = []
    var summary = SearchScanSummary()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(session: Session) throws {
        sourceURL = URL(fileURLWithPath: session.filePath).standardizedFileURL
        resolvedPath = sourceURL.resolvingSymlinksInPath().path
        physicalIdentity = SessionFileStat.precise(from: sourceURL)?.fingerprint
        var handle: OpaquePointer?
        guard sqlite3_open_v2(session.filePath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else { sqlite3_close(handle); throw SearchSourceScanner.Failure.unsupported }
        db = handle
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(SearchSourceScanner.recordBytes))
        sqlite3_busy_timeout(db, 1000)
        sqlite3_progress_handler(db, 4096, { _ in Task.isCancelled ? 1 : 0 }, nil)
        guard sqlite3_exec(db, "PRAGMA cache_size=-1024; PRAGMA temp_store=FILE; BEGIN;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); throw SearchSourceScanner.Failure.unsupported
        }
        digest.update(data: Data((session.source.rawValue + ":" + session.id + ":" + session.filePath).utf8))
    }
    deinit { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil); sqlite3_close(db) }

    func rows(_ sql: String, strings: [String] = [], integers: [Int32: Int64] = [:],
              consume: (OpaquePointer) throws -> Void) throws {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SearchSourceScanner.Failure.unsupported
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in strings.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient) }
        for (index, value) in integers { sqlite3_bind_int64(statement, index, value) }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            try Task.checkCancellation()
            var rowBytes = 0
            for column in 0..<sqlite3_column_count(statement) {
                rowBytes += Int(sqlite3_column_bytes(statement, column))
                guard rowBytes <= SearchSourceScanner.recordBytes,
                      rowBytes * 24 + SearchSourceScanner.chunkBytes * 2 <= SearchSourceScanner.payloadBytes else {
                    throw SearchSourceScanner.Failure.resourceLimit
                }
                if let bytes = sqlite3_column_blob(statement, column) {
                    let count = Int(sqlite3_column_bytes(statement, column))
                    let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: count, deallocator: .none)
                    // Length-prefix fields so concatenation cannot alias another logical record.
                    digest.update(data: Data("\(column):\(count):".utf8)); digest.update(data: data)
                }
            }
            summary.bytesRead += UInt64(rowBytes)
            summary.decompressedBytes += UInt64(rowBytes)
            summary.records += 1
            summary.peakPayloadCharge = max(summary.peakPayloadCharge, rowBytes * 24 + SearchSourceScanner.chunkBytes * 2)
            let charge = rowBytes * 24 + SearchSourceScanner.chunkBytes * 2
            guard retainedCharges.reduce(0, +) + charge <= SearchSourceScanner.payloadBytes else { throw SearchSourceScanner.Failure.resourceLimit }
            retainedCharges.append(charge)
            do {
                defer { retainedCharges.removeLast() }
                try autoreleasepool { try consume(statement) }
            }
            step = sqlite3_step(statement)
        }
        try Task.checkCancellation()
        guard step == SQLITE_DONE else {
            if step == SQLITE_TOOBIG { throw SearchSourceScanner.Failure.resourceLimit }
            throw SearchSourceScanner.Failure.unsupported
        }
    }

    func hasRow(_ sql: String, strings: [String] = []) throws -> Bool {
        var found = false
        try rows(sql, strings: strings) { _ in found = true }
        return found
    }
    func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    func json(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        let charge = try SearchSourceScanner.validateJSON(data)
        let totalCharge = retainedCharges.reduce(0, +) + max(0, charge - data.count * 24)
        guard totalCharge <= SearchSourceScanner.payloadBytes else { throw SearchSourceScanner.Failure.resourceLimit }
        summary.peakPayloadCharge = max(summary.peakPayloadCharge, totalCharge)
        if !retainedCharges.isEmpty { retainedCharges[retainedCharges.count - 1] += max(0, charge - data.count * 24) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw SearchSourceScanner.Failure.malformed }
        return object
    }
    /// Foundation's JSON parser accepts some JSON5 extensions, including trailing commas.
    /// Provider database payloads use strict JSON; SQLite's one-argument `json_valid`
    /// checks canonical RFC-8259 syntax without mutating the scan summary or digest.
    func isStrictJSON(_ text: String) throws -> Bool {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT json_valid(?1);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SearchSourceScanner.Failure.unsupported
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, text, -1, Self.transient)
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_TOOBIG { throw SearchSourceScanner.Failure.resourceLimit }
            throw SearchSourceScanner.Failure.unsupported
        }
        return sqlite3_column_int(statement, 0) == 1
    }
    func finish() -> SearchScanSummary {
        if sourceURL.resolvingSymlinksInPath().path != resolvedPath
            || SessionFileStat.precise(from: sourceURL)?.fingerprint != physicalIdentity {
            summary.reasons.insert(.sourceChanged)
        }
        summary.revision = .init(logical: digest.finalize().map { String(format: "%02x", $0) }.joined())
        return summary
    }
}

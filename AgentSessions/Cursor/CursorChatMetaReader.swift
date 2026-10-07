import Foundation
import CryptoKit
import SQLite3

/// Metadata extracted from a Cursor chat SQLite database's meta table.
struct CursorSessionMeta {
    let agentId: String          // session UUID
    let name: String             // human-readable session name
    let createdAt: Date          // from epoch milliseconds
    let lastUsedModel: String    // "default" or model ID like "claude-4-sonnet"
    let mode: String             // "default"
    let workspaceHash: String    // MD5 of project path (parent directory name)
    let dbPath: String           // absolute path to the store.db file
    /// Bytes in the hex-encoded metadata value read from SQLite. This is the
    /// payload evidence used by the telemetry scan metric; it is not the size
    /// of the whole database file.
    let metadataBytes: UInt64
    /// Digest of the decoded JSON payload read from the same SQLite snapshot.
    /// Telemetry uses this to bind a scan to the metadata it actually consumed,
    /// rather than relying only on a pathname stat.
    let metadataFingerprint: String
}

/// Read-only metadata extraction from Cursor per-session chat SQLite databases.
///
/// Each session has its own store.db at `~/.cursor/chats/<workspaceHash>/<sessionUUID>/store.db`.
/// The meta table contains hex-encoded JSON with session name, timestamps, and model info.
/// The blobs table contains protobuf-encoded messages (deferred — not parsed here).
///
/// Opens databases per call using SQLITE_OPEN_READONLY to avoid WAL lock contention.
struct CursorChatMetaReader {

    /// Cursor's metadata value is a small session header. Keep malformed or
    /// unexpectedly large values from turning a cancellation into an unbounded
    /// String/Character/Data allocation.
    private static let maximumMetadataHexBytes = 1_048_576
    /// Leave a small amount of room for SQLite's string representation while
    /// enforcing the metadata bound before a TEXT value is materialized.
    private static let sqliteTextLengthLimit = maximumMetadataHexBytes + 4_096

    // MARK: - Public

    /// Returns metadata for all Cursor sessions found in the chats directory.
    static func listSessionMeta(customRoot: String?) -> [CursorSessionMeta] {
        let chatsRoot = CursorBackendDetector.chatsRoot(customRoot: customRoot)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: chatsRoot.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        var results: [CursorSessionMeta] = []

        // Structure: chats/<workspaceHash>/<sessionUUID>/store.db
        guard let workspaceEnum = fm.enumerator(at: chatsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }

        for case let workspaceURL as URL in workspaceEnum {
            var isDirCheck: ObjCBool = false
            guard fm.fileExists(atPath: workspaceURL.path, isDirectory: &isDirCheck), isDirCheck.boolValue else { continue }
            let workspaceHash = workspaceURL.lastPathComponent

            guard let sessionEnum = fm.enumerator(at: workspaceURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }

            for case let sessionURL as URL in sessionEnum {
                var isSessionDir: ObjCBool = false
                guard fm.fileExists(atPath: sessionURL.path, isDirectory: &isSessionDir), isSessionDir.boolValue else { continue }
                let dbFile = sessionURL.appendingPathComponent("store.db")
                guard fm.fileExists(atPath: dbFile.path) else { continue }

                if let meta = readMeta(dbPath: dbFile.path, workspaceHash: workspaceHash) {
                    results.append(meta)
                }
            }
        }
        return results
    }

    /// Returns metadata for a single session database.
    static func sessionMeta(dbPath: String,
                            expectedAgentID: String? = nil) -> CursorSessionMeta? {
        // Extract workspace hash from path: .../chats/<hash>/<uuid>/store.db
        let url = URL(fileURLWithPath: dbPath)
        let sessionDir = url.deletingLastPathComponent()
        let workspaceDir = sessionDir.deletingLastPathComponent()
        let workspaceHash = workspaceDir.lastPathComponent
        guard let metadata = readMeta(dbPath: dbPath, workspaceHash: workspaceHash) else {
            return nil
        }
        if let expectedAgentID {
            let expected = expectedAgentID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expected.isEmpty, metadata.agentId == expected else { return nil }
        }
        return metadata
    }

    /// Resolve a workspace hash to a project path by checking known project directories.
    /// The workspace hash is MD5(absoluteProjectPath).
    static func resolveWorkspacePath(hash: String, knownProjectDirs: [String]) -> String? {
        for path in knownProjectDirs {
            let computed = md5String(path)
            if computed == hash {
                return path
            }
        }
        return nil
    }

    // MARK: - Internal

    private static func readMeta(dbPath: String, workspaceHash: String) -> CursorSessionMeta? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Apply the same bound at the SQLite connection level. The later
        // sqlite3_column_bytes check is still required, but by itself it can
        // run after SQLite has already materialized an oversized TEXT value.
        guard sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(sqliteTextLengthLimit)) > 0 else {
            return nil
        }

        // Meta table has key TEXT PRIMARY KEY, value TEXT.
        // The main metadata is stored at key "0" as hex-encoded JSON.
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = '0' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        guard let rawPtr = sqlite3_column_text(stmt, 0) else { return nil }
        let rawByteCount = Int(sqlite3_column_bytes(stmt, 0))
        guard rawByteCount > 0,
              rawByteCount <= maximumMetadataHexBytes,
              !Task.isCancelled else { return nil }
        let hexBytes = UnsafeBufferPointer(start: rawPtr, count: rawByteCount)
        let hexString = String(decoding: hexBytes, as: UTF8.self)

        // Decode hex → JSON bytes → parse
        guard let jsonData = dataFromHex(hexString) else { return nil }
        guard !Task.isCancelled else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
        guard !Task.isCancelled else { return nil }

        guard let agentId = obj["agentId"] as? String else { return nil }
        let name = obj["name"] as? String ?? ""
        let mode = obj["mode"] as? String ?? "default"
        let lastUsedModel = obj["lastUsedModel"] as? String ?? "default"

        var createdAt = Date.distantPast
        if let ts = obj["createdAt"] as? Int64, ts > 0 {
            createdAt = Date(timeIntervalSince1970: Double(ts) / 1000.0)
        } else if let ts = obj["createdAt"] as? Double, ts > 0 {
            createdAt = Date(timeIntervalSince1970: ts / 1000.0)
        }

        return CursorSessionMeta(
            agentId: agentId,
            name: name,
            createdAt: createdAt,
            lastUsedModel: lastUsedModel,
            mode: mode,
            workspaceHash: workspaceHash,
            dbPath: dbPath,
            metadataBytes: UInt64(rawByteCount),
            metadataFingerprint: SHA256.hash(data: jsonData).map { String(format: "%02x", $0) }.joined()
        )
    }

    // MARK: - Hex Decoding

    private static func dataFromHex(_ hex: String) -> Data? {
        let bytes = hex.utf8
        guard bytes.count % 2 == 0 else { return nil }
        var data = Data(capacity: bytes.count / 2)
        var iterator = bytes.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(),
                  let highNibble = hexNibble(high),
                  let lowNibble = hexNibble(low),
                  !Task.isCancelled else { return nil }
            data.append((highNibble << 4) | lowNibble)
        }
        return data
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    // MARK: - MD5 Hashing

    /// Compute MD5 hash of a string, returning lowercase hex. Used to match workspace hashes.
    static func md5String(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

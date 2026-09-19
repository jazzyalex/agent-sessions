import Foundation
import CryptoKit
import SQLite3

/// Metadata extracted from a Cursor chat SQLite database's meta table.
struct CursorSubagentInfo: Equatable {
    let parentAgentID: String
    let rootParentAgentID: String
    let toolCallID: String
    let typeName: String
}

struct CursorSessionMeta {
    let agentId: String          // session UUID
    let name: String             // human-readable session name
    let createdAt: Date          // from epoch milliseconds
    let lastUsedModel: String    // "default" or model ID like "claude-4-sonnet"
    let mode: String             // "default"
    let workspaceHash: String    // MD5 of project path (parent directory name)
    let dbPath: String           // absolute path to the store.db file
    /// Cursor's explicit parent lineage for ACP-created child sessions.
    /// Nil means the store is a regular root session or its metadata is not
    /// complete enough to establish a relationship safely.
    let subagentInfo: CursorSubagentInfo?

    init(agentId: String,
         name: String,
         createdAt: Date,
         lastUsedModel: String,
         mode: String,
         workspaceHash: String,
         dbPath: String,
         subagentInfo: CursorSubagentInfo? = nil) {
        self.agentId = agentId
        self.name = name
        self.createdAt = createdAt
        self.lastUsedModel = lastUsedModel
        self.mode = mode
        self.workspaceHash = workspaceHash
        self.dbPath = dbPath
        self.subagentInfo = subagentInfo
    }
}

/// Read-only metadata extraction from Cursor per-session chat SQLite databases.
///
/// Each session has its own store.db at `~/.cursor/chats/<workspaceHash>/<sessionUUID>/store.db`.
/// The meta table contains hex-encoded JSON with session name, timestamps, and model info.
/// The blobs table contains protobuf-encoded messages (deferred — not parsed here).
///
/// Opens databases per call using SQLITE_OPEN_READONLY to avoid WAL lock contention.
struct CursorChatMetaReader {

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
    static func sessionMeta(dbPath: String) -> CursorSessionMeta? {
        // Extract workspace hash from path: .../chats/<hash>/<uuid>/store.db
        let url = URL(fileURLWithPath: dbPath)
        let sessionDir = url.deletingLastPathComponent()
        let workspaceDir = sessionDir.deletingLastPathComponent()
        let workspaceHash = workspaceDir.lastPathComponent
        return readMeta(dbPath: dbPath, workspaceHash: workspaceHash)
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
        if let db = openReadOnlyDatabase(at: dbPath) {
            if let meta = makeMeta(from: db, dbPath: dbPath, workspaceHash: workspaceHash) {
                sqlite3_close(db)
                return meta
            }
            // A WAL-backed store can open successfully but reject the first
            // query against the main file. Retry the same read through an
            // immutable URI before giving up.
            sqlite3_close(db)
        }

        guard let db = openImmutableDatabase(at: dbPath) else { return nil }
        defer { sqlite3_close(db) }
        return makeMeta(from: db, dbPath: dbPath, workspaceHash: workspaceHash)
    }

    private static func makeMeta(
        from db: OpaquePointer,
        dbPath: String,
        workspaceHash: String
    ) -> CursorSessionMeta? {
        // Meta table has key TEXT PRIMARY KEY, value TEXT.
        // The main metadata is stored at key "0" as hex-encoded JSON.
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = '0' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let rawPtr = sqlite3_column_text(stmt, 0) else { return nil }
        let hexString = String(cString: rawPtr)

        // Decode hex → JSON bytes → parse
        guard let jsonData = dataFromHex(hexString),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }

        guard let agentId = obj["agentId"] as? String else { return nil }
        let name = obj["name"] as? String ?? ""
        let mode = obj["mode"] as? String ?? "default"
        let lastUsedModel = obj["lastUsedModel"] as? String ?? "default"
        let subagentInfo = parseSubagentInfo(obj["subagentInfo"])

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
            subagentInfo: subagentInfo
        )
    }

    /// Cursor keeps some chat stores in WAL mode while another process may be
    /// holding the writer side open. Try the normal read-only connection first
    /// so fresh WAL state is visible; fall back to SQLite's immutable URI mode
    /// when the store cannot acquire a shared lock. Immutable mode is
    /// read-only and avoids mutating or waiting on Cursor's lock files.
    private static func openReadOnlyDatabase(at path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK {
            return db
        }
        sqlite3_close(db)

        return openImmutableDatabase(at: path)
    }

    private static func openImmutableDatabase(at path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    /// Decode only the explicit lineage fields Cursor writes for child stores.
    /// Incomplete or malformed records are deliberately ignored so a regular
    /// chat cannot be attached through a partial/stale metadata blob.
    private static func parseSubagentInfo(_ raw: Any?) -> CursorSubagentInfo? {
        guard let value = raw as? [String: Any],
              let parent = nonEmptyString(value["parentAgentId"]),
              let root = nonEmptyString(value["rootParentAgentId"]),
              let toolCall = nonEmptyString(value["toolCallId"]),
              let typeName = nonEmptyString(value["typeName"]),
              UUID(uuidString: parent) != nil,
              UUID(uuidString: root) != nil else {
            return nil
        }
        return CursorSubagentInfo(
            parentAgentID: parent.lowercased(),
            rootParentAgentID: root.lowercased(),
            toolCallID: toolCall,
            typeName: typeName
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Hex Decoding

    private static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            data.append(byte)
            i += 2
        }
        return data
    }

    // MARK: - MD5 Hashing

    /// Compute MD5 hash of a string, returning lowercase hex. Used to match workspace hashes.
    static func md5String(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

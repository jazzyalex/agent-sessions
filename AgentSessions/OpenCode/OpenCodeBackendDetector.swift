import Foundation
import SQLite3

/// Which storage backend is available for OpenCode sessions.
enum OpenCodeStorageBackend: String {
    /// Legacy per-file JSON under storage/session/ (OpenCode < v1.2)
    case json
    /// SQLite database at opencode.db (OpenCode v1.2+). Preferred when present.
    case sqlite
    /// Nothing found on disk.
    case none
}

/// Detects which OpenCode storage backend is present on the current machine.
struct OpenCodeBackendDetector {
    /// Resolves the top-level OpenCode data directory.
    /// Default: ~/.local/share/opencode
    /// If customRoot points at the storage root or session root, we walk up to the opencode dir.
    static func openCodeRoot(customRoot: String?) -> URL {
        if let custom = customRoot, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let fm = FileManager.default

            // Allow advanced users/tests to point directly at opencode.db.
            if url.lastPathComponent == "opencode.db" {
                return url.deletingLastPathComponent()
            }

            // If the user pointed at storage/ or storage/session/, walk up to opencode/
            let migrationFile = url.appendingPathComponent("migration")
            if fm.fileExists(atPath: migrationFile.path) {
                // url is storage/ — parent is opencode/
                return url.deletingLastPathComponent()
            }
            let parentMigration = url.deletingLastPathComponent().appendingPathComponent("migration")
            if fm.fileExists(atPath: parentMigration.path) {
                // url is storage/session/ — grandparent is opencode/
                return url.deletingLastPathComponent().deletingLastPathComponent()
            }
            // Fallback for legacy installs without a migration file.
            // Check if url contains both session/ and message/ subdirs → it's storage/
            let sessionSubdir = url.appendingPathComponent("session", isDirectory: true)
            let messageSubdir = url.appendingPathComponent("message", isDirectory: true)
            var isDirA: ObjCBool = false
            var isDirB: ObjCBool = false
            if fm.fileExists(atPath: sessionSubdir.path, isDirectory: &isDirA), isDirA.boolValue,
               fm.fileExists(atPath: messageSubdir.path, isDirectory: &isDirB), isDirB.boolValue {
                // url is storage/ — parent is opencode/
                return url.deletingLastPathComponent()
            }
            // Check if parent contains both session/ and message/ → url is storage/session/
            let parentURL = url.deletingLastPathComponent()
            let parentSession = parentURL.appendingPathComponent("session", isDirectory: true)
            let parentMessage = parentURL.appendingPathComponent("message", isDirectory: true)
            var isDirC: ObjCBool = false
            var isDirD: ObjCBool = false
            if fm.fileExists(atPath: parentSession.path, isDirectory: &isDirC), isDirC.boolValue,
               fm.fileExists(atPath: parentMessage.path, isDirectory: &isDirD), isDirD.boolValue {
                // url is storage/session/ — grandparent is opencode/
                return parentURL.deletingLastPathComponent()
            }
            // Assume the user pointed at opencode/ directly
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    /// Returns the URL for opencode.db within the given opencode root.
    static func dbURL(customRoot: String?) -> URL {
        if let custom = customRoot, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if url.lastPathComponent == "opencode.db" {
                return url
            }
        }
        return openCodeRoot(customRoot: customRoot)
            .appendingPathComponent("opencode.db", isDirectory: false)
    }

    /// Detect which backend is available.
    /// SQLite takes priority when present and valid.
    static func detect(customRoot: String?) -> OpenCodeStorageBackend {
        if AppRuntime.isHostedByTooling {
            return .none
        }
        if isSQLiteAvailable(customRoot: customRoot) {
            return .sqlite
        }
        if isJSONAvailable(customRoot: customRoot) {
            return .json
        }
        return .none
    }

    /// Returns true if opencode.db exists and contains a `session` table.
    static func isSQLiteAvailable(customRoot: String?) -> Bool {
        let url = dbURL(customRoot: customRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='session' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Returns true if the legacy JSON storage/session directory exists.
    private static func isJSONAvailable(customRoot: String?) -> Bool {
        let root = openCodeRoot(customRoot: customRoot)
        let sessionDir = root
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sessionDir.path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        // Also match when the user's override points directly at a session directory
        // (e.g. a project subfolder under storage/session/) that already contains ses_*.json files.
        guard customRoot != nil else { return false }
        var isRootDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isRootDir), isRootDir.boolValue else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.lastPathComponent.hasPrefix("ses_") && $0.pathExtension == "json" }
    }
}

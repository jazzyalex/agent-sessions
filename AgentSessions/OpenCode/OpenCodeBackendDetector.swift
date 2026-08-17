import Foundation

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
    static func openCodeRoot(customRoot: String?,
                             fileProbe: any FileProbing = DefaultFileProbe(),
                             homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let custom = customRoot, !custom.isEmpty {
            let expanded = expand(custom, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded)

            // Allow advanced users/tests to point directly at opencode.db.
            if url.lastPathComponent == "opencode.db" {
                return url.deletingLastPathComponent()
            }

            // If the user pointed at storage/ or storage/session/, walk up to opencode/
            let migrationFile = url.appendingPathComponent("migration")
            if fileProbe.fileExists(atPath: migrationFile.path) {
                // url is storage/ — parent is opencode/
                return url.deletingLastPathComponent()
            }
            let parentMigration = url.deletingLastPathComponent().appendingPathComponent("migration")
            if fileProbe.fileExists(atPath: parentMigration.path) {
                // url is storage/session/ — grandparent is opencode/
                return url.deletingLastPathComponent().deletingLastPathComponent()
            }
            // Fallback for legacy installs without a migration file.
            // Check if url contains both session/ and message/ subdirs → it's storage/
            let sessionSubdir = url.appendingPathComponent("session", isDirectory: true)
            let messageSubdir = url.appendingPathComponent("message", isDirectory: true)
            if fileProbe.directoryExists(atPath: sessionSubdir.path),
               fileProbe.directoryExists(atPath: messageSubdir.path) {
                // url is storage/ — parent is opencode/
                return url.deletingLastPathComponent()
            }
            // Check if parent contains both session/ and message/ → url is storage/session/
            let parentURL = url.deletingLastPathComponent()
            let parentSession = parentURL.appendingPathComponent("session", isDirectory: true)
            let parentMessage = parentURL.appendingPathComponent("message", isDirectory: true)
            if fileProbe.directoryExists(atPath: parentSession.path),
               fileProbe.directoryExists(atPath: parentMessage.path) {
                // url is storage/session/ — grandparent is opencode/
                return parentURL.deletingLastPathComponent()
            }
            // Assume the user pointed at opencode/ directly
            return url
        }
        return homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    /// Returns the URL for opencode.db within the given opencode root.
    static func dbURL(customRoot: String?,
                      fileProbe: any FileProbing = DefaultFileProbe(),
                      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let custom = customRoot, !custom.isEmpty {
            let expanded = expand(custom, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded)
            if url.lastPathComponent == "opencode.db" {
                return url
            }
        }
        return openCodeRoot(customRoot: customRoot,
                            fileProbe: fileProbe,
                            homeDirectory: homeDirectory)
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
    static func isSQLiteAvailable(customRoot: String?,
                                  fileProbe: any FileProbing = DefaultFileProbe(),
                                  homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = dbURL(customRoot: customRoot,
                        fileProbe: fileProbe,
                        homeDirectory: homeDirectory)
        return fileProbe.sqliteDatabase(atPath: url.path, containsTable: "session")
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

    private static func expand(_ raw: String, relativeTo homeDirectory: URL) -> String {
        UserPathExpansion.expand(raw, relativeTo: homeDirectory)
    }
}

import Foundation
import SQLite3

private let fileProbeSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Injectable seam over the filesystem existence checks that path decoding and
/// command building perform. The counterpart to `PresenceRootsResolving`: same
/// class of defect (production code reading the developer's real filesystem
/// with no way for a test to intercept it), different callers.
///
/// Both users below choose *what string to return* based on whether a path
/// happens to exist on the machine running the code, which silently couples
/// their unit tests to one developer's home directory:
///
///   - `CursorSessionParser.inferCWDBestEffort` walks candidate prefixes to
///     decide where a `-` is a path separator and where it is a literal hyphen,
///     so it decodes `Users-alexm-Repository-Codex-History` correctly only
///     where `/Users/alexm/Repository` exists. Elsewhere it returns
///     `/Users/alexm/Repository-Codex-History`.
///   - `AntigravityResumeCommandBuilder.makeCommand` emits the full binary path
///     when that path is executable and the bare command name when it is not,
///     so a test asserting the full path passes only where the binary is
///     installed at exactly that path.
///
/// `DefaultFileProbe` forwards to `FileManager.default`, so production behavior
/// is unchanged; tests inject a fake holding a fixed set of paths.
protocol FileProbing: Sendable {
    /// True when `path` exists, regardless of file type.
    func fileExists(atPath path: String) -> Bool
    /// True when `path` exists *and* is a directory.
    func directoryExists(atPath path: String) -> Bool
    /// True when `path` exists and carries an executable bit for this process.
    func isExecutableFile(atPath path: String) -> Bool
    /// Immediate children of a directory. Empty when the directory cannot be read.
    func contentsOfDirectory(atPath path: String) -> [URL]
    /// Descendant directories named `name`, pruning excluded subtrees and each match.
    /// Empty when the directory cannot be read.
    func descendantDirectories(named name: String,
                               atPath path: String,
                               skippingSubtreesNamed skippedNames: Set<String>) -> [URL]
    /// True when a readable SQLite database contains the named table.
    func sqliteDatabase(atPath path: String, containsTable table: String) -> Bool
}

/// Expands user-relative preference paths while keeping injected-home tests hermetic.
/// `~` and `~/...` belong to the supplied home; named-user forms retain Foundation's
/// historical `~otheruser/...` behavior.
enum UserPathExpansion {
    static func expand(_ raw: String, relativeTo homeDirectory: URL) -> String {
        if raw == "~" { return homeDirectory.path }
        if raw.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).path
        }
        if raw.hasPrefix("~") {
            return (raw as NSString).expandingTildeInPath
        }
        return raw
    }
}

/// The real filesystem. Bodies moved verbatim from the call sites.
struct DefaultFileProbe: FileProbing {
    init() {}

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func directoryExists(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func contentsOfDirectory(atPath path: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
    }

    func descendantDirectories(named name: String,
                               atPath path: String,
                               skippingSubtreesNamed skippedNames: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if skippedNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == name else { continue }
            directories.append(url)
            enumerator.skipDescendants()
        }
        return directories
    }

    func sqliteDatabase(atPath path: String, containsTable table: String) -> Bool {
        guard fileExists(atPath: path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, fileProbeSQLiteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

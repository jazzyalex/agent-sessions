import Foundation
import SQLite3

/// Which storage surfaces are available for Cursor sessions.
enum CursorStorageBackend: String {
    /// Both JSONL agent-transcripts and chat DB meta are present.
    case transcriptsAndMeta
    /// Only JSONL agent-transcripts (no chat SQLite DBs).
    case transcriptsOnly
    /// Only chat DB metadata (no JSONL transcripts).
    case metaOnly
    /// Nothing found on disk.
    case none
}

/// Detects which Cursor storage surfaces are present on the current machine.
struct CursorBackendDetector {
    /// Top-level Cursor data directory. Default: ~/.cursor
    static func cursorRoot(customRoot: String?) -> URL {
        if let custom = customRoot, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return URL(fileURLWithPath: normalizedSystemAliasPath(expanded), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
    }

    /// Normalize only the aliases owned by macOS. Do not resolve user-created
    /// symlinks: configured-root authority checks must still see those.
    static func normalizedSystemAliasPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
        for (alias, canonical) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if standardized == alias { return canonical }
            if standardized.hasPrefix(alias + "/") {
                return canonical + String(standardized.dropFirst(alias.count))
            }
        }
        return standardized
    }

    /// Root for project-scoped data including agent-transcripts.
    /// Path: ~/.cursor/projects
    static func projectsRoot(customRoot: String?) -> URL {
        return cursorRoot(customRoot: customRoot)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Root for per-session chat SQLite databases.
    /// Path: ~/.cursor/chats
    static func chatsRoot(customRoot: String?) -> URL {
        return cursorRoot(customRoot: customRoot)
            .appendingPathComponent("chats", isDirectory: true)
    }

    /// Root for ACP-persisted Cursor sessions. Path: ~/.cursor/acp-sessions
    static func acpSessionsRoot(customRoot: String?) -> URL {
        cursorRoot(customRoot: customRoot)
            .appendingPathComponent("acp-sessions", isDirectory: true)
    }

    /// Detect which storage surfaces are available.
    static func detect(customRoot: String?) -> CursorStorageBackend {
        if AppRuntime.isHostedByTooling {
            return .none
        }
        let hasTranscripts = isTranscriptsAvailable(customRoot: customRoot)
        let hasMeta = isChatDBAvailable(customRoot: customRoot)
        if hasTranscripts && hasMeta { return .transcriptsAndMeta }
        if hasTranscripts { return .transcriptsOnly }
        if hasMeta { return .metaOnly }
        return .none
    }

    /// Returns true if any agent-transcript JSONL files exist under projects root.
    static func isTranscriptsAvailable(customRoot: String?) -> Bool {
        let root = projectsRoot(customRoot: customRoot)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }
        // Two-level scan: enumerate project dirs first, then check agent-transcripts within each.
        guard let projectEnum = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return false }
        for case let projectURL as URL in projectEnum {
            var isProjectDir: ObjCBool = false
            guard fm.fileExists(atPath: projectURL.path, isDirectory: &isProjectDir), isProjectDir.boolValue else { continue }
            let transcriptsDir = projectURL.appendingPathComponent("agent-transcripts", isDirectory: true)
            var isTransDir: ObjCBool = false
            guard fm.fileExists(atPath: transcriptsDir.path, isDirectory: &isTransDir), isTransDir.boolValue else { continue }
            guard let inner = fm.enumerator(at: transcriptsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in inner {
                if url.pathExtension.lowercased() == "jsonl" { return true }
            }
        }
        return false
    }

    /// Returns true if any store.db files exist under the chats root.
    static func isChatDBAvailable(customRoot: String?) -> Bool {
        let root = chatsRoot(customRoot: customRoot)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard let chatEnum = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in chatEnum {
            if url.lastPathComponent == "store.db" {
                return true
            }
        }
        return false
    }
}

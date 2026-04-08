import Foundation

/// Session discovery for Cursor agent transcripts and chat databases.
///
/// Cursor stores data in two locations:
/// - JSONL transcripts: `~/.cursor/projects/<project>/agent-transcripts/<uuid>/<uuid>.jsonl`
/// - Chat SQLite DBs: `~/.cursor/chats/<md5(projectPath)>/<sessionUUID>/store.db`
final class CursorSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    /// Returns the projects root where agent-transcripts live.
    func sessionsRoot() -> URL {
        return CursorBackendDetector.projectsRoot(customRoot: customRoot)
    }

    /// Returns the chats root where per-session SQLite databases live.
    func chatsRoot() -> URL {
        return CursorBackendDetector.chatsRoot(customRoot: customRoot)
    }

    /// Discovers JSONL transcript files across all projects.
    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl",
                      url.path.contains("/agent-transcripts/") else { continue }
                found.append(url)
            }
        }

        return found.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// Discovers all store.db paths under the chats directory.
    func discoverChatDBs() -> [URL] {
        let root = chatsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == "store.db" {
                    found.append(url)
                }
            }
        }
        return found
    }
}

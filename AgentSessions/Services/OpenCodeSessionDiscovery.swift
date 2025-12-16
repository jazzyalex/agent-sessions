import Foundation

/// Session discovery for OpenCode sessions backed by ~/.local/share/opencode/storage
final class OpenCodeSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    /// Root directory that contains per-project OpenCode session JSON files.
    /// Default: ~/.local/share/opencode/storage/session
    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            // Allow users to point at either:
            // - ~/.local/share/opencode/storage            (storage root)
            // - ~/.local/share/opencode/storage/session     (sessions root)
            // - ~/.local/share/opencode                    (contains storage/)
            let fm = FileManager.default

            // If this looks like a storage root, use its session/ subdirectory.
            let migration = url.appendingPathComponent("migration", isDirectory: false)
            let sessionDir = url.appendingPathComponent("session", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: migration.path),
               fm.fileExists(atPath: sessionDir.path, isDirectory: &isDir),
               isDir.boolValue {
                return sessionDir
            }

            // If user picked the opencode root, step into storage/session when present.
            let storageDir = url.appendingPathComponent("storage", isDirectory: true)
            let storageSessionDir = storageDir.appendingPathComponent("session", isDirectory: true)
            var isStorageSessionDir: ObjCBool = false
            if fm.fileExists(atPath: storageSessionDir.path, isDirectory: &isStorageSessionDir),
               isStorageSessionDir.boolValue {
                return storageSessionDir
            }

            // If user provided the sessions root directly, use it as-is.
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root,
                                          includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                          options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix("ses_"),
                      url.pathExtension.lowercased() == "json" else {
                    continue
                }
                found.append(url)
            }
        }

        // Sort by file modification time descending (newest first)
        return found.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }
}

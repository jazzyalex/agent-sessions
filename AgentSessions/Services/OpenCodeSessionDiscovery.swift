import Foundation

/// Session discovery for OpenCode sessions backed by ~/.local/share/opencode/storage
final class OpenCodeSessionDiscovery: SessionDiscovery {
    private let customRoot: String?
    private let fileProbe: any FileProbing
    private let homeDirectory: URL

    init(customRoot: String? = nil,
         fileProbe: any FileProbing = DefaultFileProbe(),
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.customRoot = customRoot
        self.fileProbe = fileProbe
        self.homeDirectory = homeDirectory
    }

    /// Root directory that contains per-project OpenCode session JSON files.
    /// Default: ~/.local/share/opencode/storage/session
    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            let expanded = UserPathExpansion.expand(custom, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            // Allow users to point at either:
            // - ~/.local/share/opencode/storage            (storage root)
            // - ~/.local/share/opencode/storage/session     (sessions root)
            // - ~/.local/share/opencode                    (contains storage/)
            // If this looks like a storage root, use its session/ subdirectory.
            let migration = url.appendingPathComponent("migration", isDirectory: false)
            let sessionDir = url.appendingPathComponent("session", isDirectory: true)
            if fileProbe.fileExists(atPath: migration.path),
               fileProbe.directoryExists(atPath: sessionDir.path) {
                return sessionDir
            }

            // If user picked the opencode root, step into storage/session when present.
            let storageDir = url.appendingPathComponent("storage", isDirectory: true)
            let storageSessionDir = storageDir.appendingPathComponent("session", isDirectory: true)
            if fileProbe.directoryExists(atPath: storageSessionDir.path) {
                return storageSessionDir
            }

            // If user provided the sessions root directly, use it as-is.
            return url
        }
        return homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
    }

    /// The top-level OpenCode data directory (~/.local/share/opencode or custom).
    func openCodeRoot() -> URL {
        OpenCodeBackendDetector.openCodeRoot(customRoot: customRoot,
                                             fileProbe: fileProbe,
                                             homeDirectory: homeDirectory)
    }

    /// Returns the opencode.db URL if the file exists on disk.
    func databaseURL() -> URL? {
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot,
                                                fileProbe: fileProbe,
                                                homeDirectory: homeDirectory)
        return fileProbe.fileExists(atPath: url.path) ? url : nil
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        guard fileProbe.directoryExists(atPath: root.path) else {
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

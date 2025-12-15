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
            return URL(fileURLWithPath: custom)
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

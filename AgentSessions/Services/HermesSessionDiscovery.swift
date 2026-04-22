import Foundation

/// Discovery for Hermes canonical session JSON files under ~/.hermes/sessions.
final class HermesSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let items = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }

        return items
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("session_") && url.pathExtension.lowercased() == "json"
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if a != b { return a > b }
                return $0.lastPathComponent > $1.lastPathComponent
            }
    }
}

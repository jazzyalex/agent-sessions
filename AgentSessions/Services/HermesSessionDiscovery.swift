import Foundation

/// Discovery for Hermes canonical session JSON files under ~/.hermes/sessions.
final class HermesSessionDiscovery: SessionDiscovery {
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

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = UserPathExpansion.expand(customRoot, relativeTo: homeDirectory)
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".hermes", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func stateDBURL() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = UserPathExpansion.expand(customRoot, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded)
            if url.pathExtension.lowercased() == "db" {
                return url
            }
            if url.lastPathComponent == "sessions" {
                return url.deletingLastPathComponent().appendingPathComponent("state.db")
            }
            return url.appendingPathComponent("state.db")
        }
        return homeDirectory
            .appendingPathComponent(".hermes", isDirectory: true)
            .appendingPathComponent("state.db")
    }

    func hasStateDB() -> Bool {
        fileProbe.fileExists(atPath: stateDBURL().path)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        guard fileProbe.directoryExists(atPath: root.path) else {
            return []
        }

        let items = fileProbe.contentsOfDirectory(atPath: root.path)

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

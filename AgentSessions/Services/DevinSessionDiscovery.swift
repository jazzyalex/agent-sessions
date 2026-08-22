import Foundation

/// Locates the Devin CLI session store.
///
/// Devin keeps every session in one SQLite database rather than a file per
/// session, so there is nothing to enumerate: `discoverSessionFiles()` returns
/// the database itself when it exists. `DevinSessionIndexer` reads the session
/// list straight out of it, the same shape OpenCode uses for its SQLite
/// backend.
final class DevinSessionDiscovery: SessionDiscovery {
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

    /// The directory holding `sessions.db`.
    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = UserPathExpansion.expand(customRoot, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded)
            // Accept the database file, its directory, or the `devin` data root.
            if url.pathExtension.lowercased() == "db" {
                return url.deletingLastPathComponent()
            }
            let cliDir = url.appendingPathComponent("cli", isDirectory: true)
            if fileProbe.fileExists(atPath: cliDir.appendingPathComponent("sessions.db").path),
               fileProbe.directoryExists(atPath: cliDir.path) {
                return cliDir
            }
            return url
        }
        return homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("devin", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
    }

    func databaseURL() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = UserPathExpansion.expand(customRoot, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded)
            if url.pathExtension.lowercased() == "db" { return url }
        }
        return sessionsRoot().appendingPathComponent("sessions.db", isDirectory: false)
    }

    func hasDatabase() -> Bool {
        fileProbe.fileExists(atPath: databaseURL().path)
    }

    func discoverSessionFiles() -> [URL] {
        hasDatabase() ? [databaseURL()] : []
    }
}

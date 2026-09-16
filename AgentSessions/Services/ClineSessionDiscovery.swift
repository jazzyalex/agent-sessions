import Foundation

/// Discovery for Cline CLI and Cline Desktop session stores under `~/.cline/data/sessions`.
///
/// Layout: `sessions/<session-id>/<session-id>.json` (the manifest) beside
/// `<session-id>.messages.json` (the transcript). The manifest is the discovery
/// unit; `*.messages.json` files are never discovery units themselves.
final class ClineSessionDiscovery: SessionDiscovery {
    /// Injected data-root override, read from the process environment in production.
    /// An explicit sessions-root override always wins; a per-run `--data-dir` flag
    /// stays a manual CLI concern and never flows through here.
    static let dataDirEnvKey = "CLINE_DATA_DIR"

    private let customRoot: String?
    private let fileProbe: any FileProbing
    private let homeDirectory: URL
    private let environment: [String: String]

    init(customRoot: String? = nil,
         fileProbe: any FileProbing = DefaultFileProbe(),
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.customRoot = customRoot
        self.fileProbe = fileProbe
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    /// The directory holding one subdirectory per session.
    ///
    /// Precedence: explicit override, then `CLINE_DATA_DIR` as the data root,
    /// then the `~/.cline/data/sessions` default. Like Qwen's `QWEN_HOME`, the
    /// environment value names the data root. When it is set it is authoritative,
    /// even before its `sessions` child exists; falling back would expose sessions
    /// from a different Cline profile than the one the user selected.
    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = UserPathExpansion.expand(customRoot, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            // Accept the sessions directory itself or the `.cline` data root above it.
            if url.lastPathComponent == "sessions" { return url }
            let sessions = url.appendingPathComponent("sessions", isDirectory: true)
            if fileProbe.directoryExists(atPath: sessions.path) { return sessions }
            // Accept a `data` directory holding `sessions` beneath it.
            let dataSessions = url.appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            if fileProbe.directoryExists(atPath: dataSessions.path) { return dataSessions }
            return url
        }
        if let dataDir = environment[Self.dataDirEnvKey],
           !dataDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = UserPathExpansion.expand(dataDir, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            return url.appendingPathComponent("sessions", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".cline", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// The session id is the directory holding `<session-id>.json`, where the
    /// file basename matches the directory name. `*.messages.json` never qualifies.
    static func sessionID(forManifest url: URL) -> String? {
        let filename = url.lastPathComponent
        guard url.pathExtension.lowercased() == "json" else { return nil }
        guard !filename.hasSuffix(".messages.json") else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        guard !base.isEmpty, base != "messages" else { return nil }
        let dir = url.deletingLastPathComponent().lastPathComponent
        guard dir == base else { return nil }
        return base
    }

    /// `<session-id>.messages.json` sits beside the manifest.
    static func messagesFile(forManifest url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(base).messages.json", isDirectory: false)
    }

    /// Pair-aware logical stat for the generic freshness paths (focused-session
    /// monitor, search ingest), which only see the manifest path. Seconds-based
    /// like `SessionFileStat.from`; nil unless the manifest itself is present,
    /// so a missing manifest still reads as a missing session.
    static func logicalFileStat(forManifest url: URL) -> SessionFileStat? {
        guard let manifest = SessionFileStat.from(url) else { return nil }
        guard let companion = SessionFileStat.from(messagesFile(forManifest: url)) else {
            return manifest
        }
        return SessionFileStat(mtime: max(manifest.mtime, companion.mtime),
                               size: manifest.size + companion.size)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        var files: [URL] = []
        let sessions = fileProbe.contentsOfDirectory(atPath: root.path)
        for session in sessions {
            guard fileProbe.directoryExists(atPath: session.path) else { continue }
            let id = session.lastPathComponent
            guard !id.isEmpty else { continue }
            let manifest = session.appendingPathComponent("\(id).json", isDirectory: false)
            guard fileProbe.fileExists(atPath: manifest.path) else { continue }
            guard Self.sessionID(forManifest: manifest) != nil else { continue }
            files.append(manifest)
        }

        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if a != b { return a > b }
            return $0.path > $1.path
        }
    }
}

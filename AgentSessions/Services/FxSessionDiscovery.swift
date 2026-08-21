import Foundation

/// Discovery for fx (vercel-labs) session stores under `~/.fx/sessions`.
///
/// Layout: `sessions/<sessionId>/`, one directory per session, where the
/// session directory holds `checkpoint.json` (the materialized conversation),
/// `session.json` (the metadata sidecar), and an append-only `events.jsonl`
/// infrastructure log that can reach tens of megabytes.
///
/// The checkpoint, not the event log, is the discovery unit. The event log is
/// write-ahead infrastructure — usage checkpoints, recovery markers, state
/// replacement chunks — and the largest session measured holds 45 MB of it
/// against a 2.4 MB checkpoint carrying the identical conversation. Reading
/// `session.json` for the list pass and `checkpoint.json` for full parses
/// never touches the journal at all.
final class FxSessionDiscovery: SessionDiscovery {
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

    /// The directory holding one subdirectory per session.
    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = UserPathExpansion.expand(customRoot, relativeTo: homeDirectory)
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            // Accept the sessions directory itself or the `.fx` data root above it.
            if url.lastPathComponent == "sessions" { return url }
            let sessions = url.appendingPathComponent("sessions", isDirectory: true)
            if fileProbe.directoryExists(atPath: sessions.path) { return sessions }
            return url
        }
        return homeDirectory
            .appendingPathComponent(".fx", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// The session id is the directory holding `checkpoint.json`.
    static func sessionID(forCheckpoint url: URL) -> String? {
        let id = url.deletingLastPathComponent().lastPathComponent
        return id.isEmpty ? nil : id
    }

    /// `session.json` sits beside the checkpoint.
    static func sidecarFile(forCheckpoint url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("session.json", isDirectory: false)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        var files: [URL] = []
        let sessions = fileProbe.contentsOfDirectory(atPath: root.path)
        for session in sessions where session.lastPathComponent != "latest" {
            // `latest/` is a pointer directory the CLI maintains, not a session.
            guard fileProbe.directoryExists(atPath: session.path) else { continue }
            let checkpoint = session.appendingPathComponent("checkpoint.json", isDirectory: false)
            guard fileProbe.fileExists(atPath: checkpoint.path) else { continue }
            guard fileProbe.fileExists(atPath: Self.sidecarFile(forCheckpoint: checkpoint).path) else { continue }
            guard Self.sessionID(forCheckpoint: checkpoint) != nil else { continue }
            files.append(checkpoint)
        }

        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if a != b { return a > b }
            return $0.path > $1.path
        }
    }
}

import Foundation

/// Discovery for fx (vercel-labs) session stores under `~/.fx/sessions`.
///
/// One directory per session, `sessions/<sessionId>/`, in one of two layouts:
///
/// - **Schema 3 (fx ≤ 0.0.7)** — `checkpoint.json` (the materialized
///   conversation), `session.json` (the metadata sidecar), `authority.json`, and
///   an append-only `events.jsonl` *infrastructure* log (usage checkpoints,
///   recovery markers, state replacement chunks) that can reach tens of
///   megabytes. The checkpoint is the discovery unit; that journal is never read.
/// - **Schema 4 (fx 0.0.8+)** — `session.json` with `schema_version: 4` and an
///   `events.jsonl` that *is* the conversation: one
///   `{schema_version, seq, timestamp_ms, event: {<kind>: …}}` frame per line
///   (upstream `session_event.zig` `ConversationEnvelope`). There is no
///   `checkpoint.json` or `authority.json`; fx deletes both when it migrates a
///   schema-3 directory in place, keeping the directory name. The event log is
///   the discovery unit.
///
/// A directory with `checkpoint.json` is schema 3. A directory without one
/// is schema 4 only when it has `session.json` + `events.jsonl` and no
/// `authority.json` — a schema-3 directory whose checkpoint never materialized
/// keeps its authority file and stays invisible, as before. The parser checks
/// the manifest's `schema_version` again before reading any frame.
///
/// `v2/` is the root of fx's opt-in sessions-v2 store (`--sessions-v2`,
/// 0.0.14; `session_layout.zig` reserves the name so no session id can take
/// it). Its format is not supported yet, so it is skipped like `latest/`.
final class FxSessionDiscovery: SessionDiscovery {
    /// Which on-disk layout a discovered session file belongs to.
    enum Layout: Equatable {
        /// `checkpoint.json` — schema 3 (fx ≤ 0.0.7).
        case checkpoint
        /// `events.jsonl` — schema 4 (fx 0.0.8+).
        case eventLog
    }

    static let checkpointFileName = "checkpoint.json"
    static let eventLogFileName = "events.jsonl"
    static let manifestFileName = "session.json"
    /// Schema-3 only; its presence marks an `events.jsonl` as infrastructure.
    static let legacyAuthorityFileName = "authority.json"

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

    /// The session id is the directory holding the session file, in both layouts.
    static func sessionID(forSessionFile url: URL) -> String? {
        let id = url.deletingLastPathComponent().lastPathComponent
        return id.isEmpty ? nil : id
    }

    /// `session.json` sits beside the checkpoint or the event log.
    static func sidecarFile(forSessionFile url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(manifestFileName, isDirectory: false)
    }

    static func layout(forSessionFile url: URL) -> Layout {
        url.lastPathComponent == eventLogFileName ? .eventLog : .checkpoint
    }

    /// Directory names under the sessions root that are never sessions:
    /// `latest/` is a pointer the CLI maintains, `v2/` the sessions-v2 root.
    private static func isReservedDirectoryName(_ name: String) -> Bool {
        name == "latest" || name.caseInsensitiveCompare("v2") == .orderedSame
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        var files: [URL] = []
        let sessions = fileProbe.contentsOfDirectory(atPath: root.path)
        for session in sessions where !Self.isReservedDirectoryName(session.lastPathComponent) {
            guard fileProbe.directoryExists(atPath: session.path) else { continue }
            guard let file = sessionFile(in: session) else { continue }
            guard Self.sessionID(forSessionFile: file) != nil else { continue }
            files.append(file)
        }

        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if a != b { return a > b }
            return $0.path > $1.path
        }
    }

    /// The discovery unit of one session directory, or nil when it is not a
    /// readable session. Both layouts require the `session.json` sidecar.
    private func sessionFile(in directory: URL) -> URL? {
        let manifest = directory.appendingPathComponent(Self.manifestFileName, isDirectory: false)
        guard fileProbe.fileExists(atPath: manifest.path) else { return nil }
        let checkpoint = directory.appendingPathComponent(Self.checkpointFileName, isDirectory: false)
        if fileProbe.fileExists(atPath: checkpoint.path) { return checkpoint }
        let authority = directory.appendingPathComponent(Self.legacyAuthorityFileName, isDirectory: false)
        if fileProbe.fileExists(atPath: authority.path) { return nil }
        let eventLog = directory.appendingPathComponent(Self.eventLogFileName, isDirectory: false)
        return fileProbe.fileExists(atPath: eventLog.path) ? eventLog : nil
    }
}

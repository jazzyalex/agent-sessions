import Foundation

/// How the CLI finds and parses one source's sessions. File-backed sources go through
/// their discovery class; database-backed ones (OpenCode v1.2+) list rows instead.
struct SourceDriver {
    let source: SessionSource
    let discovery: () -> any SessionDiscovery
    let parseLight: (URL) -> Session?
    let parseFull: (URL) -> Session?
    /// Sources whose sessions are rows in a database rather than files return
    /// (locator, session) pairs here; nil means fall back to file discovery.
    var scanDatabase: (_ light: Bool) -> [(String, Session?)]? = { _ in nil }
    /// Database-backed sources: the lightweight rows plus the authoritative identity set
    /// search ingest reconciles against (the app's indexers build the same snapshot).
    var databaseSessions: () -> (sessions: [Session], snapshot: SearchIngestService.IdentitySnapshot)? = { nil }
    /// Database-backed sources: full load of one session by its stable ID.
    var loadByID: ((String) -> Session?)? = nil
}

let drivers: [SourceDriver] = [
    SourceDriver(source: .codex,
                 discovery: { CodexSessionDiscovery() },
                 parseLight: { CodexSessionParser.parseFile(at: $0) },
                 parseFull: { CodexSessionParser.parseFileFull(at: $0) }),
    SourceDriver(source: .claude,
                 discovery: { ClaudeSessionDiscovery() },
                 parseLight: { ClaudeSessionParser.parseFile(at: $0) },
                 parseFull: { ClaudeSessionParser.parseFileFull(at: $0) }),
    SourceDriver(source: .antigravity,
                 discovery: { AntigravitySessionDiscovery() },
                 parseLight: { AntigravitySessionParser.parseFile(at: $0) },
                 parseFull: { AntigravitySessionParser.parseFileFull(at: $0) }),
    SourceDriver(source: .opencode,
                 discovery: { OpenCodeSessionDiscovery() },
                 parseLight: { OpenCodeSessionParser.parseFile(at: $0) },
                 parseFull: { OpenCodeSessionParser.parseFileFull(at: $0) },
                 scanDatabase: { light in
                     guard OpenCodeBackendDetector.detect(customRoot: nil) == .sqlite,
                           let db = OpenCodeSessionDiscovery().databaseURL() else { return nil }
                     return OpenCodeSqliteReader.listSessions(customRoot: nil).map { row in
                         ("\(db.path)#\(row.id)",
                          light ? row : OpenCodeSqliteReader.loadFullSession(customRoot: nil, sessionID: row.id))
                     }
                 },
                 databaseSessions: {
                     guard OpenCodeBackendDetector.detect(customRoot: nil) == .sqlite,
                           let db = OpenCodeSessionDiscovery().databaseURL(),
                           let rows = OpenCodeSqliteReader.listSessionsIfReadable(customRoot: nil) else { return nil }
                     return (rows, SearchIngestService.IdentitySnapshot(storagePaths: [db.path],
                                                                        sessionIDs: Set(rows.map(\.id))))
                 },
                 loadByID: { OpenCodeSqliteReader.loadFullSession(customRoot: nil, sessionID: $0) }),
    SourceDriver(source: .copilot,
                 discovery: { CopilotSessionDiscovery() },
                 parseLight: { CopilotSessionParser.parseFile(at: $0) },
                 parseFull: { CopilotSessionParser.parseFileFull(at: $0) }),
]

func driver(named name: String) -> SourceDriver? {
    drivers.first { $0.source.rawValue == name }
}

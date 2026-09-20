import Foundation

// MARK: - Arguments

struct Options {
    var positional: [String] = []
    var sources: [SourceDriver] = drivers
    var limit = 50
    var light = false
    var includeSubagents = false
    var sessionID: String?
    var databaseURL = Options.defaultDatabaseURL()

    /// `$AS_CORE_DB`, else `$XDG_DATA_HOME/agent-sessions/index.db`, else
    /// `~/.local/share/agent-sessions/index.db`. Never the macOS app's index.
    static func defaultDatabaseURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["AS_CORE_DB"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let dataHome = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return dataHome.appendingPathComponent("agent-sessions/index.db")
    }

    init(_ args: ArraySlice<String>) {
        var selected: [SourceDriver] = []
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--source":
                guard let name = it.next(), let d = driver(named: name) else {
                    fail("--source needs one of: \(drivers.map(\.source.rawValue).joined(separator: ", "))", code: 2)
                }
                selected.append(d)
            case "--limit":
                guard let value = it.next().flatMap(Int.init), value > 0 else { fail("--limit needs a positive integer", code: 2) }
                limit = value
            case "--db":
                guard let path = it.next() else { fail("--db needs a path", code: 2) }
                databaseURL = URL(fileURLWithPath: path)
            case "--light":
                light = true
            case "--include-subagents":
                includeSubagents = true
            case "--id":
                guard let id = it.next() else { fail("--id needs a session ID", code: 2) }
                sessionID = id
            default:
                if arg.hasPrefix("--") { fail("unknown option \(arg)", code: 2) }
                positional.append(arg)
            }
        }
        if !selected.isEmpty { sources = selected }
    }
}

// MARK: - Single-file commands

func sessionSummary(_ session: Session?, path: String) -> [String: Any] {
    guard let session else { return ["path": path, "error": "unparsed"] }
    return [
        "path": path,
        "id": session.id,
        "source": session.source.rawValue,
        "events": session.events.count,
        "model": orNull(session.model),
        "title": session.title,
    ]
}

/// `parse <source> <file>`: one summary for a single file.
func runParse(_ options: Options) {
    guard options.positional.count == 2, let d = driver(named: options.positional[0]) else {
        fail("usage: as-core parse <source> <file>", code: 2)
    }
    let url = URL(fileURLWithPath: options.positional[1])
    guard let session = d.parseFull(url) else { fail("could not parse \(url.path)", code: 1) }
    emit(sessionSummary(session, path: url.path))
}

/// `scan [--source s] [--light]`: discover and parse without touching the index.
func runScan(_ options: Options) {
    for d in options.sources {
        for row in d.databaseSessions() {
            let full = options.light ? row : d.loadByID(URL(fileURLWithPath: row.filePath), row.id)
            emit(sessionSummary(full ?? row, path: "\(row.filePath)#\(row.id)"))
        }
        for url in d.discoverFiles().sorted(by: { $0.path < $1.path }) {
            emit(sessionSummary(options.light ? d.parseLight(url) : d.parseFull(url), path: url.path))
        }
    }
}

/// Loads one session for `show` / `resume`: by ID for database-backed sources, else by path.
func loadSession(_ options: Options, usage: String) -> Session {
    guard options.positional.count == 2, let d = driver(named: options.positional[0]) else {
        fail(usage, code: 2)
    }
    let url = URL(fileURLWithPath: options.positional[1])
    let loaded: Session?
    if let id = options.sessionID, d.usesIdentity {
        loaded = d.loadByID(url, id)
    } else {
        loaded = d.parseFull(url)
    }
    guard let session = loaded else { fail("could not load \(options.sessionID ?? url.path)", code: 1) }
    return session
}

/// `resume <source> <file> [--id id]`: the shell command that reopens the session.
func runResume(_ options: Options) {
    let session = loadSession(options, usage: "usage: as-core resume <source> <file> [--id <session-id>]")
    do {
        let command = try resumeCommand(for: session)
        emit(["type": "resume",
              "id": session.id,
              "source": session.source.rawValue,
              "command": command.display,
              "shell": command.shell,
              "cwd": orNull(command.workingDirectory)])
    } catch {
        fail("\(error)", code: 1)
    }
}

/// `show <source> <file> [--id id]`: header, then one line per event. Database-backed
/// sources share one storage path, so they need `--id`.
func runShow(_ options: Options) {
    let session = loadSession(options, usage: "usage: as-core show <source> <file> [--id <session-id>]")
    var header = sessionSummary(session, path: session.filePath)
    header["type"] = "session"
    header["cwd"] = orNull(session.cwd)
    header["start"] = iso(session.startTime)
    header["end"] = iso(session.endTime)
    emit(header)
    for event in session.events {
        emit([
            "type": "event",
            "id": event.id,
            "kind": event.kind.rawValue,
            "timestamp": iso(event.timestamp),
            "role": orNull(event.role),
            "text": orNull(event.text),
            "toolName": orNull(event.toolName),
            "toolInput": orNull(event.toolInput),
            "toolOutput": orNull(event.toolOutput),
        ])
    }
}

/// `sources`: the sources this build can read, in catalog order.
func runSources() {
    for d in drivers {
        emit(["type": "source", "name": d.source.rawValue, "displayName": d.source.displayName])
    }
}

// MARK: - Index commands

func openIndex(_ options: Options) -> IndexDB {
    // Two processes creating a fresh database at once (the UI's first `list` and `index`)
    // can get "database is locked" even with a busy timeout: SQLite refuses to wait when
    // waiting could deadlock while the database is switched to WAL. It settles as soon as
    // one process finishes creating the schema, so retry briefly, and only for that error.
    var lastError: Error?
    for _ in 0..<40 {
        do {
            return try IndexDB(databaseURL: options.databaseURL)
        } catch {
            lastError = error
            guard "\(error)".contains("locked") else { break }
            usleep(150_000)
        }
    }
    fail("cannot open index at \(options.databaseURL.path): \(lastError.map { "\($0)" } ?? "unknown error")", code: 1)
}

/// `index [--source s]`: full-parse new or changed files into the index, through the same
/// `SearchIngestService` the app uses (its skip gates make re-runs incremental).
func runIndex(_ options: Options) async {
    let db = openIndex(options)
    let ingest = SearchIngestService(db: db)
    for d in options.sources {
        let started = Date()
        var files: [SearchIngestService.FileRef] = []
        var identitySnapshot: SearchIngestService.IdentitySnapshot?
        let databaseSessions = d.databaseSessions()
        if !databaseSessions.isEmpty {
            files = SearchIngestService.fileRefs(for: databaseSessions)
            // The authoritative set for this pass, so rows deleted upstream leave the index.
            identitySnapshot = SearchIngestService.IdentitySnapshot(
                storagePaths: Set(databaseSessions.map(\.filePath)),
                sessionIDs: Set(databaseSessions.map(\.id))
            )
        }
        files += d.discoverFiles().compactMap { url in
            guard let stat = SessionFileStat.from(url) else { return nil }
            return SearchIngestService.FileRef(path: url.path, mtime: stat.mtime, size: stat.size)
        }
        do {
            let progress = try await ingest.ingest(source: d.source,
                                                   files: files,
                                                   toolIOEnabled: false,
                                                   identitySnapshot: identitySnapshot,
                                                   yieldNanoseconds: 0,
                                                   quietSeconds: 0)
            emit([
                "type": "index",
                "source": d.source.rawValue,
                "files": files.count,
                "processed": progress.processed,
                "skippedFiles": progress.skipped,
                "ms": Int(Date().timeIntervalSince(started) * 1000),
            ])
        } catch {
            emit(["type": "index", "source": d.source.rawValue, "error": "\(error)"])
        }
    }
}

func metaSummary(_ row: SessionMetaRow) -> [String: Any] {
    [
        "type": "session",
        "id": row.sessionID,
        "source": row.source,
        "path": row.path,
        "title": orNull(row.customTitle ?? row.title),
        "model": orNull(row.model),
        "cwd": orNull(row.cwd),
        "repo": orNull(row.repo),
        "start": iso(epochSeconds: row.startTS),
        "end": iso(epochSeconds: row.endTS),
        // What `list` sorts by: the later of the last event and the file's mtime.
        "modified": iso(epochSeconds: max(row.endTS, row.mtime)),
        "messages": row.messages,
        "commands": row.commands,
        "parentSessionID": orNull(row.parentSessionID),
        "subagentType": orNull(row.subagentType),
    ]
}

/// Subagent runs (Codex guardian approval reviews, explorer/general workers, Claude
/// sidechains) nest under their parent in the app. A flat list shows top-level sessions
/// only; a guardian row carries its parent's transcript, so search still finds the parent.
func isSubagent(_ row: SessionMetaRow) -> Bool {
    row.subagentType != nil || row.parentSessionID != nil
}

func indexedRows(_ db: IndexDB, _ options: Options) async -> [SessionMetaRow] {
    var rows: [SessionMetaRow] = []
    for d in options.sources {
        rows += (try? await db.fetchSessionMeta(for: d.source.rawValue)) ?? []
    }
    return rows
}

/// `list [--source s] [--limit n]`: newest indexed sessions first.
func runList(_ options: Options) async {
    let db = openIndex(options)
    let rows = await indexedRows(db, options)
        .filter { !$0.isHousekeeping && (options.includeSubagents || !isSubagent($0)) }
        .sorted { max($0.endTS, $0.mtime) > max($1.endTS, $1.mtime) }
    for row in rows.prefix(options.limit) { emit(metaSummary(row)) }
}

/// `search <query> [--source s] [--limit n]`: full-text search, best match first.
func runSearch(_ options: Options) async {
    guard !options.positional.isEmpty else { fail("usage: as-core search <query>", code: 2) }
    let query = options.positional.joined(separator: " ")
    let db = openIndex(options)
    let rows = await indexedRows(db, options)
    // Exclude in SQL, not afterwards, so `--limit` counts only rows we will show.
    let hidden = options.includeSubagents ? [] : Set(rows.filter(isSubagent).map(\.sessionID))
    let ids: [String]
    do {
        ids = try await db.searchSessionIDsFTS(sources: options.sources.map(\.source.rawValue),
                                               model: nil,
                                               repoSubstr: nil,
                                               pathSubstr: nil,
                                               dateFrom: nil,
                                               dateTo: nil,
                                               query: query,
                                               includeSystemProbes: false,
                                               limit: options.limit,
                                               ineligibleSessionIDs: hidden)
    } catch {
        fail("search failed: \(error)", code: 1)
    }
    let byID = Dictionary(rows.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
    for id in ids {
        guard let row = byID[id] else { continue }
        emit(metaSummary(row))
    }
}

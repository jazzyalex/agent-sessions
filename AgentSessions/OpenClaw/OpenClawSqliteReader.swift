import Foundation
import SQLite3
import CryptoKit

/// Read-only access to OpenClaw's current per-agent SQLite session store.
///
/// OpenClaw 2026.9 stores session metadata in `session_windows` and transcript
/// records in `transcript_events`. Legacy JSONL files remain a separate backend;
/// this reader exists so the registry can cover the current store without making
/// the telemetry engine know about OpenClaw's schema.
struct OpenClawSqliteReader {
    private static let databaseName = "openclaw-agent.sqlite"
    private static let usageFamily = "openclaw.message.usage"
    private static let speed = "standard-normalized"

    private struct SessionRow {
        let id: String
        let createdAt: Date?
        let updatedAt: Date?
        let startedAt: Date?
        let endedAt: Date?
        let model: String?
        let displayName: String?
        let eventCount: Int
    }

    private struct EventRow {
        let sequence: Int64
        let line: String?
        let eventID: String?
        let createdAt: Date?
        let bytes: UInt64
        let compressed: Bool
    }

    private struct EventQuery {
        let rows: [EventRow]
        let bytesScanned: UInt64
        let hasCompressedPayload: Bool
        let coldArchive: ColdArchive?
        let cancelled: Bool
    }

    struct SessionListResult {
        let sessions: [Session]
        let storageIdentity: String
        let databaseVersionToken: String
    }

    private struct ColdArchive {
        let generation: String
        let archiveName: String
        let archiveSHA256: String
        let eventCount: Int
        let rawBytes: UInt64
        let archiveBytes: UInt64
        let lastSequence: Int64
        let archivedAt: Int64
        let storage: String

        var revisionFields: [String] {
            [generation,
             archiveName,
             archiveSHA256,
             String(eventCount),
             String(rawBytes),
             String(archiveBytes),
             String(lastSequence),
             String(archivedAt),
             storage]
        }
    }

    private enum ColdArchiveLookup {
        case absent
        case present(ColdArchive)
        case malformed
    }

    /// One long-lived read handle per database lets PRAGMA data_version act as
    /// a cheap WAL-aware freshness gate. The content hash is recomputed only
    /// after that gate changes, so cache hits and coalesced requests do not
    /// reread every event payload just to form their key. Publication tokens
    /// use the connection-independent database fingerprint; data_version is
    /// deliberately kept as an internal cache invalidation detail.
    private final class RevisionState: @unchecked Sendable {
        var database: OpaquePointer?
        var fingerprint: String?
        var dataVersion: String?
        var revisions: [String: SessionTelemetryRevision] = [:]
    }

    private struct RevisionResult {
        let revision: SessionTelemetryRevision?
        let bytesScanned: UInt64
        let readContent: Bool
        let storageIdentity: String?
        let databaseVersionToken: String?

        init(revision: SessionTelemetryRevision?,
             bytesScanned: UInt64,
             readContent: Bool,
             storageIdentity: String? = nil,
             databaseVersionToken: String? = nil) {
            self.revision = revision
            self.bytesScanned = bytesScanned
            self.readContent = readContent
            self.storageIdentity = storageIdentity
            self.databaseVersionToken = databaseVersionToken
        }
    }

    struct SessionProof {
        let revision: SessionTelemetryRevision
        let storageIdentity: String
        let databaseVersionToken: String
    }

    private static let revisionCacheLock = NSLock()
    private static var revisionStates: [String: RevisionState] = [:]
    private static var listSessionsBeforeMaterializationHookForTesting: (() -> Void)?
    private static var cacheHitBeforeBoundaryProbeHookForTesting: (() -> Void)?

    static func isSupportedDatabasePath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == databaseName
    }

    static func isSupportedDatabaseURL(_ url: URL) -> Bool {
        isSupportedDatabasePath(url.path)
    }

    /// Lists the sessions in one current OpenClaw agent database.
    /// nil means the path is not a readable OpenClaw database; an empty array
    /// is a valid readable database with no session rows.
    static func listSessions(databaseURL: URL, agentID requestedAgentID: String? = nil) -> [Session]? {
        listSessionsWithStorageIdentity(databaseURL: databaseURL,
                                        agentID: requestedAgentID)?.sessions
    }

    /// Lists sessions while returning the exact physical database path used for
    /// the read. Callers that reconcile shared-store identities must carry this
    /// value forward instead of resolving the lexical alias again.
    static func listSessionsWithStorageIdentity(
        databaseURL: URL,
        agentID requestedAgentID: String? = nil
    ) -> SessionListResult? {
        let storageIdentity = canonicalDatabasePath(databaseURL.path)
        guard let startingFingerprint = databaseFingerprint(path: storageIdentity) else { return nil }
        guard isSupportedDatabaseURL(databaseURL),
              let db = openReadOnly(path: storageIdentity),
              let openedFingerprint = databaseFingerprint(path: storageIdentity),
              openedFingerprint == startingFingerprint else { return nil }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db),
              let rows = querySessionRows(db: db) else { return nil }
        defer { rollbackReadTransaction(db) }
        listSessionsBeforeMaterializationHookForTesting?()

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: storageIdentity)[.size] as? NSNumber)?.intValue
        let resolvedAgentID = requestedAgentID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? agentID(from: databaseURL)
        let sessions = rows.map {
            var session = makeSession(from: $0,
                                      databaseURL: databaseURL,
                                      storageIdentity: storageIdentity,
                                      resolvedAgentID: resolvedAgentID,
                                      fileSize: fileSize)
            session.sourceStorageDatabaseVersion = databaseVersionToken(fingerprint: startingFingerprint)
            return session
        }
        guard let endingFingerprint = databaseFingerprint(path: storageIdentity),
              endingFingerprint == startingFingerprint else {
            // The read handle may still contain a consistent old snapshot,
            // but the pathname now names a different database. Do not pair
            // those rows with the replacement store's identity or token.
            return nil
        }
        return SessionListResult(
            sessions: sessions,
            storageIdentity: storageIdentity,
            databaseVersionToken: databaseVersionToken(fingerprint: startingFingerprint))
    }

    static func setListSessionsBeforeMaterializationHookForTesting(_ hook: (() -> Void)?) {
        listSessionsBeforeMaterializationHookForTesting = hook
    }

    static func setCacheHitBeforeBoundaryProbeHookForTesting(_ hook: (() -> Void)?) {
        cacheHitBeforeBoundaryProbeHookForTesting = hook
    }

    /// Lists one session without enumerating every session in the shared
    /// database. Focused preview refreshes use this to keep their cost
    /// proportional to the selected session.
    static func listSession(databaseURL: URL,
                            agentID requestedAgentID: String? = nil,
                            sessionID: String) -> Session? {
        listSessionWithProof(databaseURL: databaseURL,
                             agentID: requestedAgentID,
                             sessionID: sessionID)?.session
    }

    /// Focused metadata read with the same-snapshot proof needed by preview
    /// publication. The caller must compare both returned values with the
    /// current store before publishing the lightweight row.
    static func listSessionWithProof(
        databaseURL: URL,
        agentID requestedAgentID: String? = nil,
        sessionID: String
    ) -> (session: Session,
          revision: SessionTelemetryRevision,
          storageIdentity: String,
          databaseVersionToken: String)? {
        guard isSupportedDatabaseURL(databaseURL) else { return nil }
        let storageIdentity = canonicalDatabasePath(databaseURL.path)
        guard let fingerprint = databaseFingerprint(path: storageIdentity) else { return nil }
        guard let rawID = rawSessionID(from: sessionID),
              let db = openReadOnly(path: storageIdentity) else { return nil }
        defer { sqlite3_close(db) }
        guard let openedFingerprint = databaseFingerprint(path: storageIdentity),
              openedFingerprint == fingerprint,
              let startingDataVersion = sqliteDataVersion(db),
              beginReadTransaction(db),
              let row = querySessionRow(db: db, sessionID: rawID),
              let events = queryEvents(db: db, sessionID: rawID),
              !events.cancelled,
              let revision = makeRevision(rawID: rawID, sessionRow: row, events: events) else {
            rollbackReadTransaction(db)
            return nil
        }
        rollbackReadTransaction(db)
        guard let endingDataVersion = sqliteDataVersion(db),
              endingDataVersion == startingDataVersion,
              let endingFingerprint = databaseFingerprint(path: storageIdentity),
              endingFingerprint == fingerprint else { return nil }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: storageIdentity)[.size] as? NSNumber)?.intValue
        let resolvedAgentID = requestedAgentID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? agentID(from: databaseURL)
        var session = makeSession(from: row,
                                  databaseURL: databaseURL,
                                  storageIdentity: storageIdentity,
                                  resolvedAgentID: resolvedAgentID,
                                  fileSize: fileSize)
        session.sourceStorageIdentity = storageIdentity
        session.sourceStorageRevision = sessionRevisionKey(revision)
        return (session,
                revision,
                storageIdentity,
                databaseVersionToken(fingerprint: fingerprint))
    }

    /// Lists sessions from every discovered database. A nil result means at
    /// least one database could not be read, so callers can preserve a prior
    /// indexed copy instead of deleting it speculatively.
    static func listSessions(databaseURLs: [URL]) -> [Session]? {
        var sessions: [Session] = []
        for url in databaseURLs {
            guard let databaseSessions = listSessions(databaseURL: url) else { return nil }
            sessions.append(contentsOf: databaseSessions)
        }
        return sessions
    }

    /// The cache identity is session-scoped even though all sessions share one
    /// database. Include the session metadata and every stored event payload so
    /// WAL-backed writes invalidate only the affected logical session.
    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        let startedAt = Date()
        let result = cachedRevision(for: session)
        if result.readContent {
            SessionInfoMetrics.shared.recordTelemetryPreparation(
                duration: Date().timeIntervalSince(startedAt),
                bytesScanned: result.bytesScanned)
        }
        return result.revision
    }

    /// Session-scoped logical revision used by focused reload and preview
    /// freshness. Reuse the content-aware revision so WAL-only payload edits
    /// cannot be mistaken for an unchanged transcript.
    static func sessionRevision(for session: Session) -> SessionTelemetryRevision? {
        cachedRevision(for: session).revision
    }

    /// Captures the logical transcript revision and its database snapshot token
    /// under one persistent-reader lock. Callers attach this tuple to a full
    /// publication; they must not obtain the token in a later actor turn.
    static func sessionProof(for session: Session) -> SessionProof? {
        let result = cachedRevision(for: session)
        guard let revision = result.revision,
              let storageIdentity = result.storageIdentity,
              let databaseVersionToken = result.databaseVersionToken else {
            return nil
        }
        return SessionProof(revision: revision,
                            storageIdentity: storageIdentity,
                            databaseVersionToken: databaseVersionToken)
    }

    /// Returns a cheap, connection-independent database snapshot token for this
    /// store. The token is intentionally not a transcript proof by itself;
    /// callers pair it with a session's already-captured logical revision and
    /// use it only to reject a handoff after an intervening SQLite commit.
    static func storageRevisionToken(for session: Session) -> String? {
        guard session.source == .openclaw,
              isSupportedDatabasePath(session.filePath) else {
            return nil
        }
        let storageIdentity = session.sourceStorageIdentity
            ?? canonicalDatabasePath(session.filePath)
        return storageRevisionToken(forStorageIdentity: storageIdentity)
    }

    static func storageRevisionToken(forStorageIdentity storageIdentity: String) -> String? {
        guard let fingerprint = databaseFingerprint(path: storageIdentity) else {
            return nil
        }
        return databaseVersionToken(fingerprint: fingerprint)
    }

    private static func cachedRevision(for session: Session) -> RevisionResult {
        guard session.source == .openclaw,
              isSupportedDatabasePath(session.filePath),
              let rawID = rawSessionID(from: session.id) else {
            return RevisionResult(revision: nil, bytesScanned: 0, readContent: false)
        }

        // Resolve the lexical alias once and use that physical path for every
        // part of the cache transaction. Fingerprinting an alias and then
        // reopening the alias can bind fingerprint A to a handle for B when a
        // configured symlink is retargeted between those operations.
        let storageIdentity = session.sourceStorageIdentity
            ?? canonicalDatabasePath(session.filePath)

        revisionCacheLock.lock()
        defer { revisionCacheLock.unlock() }

        guard let fingerprint = databaseFingerprint(path: storageIdentity) else {
            return RevisionResult(revision: nil, bytesScanned: 0, readContent: false)
        }

        let state: RevisionState
        if let existing = revisionStates[storageIdentity],
           existing.fingerprint == fingerprint,
           existing.database != nil {
            state = existing
        } else {
            if let previous = revisionStates[storageIdentity], let database = previous.database {
                sqlite3_close(database)
            }
            let fresh = RevisionState()
            guard let database = openReadOnly(path: storageIdentity) else {
                revisionStates.removeValue(forKey: storageIdentity)
                return RevisionResult(revision: nil, bytesScanned: 0, readContent: false)
            }
            guard let openedFingerprint = databaseFingerprint(path: storageIdentity),
                  openedFingerprint == fingerprint else {
                // The physical target changed while the handle was opening.
                // Drop the handle and let the next request establish a proof
                // against the new target rather than caching mixed identity.
                sqlite3_close(database)
                revisionStates.removeValue(forKey: storageIdentity)
                return RevisionResult(revision: nil, bytesScanned: 0, readContent: false)
            }
            fresh.database = database
            fresh.fingerprint = fingerprint
            revisionStates[storageIdentity] = fresh
            state = fresh
        }

        guard let database = state.database,
              let currentDataVersion = sqliteDataVersion(database) else {
            return RevisionResult(revision: nil, bytesScanned: 0, readContent: false)
        }
        if state.dataVersion == currentDataVersion,
           let cached = state.revisions[rawID] {
            cacheHitBeforeBoundaryProbeHookForTesting?()
            // The cache hit still needs a publication-boundary proof. A WAL
            // commit or an atomic same-path replacement can happen after the
            // first data_version read; returning immediately would pair the
            // old logical revision with the new store.
            guard let endingDataVersion = sqliteDataVersion(database),
                  endingDataVersion == currentDataVersion,
                  let endingFingerprint = databaseFingerprint(path: storageIdentity),
                  endingFingerprint == fingerprint else {
                state.dataVersion = nil
                state.revisions.removeAll(keepingCapacity: true)
                return RevisionResult(revision: nil, bytesScanned: 0, readContent: false)
            }
            return RevisionResult(
                revision: cached,
                bytesScanned: 0,
                readContent: false,
                storageIdentity: storageIdentity,
                databaseVersionToken: databaseVersionToken(fingerprint: fingerprint))
        }

        if state.dataVersion != nil, state.dataVersion != currentDataVersion {
            // data_version is database-wide. A change invalidates every
            // session hash, not just the session requested by this caller.
            state.revisions.removeAll(keepingCapacity: true)
        }

        guard beginReadTransaction(database),
              let sessionRow = querySessionRow(db: database, sessionID: rawID),
              let events = queryEvents(db: database, sessionID: rawID) else {
            rollbackReadTransaction(database)
            state.dataVersion = nil
            state.revisions.removeAll(keepingCapacity: true)
            return RevisionResult(revision: nil, bytesScanned: 0, readContent: true)
        }
        let revision = makeRevision(rawID: rawID, sessionRow: sessionRow, events: events)
        rollbackReadTransaction(database)
        guard let revision else {
            // Cancellation or an incomplete read must never advance the global
            // version while retaining hashes from the prior snapshot.
            state.dataVersion = nil
            state.revisions.removeAll(keepingCapacity: true)
            return RevisionResult(revision: nil,
                                  bytesScanned: events.bytesScanned,
                                  readContent: true)
        }
        guard let endingDataVersion = sqliteDataVersion(database),
              endingDataVersion == currentDataVersion,
              let endingFingerprint = databaseFingerprint(path: storageIdentity),
              endingFingerprint == fingerprint else {
            // Do not publish or cache a hash produced across a concurrent
            // writer. A changed (or unreadable) ending probe makes the whole
            // snapshot untrustworthy, even if the content hash itself was
            // computed successfully.
            state.dataVersion = nil
            state.revisions.removeAll(keepingCapacity: true)
            return RevisionResult(revision: nil,
                                  bytesScanned: events.bytesScanned,
                                  readContent: true)
        }
        state.dataVersion = currentDataVersion
        state.revisions[rawID] = revision
        return RevisionResult(revision: revision,
                              bytesScanned: events.bytesScanned,
                              readContent: true,
                              storageIdentity: storageIdentity,
                              databaseVersionToken: databaseVersionToken(fingerprint: fingerprint))
    }

    private static func makeRevision(rawID: String,
                                     sessionRow: SessionRow,
                                     events: EventQuery) -> SessionTelemetryRevision? {
        guard !Task.isCancelled else { return nil }
        var hasher = SHA256()
        feed("session.id", rawID, into: &hasher)
        feedOptional("session.model", sessionRow.model, into: &hasher)
        feedOptional("session.display_name", sessionRow.displayName, into: &hasher)
        feed("session.created_at", revisionDate(sessionRow.createdAt), into: &hasher)
        feed("session.updated_at", revisionDate(sessionRow.updatedAt), into: &hasher)
        feed("session.started_at", revisionDate(sessionRow.startedAt), into: &hasher)
        feed("session.ended_at", revisionDate(sessionRow.endedAt), into: &hasher)
        if let coldArchive = events.coldArchive {
            for (index, value) in coldArchive.revisionFields.enumerated() {
                feed("cold.\(index)", value, into: &hasher)
            }
        }
        for row in events.rows {
            guard !Task.isCancelled else { return nil }
            feed("event.seq", String(row.sequence), into: &hasher)
            feed("event.created_at", revisionDate(row.createdAt), into: &hasher)
            feed("event.id", row.eventID ?? "<null>", into: &hasher)
            feed("event.compressed", row.compressed ? "1" : "0", into: &hasher)
            feed("event.bytes", String(row.bytes), into: &hasher)
            if let line = row.line {
                hasher.update(data: Data(line.utf8))
            }
            hasher.update(data: Data([0]))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .logical(digest)
    }

    /// Scans one selected SQLite session. Compressed transcript payloads are
    /// detected and reported as unavailable rather than silently dropping them;
    /// the legacy JSONL provider remains available for uncompressed archives.
    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        guard session.source == .openclaw,
              isSupportedDatabasePath(session.filePath),
              let db = openReadOnly(path: session.sourceStorageIdentity
                                    ?? canonicalDatabasePath(session.filePath)) else { return nil }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db),
              let rawID = rawSessionID(from: session.id),
              let sessionRow = querySessionRow(db: db, sessionID: rawID),
              let events = queryEvents(db: db, sessionID: rawID) else { return nil }
        defer { rollbackReadTransaction(db) }

        if Task.isCancelled || events.cancelled {
            return cancelledScan(bytesScanned: events.bytesScanned)
        }

        if let coldArchive = events.coldArchive {
            return unavailableScan(
                session: session,
                sessionRow: sessionRow,
                reason: "OpenClaw telemetry is unavailable because the selected transcript is in cold storage (archive \(coldArchive.archiveName)); restore it in OpenClaw before reading detailed telemetry.",
                bytesScanned: events.bytesScanned)
        }

        if events.hasCompressedPayload {
            return unavailableScan(
                session: session,
                sessionRow: sessionRow,
                reason: "OpenClaw telemetry is unavailable because the selected transcript contains compressed events that this build cannot decode.",
                bytesScanned: events.bytesScanned)
        }

        let lines = events.rows.compactMap(\.line)
        guard lines.count == events.rows.count else {
            return unavailableScan(
                session: session,
                sessionRow: sessionRow,
                reason: "OpenClaw telemetry is unavailable because a transcript event is not valid UTF-8 JSON.",
                bytesScanned: events.bytesScanned)
        }

        var provider = OpenClawTelemetryProvider()
        for (index, line) in lines.enumerated() {
            provider.consume(line: line, index: index)
        }
        let parsed = provider.finish()
        let telemetry = applyingSessionMetadata(
            to: parsed.telemetry,
            session: session,
            sessionRow: sessionRow,
            lineCount: lines.count)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(
                telemetry: telemetry,
                durableAccountHash: parsed.durableAccountHash),
            bytesScanned: events.bytesScanned)
    }

    /// Full-load seam used by search/transcript selection. Reusing the audited
    /// JSONL parser keeps SQLite and legacy JSONL transcripts identical at the
    /// SessionEvent boundary; the temporary file is removed before returning.
    static func loadFullSession(databaseURL: URL, sessionID: String) -> Session? {
        guard isSupportedDatabaseURL(databaseURL) else { return nil }
        let storageIdentity = canonicalDatabasePath(databaseURL.path)
        guard let rawID = rawSessionID(from: sessionID),
              let db = openReadOnly(path: storageIdentity) else { return nil }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db),
              let sessionRow = querySessionRow(db: db, sessionID: rawID),
              let events = queryEvents(db: db, sessionID: rawID),
              !events.cancelled,
              events.coldArchive == nil,
              !events.hasCompressedPayload,
              events.rows.allSatisfy({ $0.line != nil }),
              let storageRevision = makeRevision(rawID: rawID,
                                                 sessionRow: sessionRow,
                                                 events: events) else { return nil }
        defer { rollbackReadTransaction(db) }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-OpenClaw-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let data = events.rows.compactMap(\.line).joined(separator: "\n").data(using: .utf8)
        guard let data else { return nil }
        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            return nil
        }
        guard let parsed = OpenClawSessionParser.parseFileFull(at: temporaryURL, forcedID: sessionID) else {
            return nil
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: storageIdentity)[.size] as? NSNumber)?.intValue
        var result = Session(
            id: sessionID,
            source: .openclaw,
            startTime: parsed.startTime ?? sessionRow.startedAt ?? sessionRow.createdAt,
            endTime: parsed.endTime ?? sessionRow.endedAt ?? sessionRow.updatedAt ?? sessionRow.startedAt ?? sessionRow.createdAt,
            // The SQLite row is authoritative when it contains a value, and a
            // SQL NULL must not resurrect model metadata from the stale caller
            // snapshot. The transcript parser remains the only fallback because
            // it observes the same database snapshot.
            model: sessionRow.model ?? parsed.model,
            filePath: databaseURL.path,
            fileSizeBytes: fileSize,
            eventCount: parsed.eventCount,
            events: parsed.events,
            cwd: parsed.lightweightCwd,
            repoName: parsed.lightweightRepoName ?? "system",
            lightweightTitle: parsed.lightweightTitle ?? sessionRow.displayName,
            lightweightCommands: parsed.lightweightCommands,
            isHousekeeping: parsed.isHousekeeping,
            deletedAt: nil
        )
        // Both values were captured from the same canonical path and the same
        // SQLite read transaction as the parsed rows. Do not re-resolve the
        // alias or open a second connection here: an alias may be retargeted
        // while parsing, and a second connection may observe a different WAL
        // snapshot than the content returned above.
        result.sourceStorageIdentity = storageIdentity
        result.sourceStorageRevision = sessionRevisionKey(storageRevision)
        return result
    }

    private static func canonicalDatabasePath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func sessionRevisionKey(_ revision: SessionTelemetryRevision) -> String {
        switch revision {
        case .file(let signature):
            return "file:\(signature.mtime):\(signature.size)"
        case .logical(let value):
            return "logical:\(value)"
        }
    }

    private static func databaseVersionToken(fingerprint: String) -> String {
        "fingerprint:\(fingerprint)"
    }

    private static func makeSession(from row: SessionRow,
                                    databaseURL: URL,
                                    storageIdentity: String,
                                    resolvedAgentID: String,
                                    fileSize: Int?) -> Session {
        var session = Session(
            id: sessionID(agentID: resolvedAgentID, rawID: row.id),
            source: .openclaw,
            startTime: row.startedAt ?? row.createdAt,
            endTime: row.endedAt ?? row.updatedAt ?? row.startedAt ?? row.createdAt,
            model: row.model,
            filePath: databaseURL.path,
            fileSizeBytes: fileSize,
            eventCount: row.eventCount,
            events: [],
            cwd: nil,
            repoName: "system",
            lightweightTitle: row.displayName,
            lightweightCommands: nil
        )
        // Keep the physical target captured by discovery so later MainActor
        // publication guards can compare values without resolving symlinks.
        session.sourceStorageIdentity = storageIdentity
        return session
    }

    private static func querySessionRows(db: OpaquePointer?) -> [SessionRow]? {
        let sql = """
            SELECT session_id, created_at, updated_at, started_at, ended_at, model, display_name
            FROM session_windows
            ORDER BY updated_at DESC, session_id;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [SessionRow] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let id = text(statement, index: 0),
                  let createdAt = dateOrNull(statement, index: 1),
                  let updatedAt = dateOrNull(statement, index: 2),
                  let startedAt = dateOrNull(statement, index: 3),
                  let endedAt = dateOrNull(statement, index: 4),
                  let model = nullableText(statement, index: 5),
                  let displayName = nullableText(statement, index: 6),
                  let eventCount = eventCount(db: db, sessionID: id) else { return nil }
            rows.append(SessionRow(id: id,
                                   createdAt: createdAt,
                                   updatedAt: updatedAt,
                                   startedAt: startedAt,
                                   endedAt: endedAt,
                                   model: model,
                                   displayName: displayName,
                                   eventCount: eventCount))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { return nil }
        return rows
    }

    private static func querySessionRow(db: OpaquePointer?, sessionID: String) -> SessionRow? {
        let sql = """
            SELECT session_id, created_at, updated_at, started_at, ended_at, model, display_name
            FROM session_windows WHERE session_id = ? LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: sessionID)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = text(statement, index: 0),
              let createdAt = dateOrNull(statement, index: 1),
              let updatedAt = dateOrNull(statement, index: 2),
              let startedAt = dateOrNull(statement, index: 3),
              let endedAt = dateOrNull(statement, index: 4),
              let model = nullableText(statement, index: 5),
              let displayName = nullableText(statement, index: 6),
              let eventCount = eventCount(db: db, sessionID: id) else { return nil }
        return SessionRow(id: id,
                          createdAt: createdAt,
                          updatedAt: updatedAt,
                          startedAt: startedAt,
                          endedAt: endedAt,
                          model: model,
                          displayName: displayName,
                          eventCount: eventCount)
    }

    private static func eventCount(db: OpaquePointer?, sessionID: String) -> Int? {
        switch coldArchiveLookup(db: db, sessionID: sessionID) {
        case .present(let archive):
            return archive.eventCount
        case .malformed:
            return nil
        case .absent:
            break
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,
                                 "SELECT COUNT(*) FROM transcript_events WHERE session_id = ?;",
                                 -1,
                                 &statement,
                                 nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: sessionID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let value = sqlite3_column_int64(statement, 0)
        return value >= 0 ? Int(exactly: value) : nil
    }

    private static func coldArchiveLookup(db: OpaquePointer?, sessionID: String) -> ColdArchiveLookup {
        switch tablePresence(db, name: "session_transcript_cold_archives") {
        case .absent:
            return .absent
        case .malformed:
            return .malformed
        case .present:
            break
        }
        let sql = """
            SELECT generation, archive_name, archive_sha256, event_count, raw_bytes,
                   archive_bytes, last_seq, archived_at, storage
            FROM session_transcript_cold_archives
            WHERE session_id = ? LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return .malformed }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: sessionID)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { return .malformed }
        guard result == SQLITE_ROW else { return .absent }

        guard let generation = text(statement, index: 0),
              let archiveName = text(statement, index: 1),
              let archiveSHA256 = text(statement, index: 2),
              archiveSHA256.count == 64,
              let eventCount = nonNegativeInt(statement, index: 3),
              eventCount > 0,
              let rawBytes = nonNegativeUInt64(statement, index: 4),
              let archiveBytes = nonNegativeUInt64(statement, index: 5),
              let lastSequence = nonNegativeInt64(statement, index: 6),
              let archivedAt = nonNegativeInt64(statement, index: 7),
              let storage = text(statement, index: 8),
              storage == "file" || storage == "sqlite" else {
            return .malformed
        }
        return .present(ColdArchive(generation: generation,
                                    archiveName: archiveName,
                                    archiveSHA256: archiveSHA256,
                                    eventCount: eventCount,
                                    rawBytes: rawBytes,
                                    archiveBytes: archiveBytes,
                                    lastSequence: lastSequence,
                                    archivedAt: archivedAt,
                                    storage: storage))
    }

    private static func nonNegativeInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { return nil }
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else { return nil }
        return Int(exactly: value)
    }

    private static func nonNegativeUInt64(_ statement: OpaquePointer?, index: Int32) -> UInt64? {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { return nil }
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else { return nil }
        return UInt64(value)
    }

    private static func nonNegativeInt64(_ statement: OpaquePointer?, index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { return nil }
        let value = sqlite3_column_int64(statement, index)
        return value >= 0 ? value : nil
    }

    private static func queryEvents(db: OpaquePointer?, sessionID: String) -> EventQuery? {
        let coldArchive: ColdArchive?
        switch coldArchiveLookup(db: db, sessionID: sessionID) {
        case .present(let archive):
            coldArchive = archive
        case .absent:
            coldArchive = nil
        case .malformed:
            return nil
        }

        switch tablePresence(db, name: "transcript_events") {
        case .absent:
            return coldArchive.map {
                EventQuery(rows: [], bytesScanned: 0, hasCompressedPayload: false, coldArchive: $0, cancelled: false)
            }
        case .malformed:
            return nil
        case .present:
            break
        }
        let hasIdentities: Bool
        switch tablePresence(db, name: "transcript_event_identities") {
        case .absent:
            hasIdentities = false
        case .present:
            hasIdentities = true
        case .malformed:
            return nil
        }
        guard let columns = tableColumns(db, name: "transcript_events") else { return nil }
        let hasCompressedColumn = columns.contains("event_zstd")
        let hasUtf8BytesColumn = columns.contains("event_utf8_bytes")
        let eventColumn = hasCompressedColumn ? "event_json, event_zstd" : "event_json"
        let utf8Column = hasUtf8BytesColumn ? ", event_utf8_bytes" : ""
        let identityJoin = hasIdentities
            ? "LEFT JOIN transcript_event_identities AS identity ON identity.session_id = event.session_id AND identity.seq = event.seq"
            : ""
        let identityColumn = hasIdentities ? ", identity.event_id" : ""
        let sql = """
            SELECT event.seq, \(eventColumn), event.created_at\(utf8Column)\(identityColumn)
            FROM transcript_events AS event
            \(identityJoin)
            WHERE event.session_id = ?
            ORDER BY event.seq;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: sessionID)

        let eventJSONIndex: Int32 = 1
        let compressedIndex: Int32? = hasCompressedColumn ? 2 : nil
        let createdAtIndex: Int32 = hasCompressedColumn ? 3 : 2
        let utf8BytesIndex: Int32? = hasUtf8BytesColumn
            ? (hasCompressedColumn ? 4 : 3)
            : nil
        let identityIndex: Int32? = hasIdentities
            ? (hasCompressedColumn
                ? (hasUtf8BytesColumn ? 5 : 4)
                : (hasUtf8BytesColumn ? 4 : 3))
            : nil

        var rows: [EventRow] = []
        var bytesScanned: UInt64 = 0
        var hasCompressedPayload = false
        var stepResult: Int32 = SQLITE_ROW
        while stepResult == SQLITE_ROW {
            stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW || stepResult == SQLITE_DONE else { return nil }
            guard stepResult == SQLITE_ROW else { break }
            let sequence = sqlite3_column_int64(statement, 0)
            guard sequence >= 0,
                  let createdAt = dateOrNull(statement, index: createdAtIndex) else { return nil }
            let jsonType = sqlite3_column_type(statement, eventJSONIndex)
            let jsonBytes = payloadBytes(statement, index: eventJSONIndex)
            let compressedBytes = compressedIndex.map { payloadBytes(statement, index: $0) } ?? 0
            guard let nextBytes = adding(bytesScanned, jsonBytes),
                  let nextWithCompressed = adding(nextBytes, compressedBytes) else { return nil }
            bytesScanned = nextWithCompressed

            if Task.isCancelled {
                return EventQuery(rows: rows,
                                  bytesScanned: bytesScanned,
                                  hasCompressedPayload: hasCompressedPayload,
                                  coldArchive: coldArchive,
                                  cancelled: true)
            }

            if let utf8BytesIndex {
                let type = sqlite3_column_type(statement, utf8BytesIndex)
                guard type == SQLITE_NULL || type == SQLITE_INTEGER else { return nil }
                if type == SQLITE_INTEGER {
                    let value = sqlite3_column_int64(statement, utf8BytesIndex)
                    guard value >= 0, UInt64(value) == jsonBytes || jsonType == SQLITE_NULL else { return nil }
                }
            }

            let eventID = identityIndex.flatMap { optionalText(statement, index: $0) }
            if jsonType == SQLITE_NULL {
                guard let compressedIndex,
                      sqlite3_column_type(statement, compressedIndex) == SQLITE_BLOB,
                      compressedBytes > 0 else { return nil }
                hasCompressedPayload = true
                rows.append(EventRow(sequence: sequence,
                                     line: nil,
                                     eventID: eventID,
                                     createdAt: createdAt,
                                     bytes: compressedBytes,
                                     compressed: true))
                continue
            }
            guard jsonType == SQLITE_TEXT,
                  let raw = textData(statement, index: eventJSONIndex),
                  !raw.contains(0),
                  let line = String(data: raw, encoding: .utf8) else { return nil }
            let normalized = normalizedEventLine(line: line, eventID: eventID, createdAt: createdAt)
            guard let normalized else { return nil }
            rows.append(EventRow(sequence: sequence,
                                 line: normalized,
                                 eventID: eventID,
                                 createdAt: createdAt,
                                 bytes: jsonBytes,
                                 compressed: false))
        }
        return EventQuery(rows: rows,
                          bytesScanned: bytesScanned,
                          hasCompressedPayload: hasCompressedPayload,
                          coldArchive: coldArchive,
                          cancelled: false)
    }

    private static func normalizedEventLine(line: String,
                                            eventID: String?,
                                            createdAt: Date?) -> String? {
        guard let data = line.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if object["id"] == nil, let eventID, !eventID.isEmpty {
            object["id"] = eventID
        }
        if object["timestamp"] == nil, let createdAt {
            object["timestamp"] = ISO8601DateFormatter().string(from: createdAt)
        }
        guard JSONSerialization.isValidJSONObject(object),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: normalized, encoding: .utf8)
    }

    private static func applyingSessionMetadata(to telemetry: SessionTelemetry,
                                                session: Session,
                                                sessionRow: SessionRow,
                                                lineCount: Int) -> SessionTelemetry {
        // A SQL NULL is a valid, authoritative absence. Preserve only a model
        // independently observed in the transcript; never reuse a stale
        // Session snapshot that predates this database read.
        let model = sessionRow.model ?? telemetry.currentConfiguration?.model
        let modelComesFromSessionMetadata = sessionRow.model != nil
        guard model != nil || telemetry.currentConfiguration != nil else { return telemetry }
        guard modelComesFromSessionMetadata else { return telemetry }
        let observedAt = sessionRow.updatedAt ?? sessionRow.endedAt ?? sessionRow.startedAt
        let current = SessionConfiguration(
            model: model ?? telemetry.currentConfiguration?.model,
            reasoningEffort: telemetry.currentConfiguration?.reasoningEffort,
            observedAt: observedAt,
            anchorLine: max(0, lineCount),
            provenance: .sessionMetadata,
            modelObservedAt: model == nil ? telemetry.currentConfiguration?.modelObservedAt : observedAt,
            modelAnchorLine: model == nil ? telemetry.currentConfiguration?.modelAnchorLine : max(0, lineCount),
            modelProvenance: model == nil ? telemetry.currentConfiguration?.modelProvenance : .sessionMetadata,
            reasoningEffortObservedAt: telemetry.currentConfiguration?.reasoningEffortObservedAt,
            reasoningEffortAnchorLine: telemetry.currentConfiguration?.reasoningEffortAnchorLine,
            reasoningEffortProvenance: telemetry.currentConfiguration?.reasoningEffortProvenance)
        return SessionTelemetry(
            source: telemetry.source,
            initialConfiguration: telemetry.initialConfiguration,
            currentConfiguration: current,
            configurationChanges: telemetry.configurationChanges,
            usageSlices: telemetry.usageSlices,
            usageEvents: telemetry.usageEvents,
            usageSummary: telemetry.usageSummary,
            costEstimate: telemetry.costEstimate,
            weeklyQuotaEstimate: telemetry.weeklyQuotaEstimate,
            parserVersion: telemetry.parserVersion)
    }

    private static func unavailableScan(session: Session,
                                        sessionRow: SessionRow,
                                        reason: String,
                                        bytesScanned: UInt64) -> SessionTelemetryProviderScan {
        // Do not fall back to the caller's potentially stale Session metadata:
        // this path is used specifically when the transcript cannot provide a
        // model, so a live SQL NULL must remain unknown.
        let model = sessionRow.model
        let configuration = model.map {
            SessionConfiguration(model: $0,
                                 reasoningEffort: nil,
                                 observedAt: sessionRow.updatedAt ?? sessionRow.endedAt ?? sessionRow.startedAt,
                                 anchorLine: 0,
                                 provenance: .sessionMetadata)
        }
        let telemetry = SessionTelemetry(
            source: .openclaw,
            initialConfiguration: nil,
            currentConfiguration: configuration,
            configurationChanges: [],
            usageSlices: [],
            usageEvents: [],
            usageSummary: TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: [Self.usageFamily],
                usageFamilyConflict: false,
                displayTotalTokens: nil,
                unavailableReason: reason),
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private static func cancelledScan(bytesScanned: UInt64) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(
            source: .openclaw,
            initialConfiguration: nil,
            currentConfiguration: nil,
            configurationChanges: [],
            usageSlices: [],
            usageEvents: [],
            usageSummary: nil,
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private static func rawSessionID(from id: String) -> String? {
        guard id.hasPrefix("openclaw:") else { return id.isEmpty ? nil : id }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let rawID = String(parts[2])
        return rawID.isEmpty ? nil : rawID
    }

    private static func sessionID(agentID: String, rawID: String) -> String {
        "openclaw:\(agentID):\(rawID)"
    }

    private static func agentID(from url: URL) -> String {
        let parts = url.pathComponents
        if let index = parts.lastIndex(of: "agents"), index + 1 < parts.count {
            return parts[index + 1]
        }
        return "unknown"
    }

    private static func openReadOnly(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func databaseFingerprint(path: String) -> String? {
        let databaseURL = URL(fileURLWithPath: path)
        let walURL = URL(fileURLWithPath: path + "-wal")

        func filePart(_ url: URL) -> String {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return "missing"
            }
            let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = ((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).bitPattern
            return "\(number):\(size):\(modified)"
        }

        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        return "db=\(filePart(databaseURL));wal=\(filePart(walURL))"
    }

    private static func sqliteDataVersion(_ db: OpaquePointer?) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA data_version;", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return String(sqlite3_column_int64(statement, 0))
    }

    private static func beginReadTransaction(_ db: OpaquePointer?) -> Bool {
        sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK
    }

    private static func rollbackReadTransaction(_ db: OpaquePointer?) {
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
    }

    private enum TablePresence {
        case absent
        case present
        case malformed
    }

    private static func tablePresence(_ db: OpaquePointer?, name: String) -> TablePresence {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,
                                 "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
                                 -1,
                                 &statement,
                                 nil) == SQLITE_OK else { return .malformed }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: name)
        var found = false
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                found = true
            case SQLITE_DONE:
                return found ? .present : .absent
            default:
                return .malformed
            }
        }
    }

    private static func tableColumns(_ db: OpaquePointer?, name: String) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(name));", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let value = optionalText(statement, index: 1) else { return nil }
                columns.insert(value)
            case SQLITE_DONE:
                return columns
            default:
                return nil
            }
        }
    }

    private static func bind(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func text(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let data = textData(statement, index: index),
              !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func optionalText(_ statement: OpaquePointer?, index: Int32) -> String? {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_NULL || type == SQLITE_TEXT else { return nil }
        guard type == SQLITE_TEXT else { return nil }
        return text(statement, index: index)
    }

    /// Outer nil means an invalid SQLite storage class or invalid text. Inner
    /// nil means a valid SQL NULL, which is legal for OpenClaw metadata fields.
    private static func nullableText(_ statement: OpaquePointer?, index: Int32) -> String?? {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_NULL || type == SQLITE_TEXT else { return nil }
        if type == SQLITE_NULL { return .some(nil) }
        guard let data = textData(statement, index: index),
              !data.contains(0),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return .some(value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    }

    private static func textData(_ statement: OpaquePointer?, index: Int32) -> Data? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        let count = sqlite3_column_bytes(statement, index)
        guard count >= 0 else { return nil }
        return Data(bytes: pointer, count: Int(count))
    }

    private static func dateOrNull(_ statement: OpaquePointer?, index: Int32) -> Date?? {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_NULL || type == SQLITE_INTEGER || type == SQLITE_FLOAT else { return nil }
        guard type != SQLITE_NULL else { return Optional(nil) }
        let value = sqlite3_column_double(statement, index)
        guard value.isFinite, value >= 0 else { return nil }
        let seconds = value > 1e11 ? value / 1000 : value
        return Optional(Date(timeIntervalSince1970: seconds))
    }

    private static func payloadBytes(_ statement: OpaquePointer?, index: Int32) -> UInt64 {
        UInt64(max(0, sqlite3_column_bytes(statement, index)))
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private static func revisionDate(_ date: Date?) -> String {
        guard let date else { return "<null>" }
        return String(date.timeIntervalSince1970.bitPattern, radix: 16)
    }

    private static func feed(_ label: String, _ value: String, into hasher: inout SHA256) {
        hasher.update(data: Data(label.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(value.utf8))
        hasher.update(data: Data([0]))
    }

    private static func feedOptional(_ label: String,
                                     _ value: String?,
                                     into hasher: inout SHA256) {
        hasher.update(data: Data(label.utf8))
        hasher.update(data: Data([0]))
        if let value {
            hasher.update(data: Data([1]))
            hasher.update(data: Data(value.utf8))
        } else {
            hasher.update(data: Data([0]))
        }
        hasher.update(data: Data([0]))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

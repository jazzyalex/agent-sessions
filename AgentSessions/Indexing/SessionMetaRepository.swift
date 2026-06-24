import Foundation
import SQLite3

actor SessionMetaRepository {
    private let db: IndexDB
    init(db: IndexDB) { self.db = db }

    /// Derive deletedAt from OpenClaw `.jsonl.deleted.<timestamp>` filepath convention.
    private func deletedAt(fromPath path: String) -> Date? {
        guard let range = path.range(of: ".jsonl.deleted.") else { return nil }
        let tsString = String(path[range.upperBound...])
        // Unix epoch (numeric)
        if let ts = Double(tsString) { return Date(timeIntervalSince1970: ts) }
        // ISO 8601 with dashes replacing colons (e.g. 2026-03-16T21-20-30.062Z)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let colonized = tsString.replacingOccurrences(
            of: #"T(\d{2})-(\d{2})-(\d{2})"#,
            with: "T$1:$2:$3",
            options: .regularExpression)
        if let d = iso.date(from: colonized) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: colonized)
    }

    func fetchIndexedFilePaths(for source: SessionSource) async throws -> Set<String> {
        let rows = try await db.fetchIndexedFiles(for: source.rawValue)
        var paths: Set<String> = []
        paths.reserveCapacity(rows.count)
        for r in rows {
            paths.insert(r.path)
        }
        return paths
    }

    func fetchSessions(for source: SessionSource) async throws -> [Session] {
        let rows = try await db.fetchSessionMeta(for: source.rawValue)
        var out: [Session] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            let startDate = r.startTS == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(r.startTS))
            let endDate = r.endTS == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(r.endTS))
            let relationshipKind = Self.relationshipKind(for: r)
            let filePath = Self.filePath(for: r, relationshipKind: relationshipKind)
            let fileSizeBytes = Self.fileSizeBytes(for: r, relationshipKind: relationshipKind)
            let session = Session(
                id: r.sessionID,
                source: source,
                startTime: startDate,
                endTime: endDate,
                model: r.model,
                filePath: filePath,
                fileSizeBytes: fileSizeBytes,
                eventCount: r.messages,
                events: [],
                cwd: r.cwd,
                repoName: r.repo,
                lightweightTitle: r.title,
                isHousekeeping: r.isHousekeeping || (r.title == "No prompt" && (source == .codex || source == .claude)),
                codexInternalSessionIDHint: r.codexInternalSessionID,
                parentSessionID: r.parentSessionID,
                subagentType: r.subagentType,
                relationshipKind: relationshipKind,
                customTitle: r.customTitle,
                codexOriginator: r.codexOriginator,
                codexSource: r.codexSource,
                codexSurface: r.codexSurface.flatMap(CodexSessionSurface.init(rawValue:)),
                originator: r.originator,
                originSource: r.originSource,
                surface: r.surface.flatMap(SessionSurface.init(rawValue:)),
                reasoningEffort: r.reasoningEffort
            )
            // Augment with commands count from DB for lightweight filtering
            var enriched = session
            // Note: we avoid changing hashing; only attach metadata
            enriched = Session(id: session.id,
                               source: session.source,
                               startTime: session.startTime,
                               endTime: session.endTime,
                               model: session.model,
                               filePath: session.filePath,
                               fileSizeBytes: session.fileSizeBytes,
                               eventCount: session.eventCount,
                               events: session.events,
                               cwd: session.lightweightCwd,
                               repoName: r.repo,
                               lightweightTitle: session.lightweightTitle,
                               codexInternalSessionIDHint: session.codexInternalSessionIDHint,
                               parentSessionID: session.parentSessionID,
                               subagentType: session.subagentType,
                               relationshipKind: session.relationshipKind,
                               customTitle: session.customTitle,
                               codexOriginator: session.codexOriginator,
                               codexSource: session.codexSource,
                               codexSurface: session.codexSurface,
                               originator: session.originator,
                               originSource: session.originSource,
                               surface: session.surface,
                               reasoningEffort: session.reasoningEffort)
            // Reconstruct with lightweightCommands via Codable? Simpler: extend Session with helper? Keep minimal by using a factory below.
            out.append(Session(id: enriched.id,
                               source: enriched.source,
                               startTime: enriched.startTime,
                               endTime: enriched.endTime,
                               model: enriched.model,
                               filePath: enriched.filePath,
                               fileSizeBytes: enriched.fileSizeBytes,
                               eventCount: enriched.eventCount,
                               events: enriched.events,
                               cwd: enriched.lightweightCwd,
                               repoName: r.repo,
                               lightweightTitle: enriched.lightweightTitle,
                               lightweightCommands: r.commands,
                               isHousekeeping: r.isHousekeeping || (r.title == "No prompt" && (source == .codex || source == .claude)),
                               codexInternalSessionIDHint: enriched.codexInternalSessionIDHint,
                               parentSessionID: enriched.parentSessionID,
                               subagentType: enriched.subagentType,
                               relationshipKind: enriched.relationshipKind,
                               customTitle: enriched.customTitle,
                               codexOriginator: enriched.codexOriginator,
                               codexSource: enriched.codexSource,
                               codexSurface: enriched.codexSurface,
                               originator: enriched.originator,
                               originSource: enriched.originSource,
                               surface: enriched.surface,
                               reasoningEffort: enriched.reasoningEffort,
                               deletedAt: deletedAt(fromPath: r.path)))
        }
        return out
    }

    private static func relationshipKind(for row: SessionMetaRow) -> SessionRelationshipKind? {
        if row.codexSource == "side_chat"
            || row.originSource == "side_chat"
            || row.sessionID.hasPrefix("codex-side-chat-") {
            return .sideChat
        }
        return nil
    }

    private static func filePath(for row: SessionMetaRow,
                                 relationshipKind: SessionRelationshipKind?) -> String {
        guard relationshipKind == .sideChat,
              let threadID = sideChatThreadID(for: row) else {
            return row.path
        }
        return CodexSideChatLogReader.sideChatSessionPath(threadID: threadID)
    }

    private static func fileSizeBytes(for row: SessionMetaRow,
                                      relationshipKind: SessionRelationshipKind?) -> Int {
        guard relationshipKind == .sideChat,
              row.path.hasSuffix(".sqlite") else {
            return Int(row.size)
        }
        return 0
    }

    private static func sideChatThreadID(for row: SessionMetaRow) -> String? {
        if let id = row.codexInternalSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return id
        }
        let prefix = "codex-side-chat-"
        if row.sessionID.hasPrefix(prefix) {
            return String(row.sessionID.dropFirst(prefix.count))
        }
        return nil
    }
}

// no-op

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
            let session = Session(
                id: r.sessionID,
                source: source,
                startTime: startDate,
                endTime: endDate,
                model: r.model,
                filePath: r.path,
                fileSizeBytes: Int(r.size),
                eventCount: r.messages,
                events: [],
                cwd: r.cwd,
                repoName: r.repo,
                lightweightTitle: r.title,
                isHousekeeping: r.isHousekeeping || (r.title == "No prompt" && (source == .codex || source == .claude)),
                codexInternalSessionIDHint: r.codexInternalSessionID,
                parentSessionID: r.parentSessionID,
                subagentType: r.subagentType,
                customTitle: r.customTitle
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
                               customTitle: session.customTitle)
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
                               customTitle: enriched.customTitle,
                               deletedAt: deletedAt(fromPath: r.path)))
        }
        return out
    }
}

// no-op

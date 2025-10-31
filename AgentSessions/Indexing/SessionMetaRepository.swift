import Foundation
import SQLite3

actor SessionMetaRepository {
    private let db: IndexDB
    init(db: IndexDB) { self.db = db }

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
                lightweightTitle: r.title
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
                               lightweightTitle: session.lightweightTitle)
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
                               lightweightCommands: r.commands))
        }
        return out
    }
}

// no-op

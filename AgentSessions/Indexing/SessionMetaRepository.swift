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
            out.append(session)
        }
        return out
    }
}

// no-op

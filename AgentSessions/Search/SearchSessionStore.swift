import Foundation
import Dispatch

protocol SearchSessionStoring {
    func transcriptCache(for source: SessionSource) -> TranscriptCache?
    func updateSession(_ session: Session)
    func parseFull(session: Session) async -> Session?
}

final class SearchSessionStore: SearchSessionStoring {
    struct Adapter {
        var transcriptCache: TranscriptCache
        var update: (Session) -> Void
        var parseFull: (URL, String) -> Session?
    }

    private let adapters: [SessionSource: Adapter]

    init(adapters: [SessionSource: Adapter]) {
        self.adapters = adapters
    }

    func transcriptCache(for source: SessionSource) -> TranscriptCache? {
        adapters[source]?.transcriptCache
    }

    func updateSession(_ session: Session) {
        guard let update = adapters[session.source]?.update else { return }
        DispatchQueue.main.async {
            update(session)
        }
    }

    func parseFull(session: Session) async -> Session? {
        guard session.events.isEmpty else { return session }
        guard let adapter = adapters[session.source] else { return nil }

        let url = URL(fileURLWithPath: session.filePath)
        let forcedID = session.id
        return adapter.parseFull(url, forcedID)
    }
}

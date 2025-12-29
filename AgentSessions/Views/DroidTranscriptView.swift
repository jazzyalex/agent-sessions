import SwiftUI

struct DroidTranscriptView: View {
    @ObservedObject var indexer: DroidSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: droidSessionID,
            sessionIDLabel: "Droid",
            enableCaching: false
        )
    }

    private func droidSessionID(for session: Session) -> String? {
        session.id.isEmpty ? nil : session.id
    }
}


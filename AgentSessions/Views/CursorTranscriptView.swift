import SwiftUI

struct CursorTranscriptView: View {
    @ObservedObject var indexer: CursorSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: cursorSessionID,
            sessionIDLabel: "Cursor",
            enableCaching: false
        )
    }

    private func cursorSessionID(for session: Session) -> String? {
        session.id.isEmpty ? nil : session.id
    }
}

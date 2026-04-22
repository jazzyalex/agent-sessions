import SwiftUI
import AppKit

struct HermesTranscriptView: View {
    @ObservedObject var indexer: HermesSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: hermesSessionID,
            sessionIDLabel: "Hermes",
            enableCaching: false
        )
    }

    private func hermesSessionID(for session: Session) -> String? {
        let id = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}

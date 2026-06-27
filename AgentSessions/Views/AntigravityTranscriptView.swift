import SwiftUI
import AppKit

// Wrapper for transcript view using UnifiedTranscriptView with the Antigravity indexer
struct AntigravityTranscriptView: View {
    @ObservedObject var indexer: AntigravitySessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: antigravitySessionID,
            sessionIDLabel: "Antigravity",
            enableCaching: false
        )
    }

    private func antigravitySessionID(for session: Session) -> String? {
        AntigravitySessionIDHelper.deriveSessionID(from: session)
    }
}

import SwiftUI
import AppKit

// Wrapper for transcript view using UnifiedTranscriptView with the Antigravity indexer
struct GeminiTranscriptView: View {
    @ObservedObject var indexer: GeminiSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: geminiSessionID,
            sessionIDLabel: "Antigravity",
            enableCaching: false
        )
    }

    private func geminiSessionID(for session: Session) -> String? {
        GeminiSessionIDHelper.deriveSessionID(from: session)
    }
}

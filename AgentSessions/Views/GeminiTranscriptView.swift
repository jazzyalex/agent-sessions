import SwiftUI
import AppKit

// Wrapper for transcript view using UnifiedTranscriptView with Gemini indexer
struct GeminiTranscriptView: View {
    @ObservedObject var indexer: GeminiSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: geminiSessionID,
            sessionIDLabel: "Gemini",
            enableCaching: false
        )
    }

    private func geminiSessionID(for session: Session) -> String? {
        // Fallback to filename base sans extension
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        return nil
    }
}


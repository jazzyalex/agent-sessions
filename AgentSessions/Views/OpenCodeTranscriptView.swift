import SwiftUI
import AppKit

// Wrapper for transcript view using UnifiedTranscriptView with OpenCode indexer
struct OpenCodeTranscriptView: View {
    @ObservedObject var indexer: OpenCodeSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: opencodeSessionID,
            sessionIDLabel: "OpenCode",
            enableCaching: false
        )
    }

    private func opencodeSessionID(for session: Session) -> String? {
        // Use the session filename (ses_...) as the visible ID
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        return nil
    }
}


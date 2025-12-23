import SwiftUI
import AppKit

// Wrapper for transcript view using UnifiedTranscriptView with Copilot indexer
struct CopilotTranscriptView: View {
    @ObservedObject var indexer: CopilotSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: copilotSessionID,
            sessionIDLabel: "Copilot",
            enableCaching: false
        )
    }

    private func copilotSessionID(for session: Session) -> String? {
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        return nil
    }
}


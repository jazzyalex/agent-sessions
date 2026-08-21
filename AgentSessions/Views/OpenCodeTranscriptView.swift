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
        // session.id is the OpenCode ses_... id under both the JSON and SQLite backends.
        // Under SQLite every session shares filePath (opencode.db), so never derive from the path first.
        if !session.id.isEmpty { return session.id }
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8, base != "opencode" { return base }
        return nil
    }
}


import SwiftUI
import AppKit

struct BuddyTranscriptView: View {
    @ObservedObject var indexer: BuddySessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: buddySessionID,
            sessionIDLabel: "Buddy",
            enableCaching: false
        )
    }

    private func buddySessionID(for session: Session) -> String? {
        if let hint = session.codexInternalSessionIDHint, !hint.isEmpty { return hint }
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        return nil
    }
}

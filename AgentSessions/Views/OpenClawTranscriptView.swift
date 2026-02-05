import SwiftUI
import AppKit

// Wrapper for transcript view using UnifiedTranscriptView with OpenClaw indexer
struct OpenClawTranscriptView: View {
    @ObservedObject var indexer: OpenClawSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: openClawSessionID,
            sessionIDLabel: "OpenClaw",
            enableCaching: false
        )
    }

    private func openClawSessionID(for session: Session) -> String? {
        let name = URL(fileURLWithPath: session.filePath).lastPathComponent
        if let r = name.range(of: ".jsonl.deleted.") {
            let base = String(name[..<r.lowerBound])
            return base.count >= 8 ? base : nil
        }
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        return base.count >= 8 ? base : nil
    }
}


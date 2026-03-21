import SwiftUI

// Wrapper for transcript view using SessionTranscriptBuilder for consistent formatting
struct ClaudeTranscriptView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: claudeSessionID,
            sessionIDLabel: "Claude",
            enableCaching: false
        )
    }

    private func claudeSessionID(for session: Session) -> String? {
        // Prefer filename UUID: ~/.claude/projects/.../<UUID>.jsonl
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        // Fallback: scan events for sessionId field
        let limit = min(session.events.count, 2000)
        for e in session.events.prefix(limit) {
            let raw = e.rawJSON
            if let data = Data(base64Encoded: raw),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["sessionId"] as? String, !sid.isEmpty {
                return sid
            }
        }
        return nil
    }
}

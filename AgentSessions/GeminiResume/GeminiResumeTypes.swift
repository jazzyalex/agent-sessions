import Foundation

struct GeminiResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum GeminiStrategyUsed {
    case resumeByID
    case none
}

struct GeminiResumeResult {
    let launched: Bool
    let strategy: GeminiStrategyUsed
    let error: String?
    let command: String?
}

/// Extracts the Antigravity CLI conversation ID from the local artifact path.
/// Antigravity brain artifacts live under
/// `~/.gemini/antigravity/brain/<conversation-id>/*.md`.
enum GeminiSessionIDHelper {
    static func deriveSessionID(from session: Session) -> String? {
        let url = URL(fileURLWithPath: session.filePath)
        let id = url.deletingLastPathComponent().lastPathComponent
        return id.isEmpty ? nil : id
    }
}

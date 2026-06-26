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
    static func artifactID(fromArtifactURL url: URL) -> String? {
        guard let conversationID = conversationID(fromArtifactURL: url) else { return nil }
        let artifact = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artifact.isEmpty else { return conversationID }
        return "\(conversationID)#\(artifact)"
    }

    static func conversationID(fromArtifactURL url: URL) -> String? {
        let comps = url.pathComponents
        if let i = comps.firstIndex(of: "brain"), i + 1 < comps.count {
            let id = comps[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }
        let id = url.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    static func deriveSessionID(from session: Session) -> String? {
        let url = URL(fileURLWithPath: session.filePath)
        if let id = conversationID(fromArtifactURL: url) {
            return id
        }

        let trimmed = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let separator = trimmed.firstIndex(of: "#") {
            let prefix = String(trimmed[..<separator])
            return prefix.isEmpty ? nil : prefix
        }
        return trimmed
    }
}

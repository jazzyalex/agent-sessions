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

/// Extracts the Gemini CLI session UUID from the session's JSON file.
/// Session.id for Gemini is a sha256 hash of the file path (used for UI stability),
/// not the CLI sessionId that `gemini --resume` expects.
///
/// Performs a bounded regex scan (up to 64 KB) for the top-level `sessionId` or
/// `session_id` keys only — the generic `id` key is excluded to avoid capturing
/// nested message IDs. Falls back to a small JSON parse of the file head if
/// the regex doesn't match.
enum GeminiSessionIDHelper {
    private static let scanLimit = 65_536
    // Match any non-empty string value for sessionId/session_id (not just UUIDs)
    private static let pattern = try! NSRegularExpression(
        pattern: #""(?:sessionId|session_id)"\s*:\s*"([^"]+)""#
    )

    static func deriveSessionID(from session: Session) -> String? {
        let path = session.filePath
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: scanLimit)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = pattern.firstMatch(in: text, range: range),
           let idRange = Range(match.range(at: 1), in: text) {
            let sid = String(text[idRange])
            if !sid.isEmpty { return sid }
        }
        return nil
    }
}

import Foundation

/// Shared helpers for deriving Claude session IDs and project roots.
/// Used by UnifiedSessionsView for resume and copy-resume-command.
enum ClaudeSessionIDHelper {

    /// Extracts the Claude session UUID suitable for `claude --resume`.
    /// For subagent sessions (.../\<parentUUID\>/subagents/agent-*.jsonl),
    /// returns the parent session UUID since that's what the CLI expects.
    static func deriveSessionID(from session: Session) -> String? {
        let url = URL(fileURLWithPath: session.filePath)
        let base = url.deletingPathExtension().lastPathComponent

        // Direct session: filename IS the UUID
        if looksLikeUUID(base) { return base }

        // Subagent session: .../\<parentUUID\>/subagents/agent-*.jsonl
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            let parentSessionName = parent.deletingLastPathComponent().lastPathComponent
            if looksLikeUUID(parentSessionName) { return parentSessionName }
        }

        // Fallback: scan events for a sessionId field
        let limit = min(session.events.count, 2000)
        for e in session.events.prefix(limit) {
            let raw = e.rawJSON
            if let data = Data(base64Encoded: raw),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["sessionId"] as? String, looksLikeUUID(sid) {
                return sid
            }
        }
        return nil
    }

    /// Returns the Claude project root directory for a session.
    /// `claude --resume` only works when the cwd matches the project root,
    /// so we read `originalPath` from the project's sessions-index.json.
    /// Falls back to session.cwd, then to ClaudeResumeSettings.defaultWorkingDirectory.
    @MainActor
    static func projectRoot(for session: Session, settings: ClaudeResumeSettings? = nil) -> URL? {
        let settings = settings ?? .shared
        let url = URL(fileURLWithPath: session.filePath)
        var projectDir = url.deletingLastPathComponent()
        if projectDir.lastPathComponent == "subagents" {
            projectDir = projectDir.deletingLastPathComponent().deletingLastPathComponent()
        }
        let indexFile = projectDir.appendingPathComponent("sessions-index.json")
        if let data = try? Data(contentsOf: indexFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let original = json["originalPath"] as? String, !original.isEmpty {
            return URL(fileURLWithPath: original)
        }
        // Fallback chain matching effectiveWorkingDirectory behavior
        if let cwd = session.cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd)
        }
        if !settings.defaultWorkingDirectory.isEmpty {
            return URL(fileURLWithPath: settings.defaultWorkingDirectory)
        }
        return nil
    }

    /// UUID v4 format check: 8-4-4-4-12 hex chars.
    static func looksLikeUUID(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                options: .regularExpression) != nil
    }
}

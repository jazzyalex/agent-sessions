import Foundation

/// App-only half of `ClaudeSessionIDHelper`: resolving a project root falls back to
/// `ClaudeResumeSettings`, which is an `ObservableObject` and stays out of the shared core.
extension ClaudeSessionIDHelper {
    /// Returns the Claude project root directory for a session.
    /// `claude --resume` only works when the cwd matches the project root,
    /// so we read `originalPath` from the project's sessions-index.json.
    /// Falls back to session.cwd, then to ClaudeResumeSettings.defaultWorkingDirectory.
    @MainActor
    static func projectRoot(for session: Session, settings: ClaudeResumeSettings? = nil) -> URL? {
        if let recorded = recordedProjectRoot(for: session) {
            return recorded
        }
        let settings = settings ?? .shared
        if !settings.defaultWorkingDirectory.isEmpty {
            return URL(fileURLWithPath: settings.defaultWorkingDirectory)
        }
        return nil
    }
}

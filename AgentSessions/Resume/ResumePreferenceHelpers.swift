import Foundation

/// Shared helpers for resume-related preferences.
enum ResumePreferenceHelpers {
    /// Reads the iTerm preference for an agent, inheriting from Claude/Codex
    /// when the agent's own key has never been explicitly set.
    static func resolvePreferITerm(ownKey: String, defaults: UserDefaults = .standard) -> Bool {
        if let explicit = defaults.object(forKey: ownKey) as? Bool {
            return explicit
        }
        let claudeITerm = defaults.object(forKey: ClaudeResumeSettings.Keys.preferITerm) as? Bool ?? false
        let codexITerm = (defaults.string(forKey: CodexResumeSettings.Keys.defaultLaunchMode) == CodexLaunchMode.iterm.rawValue)
        return claudeITerm || codexITerm
    }
}

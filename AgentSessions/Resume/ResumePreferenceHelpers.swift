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

    static let terminalKindKey = "AgentSessionsResumeTerminalKind"

    /// Reads the shared terminal kind preference, migrating from legacy preferITerm booleans on first read.
    static func resolveTerminalKind(defaults: UserDefaults = .standard) -> TerminalKind {
        if let raw = defaults.string(forKey: terminalKindKey),
           let kind = TerminalKind(rawValue: raw) {
            return kind
        }
        // Migration: if any agent had preferITerm=true, default to .iterm2; else .terminalApp
        let claudeITerm = defaults.object(forKey: ClaudeResumeSettings.Keys.preferITerm) as? Bool ?? false
        let codexITerm = defaults.string(forKey: CodexResumeSettings.Keys.defaultLaunchMode) == CodexLaunchMode.iterm.rawValue
        let result: TerminalKind = (claudeITerm || codexITerm) ? .iterm2 : .terminalApp
        setTerminalKind(result, defaults: defaults)
        return result
    }

    static func setTerminalKind(_ kind: TerminalKind, defaults: UserDefaults = .standard) {
        defaults.set(kind.rawValue, forKey: terminalKindKey)
    }
}

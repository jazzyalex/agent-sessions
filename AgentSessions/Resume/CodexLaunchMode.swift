import Foundation

enum CodexLaunchMode: String, CaseIterable, Identifiable {
    case embedded
    case terminal
    case iterm
    case warp
    case warpPreview
    case ghostty
    case kitty
    case wezTerm

    var id: String { rawValue }

    static func selectedResumeTerminalTitle(defaults: UserDefaults = .standard) -> String {
        if defaults.string(forKey: ResumePreferenceHelpers.terminalKindKey) != nil {
            return ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults).displayName
        }
        if let raw = defaults.string(forKey: CodexResumeSettings.Keys.defaultLaunchMode),
           let mode = CodexLaunchMode(rawValue: raw),
           mode != .embedded {
            return mode.title
        }

        let claudePrefersITerm = defaults.object(forKey: ClaudeResumeSettings.Keys.preferITerm) as? Bool ?? false
        return claudePrefersITerm ? CodexLaunchMode.iterm.title : CodexLaunchMode.terminal.title
    }

    var title: String {
        switch self {
        case .embedded:
            return "Embedded"
        case .terminal:
            return "Terminal"
        case .iterm:
            return "iTerm2"
        case .warp:
            return "Warp"
        case .warpPreview:
            return "WarpPreview"
        case .ghostty:
            return "Ghostty"
        case .kitty:
            return "Kitty"
        case .wezTerm:
            return "WezTerm"
        }
    }

    var terminalKind: TerminalKind {
        switch self {
        case .embedded, .terminal: return .terminalApp
        case .iterm:               return .iterm2
        case .warp:                return .warp
        case .warpPreview:         return .warpPreview
        case .ghostty:             return .ghostty
        case .kitty:               return .kitty
        case .wezTerm:             return .wezTerm
        }
    }

    var help: String {
        switch self {
        case .embedded:
            return "Run Codex inside Agent Sessions and stream output here."
        case .terminal:
            return "Open Codex in Terminal.app and continue the session there."
        case .iterm:
            return "Open Codex in iTerm2 and continue the session there."
        case .warp:
            return "Open in Warp and continue the session there."
        case .warpPreview:
            return "Open in WarpPreview and continue the session there."
        case .ghostty:
            return "Open in Ghostty and continue the session there."
        case .kitty:
            return "Open in Kitty and continue the session there."
        case .wezTerm:
            return "Open in WezTerm and continue the session there."
        }
    }
}

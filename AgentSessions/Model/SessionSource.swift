import Foundation

/// Identifies the source/type of a session (Codex CLI vs Claude Code)
public enum SessionSource: String, Codable, CaseIterable, Sendable {
    case codex = "codex"
    case claude = "claude"
    case gemini = "gemini"
    case opencode = "opencode"
    case copilot = "copilot"
    case droid = "droid"

    public var displayName: String {
        switch self {
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .copilot: return "Copilot CLI"
        case .droid: return "Droid"
        }
    }

    public var iconName: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "command"
        case .gemini: return "sparkles"
        case .opencode: return "chevron.left.slash.chevron.right"
        case .copilot: return "bolt.horizontal.circle"
        case .droid: return "d.circle"
        }
    }
}

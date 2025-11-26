import Foundation

/// Identifies the source/type of a session (Codex CLI vs Claude Code)
public enum SessionSource: String, Codable, CaseIterable, Sendable {
    case codex = "codex"
    case claude = "claude"
    case gemini = "gemini"
    case opencode = "opencode"

    public var displayName: String {
        switch self {
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        }
    }

    public var iconName: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "command"
        case .gemini: return "sparkles"
        case .opencode: return "chevron.left.slash.chevron.right"
        }
    }
}

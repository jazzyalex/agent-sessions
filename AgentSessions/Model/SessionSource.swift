import Foundation

/// Identifies the source/type of a session (Codex CLI vs Claude Code)
public enum SessionSource: String, Codable, CaseIterable, Sendable {
    case codex = "codex"
    case claude = "claude"
    case antigravity = "antigravity"
    case opencode = "opencode"
    case hermes = "hermes"
    case copilot = "copilot"
    case droid = "droid"
    case openclaw = "openclaw"
    case cursor = "cursor"
    case pi = "pi"
    case kimi = "kimi"
    case grok = "grok"
    case qwen = "qwen"
    case devin = "devin"

    public var displayName: String {
        switch self {
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .hermes: return "Hermes"
        case .copilot: return "Copilot CLI"
        case .droid: return "Droid"
        case .openclaw: return "OpenClaw"
        case .cursor: return "Cursor"
        case .pi: return "Pi"
        case .kimi: return "Kimi Code"
        case .grok: return "Grok CLI"
        case .qwen: return "Qwen Code"
        case .devin: return "Devin CLI"
        }
    }

    public var iconName: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "command"
        case .antigravity: return "sparkles"
        case .opencode: return "chevron.left.slash.chevron.right"
        case .hermes: return "brain"
        case .copilot: return "bolt.horizontal.circle"
        case .droid: return "d.circle"
        case .openclaw: return "pawprint"
        case .cursor: return "cursorarrow.rays"
        case .pi: return "p.circle"
        case .kimi: return "k.circle"
        case .grok: return "g.circle"
        case .qwen: return "q.circle"
        case .devin: return "cpu"
        }
    }

    public var versionIntroduced: String {
        switch self {
        case .codex, .claude:   return "1.0"
        case .antigravity:      return "4.0"
        case .opencode:         return "2.8"
        case .hermes:           return "3.7"
        case .copilot:          return "2.11"
        case .droid:            return "3.0"
        case .openclaw:         return "3.1"
        case .cursor:           return "3.2"
        case .pi:               return "3.8"
        case .kimi:             return "4.7"
        case .grok:             return "4.8"
        case .qwen:             return "5.0"
        case .devin:            return "5.1"
        }
    }

    public var featureDescription: String {
        switch self {
        case .codex:    return "Track your Codex CLI coding sessions"
        case .claude:   return "Browse your Claude Code conversations"
        case .antigravity: return "Browse your Antigravity CLI conversations"
        case .opencode: return "Review your OpenCode sessions"
        case .hermes:   return "Browse your Hermes sessions and resume by ID"
        case .copilot:  return "Browse your GitHub Copilot chat history"
        case .droid:    return "View your Droid agent sessions"
        case .openclaw: return "Explore your OpenClaw conversations"
        case .cursor:   return "Import and search your Cursor AI sessions"
        case .pi:       return "Browse your Pi coding agent sessions"
        case .kimi:     return "Browse your Kimi Code sessions"
        case .grok:     return "Browse your Grok CLI sessions"
        case .qwen:     return "Browse your Qwen Code sessions"
        case .devin:    return "Browse your Devin CLI sessions"
        }
    }
}

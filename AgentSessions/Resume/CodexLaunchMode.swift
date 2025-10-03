import Foundation

enum CodexLaunchMode: String, CaseIterable, Identifiable {
    case embedded
    case terminal
    case iterm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedded:
            return "Embedded"
        case .terminal:
            return "Terminal"
        case .iterm:
            return "iTerm2"
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
        }
    }
}

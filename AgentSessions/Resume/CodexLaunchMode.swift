import Foundation

enum CodexLaunchMode: String, CaseIterable, Identifiable {
    case embedded
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedded:
            return "Embedded"
        case .terminal:
            return "Terminal"
        }
    }

    var help: String {
        switch self {
        case .embedded:
            return "Run Codex inside Agent Sessions and stream output here."
        case .terminal:
            return "Open Codex in Terminal.app and continue the session there."
        }
    }
}

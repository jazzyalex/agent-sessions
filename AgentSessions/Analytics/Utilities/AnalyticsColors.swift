import SwiftUI

/// Color utilities for Analytics feature
/// Uses existing agent brand colors from the main app
extension Color {
    /// Codex CLI brand color
    static let agentCodex = Color.blue

    /// Claude Code brand color (terracotta)
    static let agentClaude = Color(red: 204/255, green: 121/255, blue: 90/255)

    /// Gemini brand color
    static let agentGemini = Color.teal

    /// Get the brand color for a given session source
    static func agentColor(for source: SessionSource) -> Color {
        switch source {
        case .codex: return .agentCodex
        case .claude: return .agentClaude
        case .gemini: return .agentGemini
        }
    }

    /// Get the brand color for a session source string
    static func agentColor(for sourceString: String) -> Color {
        let lower = sourceString.lowercased()
        if lower.contains("codex") {
            return .agentCodex
        } else if lower.contains("claude") {
            return .agentClaude
        } else if lower.contains("gemini") {
            return .agentGemini
        } else {
            return .accentColor
        }
    }
}

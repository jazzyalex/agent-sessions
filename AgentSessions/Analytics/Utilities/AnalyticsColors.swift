import SwiftUI
import AppKit

/// Color utilities for Analytics feature
/// Uses existing agent brand colors from the main app
extension Color {
    /// Codex CLI brand color (softened coral)
    static let agentCodex = Color(hex: "D7745E")

    /// Claude Code brand color (muted lavender)
    static let agentClaude = Color(hex: "8F86B8")

    /// Gemini brand color
    static let agentGemini = Color.teal
    /// OpenCode brand color
    static let agentOpenCode = Color.purple
    /// Copilot brand color
    static let agentCopilot = Color(red: 0.90, green: 0.20, blue: 0.60)
    /// Droid brand color
    static let agentDroid = Color(red: 0.16, green: 0.68, blue: 0.28)

    // MARK: - Monochrome Support

    /// Monochrome gray shades for each agent (maintains visual distinction)
    static let agentCodexGray = Color(white: 0.4)   // Darker gray
    static let agentClaudeGray = Color(white: 0.5)  // Medium gray
    static let agentGeminiGray = Color(white: 0.6)  // Lighter gray
    static let agentOpenCodeGray = Color(white: 0.7) // Lightest gray
    static let agentCopilotGray = Color(white: 0.75) // Very light gray
    static let agentDroidGray = Color(white: 0.8)

    /// Get the brand color for a given session source
    static func agentColor(for source: SessionSource) -> Color {
        switch source {
        case .codex: return .agentCodex
        case .claude: return .agentClaude
        case .gemini: return .agentGemini
        case .opencode: return .agentOpenCode
        case .copilot: return .agentCopilot
        case .droid: return .agentDroid
        }
    }

    /// Get the brand color or monochrome gray for a given session source
    static func agentColor(for source: SessionSource, monochrome: Bool) -> Color {
        if monochrome {
            switch source {
            case .codex: return .agentCodexGray
            case .claude: return .agentClaudeGray
            case .gemini: return .agentGeminiGray
            case .opencode: return .agentOpenCodeGray
            case .copilot: return .agentCopilotGray
            case .droid: return .agentDroidGray
            }
        } else {
            return agentColor(for: source)
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
        } else if lower.contains("opencode") {
            return .agentOpenCode
        } else if lower.contains("copilot") {
            return .agentCopilot
        } else if lower.contains("droid") {
            return .agentDroid
        } else {
            return .accentColor
        }
    }

    /// Get the brand color or monochrome gray for a session source string
    static func agentColor(for sourceString: String, monochrome: Bool) -> Color {
        if monochrome {
            let lower = sourceString.lowercased()
            if lower.contains("codex") {
                return .agentCodexGray
            } else if lower.contains("claude") {
                return .agentClaudeGray
            } else if lower.contains("gemini") {
                return .agentGeminiGray
            } else if lower.contains("opencode") {
                return .agentOpenCodeGray
            } else if lower.contains("copilot") {
                return .agentCopilotGray
            } else if lower.contains("droid") {
                return .agentDroidGray
            } else {
                return .secondary
            }
        } else {
            return agentColor(for: sourceString)
        }
    }
}

// MARK: - Syntax Highlighting Colors

/// Syntax highlighting color types for transcript views
enum SyntaxColorType {
    // Terminal mode
    case command        // Orange
    case userInput      // Blue
    case toolOutput     // Teal
    case error          // Red
    case assistant      // Gray

    // JSON mode
    case jsonKey        // Pink
    case jsonString     // Blue
    case jsonNumber     // Green
    case jsonKeyword    // Purple
}

extension NSColor {
    /// Get syntax highlighting color with optional monochrome support
    static func syntaxColor(_ type: SyntaxColorType, monochrome: Bool = false) -> NSColor {
        if monochrome {
            // Use different gray shades for distinction
            switch type {
            case .command: return NSColor(white: 0.4, alpha: 1.0)
            case .userInput: return NSColor(white: 0.5, alpha: 1.0)
            case .toolOutput: return NSColor(white: 0.6, alpha: 1.0)
            case .error: return NSColor(white: 0.3, alpha: 1.0)  // Darkest for emphasis
            case .assistant: return NSColor.secondaryLabelColor
            case .jsonKey: return NSColor(white: 0.45, alpha: 1.0)
            case .jsonString: return NSColor(white: 0.55, alpha: 1.0)
            case .jsonNumber: return NSColor(white: 0.65, alpha: 1.0)
            case .jsonKeyword: return NSColor(white: 0.35, alpha: 1.0)
            }
        } else {
            // Use semantic system colors
            switch type {
            case .command: return NSColor.systemOrange
            case .userInput: return NSColor.systemBlue
            case .toolOutput: return NSColor.systemTeal
            case .error: return NSColor.systemRed
            case .assistant: return NSColor.secondaryLabelColor
            case .jsonKey: return NSColor.systemPink
            case .jsonString: return NSColor.systemBlue
            case .jsonNumber: return NSColor.systemGreen
            case .jsonKeyword: return NSColor.systemPurple
            }
        }
    }
}

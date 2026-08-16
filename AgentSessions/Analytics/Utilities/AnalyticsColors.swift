import SwiftUI
import AppKit

/// Color utilities for Analytics feature
/// Uses existing agent brand colors from the main app
extension Color {
    /// Codex CLI brand color (deep blue)
    static let agentCodex: Color = TranscriptColorSystem.agentBrandAccent(source: .codex)

    /// Claude Code brand color (warm brown)
    static let agentClaude: Color = TranscriptColorSystem.agentBrandAccent(source: .claude)

    /// Antigravity brand color
    static let agentAntigravity: Color = TranscriptColorSystem.agentBrandAccent(source: .antigravity)
    /// OpenCode brand color
    static let agentOpenCode: Color = TranscriptColorSystem.agentBrandAccent(source: .opencode)
    /// Hermes brand color
    static let agentHermes: Color = TranscriptColorSystem.agentBrandAccent(source: .hermes)
    /// Copilot brand color
    static let agentCopilot: Color = TranscriptColorSystem.agentBrandAccent(source: .copilot)
    /// Droid brand color
    static let agentDroid: Color = TranscriptColorSystem.agentBrandAccent(source: .droid)
    /// OpenClaw brand color
    static let agentOpenClaw: Color = TranscriptColorSystem.agentBrandAccent(source: .openclaw)
    /// Cursor brand color
    static let agentCursor: Color = TranscriptColorSystem.agentBrandAccent(source: .cursor)
    /// Pi brand color
    static let agentPi: Color = TranscriptColorSystem.agentBrandAccent(source: .pi)
    /// Kimi Code brand color
    static let agentKimi: Color = TranscriptColorSystem.agentBrandAccent(source: .kimi)
    /// Grok CLI brand color
    static let agentGrok: Color = TranscriptColorSystem.agentBrandAccent(source: .grok)

    // MARK: - Monochrome Support

    /// Monochrome gray shades for each agent (maintains visual distinction)
    static let agentCodexGray = Color(white: 0.4)   // Darker gray
    static let agentClaudeGray = Color(white: 0.5)  // Medium gray
    static let agentAntigravityGray = Color(white: 0.6)  // Lighter gray
    static let agentOpenCodeGray = Color(white: 0.7) // Lightest gray
    static let agentHermesGray = Color(white: 0.72)
    static let agentCopilotGray = Color(white: 0.75) // Very light gray
    static let agentDroidGray = Color(white: 0.8)
    static let agentOpenClawGray = Color(white: 0.85)
    static let agentCursorGray = Color(white: 0.9)
    static let agentPiGray = Color(white: 0.68)
    static let agentKimiGray = Color(white: 0.66)
    static let agentGrokGray = Color(white: 0.62)

    /// Get the brand color for a given session source.
    ///
    /// Reads the registry rather than re-listing the twelve `agentX` constants above: the
    /// constants are themselves `agentBrandAccent`, which is now descriptor-driven, so a
    /// new source picks its color up here for free.
    static func agentColor(for source: SessionSource) -> Color {
        Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: source))
    }

    /// Get the brand color or monochrome gray for a given session source
    static func agentColor(for source: SessionSource, monochrome: Bool) -> Color {
        if monochrome {
            // Same shades as the `agentXGray` constants above, carried per source on the
            // descriptor (`monochromeWhite`) and pinned by test goldens.
            return Color(white: source.descriptor.monochromeWhite)
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
            return .agentAntigravity
        } else if lower.contains("opencode") {
            return .agentOpenCode
        } else if lower.contains("hermes") {
            return .agentHermes
        } else if lower.contains("copilot") {
            return .agentCopilot
        } else if lower.contains("droid") {
            return .agentDroid
        } else if lower.contains("openclaw") || lower.contains("clawdbot") {
            return .agentOpenClaw
        } else if lower.contains("cursor") {
            return .agentCursor
        } else if lower == "pi" || lower.contains("pi coding") {
            return .agentPi
        } else if lower.contains("kimi") {
            return .agentKimi
        } else if lower.contains("grok") {
            return .agentGrok
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
                return .agentAntigravityGray
            } else if lower.contains("opencode") {
                return .agentOpenCodeGray
            } else if lower.contains("hermes") {
                return .agentHermesGray
            } else if lower.contains("copilot") {
                return .agentCopilotGray
            } else if lower.contains("droid") {
                return .agentDroidGray
            } else if lower.contains("openclaw") || lower.contains("clawdbot") {
                return .agentOpenClawGray
            } else if lower.contains("cursor") {
                return .agentCursorGray
            } else if lower == "pi" || lower.contains("pi coding") {
                return .agentPiGray
            } else if lower.contains("kimi") {
                return .agentKimiGray
            } else if lower.contains("grok") {
                return .agentGrokGray
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
    case toolOutput     // Green
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
            case .toolOutput: return NSColor.systemGreen
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

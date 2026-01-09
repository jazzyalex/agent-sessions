import SwiftUI
import AppKit

/// Single source of truth for transcript semantic colors.
///
/// This intentionally separates:
/// - semantic categories (user/tools/output/error)
/// - agent brand colors (per SessionSource)
///
/// Agent brand colors should remain stable for recognition. If an agent brand hue
/// overlaps a semantic color (for example green vs tool success), disambiguation
/// should come from styling (strip treatment), not hue remapping.
enum TranscriptColorSystem {
    enum SemanticRole {
        case user
        case toolCall
        case toolOutputSuccess
        case toolOutputError
        case error
    }

    static func semanticAccent(_ role: SemanticRole) -> NSColor {
        switch role {
        case .user:
            return NSColor.systemBlue
        case .toolCall:
            return NSColor.systemPurple
        case .toolOutputSuccess:
            return NSColor.systemGreen
        case .toolOutputError, .error:
            return NSColor.systemRed
        }
    }

    static func semanticAccent(_ role: SemanticRole) -> Color {
        Color(nsColor: semanticAccent(role))
    }

    static func agentBrandAccent(source: SessionSource) -> NSColor {
        // Keep these stable across the app.
        switch source {
        case .codex:
            // Softened coral
            return NSColor(calibratedRed: 0.84, green: 0.46, blue: 0.37, alpha: 1.0)
        case .claude:
            // Muted lavender
            return NSColor(calibratedRed: 0.56, green: 0.53, blue: 0.72, alpha: 1.0)
        case .gemini:
            // Teal
            return NSColor.systemTeal
        case .opencode:
            // Purple
            return NSColor.systemPurple
        case .copilot:
            // Magenta-ish
            return NSColor(calibratedRed: 0.90, green: 0.20, blue: 0.60, alpha: 1.0)
        case .droid:
            // Green brand (disambiguation handled via styling, not hue).
            return NSColor(calibratedRed: 0.16, green: 0.68, blue: 0.28, alpha: 1.0)
        }
    }

    static func agentBrandAccent(source: SessionSource) -> Color {
        Color(nsColor: agentBrandAccent(source: source))
    }
}


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
        case assistant
        case toolCall
        case toolOutputSuccess
        case toolOutputError
        case error
        case plan
        case code
        case diff
        case reviewSummary
    }

    static func semanticAccent(_ role: SemanticRole) -> NSColor {
        switch role {
        case .user:
            return NSColor.systemBlue
        case .assistant:
            // Single, agent-independent accent for the assistant's voice.
            // Warm brown (formerly the Claude brand hue), kept clear of the
            // blue/purple/green/red used by the other semantic roles so the
            // transcript reads the same regardless of which agent produced it.
            // Appearance-adaptive: darkened in light mode so the small semibold
            // role label clears AA contrast on the near-white card background.
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.74, green: 0.46, blue: 0.22, alpha: 1.0)
                    : NSColor(calibratedRed: 0.55, green: 0.34, blue: 0.12, alpha: 1.0)
            }
        case .toolCall:
            return NSColor.systemPurple
        case .toolOutputSuccess:
            return NSColor.systemGreen
        case .toolOutputError, .error:
            return NSColor.systemRed
        case .plan:
            return NSColor.systemTeal
        case .code:
            return NSColor.systemIndigo
        case .diff:
            return NSColor.systemOrange
        case .reviewSummary:
            return NSColor.systemCyan
        }
    }

    static func semanticAccent(_ role: SemanticRole) -> Color {
        Color(nsColor: semanticAccent(role))
    }

    static func agentBrandAccent(source: SessionSource) -> NSColor {
        // Brand hues, stable across the app. Each is wrapped in `adaptiveBrand`
        // so the light-mode value is preserved while dark mode gets a brighter
        // variant (the calibrated hues were tuned on light and read muddy on a
        // dark background). System dynamic colors already adapt, so they pass
        // through unchanged.
        switch source {
        case .codex:
            // Deep blue
            return adaptiveBrand(NSColor(calibratedRed: 0.14, green: 0.30, blue: 0.60, alpha: 1.0))
        case .claude:
            // Warm brown
            return adaptiveBrand(NSColor(calibratedRed: 0.74, green: 0.46, blue: 0.22, alpha: 1.0))
        case .antigravity:
            // Teal
            return NSColor.systemTeal
        case .opencode:
            // Purple
            return NSColor.systemPurple
        case .hermes:
            // Olive-gold accent, shifted away from Claude/OpenClaw warm oranges.
            return adaptiveBrand(NSColor(calibratedRed: 0.62, green: 0.64, blue: 0.18, alpha: 1.0))
        case .copilot:
            // Magenta-ish
            return adaptiveBrand(NSColor(calibratedRed: 0.90, green: 0.20, blue: 0.60, alpha: 1.0))
        case .droid:
            // Green brand (disambiguation handled via styling, not hue).
            return adaptiveBrand(NSColor(calibratedRed: 0.16, green: 0.68, blue: 0.28, alpha: 1.0))
        case .openclaw:
            // Coral-orange accent, kept warm but separated from Claude/Hermes.
            return adaptiveBrand(NSColor(calibratedRed: 0.88, green: 0.33, blue: 0.20, alpha: 1.0))
        case .cursor:
            // Teal-ish (Cursor brand).
            return adaptiveBrand(NSColor(calibratedRed: 0.20, green: 0.60, blue: 0.70, alpha: 1.0))
        case .pi:
            // Green-cyan accent, distinct from Gemini and Cursor.
            return adaptiveBrand(NSColor(calibratedRed: 0.05, green: 0.62, blue: 0.48, alpha: 1.0))
        }
    }

    /// Wraps a light-tuned brand hue in an appearance-adaptive color: light mode
    /// keeps the exact value; dark mode returns a brightened, slightly desaturated
    /// variant so the hue stays legible on a dark background. Deterministic (no
    /// hand-tuned per-agent dark values), so every brand color adapts consistently.
    private static func adaptiveBrand(_ light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard isDark else { return light }
            let rgb = light.usingColorSpace(.sRGB) ?? light
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return NSColor(hue: h, saturation: s * 0.88, brightness: min(1.0, max(b, 0.74)), alpha: a)
        }
    }

    static func agentBrandAccent(source: SessionSource) -> Color {
        Color(nsColor: agentBrandAccent(source: source))
    }
}

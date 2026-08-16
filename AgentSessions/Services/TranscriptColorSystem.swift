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

    /// Brand hues, stable across the app. Each source's hue now lives on its descriptor
    /// (`SessionSourceDescriptor.brandHue`); `resolvedBrandAccent` applies the same rule
    /// this switch used to: a light-calibrated triple is wrapped in `adaptiveBrand` so the
    /// light value is preserved and dark mode gets a brighter variant, while a system
    /// dynamic color already adapts and passes through unchanged (K6).
    ///
    /// The pinned goldens in `SessionSourceRegistryTests` are what this drew before the
    /// registry existed, per source and per appearance.
    static func agentBrandAccent(source: SessionSource) -> NSColor {
        SessionSourceRegistry.resolvedBrandAccent(for: source)
    }

    /// Wraps a light-tuned brand hue in an appearance-adaptive color: light mode
    /// keeps the exact value; dark mode returns a brightened, slightly desaturated
    /// variant so the hue stays legible on a dark background. Deterministic (no
    /// hand-tuned per-agent dark values), so every brand color adapts consistently.
    static func adaptiveBrand(_ light: NSColor) -> NSColor {
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

import SwiftUI
import AppKit

/// Shared color/gradient palette for all onboarding surfaces (first-run setup,
/// What's New, feedback) and the legacy Power Tips renderer. Extracted from
/// `OnboardingSheetView` so every surface reads from one visual source of truth.
struct OnboardingPalette {
    let colorScheme: ColorScheme
    private var controlAccent: NSColor { NSColor.controlAccentColor }

    private func blendAccent(towards target: NSColor, fraction: CGFloat) -> Color {
        Color(nsColor: controlAccent.blended(withFraction: fraction, of: target) ?? controlAccent)
    }

    var backgroundTop: Color {
        colorScheme == .dark
            ? Color(red: 0.05, green: 0.06, blue: 0.09)
            : Color(red: 0.94, green: 0.96, blue: 0.98)
    }

    var backgroundBottom: Color {
        colorScheme == .dark
            ? Color(red: 0.06, green: 0.08, blue: 0.12)
            : Color(red: 0.90, green: 0.93, blue: 0.98)
    }

    var cardFill: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.55)
            : Color.white.opacity(0.85)
    }

    var cardStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    var cardShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.45)
            : Color.black.opacity(0.18)
    }

    var divider: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    var rowFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.035)
    }

    var rowStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    var pillFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.04)
    }

    var pillStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.08)
    }

    var tipFill: Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.18, blue: 0.32, opacity: 0.45)
            : Color(red: 0.55, green: 0.68, blue: 0.92, opacity: 0.2)
    }

    var tipStroke: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.38, blue: 0.64, opacity: 0.4)
            : Color(red: 0.45, green: 0.60, blue: 0.82, opacity: 0.4)
    }

    var dotActive: Color { accentBlue }

    var dotInactive: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.18)
            : Color.black.opacity(0.16)
    }

    var iconGradientPrimary: LinearGradient {
        LinearGradient(
            colors: [
                blendAccent(towards: .white, fraction: colorScheme == .dark ? 0.12 : 0.18),
                blendAccent(towards: .black, fraction: colorScheme == .dark ? 0.18 : 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var iconGradientBlue: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.26, green: 0.56, blue: 0.96), Color(red: 0.38, green: 0.70, blue: 0.98)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var iconGradientGreen: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.28, green: 0.78, blue: 0.58), Color(red: 0.40, green: 0.86, blue: 0.66)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var iconGradientPurple: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.64, green: 0.45, blue: 0.95), Color(red: 0.85, green: 0.44, blue: 0.82)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var primaryGradient: LinearGradient {
        LinearGradient(
            colors: [
                blendAccent(towards: .white, fraction: colorScheme == .dark ? 0.10 : 0.14),
                blendAccent(towards: .black, fraction: colorScheme == .dark ? 0.16 : 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var primaryFinalGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.29, green: 0.78, blue: 0.60), Color(red: 0.30, green: 0.68, blue: 0.82)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var primaryLiquidOverlay: RadialGradient {
        RadialGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.22 : 0.28),
                Color.white.opacity(0.0)
            ],
            center: .topLeading,
            startRadius: 6,
            endRadius: 140
        )
    }

    var primaryLiquidOverlayOpacity: Double {
        colorScheme == .dark ? 0.34 : 0.26
    }

    var primaryButtonStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.12)
    }

    var primaryButtonShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.42)
            : Color.black.opacity(0.18)
    }

    var secondaryButtonFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.05)
    }

    var secondaryButtonStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.1)
    }

    var meterBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    var chartBase: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.04)
    }

    var liveBadgeFill: Color {
        Color(red: 0.19, green: 0.68, blue: 0.36, opacity: colorScheme == .dark ? 0.35 : 0.2)
    }

    var liveBadgeText: Color {
        colorScheme == .dark
            ? Color(red: 0.58, green: 0.92, blue: 0.68)
            : Color(red: 0.18, green: 0.52, blue: 0.28)
    }

    var orbBlue: Color {
        Color(red: 0.28, green: 0.55, blue: 0.98, opacity: colorScheme == .dark ? 0.35 : 0.18)
    }

    var orbPurple: Color {
        Color(red: 0.64, green: 0.45, blue: 0.95, opacity: colorScheme == .dark ? 0.35 : 0.16)
    }

    var orbCyan: Color {
        Color(red: 0.32, green: 0.85, blue: 0.88, opacity: colorScheme == .dark ? 0.32 : 0.15)
    }

    var accentOrange: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.62, blue: 0.30)
            : Color(red: 0.90, green: 0.54, blue: 0.22)
    }

    var accentGreen: Color {
        colorScheme == .dark
            ? Color(red: 0.34, green: 0.84, blue: 0.60)
            : Color(red: 0.26, green: 0.72, blue: 0.50)
    }

    var accentBlue: Color {
        colorScheme == .dark
            ? Color(red: 0.40, green: 0.66, blue: 1.0)
            : Color(red: 0.30, green: 0.56, blue: 0.90)
    }

    var accentPurple: Color {
        colorScheme == .dark
            ? Color(red: 0.68, green: 0.50, blue: 1.0)
            : Color(red: 0.58, green: 0.40, blue: 0.90)
    }

    var slideIconShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.4)
            : Color.black.opacity(0.15)
    }

    var blurMaterial: NSVisualEffectView.Material {
        colorScheme == .dark ? .hudWindow : .sidebar
    }

    func agentAccent(for source: SessionSource) -> Color {
        switch source {
        case .claude:
            return accentOrange
        case .codex:
            return accentGreen
        case .antigravity:
            return accentBlue
        case .opencode:
            return Color(red: 0.62, green: 0.52, blue: 0.96)
        case .hermes:
            return Color.agentHermes
        case .copilot:
            return Color(red: 0.82, green: 0.36, blue: 0.78)
        case .droid:
            return Color(red: 0.26, green: 0.72, blue: 0.38)
        case .openclaw:
            return Color(red: 0.95, green: 0.55, blue: 0.18)
        case .cursor:
            return Color(red: 0.20, green: 0.60, blue: 0.70)
        case .pi:
            return Color.agentPi
        }
    }
}

import SwiftUI

/// The Quota Meter explainer, reached from the top-slot card. Sells the feature
/// with the same looping demo the first-run screen uses, then teaches the three
/// gestures that are not self-evident on a chromeless widget.
///
/// It exists because the card's action cannot simply open the window: with usage
/// tracking off the Quota Meter renders "Usage tracking is off", so we would be
/// advertising the feature and delivering an empty box. Enabling tracking starts
/// CLI usage probes, which the user should agree to knowingly rather than
/// discover — so the explanation and the consent are the same screen.
struct QuotaMeterPromoView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    /// False when tracking is already on and this is only "you've never opened it".
    let needsUsageEnabled: Bool
    var onActivate: () -> Void
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }

    /// Same asset and geometry as the first-run block — one demo, one source.
    private static let gifAsset = "OnboardingQuotaMeterRunwayAnimated"
    private static let gifWidth: CGFloat = 420
    private static let gifAspect: CGFloat = 640.0 / 188.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            demo
            gestures
            if needsUsageEnabled {
                consentNote
            }
            footer
        }
        .padding(24)
        .frame(width: 500)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quota Meter")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            Text("An always-on-top window showing how much Codex and Claude quota you have left, and how fast each session is burning it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var demo: some View {
        if AnimatedGIFView.hasAsset(named: Self.gifAsset) {
            AnimatedGIFView(assetName: Self.gifAsset, animates: !reduceMotion)
                .frame(width: Self.gifWidth, height: Self.gifWidth / Self.gifAspect)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(palette.rowStroke, lineWidth: 1)
                )
                .frame(maxWidth: .infinity)
        }
    }

    /// The window is deliberately chromeless, so none of these are discoverable
    /// by looking at it.
    private var gestures: some View {
        VStack(alignment: .leading, spacing: 8) {
            gesture("cursorarrow.click.2", "Right-click", "Show the toolbar — runway, text size, pin.")
            gesture("hand.draw", "Drag anywhere", "Move it. It never resizes under your pointer.")
            gesture("arrow.clockwise", "Double-click", "Refresh usage right now.")
        }
    }

    private func gesture(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(palette.accentBlue)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 92, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var consentNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("Enabling reads quota from your local Codex and Claude CLIs. Nothing is sent anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Not now") {
                coordinator.recordQuotaMeterDeclined()
                onClose()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button(needsUsageEnabled ? "Enable & Show" : "Show Quota Meter") {
                onActivate()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle(palette: palette, isFinal: true))
            .keyboardShortcut(.defaultAction)
        }
    }
}

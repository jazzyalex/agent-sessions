import SwiftUI

/// The one-time notch intro: a picture of the open notch, one sentence, and the buttons for
/// the user's situation. Presentation-only; `NotchIntroActivator` carries out the buttons.
/// Spec: docs/superpowers/specs/2026-10-12-quota-meter-notch-design.md, "Notch intro".
struct NotchIntroView: View {
    let variant: NotchIntroVariant
    var onPrimary: () -> Void
    var onSecondary: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NotchIntroPicture()
            VStack(alignment: .leading, spacing: 4) {
                Text("Quota Meter in the notch")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("See your live burn rate and when your quota runs out, at the top of the screen. Hover to open it; click for the menu.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if variant == .turnOnTracking {
                consentNote
            }
            footer
        }
        .padding(24)
        .frame(width: 500)
        .background(escapeShortcut)
    }

    /// Escape takes the secondary path (Got It when that is the only button). A hidden
    /// `.cancelAction` button, like the app's other sheets: `onExitCommand` needs focus, which
    /// nothing in this sheet takes without Full Keyboard Access.
    private var escapeShortcut: some View {
        Button("", action: onSecondary)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// Same consent wording as the Quota Meter promo: Turn On switches tracking on.
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
            switch variant {
            case .moveToNotch:
                secondaryButton("Keep on Desktop")
            case .turnOnTracking:
                secondaryButton("Not Now")
            case .alreadyInNotch:
                EmptyView()
            }
            Spacer()
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(OnboardingPrimaryButtonStyle(palette: palette, isFinal: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch variant {
        case .moveToNotch: return "Move to Notch"
        case .alreadyInNotch: return "Got It"
        case .turnOnTracking: return "Turn On"
        }
    }

    private func secondaryButton(_ title: LocalizedStringKey) -> some View {
        Button(title, action: onSecondary)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }
}

/// A drawn picture of the open notch, matching the owner-reviewed mockup: a slice of the menu
/// bar, the black panel below it, a Codex row, one runway row and a Claude row in the real
/// Quota Meter styling. Sample values, not the user's data, so it is verbatim and hidden
/// from VoiceOver (the title and body say what it shows).
private struct NotchIntroPicture: View {
    private static let orange = Color(red: 1.0, green: 0.60, blue: 0.12)
    private static let grey = Color(white: 0.56)
    private static let menuBarHeight: CGFloat = 24

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.17)
            VStack(spacing: 0) {
                menuBar
                Spacer(minLength: 0)
            }
            panel
        }
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var menuBar: some View {
        HStack {
            Text(verbatim: "Agent Sessions   File   Edit   View")
            Spacer()
            Text(verbatim: "Mon 9:41 AM")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color(white: 0.85))
        .padding(.horizontal, 12)
        .frame(height: Self.menuBarHeight)
        .background(Color(white: 0.24))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Self.menuBarHeight)
            providerRow(icon: codexIcon, five: "63%", runout: "▸2h 5m", fiveReset: "↻ 1h 40m",
                        week: "54%", weekReset: "↻ Sun 4:59 AM")
                .padding(.top, 8)
            runwayRow
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5).padding(.vertical, 6)
            providerRow(icon: claudeIcon, five: "81%", runout: nil, fiveReset: "↻ 3h 12m",
                        week: "72%", weekReset: "↻ Thu 9:00 AM")
                .padding(.bottom, 12)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(white: 0.95))
        .padding(.horizontal, 16)
        .frame(width: 400)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18).fill(.black))
    }

    private var codexIcon: some View {
        Image("FooterIconCodex").renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(.white)
    }

    private var claudeIcon: some View {
        Image("FooterIconClaude").renderingMode(.original).resizable().scaledToFit()
    }

    private func providerRow(icon: some View, five: String, runout: String?, fiveReset: String,
                             week: String, weekReset: String) -> some View {
        HStack(spacing: 7) {
            icon.frame(width: 13, height: 13)
            (Text(verbatim: "5h:") + Text(verbatim: five).foregroundColor(QuotaStripPalette.healthy))
            if let runout {
                Text(verbatim: runout).fontWeight(.bold).foregroundStyle(Self.orange)
            } else {
                Text(verbatim: "·").foregroundStyle(Self.grey)
            }
            Text(verbatim: fiveReset).foregroundStyle(Self.grey)
            Text(verbatim: "|").foregroundStyle(Color.white.opacity(0.25))
            (Text(verbatim: "Wk:") + Text(verbatim: week).foregroundColor(QuotaStripPalette.healthy))
            Spacer(minLength: 4)
            Text(verbatim: weekReset).foregroundStyle(Self.grey)
        }
        .frame(height: 22)
    }

    private var runwayRow: some View {
        HStack(spacing: 8) {
            Text(verbatim: "transcript-redesign").foregroundStyle(Color(white: 0.8))
            Spacer(minLength: 4)
            Text(verbatim: "38m/h").foregroundStyle(Self.orange)
            Capsule().fill(Color.white.opacity(0.14))
                .frame(width: 96, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(Self.orange).frame(width: 96 * 0.7, height: 5)
                }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .padding(.leading, 20)
        .frame(height: 18)
    }
}

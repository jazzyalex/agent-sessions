import SwiftUI
import AppKit

// Shared visual atoms used across every onboarding surface (first-run setup,
// What's New panel/card, feedback prompt) and the legacy Power Tips renderer.
// Extracted from OnboardingSheetView so the surfaces stay visually consistent.

/// Text at a shared onboarding boundary. Static product copy uses a
/// LocalizedStringResource; imported What's New data remains verbatim user-facing
/// content until that catalog is migrated deliberately.
enum OnboardingText {
    case localized(LocalizedStringResource)
    case verbatim(String)

    @ViewBuilder
    func makeView() -> some View {
        switch self {
        case .localized(let resource):
            Text(resource)
        case .verbatim(let value):
            Text(verbatim: value)
        }
    }
}

// MARK: - Feature / tip rows

struct FeatureRow: View {
    let palette: OnboardingPalette
    let icon: String
    let iconColor: Color
    let title: OnboardingText
    let description: OnboardingText

    init(
        palette: OnboardingPalette,
        icon: String,
        iconColor: Color,
        title: LocalizedStringResource,
        description: LocalizedStringResource
    ) {
        self.palette = palette
        self.icon = icon
        self.iconColor = iconColor
        self.title = .localized(title)
        self.description = .localized(description)
    }

    /// Legacy What's New content is deliberately rendered verbatim. It is not
    /// converted into a runtime localization key.
    init(
        palette: OnboardingPalette,
        icon: String,
        iconColor: Color,
        verbatimTitle: String,
        verbatimDescription: String
    ) {
        self.palette = palette
        self.icon = icon
        self.iconColor = iconColor
        self.title = .verbatim(verbatimTitle)
        self.description = .verbatim(verbatimDescription)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(palette.colorScheme == .dark ? 0.22 : 0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                title.makeView()
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)
                description.makeView()
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(palette.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(palette.rowStroke, lineWidth: 1)
        )
    }
}

struct TipBox: View {
    let text: LocalizedStringResource
    let palette: OnboardingPalette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accentBlue)
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(palette.tipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(palette.tipStroke, lineWidth: 1)
        )
    }
}

// MARK: - Agent badge + toggle tile

struct AgentBadge: View {
    let source: SessionSource
    let palette: OnboardingPalette
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(
                    LinearGradient(
                        colors: [palette.agentAccent(for: source).opacity(0.9), palette.agentAccent(for: source)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            Text(Self.initials(for: source))
                .font(.system(size: size * 0.33, weight: .bold, design: .default))
                .foregroundStyle(.white)
        }
    }

    static func initials(for source: SessionSource) -> String {
        source.descriptor.badgeInitials
    }
}

/// Agent enable/disable tile used on the first-run setup grid.
struct AgentToggleTile: View {
    let source: SessionSource
    let displayName: String
    let count: Int
    let isEnabled: Bool
    let palette: OnboardingPalette
    let isOn: Binding<Bool>
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            AgentBadge(source: source, palette: palette, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)
                    .opacity(isEnabled ? 1.0 : 0.7)
                Text(OnboardingLocalizedCopy.sessionsFound(count))
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isDisabled)
                .scaleEffect(0.9, anchor: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(palette.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(palette.rowStroke, lineWidth: 1)
        )
    }
}

// MARK: - Slide header

enum SlideIcon {
    case appIcon
    case symbol(String)
}

struct SlideIconView: View {
    let icon: SlideIcon
    let gradient: LinearGradient
    let palette: OnboardingPalette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(gradient)
                .frame(width: 64, height: 64)

            switch icon {
            case .appIcon:
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: palette.slideIconShadow, radius: 10, y: 4)
    }
}

struct SlideHeader: View {
    let palette: OnboardingPalette
    let icon: SlideIcon
    let iconGradient: LinearGradient
    let title: LocalizedStringResource?
    let subtitle: LocalizedStringResource

    var body: some View {
        VStack(spacing: 10) {
            SlideIconView(icon: icon, gradient: iconGradient, palette: palette)

            if let title {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }

            Text(subtitle)
                .font(.system(size: 15, weight: .medium, design: .default))
                .foregroundStyle(.primary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Localized counts

enum OnboardingLocalizedCopy {
    static func sessionsFound(
        _ count: Int,
        locale: Locale = .current
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            "\(count) sessions found",
            locale: locale,
            comment: "Session discovery count. Use the singular form for one session."
        )
    }
}

struct CountingSessionsFoundText: View {
    var value: Double
    var numberFont: Font
    var labelFont: Font
    var numberColor: Color

    var body: some View {
        let count = Int(value.rounded())
        var copy = AttributedString(
            localized: OnboardingLocalizedCopy.sessionsFound(count),
            including: \.swiftUI
        )
        if let numberRange = copy.range(of: count.formatted()) {
            copy[numberRange].font = numberFont
            copy[numberRange].foregroundColor = numberColor
        }
        return Text(copy)
            .font(labelFont)
            .foregroundStyle(.primary)
            .monospacedDigit()
    }
}

extension CountingSessionsFoundText: Animatable {
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
}

// MARK: - Button styles

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    let palette: OnboardingPalette
    let isFinal: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .default))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(palette.primaryGradient)

                    if isFinal {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(palette.primaryLiquidOverlay)
                            .blendMode(.softLight)
                            .opacity(palette.primaryLiquidOverlayOpacity)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(palette.primaryButtonStroke, lineWidth: 1)
            )
            .shadow(color: palette.primaryButtonShadow, radius: 6, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    let palette: OnboardingPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .default))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(palette.secondaryButtonFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(palette.secondaryButtonStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Progress dots (legacy Power Tips footer)

struct OnboardingProgressDots: View {
    let count: Int
    let index: Int
    let palette: OnboardingPalette
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Button {
                    onSelect(i)
                } label: {
                    Capsule()
                        .fill(i == index ? palette.dotActive : palette.dotInactive)
                        .frame(width: i == index ? 22 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: index)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Ambient background + glass card

struct OnboardingAmbientBackground: View {
    let palette: OnboardingPalette
    let animate: Bool
    @State private var drift: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            Circle()
                .fill(palette.orbBlue)
                .frame(width: 260, height: 260)
                .blur(radius: 80)
                .offset(x: drift ? -180 : -120, y: drift ? -120 : -160)

            Circle()
                .fill(palette.orbCyan)
                .frame(width: 240, height: 240)
                .blur(radius: 90)
                .offset(x: drift ? 160 : 110, y: drift ? -80 : -140)

            Circle()
                .fill(palette.orbCyan)
                .frame(width: 220, height: 220)
                .blur(radius: 80)
                .offset(x: drift ? 140 : 90, y: drift ? 140 : 100)
        }
        .onAppear {
            guard animate else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

struct OnboardingGlassCard<Content: View>: View {
    let palette: OnboardingPalette
    let content: Content

    init(palette: OnboardingPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        ZStack {
            OnboardingVisualEffectBlur(material: palette.blurMaterial, blendingMode: .withinWindow, state: .active)

            RoundedRectangle(cornerRadius: 28)
                .fill(palette.cardFill)

            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(palette.cardStroke, lineWidth: 1)
        )
        .shadow(color: palette.cardShadow, radius: 24, x: 0, y: 16)
    }
}

struct OnboardingVisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

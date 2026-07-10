import SwiftUI
import AppKit

/// The multi-slide Power Tips tour (Help → Power Tips). This is the sole surviving
/// use of the old onboarding sheet — first run and update announcements now live in
/// `FirstRunSetupView` and the What's New surfaces. It's a self-contained,
/// swipe-through tour of tips drawn from the Power Tips catalog.
struct OnboardingSheetView: View {
    let content: OnboardingContent
    @ObservedObject var coordinator: OnboardingCoordinator

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var slideIndex: Int = 0
    @State private var isForward: Bool = true
    @State private var slideAppeared: Bool = false

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }

    private var screens: [OnboardingContent.Screen] {
        content.screens.isEmpty
            ? OnboardingContent.powerTipsTour(for: content.versionMajorMinor).screens
            : content.screens
    }
    private var isFirst: Bool { slideIndex == 0 }
    private var isLast: Bool { slideIndex == screens.count - 1 }

    var body: some View {
        ZStack {
            OnboardingAmbientBackground(palette: palette, animate: !reduceMotion)

            OnboardingGlassCard(palette: palette) {
                VStack(spacing: 0) {
                    ZStack {
                        slideView
                            .transition(slideTransition)
                    }
                    .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 30)
                    .padding(.top, 24)
                    .padding(.bottom, 18)

                    Rectangle()
                        .fill(palette.divider)
                        .frame(height: 1)

                    footer
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            }
            .frame(minWidth: 780, minHeight: 640)
            .padding(20)
        }
        .frame(minWidth: 820, minHeight: 700)
        .interactiveDismissDisabled(true)
        .onKeyPress(.leftArrow) {
            if !isFirst { goToSlide(slideIndex - 1) }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if !isLast { goToSlide(slideIndex + 1) }
            return .handled
        }
        .onAppear { triggerSlideAppear() }
        .onChange(of: content.versionMajorMinor) { _, _ in slideIndex = 0 }
        .onChange(of: slideIndex) { _, _ in triggerSlideAppear() }
    }

    private var slideView: some View {
        let screen = screens.indices.contains(slideIndex) ? screens[slideIndex] : screens.first
        return Group {
            if let screen {
                let tips = screen.bullets.map(splitPowerTip)
                VStack(spacing: 18) {
                    SlideHeader(
                        palette: palette,
                        icon: .symbol(screen.symbolName),
                        iconGradient: palette.iconGradientBlue,
                        title: screen.title,
                        subtitle: screen.body
                    )

                    VStack(spacing: 12) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { offset, tip in
                            FeatureRow(
                                palette: palette,
                                icon: offset == 0 ? "1.circle.fill" : "2.circle.fill",
                                iconColor: palette.accentBlue,
                                title: tip.title,
                                description: tip.description
                            )
                        }
                    }

                    TipBox(
                        text: "Use Back and Next to move through the Power Tips tour.",
                        palette: palette
                    )
                }
            }
        }
        .id(slideIndex)
        .opacity(slideAppeared ? 1 : 0)
        .offset(y: slideAppeared ? 0 : 8)
    }

    private var slideTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: isForward ? 28 : -28)),
            removal: .opacity.combined(with: .offset(x: isForward ? -28 : 28))
        )
    }

    private func splitPowerTip(_ text: String) -> (title: String, description: String) {
        guard let separator = text.firstIndex(of: ":") else {
            return ("Tip", text)
        }
        let title = String(text[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let description = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, description)
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Button("Later") {
                coordinator.skip()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reopen from Help → Power Tips")

            Spacer()

            VStack(spacing: 6) {
                OnboardingProgressDots(
                    count: screens.count,
                    index: slideIndex,
                    palette: palette,
                    onSelect: { target in
                        goToSlide(target)
                    }
                )
                .accessibilityLabel("Step \(slideIndex + 1) of \(screens.count)")

                Text("Step \(slideIndex + 1) of \(screens.count)")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 10) {
                if !isFirst {
                    Button("Back") {
                        goToSlide(max(0, slideIndex - 1))
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle(palette: palette))
                }

                Button(isLast ? "Done" : "Next") {
                    if isLast {
                        coordinator.complete()
                    } else {
                        goToSlide(min(screens.count - 1, slideIndex + 1))
                    }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle(palette: palette, isFinal: isLast))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func goToSlide(_ index: Int) {
        guard index != slideIndex else { return }
        isForward = index > slideIndex
        if reduceMotion {
            slideIndex = index
        } else {
            withAnimation(.easeOut(duration: 0.4)) {
                slideIndex = index
            }
        }
    }

    private func triggerSlideAppear() {
        slideAppeared = false
        guard !reduceMotion else {
            slideAppeared = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.35)) {
                slideAppeared = true
            }
        }
    }
}

import SwiftUI

struct OnboardingSheetView: View {
    let content: OnboardingContent
    @ObservedObject var coordinator: OnboardingCoordinator

    @State private var screenIndex: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    private var isFirst: Bool { screenIndex == 0 }
    private var isLast: Bool { screenIndex >= content.screens.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    headerIcon
                    screenText
                    bullets
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 18)
            }

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 600, minHeight: 460)
        .interactiveDismissDisabled(true)
    }

    private var headerIcon: some View {
        let screen = content.screens[screenIndex]
        return ZStack {
            Circle()
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                .frame(width: 92, height: 92)

            Image(systemName: screen.symbolName)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityHidden(true)
    }

    private var screenText: some View {
        let screen = content.screens[screenIndex]
        return VStack(spacing: 10) {
            Text(screen.title)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text(screen.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var bullets: some View {
        let screen = content.screens[screenIndex]
        if !screen.bullets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(screen.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 10) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(bullet)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 2)
        }
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Button("Skip") {
                coordinator.skip()
            }
            .buttonStyle(.link)
            .keyboardShortcut(.cancelAction)

            Spacer()

            OnboardingProgressDots(count: content.screens.count, index: screenIndex)
                .accessibilityLabel("Step \(screenIndex + 1) of \(content.screens.count)")

            Spacer()

            HStack(spacing: 10) {
                Button("Back") {
                    screenIndex = max(0, screenIndex - 1)
                }
                .disabled(isFirst)

                Button(isLast ? "Done" : "Next") {
                    if isLast {
                        coordinator.complete()
                    } else {
                        screenIndex = min(content.screens.count - 1, screenIndex + 1)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct OnboardingProgressDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
    }
}


import SwiftUI

struct OnboardingSheetView: View {
    let content: OnboardingContent
    @ObservedObject var coordinator: OnboardingCoordinator

    @State private var screenIndex: Int = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var christmasTwinkleStarted: Bool = false
    @State private var christmasTwinkle: Bool = false

    private var isFirst: Bool { screenIndex == 0 }
    private var isLast: Bool { screenIndex >= content.screens.count - 1 }

    var body: some View {
        let isChristmas = AppEdition.isChristmasEdition29
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    headerIcon
                    screenText
                    agentShowcase
                    bullets
                    shortcuts
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
        .onChange(of: content.versionMajorMinor) { _, _ in
            screenIndex = 0
        }
        .onChange(of: content.kind) { _, _ in
            screenIndex = 0
        }
        .onAppear {
            guard isChristmas else { return }
            guard !reduceMotion else { return }
            guard !christmasTwinkleStarted else { return }
            christmasTwinkleStarted = true
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                christmasTwinkle = true
            }
        }
    }

    private var headerIcon: some View {
        let isChristmas = AppEdition.isChristmasEdition29
        let screen = content.screens[screenIndex]
        return ZStack {
            Circle()
                .fill(
                    isChristmas
                        ? AnyShapeStyle(LinearGradient(
                            colors: [
                                Color.red.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                Color.green.opacity(colorScheme == .dark ? 0.20 : 0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        : AnyShapeStyle(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                )
                .frame(width: 92, height: 92)

            if isChristmas && screenIndex == 0 {
                Group {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .offset(x: -42, y: -30)
                        .opacity(christmasTwinkle ? 0.85 : 0.18)
                        .scaleEffect(christmasTwinkle ? 1.05 : 0.8)

                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .offset(x: 44, y: -18)
                        .opacity(christmasTwinkle ? 0.35 : 0.75)
                        .scaleEffect(christmasTwinkle ? 0.85 : 1.05)

                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .offset(x: 28, y: 40)
                        .opacity(christmasTwinkle ? 0.72 : 0.22)
                        .scaleEffect(christmasTwinkle ? 1.0 : 0.82)
                }
                .foregroundStyle(Color.primary.opacity(0.9))
                .accessibilityHidden(true)
            }

            Image(systemName: screen.symbolName)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityHidden(true)
    }

    private var screenText: some View {
        let isChristmas = AppEdition.isChristmasEdition29
        let screen = content.screens[screenIndex]
        return VStack(spacing: 10) {
            Text(screen.title)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            if isChristmas && screenIndex == 0 {
                Text("Christmas Edition")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !screen.body.isEmpty {
                Text(screen.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
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

    @ViewBuilder
    private var agentShowcase: some View {
        let screen = content.screens[screenIndex]
        if !screen.agentShowcase.isEmpty {
            VStack(alignment: .center, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .center)], spacing: 10) {
                    ForEach(screen.agentShowcase) { item in
                        AgentChip(symbolName: item.symbolName, title: item.title)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        let isChristmas = AppEdition.isChristmasEdition29
        let screen = content.screens[screenIndex]
        if !screen.shortcuts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Shortcuts")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .padding(.top, 4)

                ForEach(screen.shortcuts) { s in
                    HStack(spacing: 10) {
                        Keycap(keys: s.keys, isChristmasEdition: isChristmas)
                        Text(s.label)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct Keycap: View {
    let keys: String
    let isChristmasEdition: Bool

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        AnyShapeStyle(Color.secondary.opacity(0.25)),
                        lineWidth: 1
                    )
            )
            .foregroundStyle(.primary)
            .accessibilityLabel(keys)
    }
}

private struct AgentChip: View {
    let symbolName: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
	        .overlay(
	            RoundedRectangle(cornerRadius: 12)
	                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
	        )
	        .frame(maxWidth: .infinity)
	        .accessibilityElement(children: .combine)
	        .accessibilityLabel(title)
	    }
}

import SwiftUI

/// Compact, Esc-dismissible What's New panel (~480pt). Lists release highlights,
/// auto-generated new-provider items, an optional tip/promo/support row, and —
/// when the timing rules say so — an inline feedback ask. The feedback ask and a
/// support row never appear together (feedback wins).
struct WhatsNewPanelView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let majorMinor: String
    var onClose: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var showFeedbackForm: Bool = false

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }

    private var items: [WhatsNewItem] {
        var result = WhatsNewCatalog.assemble(for: majorMinor)
        if coordinator.isFeedbackAskDue() {
            // Feedback wins the CTA slot: drop any support row and append the ask.
            result.removeAll { $0.kind == .support }
            result.append(
                WhatsNewItem(
                    kind: .feedbackAsk,
                    iconSystemName: "text.bubble",
                    title: "Tell us what to build next",
                    body: "What's the one thing you wish Agent Sessions did better?"
                )
            )
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 12) {
                    if showFeedbackForm {
                        FeedbackPromptView(
                            coordinator: coordinator,
                            onFinished: { showFeedbackForm = false }
                        )
                        .frame(maxWidth: .infinity)
                    } else if items.isEmpty {
                        emptyState
                    } else {
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 520)
        .background(palette.backgroundBottom)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(palette.accentBlue)
                Text("What's New in \(majorMinor)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(palette.accentBlue)
            Text("You're all caught up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("No release notes for this version. Tips are always in Help → Power Tips.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func row(for item: WhatsNewItem) -> some View {
        switch item.kind {
        case .highlight, .tip:
            FeatureRow(
                palette: palette,
                icon: item.iconSystemName,
                iconColor: palette.accentBlue,
                title: item.title,
                description: item.body
            )
        case .promo:
            promoRow(item)
        case .support:
            linkRow(item, accent: palette.accentGreen, tag: nil)
        case .feedbackAsk:
            feedbackRow(item)
        }
    }

    private func promoRow(_ item: WhatsNewItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.iconSystemName)
                    .foregroundStyle(palette.accentOrange)
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Promo")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.tipFill))
                    .overlay(Capsule().stroke(palette.tipStroke, lineWidth: 1))
                Spacer()
            }
            Text(item.body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let title = item.linkTitle, let url = item.linkURL {
                Link(title, destination: url)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.rowStroke, lineWidth: 1))
    }

    private func linkRow(_ item: WhatsNewItem, accent: Color, tag: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.iconSystemName)
                    .foregroundStyle(accent)
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text(item.body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let title = item.linkTitle, let url = item.linkURL {
                Link(title, destination: url)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.rowStroke, lineWidth: 1))
    }

    private func feedbackRow(_ item: WhatsNewItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.iconSystemName)
                    .foregroundStyle(palette.accentBlue)
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text(item.body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Share feedback") {
                showFeedbackForm = true
            }
            .buttonStyle(OnboardingSecondaryButtonStyle(palette: palette))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.tipFill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.tipStroke, lineWidth: 1))
    }
}

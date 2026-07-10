import SwiftUI

/// Lightweight container mounted at the top of the session list. It hosts either
/// the What's New card or the feedback card (never both — What's New wins) and
/// carries the sheets for the compact What's New panel and the standalone
/// feedback prompt. Renders nothing when there is nothing to show.
struct OnboardingListTopSlot: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    @Environment(\.colorScheme) private var colorScheme

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }

    var body: some View {
        Group {
            if let version = coordinator.whatsNewMajorMinor {
                WhatsNewCard(
                    palette: palette,
                    majorMinor: version,
                    teaser: WhatsNewCatalog.teaser(for: version),
                    onOpen: { coordinator.openWhatsNewPanel(version: version) },
                    onDismiss: { coordinator.dismissWhatsNewCard() }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
            } else if coordinator.shouldShowFeedbackCard() {
                FeedbackCard(
                    palette: palette,
                    onOpen: { coordinator.isFeedbackPromptPresented = true },
                    onDismiss: { coordinator.suppressFeedbackCardThisLaunch() }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
        }
    }
}

extension View {
    /// Attaches the What's New panel and feedback-prompt sheets to a stable,
    /// always-present anchor. The cards themselves live in `OnboardingListTopSlot`,
    /// but that slot renders empty once the card is dismissed — and a `.sheet` on an
    /// empty view can fail to present — so the sheets must hang off the list pane,
    /// which is always on screen (Help → What's New relies on this).
    func onboardingSheets(coordinator: OnboardingCoordinator) -> some View {
        self
            .sheet(isPresented: Binding(
                get: { coordinator.isWhatsNewPanelPresented },
                set: { coordinator.isWhatsNewPanelPresented = $0 }
            )) {
                WhatsNewPanelView(
                    coordinator: coordinator,
                    majorMinor: coordinator.whatsNewPanelVersion ?? coordinator.whatsNewMajorMinor ?? "",
                    onClose: { coordinator.isWhatsNewPanelPresented = false }
                )
            }
            .sheet(isPresented: Binding(
                get: { coordinator.isFeedbackPromptPresented },
                set: { coordinator.isFeedbackPromptPresented = $0 }
            )) {
                FeedbackPromptView(
                    coordinator: coordinator,
                    onFinished: { coordinator.isFeedbackPromptPresented = false }
                )
            }
    }
}

/// Dismissible "✨ What's New in X.Y" banner.
struct WhatsNewCard: View {
    let palette: OnboardingPalette
    let majorMinor: String
    let teaser: String?
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accentBlue)

            VStack(alignment: .leading, spacing: 1) {
                Text("What's New in \(majorMinor)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let teaser {
                    Text(teaser)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button("See what's new", action: onOpen)
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .semibold))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.tipFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.tipStroke, lineWidth: 1))
    }
}

/// Dismissible feedback card (shown only when What's New is absent and the
/// feedback ask is due).
struct FeedbackCard: View {
    let palette: OnboardingPalette
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accentBlue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Got a minute?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("What's the one thing you wish Agent Sessions did better?")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Share feedback", action: onOpen)
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .semibold))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss for now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.rowStroke, lineWidth: 1))
    }
}

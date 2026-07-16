import SwiftUI

/// Lightweight container mounted at the top of the session list. It hosts exactly
/// one card — What's New, then Quota Meter, then feedback — and carries the
/// sheets for the compact What's New panel, the Quota Meter explainer, and the
/// standalone feedback prompt. Renders nothing when there is nothing to show.
///
/// Order is activation before extraction: the Quota Meter card asks the user to
/// try something, the feedback card asks them for something. Feedback waits for
/// 10 sessions or 14 days regardless, so the two rarely compete.
struct OnboardingListTopSlot: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    /// Which quota providers the user actually has sessions for. Kept per
    /// provider rather than collapsed to one Bool: activation needs to enable
    /// only what applies, and a single "has either" flag makes that impossible
    /// by the time it reaches the activator.
    let providers: QuotaMeterProviderAvailability
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled: Bool = false

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }

    private var usageEnabled: Bool { codexUsageEnabled || claudeUsageEnabled }

    /// Tracking alone is not "using it": the data flows but the window may never
    /// have been opened. Both must be true to retire the card.
    private var isQuotaMeterActive: Bool {
        usageEnabled && coordinator.hasEverOpenedCockpit
    }

    private var showsQuotaMeterCard: Bool {
        coordinator.shouldShowQuotaMeterCard(
            hasCodexOrClaudeSessions: providers.hasAny,
            isQuotaMeterActive: isQuotaMeterActive
        )
    }

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
            } else if showsQuotaMeterCard {
                QuotaMeterCard(
                    palette: palette,
                    needsUsageEnabled: !usageEnabled,
                    onOpen: { coordinator.isQuotaMeterPromoPresented = true },
                    onDismiss: { coordinator.suppressQuotaMeterCardThisLaunch() }
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

/// Dismissible "Track your Codex and Claude quota" banner.
struct QuotaMeterCard: View {
    let palette: OnboardingPalette
    let needsUsageEnabled: Bool
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accentBlue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Know your quota before it runs out")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("A pinned window with Codex and Claude limits, and how fast each session burns them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(needsUsageEnabled ? "Turn on" : "Show me", action: onOpen)
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
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.rowStroke, lineWidth: 1))
    }
}

extension View {
    /// Attaches the What's New panel and feedback-prompt sheets to a stable,
    /// always-present anchor. The cards themselves live in `OnboardingListTopSlot`,
    /// but that slot renders empty once the card is dismissed — and a `.sheet` on an
    /// empty view can fail to present — so the sheets must hang off the list pane,
    /// which is always on screen (Help → What's New relies on this).
    /// `providers` scopes what the Quota Meter promo's activation may switch on.
    func onboardingSheets(
        coordinator: OnboardingCoordinator,
        quotaMeterProviders: QuotaMeterProviderAvailability = QuotaMeterProviderAvailability()
    ) -> some View {
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
            .sheet(isPresented: Binding(
                get: { coordinator.isQuotaMeterPromoPresented },
                set: { coordinator.isQuotaMeterPromoPresented = $0 }
            )) {
                QuotaMeterPromoActivator(coordinator: coordinator, providers: quotaMeterProviders)
            }
    }
}

/// Which quota providers a user actually has sessions for. The Quota Meter
/// reports Codex and Claude quota only, so this both gates the card and decides
/// what activation is allowed to switch on.
struct QuotaMeterProviderAvailability: Equatable {
    var hasCodex: Bool = false
    var hasClaude: Bool = false

    var hasAny: Bool { hasCodex || hasClaude }
}

/// Owns the one side-effectful step the promo has: turning usage tracking on and
/// putting the Quota Meter on screen. Kept out of `QuotaMeterPromoView` so that
/// view stays presentation-only, and kept here because the sheet's host is the
/// list pane, which is always mounted.
private struct QuotaMeterPromoActivator: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let providers: QuotaMeterProviderAvailability
    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudDisplayMode) private var hudDisplayModeRaw: String = AgentCockpitHUDDisplayMode.initialMode().rawValue

    /// Only counts providers the user actually has: a Codex-only user whose
    /// Claude tracking happens to be off does not need "Enable", and switching
    /// Claude on for them would just start a probe against a CLI they may not
    /// have.
    private var needsUsageEnabled: Bool {
        (providers.hasCodex && !codexUsageEnabled) || (providers.hasClaude && !claudeUsageEnabled)
    }

    var body: some View {
        QuotaMeterPromoView(
            coordinator: coordinator,
            needsUsageEnabled: needsUsageEnabled,
            onActivate: activate,
            onClose: { coordinator.isQuotaMeterPromoPresented = false }
        )
    }

    private func activate() {
        // Enable before opening: the Quota Meter renders "Usage tracking is off"
        // otherwise, which would make the promo deliver an empty box.
        //
        // Only the providers the user has sessions for, and only ever switching
        // on — never off, so an existing preference for the other provider
        // survives untouched.
        if providers.hasCodex {
            codexUsageEnabled = true
        }
        if providers.hasClaude {
            claudeUsageEnabled = true
        }
        hudDisplayModeRaw = AgentCockpitHUDDisplayMode.limits.rawValue
        UserDefaults.standard.set(
            AgentCockpitHUDDisplayMode.limits.usesCompactChrome,
            forKey: PreferencesKey.Cockpit.hudCompact
        )
        coordinator.recordQuotaMeterActivated()
        AppWindowRouter.showAgentCockpitWindow()
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

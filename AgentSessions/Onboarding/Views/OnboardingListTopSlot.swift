import SwiftUI
import AppKit

/// Lightweight container mounted at the top of the session list. It hosts exactly
/// one card — What's New, then Quota Meter, then star, then feedback, then the
/// steward invitation, then the contribute-an-agent invitation (last two: they ask
/// for the most work, targeted before generic) — and carries the sheets for the
/// compact What's New panel, the Quota Meter explainer, and the standalone
/// feedback prompt. Renders nothing when there is nothing to show.
///
/// Order is activation before extraction: the Quota Meter card asks the user to
/// try something, the star and feedback cards ask them for something. Feedback
/// waits for 10 sessions or 14 days regardless, so the two rarely compete.
///
/// The star card outranks feedback because it terminates — see
/// `OnboardingCoordinator.shouldShowStarCard()`.
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
    /// Measured pane width, handed to the two cards whose text is allowed to
    /// wrap so they can move their actions below it in a narrow window. Zero
    /// until the first layout pass; see `WrappingSlotCard.paneWidth`.
    ///
    /// Safe against a layout loop: it feeds a card's internal arrangement, which
    /// changes the card's height, and the width being measured comes from the
    /// pane above and never from the card.
    @State private var paneWidth: CGFloat = 0
    /// Lets the ✕ on a forced card actually dismiss it, so the override can be
    /// clicked through like the real thing instead of being pinned on screen.
    @State private var debugCardDismissed = false

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
            // Ahead of the whole chain on purpose: the point of the override is
            // to see one card regardless of what would otherwise hold the slot.
            if let override = TopSlotDebugOverride.current, !debugCardDismissed {
                debugCard(override)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            } else if let version = coordinator.whatsNewMajorMinor {
                WhatsNewCard(
                    palette: palette,
                    majorMinor: version,
                    teaser: WhatsNewCatalog.teaser(for: version),
                    onOpen: { coordinator.openWhatsNewFromCard(version: version) },
                    onDismiss: { coordinator.dismissWhatsNewCard() }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                // Being ignored is an answer. The coordinator counts one
                // impression per launch however often this fires.
                .onAppear { coordinator.noteWhatsNewCardShown() }
            } else if showsQuotaMeterCard {
                QuotaMeterCard(
                    palette: palette,
                    needsUsageEnabled: !usageEnabled,
                    onOpen: { coordinator.isQuotaMeterPromoPresented = true },
                    onDismiss: { coordinator.suppressQuotaMeterCardThisLaunch() }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
            } else if coordinator.shouldShowStarCard() {
                StarCard(
                    palette: palette,
                    onOpen: openRepository,
                    onSnooze: { coordinator.snoozeStarAsk() },
                    onDismiss: { coordinator.dismissStarAskForever() }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                // Being ignored is an answer. The coordinator counts one
                // impression per launch however often this fires.
                .onAppear { coordinator.noteStarCardShown() }
            } else if coordinator.shouldShowFeedbackCard() {
                FeedbackCard(
                    palette: palette,
                    onOpen: { coordinator.isFeedbackPromptPresented = true },
                    onDismiss: { coordinator.suppressFeedbackCardThisLaunch() }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
            } else if let agent = coordinator.stewardAskTarget, coordinator.shouldShowStewardCard() {
                StewardCard(
                    palette: palette,
                    agent: agent,
                    onSignUp: { openStewardSignup(for: agent) },
                    onLearnMore: openStewardGuide,
                    onDismiss: { coordinator.dismissStewardAskForever() },
                    paneWidth: paneWidth
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                // Being ignored is an answer, counted once per launch.
                .onAppear { coordinator.noteStewardCardShown() }
            } else if coordinator.shouldShowContributeCard() {
                ContributeCard(
                    palette: palette,
                    onOpen: openContributeForm,
                    onLearnMore: openContributeGuide,
                    onSnooze: { coordinator.snoozeContributeAsk() },
                    onDismiss: { coordinator.dismissContributeAskForever() },
                    paneWidth: paneWidth
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                // Being ignored is an answer, counted once per launch.
                .onAppear { coordinator.noteContributeCardShown() }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SlotWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(SlotWidthKey.self) { paneWidth = $0 }
    }

    /// The star card's one side effect. Kept here rather than in the coordinator
    /// so that stays a pure state machine, matching `QuotaMeterPromoActivator`.
    /// Opening the page is the whole action — nothing is sent anywhere.
    private func openRepository() {
        // Only retire the ask if the page actually opened. If no browser is
        // available the click did nothing, and recording it as answered would
        // silently cost the user the ask they just tried to accept.
        guard NSWorkspace.shared.open(OnboardingCoordinator.githubRepositoryURL) else { return }
        coordinator.recordStarOpened()
    }

    /// Both contribute actions open a public page and nothing else — no session
    /// data is read, and nothing is sent anywhere. Same success guard as the
    /// star card: a click that opened no browser must not spend the ask.
    private func openContributeForm() {
        guard NSWorkspace.shared.open(OnboardingCoordinator.contributeAgentSourceURL) else { return }
        coordinator.recordContributeOpened()
    }

    private func openContributeGuide() {
        guard NSWorkspace.shared.open(OnboardingCoordinator.contributeGuideURL) else { return }
        coordinator.recordContributeOpened()
    }

    /// Opens the signup form with the agent pre-filled. Same success guard as the
    /// other cards: a click that opened no browser must not spend the ask. Only
    /// the agent's name leaves the app — see `stewardSignupURL(for:)`.
    private func openStewardSignup(for agent: StewardAgent) {
        guard NSWorkspace.shared.open(OnboardingCoordinator.stewardSignupURL(for: agent)) else { return }
        coordinator.recordStewardSignupOpened()
    }

    private func openStewardGuide() {
        guard NSWorkspace.shared.open(OnboardingCoordinator.stewardGuideURL) else { return }
        coordinator.recordStewardGuideOpened()
    }

    /// A forced card, wired to the real destinations but to none of the ask
    /// lifecycles. The links open exactly what they open in production — worth
    /// clicking, since that is the only way to see the prefilled signup form —
    /// while nothing here records an impression, spends a round, or dismisses an
    /// ask forever. Looking at a card must not cost the user the real one.
    @ViewBuilder
    private func debugCard(_ override: TopSlotDebugOverride) -> some View {
        switch override {
        case let .whatsNew(version):
            WhatsNewCard(
                palette: palette,
                majorMinor: version,
                teaser: WhatsNewCatalog.teaser(for: version),
                // Opens the real panel — that side is worth looking at — but
                // routes around `openWhatsNewFromCard` so viewing the card
                // cannot retire the version for real.
                onOpen: { coordinator.openWhatsNewPanel(version: version) },
                onDismiss: { debugCardDismissed = true }
            )
        case .star:
            StarCard(
                palette: palette,
                onOpen: { _ = NSWorkspace.shared.open(OnboardingCoordinator.githubRepositoryURL) },
                onSnooze: { debugCardDismissed = true },
                onDismiss: { debugCardDismissed = true }
            )
        case let .steward(agent):
            StewardCard(
                palette: palette,
                agent: agent,
                onSignUp: { _ = NSWorkspace.shared.open(OnboardingCoordinator.stewardSignupURL(for: agent)) },
                onLearnMore: { _ = NSWorkspace.shared.open(OnboardingCoordinator.stewardGuideURL) },
                onDismiss: { debugCardDismissed = true },
                paneWidth: paneWidth
            )
        case .contribute:
            ContributeCard(
                palette: palette,
                onOpen: { _ = NSWorkspace.shared.open(OnboardingCoordinator.contributeAgentSourceURL) },
                onLearnMore: { _ = NSWorkspace.shared.open(OnboardingCoordinator.contributeGuideURL) },
                onSnooze: { debugCardDismissed = true },
                onDismiss: { debugCardDismissed = true },
                paneWidth: paneWidth
            )
        }
    }
}

/// Forces one top-slot card on screen so it can be looked at in a running app.
///
/// The asks this slot holds are all gated behind weeks of retention and a
/// spent-once lifecycle, so there is no way to reach most of them by hand — the
/// steward card additionally needs sessions of an unstewarded agent in the
/// index. Rather than hand-editing `UserDefaults` into a state that then sticks,
/// pass the card as a launch argument, which lands in the volatile argument
/// domain and leaves nothing behind when the app quits:
///
/// ```
/// open <built>.app --args -AgentSessionsDebugTopSlotCard qwen
/// ```
///
/// Accepts `star`, `whatsnew` (optionally `whatsnew:5.1` to pick the version),
/// `contribute`, or any `SessionSource` raw value listed in
/// `StewardAskEligibility.stewardlessAgents` (`qwen`, `grok`, `cursor`, …).
/// Debug builds only: `current` is a compile-time nil elsewhere, so no release
/// build can be argued into showing a card it has not earned.
///
/// This shows a card's *appearance* — copy, layout, wrapping, light and dark. It
/// deliberately does not exercise the lifecycles: every action below hides the
/// override instead of calling the coordinator, so looking at a card here cannot
/// spend the real ask. State transitions are covered by the unit tests, not by
/// this.
enum TopSlotDebugOverride {
    case whatsNew(String)
    case star
    case steward(StewardAgent)
    case contribute

    static let defaultsKey = "AgentSessionsDebugTopSlotCard"

    static var current: TopSlotDebugOverride? {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return parse(raw, buildMajorMinor: buildMajorMinor)
        #else
        nil
        #endif
    }

    #if DEBUG
    /// This build's own major.minor, which a bare `whatsnew` renders so the card
    /// shows the copy about to ship rather than an archived entry.
    ///
    /// A `let` rather than a computed property: the Info dictionary cannot change
    /// while the process runs, and `current` is read on every render of the slot.
    private static let buildMajorMinor = OnboardingContent.currentMajorMinor()

    /// The raw-value grammar, split out from `current` so it can be tested
    /// without writing to `UserDefaults.standard`. `buildMajorMinor` is passed in
    /// for the same reason: the bare `whatsnew` case stays deterministic.
    static func parse(_ raw: String, buildMajorMinor: String?) -> TopSlotDebugOverride? {
        // Literals first: none of them is a `SessionSource` raw value, and
        // matching them here keeps the agent lookup from having to know about
        // the cards that are not agents.
        if raw == "contribute" { return .contribute }
        if raw == "star" { return .star }
        if raw == "whatsnew" || raw.hasPrefix("whatsnew:") {
            let requested = String(raw.dropFirst("whatsnew".count).drop(while: { $0 == ":" }))
            if !requested.isEmpty { return .whatsNew(requested) }
            // No version asked for and none to fall back on: decline rather than
            // invent one, which would render a card for a version that is not
            // this build's and may have no catalog entry.
            guard let buildMajorMinor else { return nil }
            return .whatsNew(buildMajorMinor)
        }
        guard let source = SessionSource(rawValue: raw),
              let agent = StewardAskEligibility.stewardlessAgents.first(where: { $0.source == source })
        else { return nil }
        return .steward(agent)
    }
    #endif
}

/// Carries the slot's measured width up from a background reader.
private struct SlotWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One link-style action in a slot card's action row.
struct SlotCardAction: Identifiable {
    let title: String
    /// The card's primary action, drawn semibold. At most one per card.
    let isProminent: Bool
    let perform: () -> Void

    /// Titles are unique within a card and stable across renders, which `UUID()`
    /// would not be.
    var id: String { title }
}

/// Chrome shared by the two slot cards whose body text is allowed to wrap.
///
/// Every other card in this slot caps its body at `lineLimit(1)` and truncates
/// cleanly however narrow the pane gets. These two must not: each ends on a
/// sentence about what is never shared, and truncating is precisely what would
/// delete it. So the layout adapts instead.
///
/// In one row, the actions are laid beside the text and take a fixed width, so
/// every pixel the pane loses comes out of the text column. Below
/// `minimumWideWidth` there is not enough left for a sentence — at the session
/// list's 320pt minimum the contribute card's column fell under the width of the
/// word "contributions", and SwiftUI broke it mid-word into "contributio / ns".
/// Under that threshold the actions move below the text and wrap among
/// themselves, so the text always gets the full width.
struct WrappingSlotCard: View {
    let palette: OnboardingPalette
    let iconName: String
    let iconTint: Color
    let title: String
    let message: String
    let actions: [SlotCardAction]
    let dismissHelp: String
    var onDismiss: () -> Void
    /// Width of the slot, measured by `OnboardingListTopSlot`. Zero before the
    /// first layout pass, which is read as wide: most windows are, and starting
    /// wide avoids a visible flip on the common path.
    var paneWidth: CGFloat = 0

    /// Pane width below which the actions wrap under the text.
    ///
    /// Derived from the widest action row here — the contribute card's three
    /// links need roughly 320pt — plus the icon, the card's own padding, and
    /// about 200pt of text column, under which an 11pt sentence stops reading as
    /// a sentence. Shared by both cards rather than computed per card: the
    /// steward card could stay wide slightly longer, and gains nothing from
    /// switching at a different width than its neighbour.
    static let minimumWideWidth: CGFloat = 560

    /// Indent that lines the wrapped action row up with the text column above it.
    private static let textColumnIndent: CGFloat = 24

    /// Whether the actions wrap under the text. Internal rather than private so
    /// the threshold's behaviour at the list's minimum width can be tested
    /// without rendering.
    var prefersCompactLayout: Bool { paneWidth > 0 && paneWidth < Self.minimumWideWidth }

    var body: some View {
        Group {
            if prefersCompactLayout {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        icon
                        textColumn
                        Spacer(minLength: 8)
                        dismissButton
                    }
                    Flow(spacing: 12) {
                        ForEach(actions) { actionButton($0) }
                    }
                    .padding(.leading, Self.textColumnIndent)
                }
            } else {
                HStack(spacing: 10) {
                    icon
                    textColumn
                    Spacer(minLength: 8)
                    ForEach(actions) { actionButton($0) }
                    dismissButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.rowStroke, lineWidth: 1))
    }

    private var icon: some View {
        Image(systemName: iconName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(iconTint)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                // Titles here carry agent names and run longer than the
                // single-line cards' do. Wrapping beats truncating to "Help ad…".
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ action: SlotCardAction) -> some View {
        Button(action.title, action: action.perform)
            .buttonStyle(.link)
            .font(.system(size: 12, weight: action.isProminent ? .semibold : .regular))
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(dismissHelp)
    }
}

/// Invitation to steward one specific agent — the one the user's own sessions
/// show they run.
///
/// Three exits, one fewer than the contribute card: sign up, read what the job
/// is, or never. There is no "Maybe later" because the ask already re-arms on a
/// release bump, and a snooze button on top of that would only add a second way
/// to say the thing silence already says.
struct StewardCard: View {
    let palette: OnboardingPalette
    let agent: StewardAgent
    var onSignUp: () -> Void
    var onLearnMore: () -> Void
    var onDismiss: () -> Void
    var paneWidth: CGFloat = 0

    /// A question, not a statement of the project's problem. The card is asking
    /// the reader to volunteer, so it opens by qualifying them — someone who does
    /// not use this agent can stop reading at the first two words. Held as static
    /// functions so tests can pin the claims without rendering the view.
    static func titleText(for agent: StewardAgent) -> String {
        "Use \(agent.stewardName)?"
    }

    /// Opens with the ask, then the reason, then what it costs. Qwen keeps its own
    /// reason because its situation is genuinely different: every other agent here
    /// can at least be spot-checked by the maintainer, and Qwen cannot be checked
    /// at all. No version or month is quoted — `STEWARDS.md`, one click away
    /// behind "What's involved", carries the precise footnote and can be kept
    /// current without shipping a build.
    static func bodyText(for agent: StewardAgent) -> String {
        if agent.source == .qwen {
            return """
                Looking for a steward. Qwen's free tier ended, so newer builds go unverified here. \
                One command, a few times a year. No code, nothing shared.
                """
        }
        return """
            Looking for a steward to help keep Agent Sessions reading it correctly when the format \
            moves. One command, a few times a year. No code, nothing shared.
            """
    }

    var body: some View {
        WrappingSlotCard(
            palette: palette,
            iconName: "checkmark.seal",
            iconTint: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: agent.source)),
            title: Self.titleText(for: agent),
            message: Self.bodyText(for: agent),
            actions: [
                SlotCardAction(title: "Become the steward", isProminent: true, perform: onSignUp),
                SlotCardAction(title: "What's involved", isProminent: false, perform: onLearnMore)
            ],
            dismissHelp: "Don't ask again",
            onDismiss: onDismiss,
            paneWidth: paneWidth
        )
    }
}

/// Dismissible one-time invitation to add support for another coding agent.
///
/// Four exits, because the ask has four honest answers: contribute, read what it
/// involves first, ask me later, or never. Both open actions are terminal — a
/// user who went to look has been asked.
struct ContributeCard: View {
    let palette: OnboardingPalette
    var onOpen: () -> Void
    var onLearnMore: () -> Void
    var onSnooze: () -> Void
    var onDismiss: () -> Void
    var paneWidth: CGFloat = 0

    /// The card's own copy, held as a constant only so the frozen privacy
    /// sentence can be pinned by a test. Deliberately not a strings file — every
    /// other card in this slot keeps its copy inline too. No source count is
    /// stated here: that number changes every release.
    static let titleText = "Help add your agent"
    static let bodyText = """
        Agent Sessions adds new agents from user contributions — a pull request, your coding agent \
        working from our brief, or a sanitized sample. Never share real transcripts, keys, or \
        private paths.
        """

    var body: some View {
        WrappingSlotCard(
            palette: palette,
            iconName: "puzzlepiece.extension",
            iconTint: palette.accentBlue,
            title: Self.titleText,
            message: Self.bodyText,
            actions: [
                SlotCardAction(title: "Contribute an agent", isProminent: true, perform: onOpen),
                SlotCardAction(title: "How it works", isProminent: false, perform: onLearnMore),
                SlotCardAction(title: "Maybe later", isProminent: false, perform: onSnooze)
            ],
            dismissHelp: "Don't ask again",
            onDismiss: onDismiss,
            paneWidth: paneWidth
        )
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

/// Dismissible "star the repo" card, shown once the retention bar is met.
///
/// Three exits, because the ask has three honest answers: star it, ask me later,
/// or never. `star.circle` rather than a bare `star` — the session list already
/// spends that glyph on per-session favourites one row below.
struct StarCard: View {
    let palette: OnboardingPalette
    var onOpen: () -> Void
    var onSnooze: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accentBlue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Leave a star if this helps")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("A star helps others find this project. One click, nothing sent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Star on GitHub", action: onOpen)
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .semibold))

            // Same link style as the primary action, one weight lighter — the
            // accent colour is `.link`'s own, so tinting it here would not reach
            // the layer that draws it.
            Button("Maybe later", action: onSnooze)
                .buttonStyle(.link)
                .font(.system(size: 12))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Don't ask again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.rowStroke, lineWidth: 1))
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
                Text("Help make Agent Sessions better")
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

#if DEBUG
/// The steward card at the pane widths that actually occur: the session list's
/// 320pt minimum, a typical split, and a wide window. The contribute card sits
/// underneath as the reference — this card is measured against it, since the two
/// are neighbours in the slot and ask for comparable work.
private struct StewardCardPreviewMatrix: View {
    let colorScheme: ColorScheme

    private static let qwen = StewardAgent(source: .qwen, stewardName: "Qwen Code")
    /// The longest name in the list — the worst case for the title.
    private static let copilot = StewardAgent(source: .copilot, stewardName: "GitHub Copilot CLI")

    var body: some View {
        let palette = OnboardingPalette(colorScheme: colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach([CGFloat(340), 520, 900], id: \.self) { width in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("— \(Int(width))pt pane —")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.secondary)
                        VStack(spacing: 8) {
                            StewardCard(palette: palette, agent: Self.qwen,
                                        onSignUp: {}, onLearnMore: {}, onDismiss: {},
                                        paneWidth: width)
                            StewardCard(palette: palette, agent: Self.copilot,
                                        onSignUp: {}, onLearnMore: {}, onDismiss: {},
                                        paneWidth: width)
                            ContributeCard(palette: palette, onOpen: {}, onLearnMore: {},
                                           onSnooze: {}, onDismiss: {}, paneWidth: width)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(width: width)
                    }
                }
            }
            .padding(20)
        }
        .environment(\.colorScheme, colorScheme)
    }
}

#Preview("StewardCard • Light") { StewardCardPreviewMatrix(colorScheme: .light) }
#Preview("StewardCard • Dark") { StewardCardPreviewMatrix(colorScheme: .dark) }
#endif

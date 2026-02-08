import SwiftUI
import AppKit

struct OnboardingSheetView: View {
    let content: OnboardingContent
    @ObservedObject var coordinator: OnboardingCoordinator
    @ObservedObject var codexIndexer: SessionIndexer
    @ObservedObject var claudeIndexer: ClaudeSessionIndexer
    @ObservedObject var geminiIndexer: GeminiSessionIndexer
    @ObservedObject var opencodeIndexer: OpenCodeSessionIndexer
    @ObservedObject var copilotIndexer: CopilotSessionIndexer
    @ObservedObject var droidIndexer: DroidSessionIndexer
    @ObservedObject var openclawIndexer: OpenClawSessionIndexer
    @ObservedObject var codexUsageModel: CodexUsageModel
    @ObservedObject var claudeUsageModel: ClaudeUsageModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.geminiEnabled) private var geminiAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.copilotEnabled) private var copilotAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.droidEnabled) private var droidAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openClawEnabled) private var openClawAgentEnabled: Bool = AgentEnablement.isAvailable(.openclaw)

    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.hideZeroMessageSessions) private var hideZeroMessageSessionsPref: Bool = true
    @AppStorage(PreferencesKey.hideLowMessageSessions) private var hideLowMessageSessionsPref: Bool = true
    @AppStorage(PreferencesKey.showHousekeepingSessions) private var showHousekeepingSessionsPref: Bool = false
    @AppStorage(PreferencesKey.Unified.hasCommandsOnly) private var hasCommandsOnlyPref: Bool = false
    @AppStorage(PreferencesKey.showSystemProbeSessions) private var showSystemProbeSessions: Bool = false

    @State private var slideIndex: Int = 0
    @State private var isForward: Bool = true
    @State private var showSkipConfirm: Bool = false
    @State private var animatedPrimarySessions: Double = 0
    @State private var indexedSessionsSnapshot: [SessionSource: [Session]] = [:]
    @State private var didLoadIndexedSessionsSnapshot: Bool = false
    @StateObject private var agentAvailabilityModel = OnboardingAgentAvailabilityModel()

    private let onboardingFeedbackFormURL = URL(string: "https://docs.google.com/forms/d/1SSILAAn0RYmjhWDfJwc5BqpAIunhrJN1SAvy_OzhdaA/viewform")

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }
    private var slides: [OnboardingSlide] { OnboardingSlide.allCases }
    private var isFirst: Bool { slideIndex == 0 }
    private var isLast: Bool { slideIndex == slides.count - 1 }

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
        .task {
            await agentAvailabilityModel.refreshIfNeeded()
        }
        .onAppear {
            loadIndexedSessionsSnapshotIfNeeded()
            updateAnimatedCount(animated: !reduceMotion)
        }
        .onChange(of: totalSessions) { _, _ in
            updateAnimatedCount(animated: !reduceMotion)
        }
        .onChange(of: visibleSessionsTotal) { _, _ in
            updateAnimatedCount(animated: !reduceMotion)
        }
        .onChange(of: content.versionMajorMinor) { _, _ in
            slideIndex = 0
        }
        .onChange(of: content.kind) { _, _ in
            slideIndex = 0
        }
        .alert("Skip onboarding?", isPresented: $showSkipConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Skip", role: .destructive) {
                coordinator.skip()
            }
        } message: {
            Text("You can reopen this tour from the Help menu.")
        }
    }

    private var slideView: some View {
        Group {
            switch slides[slideIndex] {
            case .sessionsFound:
                sessionsFoundSlide
            case .connectAgents:
                connectAgentsSlide
            case .workWithSessions:
                workWithSessionsSlide
            case .analyticsUsage:
                analyticsUsageSlide
            }
        }
        .id(slideIndex)
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

    private var sessionsFoundSlide: some View {
        VStack(spacing: 22) {
            SlideHeader(
                palette: palette,
                icon: .appIcon,
                iconGradient: palette.iconGradientPrimary,
                title: nil,
                subtitle: "Your CLI agent history is ready to explore"
            )

            VStack(spacing: 10) {
                HStack(spacing: 18) {
                    CountingNumberText(value: animatedPrimarySessions, font: .system(size: 56, weight: .regular, design: .default))
                        .foregroundStyle(palette.accentBlue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("sessions visible")
                            .font(.system(size: 16, weight: .semibold, design: .default))
                            .foregroundStyle(.primary)
                    }
                }

                Text("\(formattedCount(hiddenSessionsCount)) hidden by current filters. Adjust in Settings.")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(displayAgents) { agent in
                    AgentPill(agent: agent, palette: palette)
                }
            }

            if let onboardingFeedbackFormURL {
                FeedbackRequestCard(palette: palette, formURL: onboardingFeedbackFormURL)
            }
        }
    }

    private var connectAgentsSlide: some View {
        VStack(spacing: 14) {
            SlideHeader(
                palette: palette,
                icon: .symbol("display"),
                iconGradient: palette.iconGradientBlue,
                title: "Connect Your Agents",
                subtitle: "Enable the agents you use. Disabled agents will not appear in filters or analytics."
            )

            VStack(spacing: 10) {
                if totalSessions == 0 {
                    OnboardingEmptyState(text: "No sessions found yet. Check Settings → Paths to connect an agent.", palette: palette)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(agentsForToggles) { agent in
                        AgentToggleTile(
                            agent: agent,
                            palette: palette,
                            isOn: agentBinding(for: agent.source),
                            isDisabled: isToggleDisabled(for: agent.source)
                        )
                    }
                }
            }

            TipBox(
                text: "Start with one agent to confirm sessions appear, then enable others. You can change this anytime in Settings.",
                palette: palette
            )
        }
    }

    private var workWithSessionsSlide: some View {
        VStack(spacing: 18) {
            SlideHeader(
                palette: palette,
                icon: .symbol("list.bullet"),
                iconGradient: palette.iconGradientGreen,
                title: "Work With Sessions",
                subtitle: "Quick actions to navigate and manage your work"
            )

            VStack(spacing: 12) {
                FeatureRow(
                    palette: palette,
                    icon: "play.fill",
                    iconColor: palette.accentGreen,
                    title: "Resume Sessions",
                    description: "Continue where you left off in Claude Code or Codex CLI directly from the session list"
                )
                FeatureRow(
                    palette: palette,
                    icon: "arrow.up.arrow.down",
                    iconColor: palette.accentBlue,
                    title: "Sort by Any Column",
                    description: "Click column headers to sort by date, size, agent, or project"
                )
                FeatureRow(
                    palette: palette,
                    icon: "folder.fill",
                    iconColor: palette.accentPurple,
                    title: "Filter by Project",
                    description: "Double-click any project name in the list to filter instantly"
                )
                FeatureRow(
                    palette: palette,
                    icon: "bookmark.fill",
                    iconColor: palette.accentOrange,
                    title: "Save Important Sessions",
                    description: "Keep sessions from being pruned when agent history clears"
                )
            }
        }
    }

    private var analyticsUsageSlide: some View {
        VStack(spacing: 18) {
            SlideHeader(
                palette: palette,
                icon: .symbol("chart.bar.xaxis"),
                iconGradient: palette.iconGradientPurple,
                title: "Analytics & Usage",
                subtitle: "See your coding patterns and track usage limits"
            )

            WeeklyActivityCard(data: weeklyActivity, palette: palette)

            VStack(alignment: .leading, spacing: 10) {
                Text("Usage Limit Tracking")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)

                UsageTrackingCard(
                    palette: palette,
                    source: .claude,
                    isEnabled: $claudeUsageEnabled,
                    codex: codexUsageModel,
                    claude: claudeUsageModel
                )

                UsageTrackingCard(
                    palette: palette,
                    source: .codex,
                    isEnabled: $codexUsageEnabled,
                    codex: codexUsageModel,
                    claude: claudeUsageModel
                )
            }

            Text("Limit tracking syncs with your terminal. Toggle off anytime in Settings.")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Button("Skip") {
                showSkipConfirm = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            OnboardingProgressDots(
                count: slides.count,
                index: slideIndex,
                palette: palette,
                onSelect: { target in
                    goToSlide(target)
                }
            )
            .accessibilityLabel("Step \(slideIndex + 1) of \(slides.count)")

            Spacer()

            HStack(spacing: 10) {
                if !isFirst {
                    Button("Back") {
                        goToSlide(max(0, slideIndex - 1))
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle(palette: palette))
                }

                Button(isLast ? "Get Started" : "Next") {
                    if isLast {
                        coordinator.complete()
                    } else {
                        goToSlide(min(slides.count - 1, slideIndex + 1))
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

    private func updateAnimatedCount(animated: Bool) {
        let target = Double(primarySessionCount)
        if !animated {
            animatedPrimarySessions = target
            return
        }
        withAnimation(.easeOut(duration: 0.7)) {
            animatedPrimarySessions = target
        }
    }

    private func agentBinding(for source: SessionSource) -> Binding<Bool> {
        switch source {
        case .codex:
            return Binding(
                get: { codexAgentEnabled },
                set: { _ = AgentEnablement.setEnabled(.codex, enabled: $0) }
            )
        case .claude:
            return Binding(
                get: { claudeAgentEnabled },
                set: { _ = AgentEnablement.setEnabled(.claude, enabled: $0) }
            )
        case .gemini:
            return Binding(
                get: { geminiAgentEnabled },
                set: { _ = AgentEnablement.setEnabled(.gemini, enabled: $0) }
            )
        case .opencode:
            return Binding(
                get: { openCodeAgentEnabled },
                set: { _ = AgentEnablement.setEnabled(.opencode, enabled: $0) }
            )
        case .copilot:
            return Binding(
                get: { copilotAgentEnabled },
                set: { _ = AgentEnablement.setEnabled(.copilot, enabled: $0) }
            )
        case .droid:
            return Binding(
                get: { droidAgentEnabled },
                set: { _ = AgentEnablement.setEnabled(.droid, enabled: $0) }
            )
        case .openclaw:
            return Binding(
                get: { openClawAgentEnabled },
                set: { _ = AgentEnablement.setEnabled(.openclaw, enabled: $0) }
            )
        }
    }

    private var agentCounts: [AgentCount] {
        SessionSource.allCases.map { source in
            let sessions = sessionsForCounts(source: source)
            return AgentCount(
                source: source,
                totalCount: sessions.count,
                visibleCount: visibleCount(in: sessions),
                isEnabled: isAgentEnabled(source)
            )
        }
    }

    private var totalSessions: Int {
        agentCounts.reduce(0) { $0 + $1.totalCount }
    }

    private var visibleSessionsTotal: Int {
        agentCounts.reduce(0) { $0 + $1.visibleCount }
    }

    private var primarySessionCount: Int {
        visibleSessionsTotal
    }

    private var hiddenSessionsCount: Int {
        max(0, totalSessions - visibleSessionsTotal)
    }

    private var displayAgents: [AgentCount] {
        agentCounts.sorted { lhs, rhs in
            if lhs.displayCount == rhs.displayCount {
                return lhs.source.displayName < rhs.source.displayName
            }
            return lhs.displayCount > rhs.displayCount
        }
    }

    private var agentsForToggles: [AgentCount] {
        // Preserve the enum order (matches Preferences)
        SessionSource.allCases.compactMap { source in
            agentCounts.first(where: { $0.source == source })
        }
    }

    private func sessionsForCounts(source: SessionSource) -> [Session] {
        let live = sessionsFromIndexer(source)
        if !live.isEmpty { return live }
        if let snapshot = indexedSessionsSnapshot[source], !snapshot.isEmpty { return snapshot }
        return live
    }

    private func sessionsFromIndexer(_ source: SessionSource) -> [Session] {
        switch source {
        case .codex: return codexIndexer.allSessions
        case .claude: return claudeIndexer.allSessions
        case .gemini: return geminiIndexer.allSessions
        case .opencode: return opencodeIndexer.allSessions
        case .copilot: return copilotIndexer.allSessions
        case .droid: return droidIndexer.allSessions
        case .openclaw: return openclawIndexer.allSessions
        }
    }

    private func isAgentEnabled(_ source: SessionSource) -> Bool {
        switch source {
        case .codex: return codexAgentEnabled
        case .claude: return claudeAgentEnabled
        case .gemini: return geminiAgentEnabled
        case .opencode: return openCodeAgentEnabled
        case .copilot: return copilotAgentEnabled
        case .droid: return droidAgentEnabled
        case .openclaw: return openClawAgentEnabled
        }
    }

    private func isToggleDisabled(for source: SessionSource) -> Bool {
        let enabledCount = SessionSource.allCases.filter { isAgentEnabled($0) }.count
        let isCurrentlyOn = isAgentEnabled(source)
        let canDisable = !(enabledCount == 1 && isCurrentlyOn)

        let availability = agentAvailabilityModel.availability(for: source)
        let canEnable = availability != .missing || isCurrentlyOn

        return !(canDisable && canEnable)
    }

    private func loadIndexedSessionsSnapshotIfNeeded() {
        guard !didLoadIndexedSessionsSnapshot else { return }
        didLoadIndexedSessionsSnapshot = true

        Task(priority: .utility) {
            do {
                let snapshot = try await buildIndexedSessionsSnapshot()
                await MainActor.run {
                    self.indexedSessionsSnapshot = snapshot
                }
            } catch {
                // Best-effort: onboarding can still render live counts from active indexers.
            }
        }
    }

    private func buildIndexedSessionsSnapshot() async throws -> [SessionSource: [Session]] {
        let db = try IndexDB()
        let repo = SessionMetaRepository(db: db)
        var snapshot: [SessionSource: [Session]] = [:]
        for source in SessionSource.allCases {
            if let sessions = try? await repo.fetchSessions(for: source) {
                snapshot[source] = sessions
            }
        }
        return snapshot
    }

    private var weeklyActivity: [WeeklyActivityDay] {
        let sessions = codexIndexer.allSessions
            + claudeIndexer.allSessions
            + geminiIndexer.allSessions
            + opencodeIndexer.allSessions
            + copilotIndexer.allSessions
            + droidIndexer.allSessions
            + openclawIndexer.allSessions
        return WeeklyActivityDay.build(from: sessions, palette: palette)
    }

    private func visibleCount(in sessions: [Session]) -> Int {
        sessions.filter { isVisibleSession($0) }.count
    }

    private func isVisibleSession(_ session: Session) -> Bool {
        // Probes are filtered out of live indexers, but DB snapshots may include them.
        if !showSystemProbeSessions {
            switch session.source {
            case .codex:
                if CodexProbeConfig.isProbeSession(session) { return false }
            case .claude:
                if ClaudeProbeConfig.isProbeSession(session) { return false }
            default:
                break
            }
        }

        if !showHousekeepingSessionsPref, session.isHousekeeping { return false }

        // Message count filters (OpenCode excluded from msg-count heuristics)
        if session.source != .opencode {
            if hideZeroMessageSessionsPref, session.messageCount == 0 { return false }
            if hideLowMessageSessionsPref, session.messageCount > 0, session.messageCount <= 2 { return false }
        }

        // Tool-call-only filter (strict)
        if hasCommandsOnlyPref {
            switch session.source {
            case .codex, .opencode, .copilot, .droid, .openclaw:
                if !session.events.isEmpty {
                    if !session.events.contains(where: { $0.kind == .tool_call }) { return false }
                } else {
                    if (session.lightweightCommands ?? 0) <= 0 { return false }
                }
            case .claude, .gemini:
                if session.events.isEmpty { return false }
                if !session.events.contains(where: { $0.kind == .tool_call }) { return false }
            }
        }

        return true
    }

    private func formattedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private enum OnboardingAgentAvailability: Equatable, Sendable {
    case unknown
    case present
    case missing
}

@MainActor
private final class OnboardingAgentAvailabilityModel: ObservableObject {
    @Published private var availabilityBySource: [SessionSource: OnboardingAgentAvailability] = [:]
    private var didCompute: Bool = false

    func availability(for source: SessionSource) -> OnboardingAgentAvailability {
        availabilityBySource[source] ?? .unknown
    }

    func refreshIfNeeded() async {
        if didCompute { return }
        didCompute = true
        await refresh()
    }

    func refresh() async {
        let computed = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: SessionSource.allCases.map { source in
                let availability: OnboardingAgentAvailability = AgentEnablement.isAvailable(source) ? .present : .missing
                return (source, availability)
            })
        }.value

        availabilityBySource = computed
    }
}

private enum OnboardingSlide: Int, CaseIterable {
    case sessionsFound
    case connectAgents
    case workWithSessions
    case analyticsUsage
}

private struct AgentCount: Identifiable {
    let source: SessionSource
    let totalCount: Int
    let visibleCount: Int
    let isEnabled: Bool

    var id: String { source.rawValue }
    var displayCount: Int { visibleCount }
}

private struct SlideHeader: View {
    let palette: OnboardingPalette
    let icon: SlideIcon
    let iconGradient: LinearGradient
    let title: String?
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            SlideIconView(icon: icon, gradient: iconGradient)

            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }

            Text(subtitle)
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private enum SlideIcon {
    case appIcon
    case symbol(String)
}

private struct SlideIconView: View {
    let icon: SlideIcon
    let gradient: LinearGradient

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
    }
}

private struct AgentPill: View {
    let agent: AgentCount
    let palette: OnboardingPalette

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(palette.agentAccent(for: agent.source))
                .frame(width: 8, height: 8)

            Text(agent.source.displayName)
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(.primary)

            Text("\(agent.displayCount)")
                .font(.system(size: 13, weight: .regular, design: .default))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if !agent.isEnabled {
                Text("Inactive")
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(palette.tipFill)
                    )
                    .overlay(
                        Capsule()
                            .stroke(palette.tipStroke, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(palette.pillFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(palette.pillStroke, lineWidth: 1)
        )
        .opacity(agent.isEnabled ? 1.0 : 0.7)
    }
}

private struct AgentToggleTile: View {
    let agent: AgentCount
    let palette: OnboardingPalette
    let isOn: Binding<Bool>
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            AgentBadge(source: agent.source, palette: palette, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.source.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)
                    .opacity(agent.isEnabled ? 1.0 : 0.7)
                HStack(spacing: 4) {
                    Text("\(agent.displayCount)")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .monospacedDigit()
                    Text("sessions found")
                        .font(.system(size: 11, weight: .regular, design: .default))
                }
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

private struct AgentBadge: View {
    let source: SessionSource
    let palette: OnboardingPalette
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(palette.agentAccent(for: source))
                .frame(width: size, height: size)

            Text(initials(for: source))
                .font(.system(size: size * 0.33, weight: .bold, design: .default))
                .foregroundStyle(.white)
        }
    }

    private func initials(for source: SessionSource) -> String {
        switch source {
        case .claude: return "CC"
        case .codex: return "CX"
        case .gemini: return "G"
        case .opencode: return "OC"
        case .copilot: return "CP"
        case .droid: return "D"
        case .openclaw: return "CL"
        }
    }
}

private struct TipBox: View {
    let text: String
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

private struct FeedbackRequestCard: View {
    let palette: OnboardingPalette
    let formURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "square.and.pencil.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accentBlue)

                Text("Help improve Agent Sessions")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)
            }

            Text("Agent Sessions is a local-only app with no telemetry. This short form is the only way for us to receive your feedback.")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(.secondary)

            Link(destination: formURL) {
                HStack(spacing: 6) {
                    Text("Fill out the short feedback form")
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12, weight: .semibold, design: .default))
                .foregroundStyle(palette.accentBlue)
            }
            .buttonStyle(.plain)

        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(palette.tipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(palette.tipStroke, lineWidth: 1)
        )
    }
}

private struct FeatureRow: View {
    let palette: OnboardingPalette
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)
                Text(description)
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

private struct OnboardingEmptyState: View {
    let text: String
    let palette: OnboardingPalette

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(.secondary)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
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

private struct WeeklyActivityCard: View {
    let data: [WeeklyActivityDay]
    let palette: OnboardingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sessions by Agent")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Last 7 days")
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
            }

            WeeklyActivityChart(data: data, palette: palette)
        }
        .padding(16)
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

private struct WeeklyActivityChart: View {
    let data: [WeeklyActivityDay]
    let palette: OnboardingPalette

    var body: some View {
        let barWidth: CGFloat = 36
        let maxBarHeight: CGFloat = 72
        let maxTotal = max(1, data.map { $0.total }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(data) { day in
                let filledHeight = day.filledHeight(maxTotal: maxTotal, maxBarHeight: maxBarHeight)
                let segmentHeights = day.segmentHeights(maxTotal: maxTotal, maxBarHeight: maxBarHeight)
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.chartBase)
                            .frame(width: barWidth, height: maxBarHeight)

                        VStack(spacing: 0) {
                            ForEach(Array(day.segments.indices), id: \.self) { index in
                                let segment = day.segments[index]
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(segment.color)
                                    .frame(width: barWidth, height: segmentHeights[index])
                            }
                        }
                        .frame(width: barWidth, height: filledHeight, alignment: .bottom)
                        .clipped()
                    }

                    Text(day.label)
                        .font(.system(size: 10, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WeeklyActivityDay: Identifiable {
    struct Segment: Identifiable {
        let id = UUID()
        let color: Color
        let count: Int
    }

    let id = UUID()
    let label: String
    let total: Int
    let segments: [Segment]

    func filledHeight(maxTotal: Int, maxBarHeight: CGFloat) -> CGFloat {
        guard total > 0, maxTotal > 0 else { return 0 }
        return (CGFloat(total) / CGFloat(maxTotal)) * maxBarHeight
    }

    func segmentHeights(maxTotal: Int, maxBarHeight: CGFloat) -> [CGFloat] {
        guard total > 0 else { return segments.map { _ in 0 } }
        let fillHeight = filledHeight(maxTotal: maxTotal, maxBarHeight: maxBarHeight)
        return segments.map { segment in
            (CGFloat(segment.count) / CGFloat(total)) * fillHeight
        }
    }

    static func build(from sessions: [Session], palette: OnboardingPalette) -> [WeeklyActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var buckets: [Date: [SessionSource: Int]] = [:]

        for session in sessions {
            let date = calendar.startOfDay(for: session.modifiedAt)
            guard date >= start else { continue }
            var counts = buckets[date] ?? [:]
            counts[session.source, default: 0] += 1
            buckets[date] = counts
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEE")

        var days: [WeeklyActivityDay] = []
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: start) ?? today
            let label = formatter.string(from: day)
            let counts = buckets[day] ?? [:]
            let total = counts.values.reduce(0, +)
            let segments = counts.map { key, value in
                Segment(color: palette.agentAccent(for: key), count: value)
            }.sorted { $0.count > $1.count }
            days.append(WeeklyActivityDay(label: label, total: total, segments: segments))
        }

        if days.allSatisfy({ $0.total == 0 }) {
            let placeholder = [6, 4, 7, 2, 5, 4, 6]
            return placeholder.enumerated().map { index, value in
                let day = calendar.date(byAdding: .day, value: index, to: start) ?? today
                return WeeklyActivityDay(
                    label: formatter.string(from: day),
                    total: value,
                    segments: [Segment(color: palette.accentOrange, count: value)]
                )
            }
        }

        return days
    }
}

private struct UsageTrackingCard: View {
    let palette: OnboardingPalette
    let source: SessionSource
    let isEnabled: Binding<Bool>
    let codex: CodexUsageModel
    let claude: ClaudeUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentBadge(source: source, palette: palette, size: 28)

                Text(source.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)

                Text("Live")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(palette.liveBadgeText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(palette.liveBadgeFill)
                    )

                Spacer()

                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.9, anchor: .trailing)
            }

            HStack {
                Spacer()
                Text(usageText(for: source))
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ProgressBar(progress: usageProgress(for: source), palette: palette, accent: palette.agentAccent(for: source))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(palette.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(palette.rowStroke, lineWidth: 1)
        )
    }

    private func usageProgress(for source: SessionSource) -> Double {
        switch source {
        case .claude:
            if claude.lastUpdate == nil {
                return 0.68
            }
            return max(0, min(1, Double(100 - claude.weekAllModelsRemainingPercent) / 100.0))
        case .codex:
            if codex.lastUpdate == nil {
                return 0.54
            }
            return max(0, min(1, Double(100 - codex.fiveHourRemainingPercent) / 100.0))
        default:
            return 0
        }
    }

    private func usageText(for source: SessionSource) -> String {
        let totalSeconds = 5 * 60 * 60
        let usedSeconds: Int
        switch source {
        case .claude:
            if claude.lastUpdate == nil {
                return "2h 15m / 5h"
            }
            usedSeconds = Int(Double(totalSeconds) * usageProgress(for: .claude))
        case .codex:
            if codex.lastUpdate == nil {
                return "1h 40m / 5h"
            }
            usedSeconds = Int(Double(totalSeconds) * usageProgress(for: .codex))
        default:
            usedSeconds = 0
        }
        return "\(formatDuration(usedSeconds)) / 5h"
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private struct ProgressBar: View {
    let progress: Double
    let palette: OnboardingPalette
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.meterBackground)
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 4)
                    .fill(accent)
                    .frame(width: proxy.size.width * CGFloat(max(0, min(progress, 1))), height: 6)
            }
        }
        .frame(height: 6)
    }
}

private struct OnboardingProgressDots: View {
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
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
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
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
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
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct OnboardingAmbientBackground: View {
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
                .fill(palette.orbPurple)
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

private struct OnboardingGlassCard<Content: View>: View {
    let palette: OnboardingPalette
    let content: Content

    init(palette: OnboardingPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: palette.blurMaterial, blendingMode: .withinWindow, state: .active)

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

private struct VisualEffectBlur: NSViewRepresentable {
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

private struct CountingNumberText: View {
    var value: Double
    var font: Font

    var body: some View {
        Text("\(Int(value.rounded()))")
            .font(font)
            .monospacedDigit()
    }
}

extension CountingNumberText: Animatable {
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
}

private struct OnboardingPalette {
    let colorScheme: ColorScheme
    private var controlAccent: NSColor { NSColor.controlAccentColor }

    private func blendAccent(towards target: NSColor, fraction: CGFloat) -> Color {
        Color(nsColor: controlAccent.blended(withFraction: fraction, of: target) ?? controlAccent)
    }

    var backgroundTop: Color {
        colorScheme == .dark
            ? Color(red: 0.05, green: 0.06, blue: 0.09)
            : Color(red: 0.94, green: 0.96, blue: 0.98)
    }

    var backgroundBottom: Color {
        colorScheme == .dark
            ? Color(red: 0.06, green: 0.08, blue: 0.12)
            : Color(red: 0.90, green: 0.93, blue: 0.98)
    }

    var cardFill: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.55)
            : Color.white.opacity(0.85)
    }

    var cardStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    var cardShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.45)
            : Color.black.opacity(0.18)
    }

    var divider: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    var rowFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    var rowStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    var pillFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.04)
    }

    var pillStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.08)
    }

    var tipFill: Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.18, blue: 0.32, opacity: 0.45)
            : Color(red: 0.55, green: 0.68, blue: 0.92, opacity: 0.2)
    }

    var tipStroke: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.38, blue: 0.64, opacity: 0.4)
            : Color(red: 0.45, green: 0.60, blue: 0.82, opacity: 0.4)
    }

    var dotActive: Color {
        accentBlue
    }

    var dotInactive: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.18)
            : Color.black.opacity(0.16)
    }

    var iconGradientPrimary: LinearGradient {
        LinearGradient(
            colors: [
                blendAccent(towards: .white, fraction: colorScheme == .dark ? 0.12 : 0.18),
                blendAccent(towards: .black, fraction: colorScheme == .dark ? 0.18 : 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var iconGradientBlue: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.26, green: 0.56, blue: 0.96), Color(red: 0.38, green: 0.70, blue: 0.98)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var iconGradientGreen: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.28, green: 0.78, blue: 0.58), Color(red: 0.40, green: 0.86, blue: 0.66)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var iconGradientPurple: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.64, green: 0.45, blue: 0.95), Color(red: 0.85, green: 0.44, blue: 0.82)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var primaryGradient: LinearGradient {
        LinearGradient(
            colors: [
                blendAccent(towards: .white, fraction: colorScheme == .dark ? 0.10 : 0.14),
                blendAccent(towards: .black, fraction: colorScheme == .dark ? 0.16 : 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var primaryFinalGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.29, green: 0.78, blue: 0.60), Color(red: 0.30, green: 0.68, blue: 0.82)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var primaryLiquidOverlay: RadialGradient {
        RadialGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.22 : 0.28),
                Color.white.opacity(0.0)
            ],
            center: .topLeading,
            startRadius: 6,
            endRadius: 140
        )
    }

    var primaryLiquidOverlayOpacity: Double {
        colorScheme == .dark ? 0.34 : 0.26
    }

    var primaryButtonStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.12)
    }

    var primaryButtonShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.42)
            : Color.black.opacity(0.18)
    }

    var secondaryButtonFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.05)
    }

    var secondaryButtonStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.1)
    }

    var meterBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    var chartBase: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.04)
    }

    var liveBadgeFill: Color {
        Color(red: 0.19, green: 0.68, blue: 0.36, opacity: colorScheme == .dark ? 0.35 : 0.2)
    }

    var liveBadgeText: Color {
        colorScheme == .dark
            ? Color(red: 0.58, green: 0.92, blue: 0.68)
            : Color(red: 0.18, green: 0.52, blue: 0.28)
    }

    var orbBlue: Color {
        Color(red: 0.28, green: 0.55, blue: 0.98, opacity: colorScheme == .dark ? 0.35 : 0.18)
    }

    var orbPurple: Color {
        Color(red: 0.64, green: 0.45, blue: 0.95, opacity: colorScheme == .dark ? 0.35 : 0.16)
    }

    var orbCyan: Color {
        Color(red: 0.32, green: 0.85, blue: 0.88, opacity: colorScheme == .dark ? 0.32 : 0.15)
    }

    var accentOrange: Color {
        Color(red: 0.95, green: 0.58, blue: 0.25)
    }

    var accentGreen: Color {
        Color(red: 0.30, green: 0.78, blue: 0.56)
    }

    var accentBlue: Color {
        Color(red: 0.36, green: 0.62, blue: 0.96)
    }

    var accentPurple: Color {
        Color(red: 0.64, green: 0.45, blue: 0.95)
    }

    var blurMaterial: NSVisualEffectView.Material {
        colorScheme == .dark ? .hudWindow : .sidebar
    }

    func agentAccent(for source: SessionSource) -> Color {
        switch source {
        case .claude:
            return accentOrange
        case .codex:
            return accentGreen
        case .gemini:
            return accentBlue
        case .opencode:
            return Color(red: 0.62, green: 0.52, blue: 0.96)
        case .copilot:
            return Color(red: 0.82, green: 0.36, blue: 0.78)
        case .droid:
            return Color(red: 0.26, green: 0.72, blue: 0.38)
        case .openclaw:
            return Color(red: 0.95, green: 0.55, blue: 0.18)
        }
    }
}

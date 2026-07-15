import SwiftUI
import AppKit

/// First-run setup — a single screen shown once on a fresh install. It replaces
/// the old multi-slide tour with two blocks: "Your sessions" (an animated
/// "N sessions found" count + agent toggle grid) and "Quota Meter" (a looping
/// demo GIF + a single Enable Quota Meter switch), plus a Start Exploring
/// button. Esc is equivalent to Start Exploring (completion is recorded either
/// way).
struct FirstRunSetupView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let codexIndexer: SessionIndexer
    let claudeIndexer: ClaudeSessionIndexer
    let antigravityIndexer: AntigravitySessionIndexer
    let opencodeIndexer: OpenCodeSessionIndexer
    let hermesIndexer: HermesSessionIndexer
    let copilotIndexer: CopilotSessionIndexer
    let droidIndexer: DroidSessionIndexer
    let openclawIndexer: OpenClawSessionIndexer
    let cursorIndexer: CursorSessionIndexer
    let piIndexer: PiSessionIndexer

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.antigravityEnabled) private var antigravityAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.hermesEnabled) private var hermesAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.copilotEnabled) private var copilotAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.droidEnabled) private var droidAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openClawEnabled) private var openClawAgentEnabled: Bool = false
    @AppStorage(PreferencesKey.Agents.cursorEnabled) private var cursorAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.piEnabled) private var piAgentEnabled: Bool = AgentEnablement.isEnabled(.pi)

    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.hideZeroMessageSessions) private var hideZeroMessageSessionsPref: Bool = true
    @AppStorage(PreferencesKey.hideLowMessageSessions) private var hideLowMessageSessionsPref: Bool = true
    @AppStorage(PreferencesKey.showHousekeepingSessions) private var showHousekeepingSessionsPref: Bool = false
    @AppStorage(PreferencesKey.Unified.hasCommandsOnly) private var hasCommandsOnlyPref: Bool = false
    @AppStorage(PreferencesKey.showSystemProbeSessions) private var showSystemProbeSessions: Bool = false

    @State private var animatedPrimarySessions: Double = 0
    @State private var indexedSessionsSnapshot: [SessionSource: [Session]] = [:]
    @State private var cachedSessionCounts: [SessionSource: (total: Int, visible: Int)] = [:]
    @State private var didLoadIndexedSessionsSnapshot: Bool = false
    /// The count-up animation runs once; later updates snap so the number never re-spins.
    @State private var didAnimateCount: Bool = false
    /// Cheap raw per-source counts; skip the expensive visible-filter when unchanged.
    @State private var lastRawCounts: [SessionSource: Int] = [:]
    @StateObject private var availabilityModel = FirstRunAgentAvailabilityModel()

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }

    /// Asset-catalog data set holding the looping Quota Meter demo GIF.
    private static let quotaMeterGIFAsset = "OnboardingQuotaMeterRunwayAnimated"
    /// Trimmed GIF is 640×188; keep the frame on that aspect so it never distorts.
    private static let quotaMeterGIFWidth: CGFloat = 420
    private static let quotaMeterGIFAspect: CGFloat = 640.0 / 188.0

    var body: some View {
        ZStack {
            OnboardingAmbientBackground(palette: palette, animate: !reduceMotion)

            OnboardingGlassCard(palette: palette) {
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: 560, maxHeight: .infinity)
                        .padding(.horizontal, 30)
                        .padding(.top, 24)
                        .padding(.bottom, 14)

                    Rectangle()
                        .fill(palette.divider)
                        .frame(height: 1)

                    footer
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            }
            .frame(minWidth: 620, minHeight: 640)
            .padding(20)
        }
        .frame(minWidth: 680, minHeight: 720)
        .task { await availabilityModel.refreshIfNeeded() }
        .onAppear {
            seedQuotaMeterOnForFreshInstall()
            loadIndexedSessionsSnapshotIfNeeded()
            handleSessionDataUpdate()
        }
        .onReceive(codexIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(claudeIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(antigravityIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(opencodeIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(hermesIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(copilotIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(droidIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(openclawIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(cursorIndexer.$allSessions) { _ in handleSessionDataUpdate() }
        .onReceive(piIndexer.$allSessions) { _ in handleSessionDataUpdate() }
    }

    private var content: some View {
        VStack(spacing: 14) {
            SlideHeader(
                palette: palette,
                icon: .appIcon,
                iconGradient: palette.iconGradientPrimary,
                title: nil,
                subtitle: "Your CLI agent history is ready to explore"
            )

            // Block A flexes and scrolls internally; Block B stays pinned so the
            // Quota Meter is always on screen no matter how many agents there are.
            sessionsBlock
                .frame(maxHeight: .infinity)
            quotaMeterBlock

            Text("Tips live in Help → Power Tips.")
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Block A: Your sessions

    private var sessionsBlock: some View {
        setupBlock(title: "Your sessions", fill: true) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    CountingNumberText(value: animatedPrimarySessions, font: .system(size: 40, weight: .regular, design: .default))
                        .foregroundStyle(palette.accentBlue)
                    Text("sessions found")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    if hiddenSessionsCount > 0 {
                        Spacer(minLength: 8)
                        Text("\(formattedCount(hiddenSessionsCount)) hidden")
                            .font(.system(size: 11, weight: .regular, design: .default))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(agentsForToggles, id: \.rawValue) { source in
                            let counts = cachedSessionCounts[source] ?? (total: 0, visible: 0)
                            AgentToggleTile(
                                source: source,
                                displayName: source.displayName,
                                count: counts.visible,
                                isEnabled: isAgentEnabled(source),
                                palette: palette,
                                isOn: agentBinding(for: source),
                                isDisabled: isToggleDisabled(for: source)
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Block B: Quota Meter

    private var quotaMeterBlock: some View {
        setupBlock(title: "Quota Meter") {
            VStack(spacing: 16) {
                quotaMeterDemo

                HStack(spacing: 12) {
                    Text("Enable Quota Meter")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: quotaMeterBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .scaleEffect(0.9, anchor: .trailing)
                }
            }
        }
    }

    /// Looping GIF of the real Quota Meter. Static first frame under Reduce Motion.
    @ViewBuilder
    private var quotaMeterDemo: some View {
        if AnimatedGIFView.hasAsset(named: Self.quotaMeterGIFAsset) {
            // Fixed exact-aspect frame: the GIF fills it precisely, so it never
            // crops (a maxWidth + aspectRatio combo let the NSImageView overflow).
            AnimatedGIFView(assetName: Self.quotaMeterGIFAsset, animates: !reduceMotion)
                .frame(width: Self.quotaMeterGIFWidth, height: Self.quotaMeterGIFWidth / Self.quotaMeterGIFAspect)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(palette.rowStroke, lineWidth: 1)
                )
                .frame(maxWidth: .infinity)
        }
    }

    /// One rounded, uppercase-titled block on the gray card background, matching
    /// the "Your sessions" / "Quota Meter" pairing.
    private func setupBlock<Inner: View>(title: String, fill: Bool = false, @ViewBuilder content: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .default))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
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

    /// Fresh installs land with the Quota Meter already on. The switch below is
    /// the highest-leverage lever the feature has, and off-by-default silently
    /// loses everyone who clicks straight through — onboarding never asks again.
    ///
    /// Only seeds when neither key has ever been written, so it can never
    /// overturn a deliberate choice, and the switch stays the user's to flip
    /// before leaving this screen. Enabling tracking does not open any window;
    /// it only starts usage probes.
    private func seedQuotaMeterOnForFreshInstall() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PreferencesKey.codexUsageEnabled) == nil,
              defaults.object(forKey: PreferencesKey.claudeUsageEnabled) == nil else { return }
        codexUsageEnabled = true
        claudeUsageEnabled = true
    }

    /// Enables/disables the Quota Meter as a whole from a single switch.
    private var quotaMeterBinding: Binding<Bool> {
        Binding(
            get: { codexUsageEnabled || claudeUsageEnabled },
            set: { newValue in
                codexUsageEnabled = newValue
                claudeUsageEnabled = newValue
            }
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Start Exploring") {
                coordinator.complete()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle(palette: palette, isFinal: true))
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Counts

    private var agentsForToggles: [SessionSource] { SessionSource.allCases }

    private var totalSessions: Int {
        SessionSource.allCases.reduce(0) { $0 + (cachedSessionCounts[$1]?.total ?? 0) }
    }

    private var visibleSessionsTotal: Int {
        SessionSource.allCases.reduce(0) { $0 + (cachedSessionCounts[$1]?.visible ?? 0) }
    }

    private var hiddenSessionsCount: Int {
        max(0, totalSessions - visibleSessionsTotal)
    }

    private func handleSessionDataUpdate() {
        // The 10 indexers each publish on appear; skip the expensive visible-filter
        // recompute when the cheap raw per-source counts haven't actually changed.
        let raw = rawCountsSignature()
        guard raw != lastRawCounts else { return }
        lastRawCounts = raw
        refreshSessionCounts()
        updateAnimatedCount(animated: !reduceMotion)
    }

    private func rawCountsSignature() -> [SessionSource: Int] {
        var signature: [SessionSource: Int] = [:]
        for source in SessionSource.allCases {
            let live = sessionsFromIndexer(source).count
            signature[source] = live > 0 ? live : (indexedSessionsSnapshot[source]?.count ?? 0)
        }
        return signature
    }

    private func updateAnimatedCount(animated: Bool) {
        let target = Double(visibleSessionsTotal)
        // Animate the count-up exactly once (the first time real data arrives);
        // every later update snaps, so the number never re-spins.
        if animated, !didAnimateCount, target > 0 {
            didAnimateCount = true
            withAnimation(.easeOut(duration: 0.7)) {
                animatedPrimarySessions = target
            }
        } else {
            animatedPrimarySessions = target
        }
    }

    private func refreshSessionCounts() {
        var counts: [SessionSource: (total: Int, visible: Int)] = [:]
        for source in SessionSource.allCases {
            let live = sessionsFromIndexer(source)
            if !live.isEmpty {
                counts[source] = (total: live.count, visible: visibleCount(in: live))
            } else if let snapshot = indexedSessionsSnapshot[source] {
                counts[source] = (total: snapshot.count, visible: visibleCount(in: snapshot))
            } else {
                counts[source] = (total: 0, visible: 0)
            }
        }
        cachedSessionCounts = counts
    }

    private func sessionsFromIndexer(_ source: SessionSource) -> [Session] {
        switch source {
        case .codex: return codexIndexer.allSessions
        case .claude: return claudeIndexer.allSessions
        case .antigravity: return antigravityIndexer.allSessions
        case .opencode: return opencodeIndexer.allSessions
        case .hermes: return hermesIndexer.allSessions
        case .copilot: return copilotIndexer.allSessions
        case .droid: return droidIndexer.allSessions
        case .openclaw: return openclawIndexer.allSessions
        case .cursor: return cursorIndexer.allSessions
        case .pi: return piIndexer.allSessions
        }
    }

    private func loadIndexedSessionsSnapshotIfNeeded() {
        guard !didLoadIndexedSessionsSnapshot else { return }
        didLoadIndexedSessionsSnapshot = true

        Task(priority: .utility) {
            do {
                let db = try IndexDB()
                let repo = SessionMetaRepository(db: db)
                var snapshot: [SessionSource: [Session]] = [:]
                for source in SessionSource.allCases {
                    if let sessions = try? await repo.fetchSessions(for: source) {
                        snapshot[source] = sessions
                    }
                }
                await MainActor.run {
                    self.indexedSessionsSnapshot = snapshot
                    self.handleSessionDataUpdate()
                }
            } catch {
                // Best-effort: live indexers still supply counts.
            }
        }
    }

    // MARK: - Agent enable/disable

    private func isAgentEnabled(_ source: SessionSource) -> Bool {
        switch source {
        case .codex: return codexAgentEnabled
        case .claude: return claudeAgentEnabled
        case .antigravity: return antigravityAgentEnabled
        case .opencode: return openCodeAgentEnabled
        case .hermes: return hermesAgentEnabled
        case .copilot: return copilotAgentEnabled
        case .droid: return droidAgentEnabled
        case .openclaw: return openClawAgentEnabled
        case .cursor: return cursorAgentEnabled
        case .pi: return piAgentEnabled
        }
    }

    private func agentBinding(for source: SessionSource) -> Binding<Bool> {
        Binding(
            get: { isAgentEnabled(source) },
            set: { _ = AgentEnablement.setEnabled(source, enabled: $0) }
        )
    }

    private func isToggleDisabled(for source: SessionSource) -> Bool {
        let enabledCount = SessionSource.allCases.filter { isAgentEnabled($0) }.count
        let isCurrentlyOn = isAgentEnabled(source)
        let canDisable = !(enabledCount == 1 && isCurrentlyOn)
        let canEnable = availabilityModel.availability(for: source) != .missing || isCurrentlyOn
        return !(canDisable && canEnable)
    }

    // MARK: - Visibility filter (mirrors the session list filters)

    private func visibleCount(in sessions: [Session]) -> Int {
        sessions.filter { isVisibleSession($0) }.count
    }

    private func isVisibleSession(_ session: Session) -> Bool {
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

        if session.source != .opencode, !CursorSessionIndexer.isDBOnlySession(session) {
            if hideZeroMessageSessionsPref, session.messageCount == 0 { return false }
            if hideLowMessageSessionsPref, session.messageCount > 0, session.messageCount <= 2 { return false }
        }

        if hasCommandsOnlyPref {
            switch session.source {
            case .codex, .opencode, .hermes, .copilot, .droid, .openclaw, .cursor, .pi:
                if !session.events.isEmpty {
                    if !session.events.contains(where: { $0.kind == .tool_call }) { return false }
                } else {
                    if (session.lightweightCommands ?? 0) <= 0 { return false }
                }
            case .claude, .antigravity:
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

private enum FirstRunAgentAvailability: Equatable, Sendable {
    case unknown
    case present
    case missing
}

@MainActor
private final class FirstRunAgentAvailabilityModel: ObservableObject {
    @Published private var availabilityBySource: [SessionSource: FirstRunAgentAvailability] = [:]
    private var didCompute: Bool = false

    func availability(for source: SessionSource) -> FirstRunAgentAvailability {
        availabilityBySource[source] ?? .unknown
    }

    func refreshIfNeeded() async {
        if didCompute { return }
        didCompute = true
        let computed = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: SessionSource.allCases.map { source in
                (source, AgentEnablement.isAvailable(source) ? FirstRunAgentAvailability.present : .missing)
            })
        }.value
        availabilityBySource = computed
    }
}

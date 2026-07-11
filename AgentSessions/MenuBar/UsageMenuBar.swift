import SwiftUI
import AppKit
import Combine

@MainActor
private final class UsageMenuBarLiveSummaryModel: ObservableObject {
    @Published private(set) var summary = HUDLiveSessionSummary(activeCount: 0, waitingCount: 0)

    private var activeCodexID: ObjectIdentifier?
    private var codexIndexerID: ObjectIdentifier?
    private var claudeIndexerID: ObjectIdentifier?
    private var opencodeIndexerID: ObjectIdentifier?
    private weak var activeCodex: CodexActiveSessionsModel?
    private weak var codexIndexer: SessionIndexer?
    private weak var claudeIndexer: ClaudeSessionIndexer?
    private weak var opencodeIndexer: OpenCodeSessionIndexer?
    private var lookupIndexes = SessionLookupIndexes(byLogPath: [:], bySessionID: [:], byWorkspace: [:])
    private var cancellables: Set<AnyCancellable> = []

    func connect(activeCodex: CodexActiveSessionsModel,
                 codexIndexer: SessionIndexer,
                 claudeIndexer: ClaudeSessionIndexer,
                 opencodeIndexer: OpenCodeSessionIndexer) {
        let nextActiveCodexID = ObjectIdentifier(activeCodex)
        let nextCodexIndexerID = ObjectIdentifier(codexIndexer)
        let nextClaudeIndexerID = ObjectIdentifier(claudeIndexer)
        let nextOpenCodeIndexerID = ObjectIdentifier(opencodeIndexer)
        guard activeCodexID != nextActiveCodexID
            || codexIndexerID != nextCodexIndexerID
            || claudeIndexerID != nextClaudeIndexerID
            || opencodeIndexerID != nextOpenCodeIndexerID else {
            return
        }

        activeCodexID = nextActiveCodexID
        codexIndexerID = nextCodexIndexerID
        claudeIndexerID = nextClaudeIndexerID
        opencodeIndexerID = nextOpenCodeIndexerID
        self.activeCodex = activeCodex
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.opencodeIndexer = opencodeIndexer
        cancellables.removeAll()

        activeCodex.membershipTicks
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        codexIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                guard let claudeIndexer = self.claudeIndexer else { return }
                self.lookupIndexes = AgentCockpitHUDView.buildSessionLookupIndexes(
                    codexSessions: sessions,
                    claudeSessions: claudeIndexer.allSessions,
                    opencodeSessions: self.opencodeIndexer?.allSessions ?? []
                )
                self.rebuild()
            }
            .store(in: &cancellables)

        claudeIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                guard let codexIndexer = self.codexIndexer else { return }
                self.lookupIndexes = AgentCockpitHUDView.buildSessionLookupIndexes(
                    codexSessions: codexIndexer.allSessions,
                    claudeSessions: sessions,
                    opencodeSessions: self.opencodeIndexer?.allSessions ?? []
                )
                self.rebuild()
            }
            .store(in: &cancellables)

        opencodeIndexer.$allSessions
            .sink { [weak self] sessions in
                guard let self else { return }
                guard let codexIndexer = self.codexIndexer,
                      let claudeIndexer = self.claudeIndexer else { return }
                self.lookupIndexes = AgentCockpitHUDView.buildSessionLookupIndexes(
                    codexSessions: codexIndexer.allSessions,
                    claudeSessions: claudeIndexer.allSessions,
                    opencodeSessions: sessions
                )
                self.rebuild()
            }
            .store(in: &cancellables)

        lookupIndexes = AgentCockpitHUDView.buildSessionLookupIndexes(
            codexSessions: codexIndexer.allSessions,
            claudeSessions: claudeIndexer.allSessions,
            opencodeSessions: opencodeIndexer.allSessions
        )
        rebuild()
    }

    private func rebuild() {
        guard let activeCodex else { return }
        summary = AgentCockpitHUDView.liveSessionSummary(activeCodex: activeCodex, lookupIndexes: lookupIndexes)
    }
}

struct UsageMenuBarLabel: View {
    @Environment(CodexActiveSessionsModel.self) var activeCodex
    @EnvironmentObject var codexIndexer: SessionIndexer
    @EnvironmentObject var claudeIndexer: ClaudeSessionIndexer
    @EnvironmentObject var opencodeIndexer: OpenCodeSessionIndexer
    @EnvironmentObject var codexStatus: CodexUsageModel
    @EnvironmentObject var claudeStatus: ClaudeUsageModel
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var liveSessionsEnabled: Bool = true
    @AppStorage(PreferencesKey.MenuBar.showLiveSessionIcons) private var showLiveSessionIcons: Bool = true
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled: Bool = false
    @StateObject private var liveSummaryModel = UsageMenuBarLiveSummaryModel()

    var body: some View {
        HStack(spacing: 10) {
            if liveSessionsEnabled && showLiveSessionIcons {
                LiveSessionMenuBarLabel(summary: liveSummaryModel.summary)
            }
            if hasAnyUsageSource {
                UsageMeterMenuBarLabel()
                    .environmentObject(codexStatus)
                    .environmentObject(claudeStatus)
            }
            if !(liveSessionsEnabled && showLiveSessionIcons) && !hasAnyUsageSource {
                FallbackMenuBarLabel()
            }
        }
        .frame(height: NSStatusBar.system.thickness)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            liveSummaryModel.connect(
                activeCodex: activeCodex,
                codexIndexer: codexIndexer,
                claudeIndexer: claudeIndexer,
                opencodeIndexer: opencodeIndexer
            )
        }
    }

    private var hasAnyUsageSource: Bool {
        (codexAgentEnabled && codexUsageEnabled) || (claudeAgentEnabled && claudeUsageEnabled)
    }
}

private struct LiveSessionMenuBarLabel: View {
    let summary: HUDLiveSessionSummary

    var body: some View {
        HStack(spacing: 7) {
            if summary.activeCount > 0 {
                countSegment(count: summary.activeCount, color: Color(hex: "30d158"))
            }
            if summary.waitingCount > 0 {
                countSegment(count: summary.waitingCount, color: Color(hex: "e08600"))
            }
            if summary.activeCount == 0 && summary.waitingCount == 0 {
                Text("—")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.85))
            }
        }
    }

    private func countSegment(count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

private struct FallbackMenuBarLabel: View {
    var body: some View {
        Text("AS")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary.opacity(0.9))
    }
}

/// Spinning arrows shown on the menu-bar face while a provider's usage is
/// reconnecting — the compact form of the footer's "reconnecting…" chip, so all
/// three surfaces share the same vocabulary.
private struct MenuBarReconnectingGlyph: View {
    @State private var spin = false
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

private struct UsageMeterMenuBarLabel: View {
    @EnvironmentObject var codexStatus: CodexUsageModel
    @EnvironmentObject var claudeStatus: ClaudeUsageModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("MenuBarScope") private var scopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var styleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("MenuBarSource") private var sourceRaw: String = MenuBarSource.codex.rawValue
    @AppStorage(PreferencesKey.MenuBar.showCodexResetTimes) private var showCodexResetIndicators: Bool = true
    @AppStorage(PreferencesKey.MenuBar.showClaudeResetTimes) private var showClaudeResetIndicators: Bool = true
    @AppStorage(PreferencesKey.MenuBar.showPills) private var showPills: Bool = false
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.codexUsageEnabled) private var codexUsageEnabled: Bool = false
    @AppStorage(PreferencesKey.claudeUsageEnabled) private var claudeUsageEnabled: Bool = false

    private struct MenuVisibility: Equatable {
        var codex: Bool
        var claude: Bool
    }

    private func applyMenuVisibility(_ visibility: MenuVisibility) {
        codexStatus.setMenuVisible(visibility.codex)
        claudeStatus.setMenuVisible(visibility.claude)
    }

    var body: some View {
        let menuScope = MenuBarScope(rawValue: scopeRaw) ?? .both
        let menuStyle = MenuBarStyleKind(rawValue: styleRaw) ?? .bars
        let desiredSource = MenuBarSource(rawValue: sourceRaw) ?? .codex
        let codexAvailable = codexAgentEnabled && codexUsageEnabled
        let claudeAvailable = claudeAgentEnabled && claudeUsageEnabled
        let source: MenuBarSource = {
            if codexAvailable && claudeAvailable { return desiredSource }
            if codexAvailable { return .codex }
            if claudeAvailable { return .claude }
            return desiredSource
        }()

        let showCodex = codexAvailable && (source == .codex || source == .both)
        let showClaude = claudeAvailable && (source == .claude || source == .both)
        let visibility = MenuVisibility(codex: showCodex, claude: showClaude)

        let quotas: [QuotaData] = {
            var out: [QuotaData] = []
            out.reserveCapacity(2)
            if showCodex {
                out.append(QuotaData.codex(from: codexStatus))
            }
            if showClaude {
                out.append(QuotaData.claude(from: claudeStatus))
            }
            return out
        }()

        let scope: CockpitQuotaScope = {
            switch menuScope {
            case .fiveHour: return .fiveHour
            case .weekly: return .week
            case .both: return .both
            }
        }()

        let style: CockpitQuotaStyle = (menuStyle == .numbers) ? .numbers : .bars

        HStack(spacing: 10) {
            ForEach(Array(quotas.enumerated()), id: \.offset) { _, q in
                // Same three states as the footer and QM dropdown, sized for the
                // bar — never a misleading "0% / no resets" (which reads as
                // exhausted).
                switch q.presentationState {
                case .needsAction:
                    // Amber ⚠ + provider name; the dropdown carries the full fix.
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: "e08600"))
                        Text(q.provider == .claude ? "Claude" : "Codex")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                case .reconnecting:
                    // Spinning arrows + provider name — the footer's "reconnecting"
                    // affordance in a menu-bar-sized form.
                    HStack(spacing: 3) {
                        MenuBarReconnectingGlyph()
                        Text(q.provider == .claude ? "Claude" : "Codex")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                case .live:
                    CockpitQuotaWidget(
                        data: q,
                        isDarkMode: colorScheme == .dark,
                        scope: scope,
                        style: style,
                        modeOverride: nil,
                        baseForeground: .primary,
                        showResetIndicators: (q.provider == .codex) ? showCodexResetIndicators : showClaudeResetIndicators,
                        showPill: showPills
                    )
                }
            }
        }
        .onAppear { applyMenuVisibility(visibility) }
        .onChange(of: visibility) { _, newValue in
            applyMenuVisibility(newValue)
        }
        .onDisappear {
            applyMenuVisibility(MenuVisibility(codex: false, claude: false))
        }
    }
}

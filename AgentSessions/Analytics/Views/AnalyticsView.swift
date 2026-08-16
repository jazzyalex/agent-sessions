import SwiftUI

/// Main analytics view with header, stats, charts, and insights
struct AnalyticsView: View {
    @ObservedObject var service: AnalyticsService
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.antigravityEnabled) private var antigravityAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.hermesEnabled) private var hermesAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.copilotEnabled) private var copilotAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.droidEnabled) private var droidAgentEnabled: Bool = true
    // Pi and Kimi default to their availability probe, not `true`: `AgentEnablement`
    // gates both on the CLI actually being present, so a literal would show their
    // agent filters to everyone whenever `seedIfNeeded` has not written an explicit
    // value yet — which is every preview and test run. Matches PreferencesView.
    @AppStorage(PreferencesKey.Agents.piEnabled) private var piAgentEnabled: Bool = AgentEnablement.isEnabled(.pi)
    @AppStorage(PreferencesKey.Agents.kimiEnabled) private var kimiAgentEnabled: Bool = AgentEnablement.isEnabled(.kimi)
    @AppStorage(PreferencesKey.Agents.grokEnabled) private var grokAgentEnabled: Bool = AgentEnablement.isEnabled(.grok)
    // OpenClaw and Cursor keep the literal defaults PreferencesView and
    // UnifiedSessionsView already use for these keys. The default only applies
    // before `seedIfNeeded` writes an explicit value, and two views disagreeing
    // about the same unset key is worse than either answer.
    @AppStorage(PreferencesKey.Agents.openClawEnabled) private var openClawAgentEnabled: Bool = false
    @AppStorage(PreferencesKey.Agents.cursorEnabled) private var cursorAgentEnabled: Bool = true

    @State private var dateRange: AnalyticsDateRange = .last7Days
    @State private var agentFilter: AnalyticsAgentFilter = .all
    @State private var projectFilter: AnalyticsProjectFilter = .all
    @State private var availableProjects: [String] = []
    @State private var isRefreshing: Bool = false
    @State private var aggregationMetric: AnalyticsAggregationMetric = .messages

    /// Exhaustive on purpose, with no `default`. This view used to carry four
    /// independent hand-written lists of agents — an OR chain, an AND chain, a
    /// sequence of `if enabled { append }` lines, and a set of `onChange`
    /// handlers — and three of them silently stopped at Kimi. Grok, Cursor and
    /// OpenClaw were absent from all three, so Analytics reported "no sources
    /// enabled" when one of them was the only enabled agent and never offered
    /// their filters in the picker. Everything below now derives from this one
    /// switch, so the compiler refuses to build until a new source is handled.
    private func isEnabled(_ source: SessionSource) -> Bool {
        switch source {
        case .codex:       return codexAgentEnabled
        case .claude:      return claudeAgentEnabled
        case .antigravity: return antigravityAgentEnabled
        case .opencode:    return openCodeAgentEnabled
        case .hermes:      return hermesAgentEnabled
        case .copilot:     return copilotAgentEnabled
        case .droid:       return droidAgentEnabled
        case .openclaw:    return openClawAgentEnabled
        case .cursor:      return cursorAgentEnabled
        case .pi:          return piAgentEnabled
        case .kimi:        return kimiAgentEnabled
        case .grok:        return grokAgentEnabled
        }
    }

    private var enabledSources: [SessionSource] {
        SessionSource.allCases.filter(isEnabled)
    }

    private var hasEnabledSources: Bool {
        !enabledSources.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch service.analyticsPhase {
            case .idle:
                if !hasEnabledSources {
                    buildStateView(
                        message: "No analytics sources enabled",
                        detail: "Enable at least one agent in Settings to view analytics.",
                        showProgress: false
                    )
                } else {
                    buildStateView(message: "Preparing analytics…", detail: nil, showProgress: true)
                }
            case .queued:
                buildStateView(message: "Preparing analytics build…", detail: nil, showProgress: true)
            case .building:
                buildingStateView
            case .failed:
                buildStateView(
                    message: "Analytics build failed",
                    detail: nil,
                    showProgress: false,
                    primaryAction: ("Retry Build", { service.requestBuild() })
                )
            case .canceled:
                buildStateView(
                    message: "Analytics build canceled",
                    detail: nil,
                    showProgress: false,
                    primaryAction: ("Restart Build", { service.requestBuild() })
                )
            case .ready:
                if service.isLoading {
                    loadingState
                } else {
                    content
                }
            }
        }
        .onAppear {
            availableProjects = service.getAvailableProjects()
            if service.analyticsPhase == .ready {
                refreshData()
            } else if service.analyticsPhase == .idle {
                service.requestBuild()
            }
        }
        .onChange(of: service.analyticsPhase) { _, phase in
            if phase == .ready {
                availableProjects = service.getAvailableProjects()
                refreshData()
            }
        }
        .onChange(of: service.isStaleSinceLastBuild) { _, stale in
            if stale && service.analyticsPhase == .ready {
                service.requestUpdate()
            }
        }
        .onChange(of: dateRange) { _, _ in refreshData() }
        .onChange(of: agentFilter) { _, _ in refreshData() }
        .onChange(of: projectFilter) { _, _ in refreshData() }
        // One observer over the derived list rather than one per flag. Twelve
        // separate `onChange` modifiers were both a hand-maintained list that
        // stopped at Kimi and enough of a modifier chain to push `body` past the
        // type-checker's time limit.
        .onChange(of: enabledSources) { _, _ in sanitizeAgentFilterIfNeeded() }
        // Apply preferredColorScheme only for explicit Light/Dark modes
        // For System mode, omit the modifier entirely to avoid SwiftUI's buggy nil-handling
        .applyIf((AppAppearance(rawValue: appAppearanceRaw) ?? .system) == .light) {
            $0.preferredColorScheme(.light)
        }
        .applyIf((AppAppearance(rawValue: appAppearanceRaw) ?? .system) == .dark) {
            $0.preferredColorScheme(.dark)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if anyAgentDisabled {
                Text("Showing active agents only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if service.analyticsPhase == .ready {
                if service.isStaleSinceLastBuild {
                    Text("Stale")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
                if let lastBuiltAt = service.lastBuiltAt {
                    Text("Last updated \(AppDateFormatting.dateTimeShort(lastBuiltAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            // Date range picker
            Picker("Date Range", selection: $dateRange) {
                ForEach(AnalyticsDateRange.allCases.filter { $0 != .custom }) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 180)

            // Agent filter picker
            Picker("Agent", selection: $agentFilter) {
                ForEach(availableAgentFilters) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 140)

            // Project filter picker
            Picker("Project", selection: $projectFilter) {
                Text("All Projects").tag(AnalyticsProjectFilter.all)
                ForEach(availableProjects, id: \.self) { project in
                    Text(project).tag(AnalyticsProjectFilter.specific(project))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 200)

            // Refresh button
            Button(action: { withAnimation { refreshData() } }) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
            }
            .buttonStyle(.plain)
            .help(service.analyticsPhase == .ready ? "Refresh analytics view" : "Refresh unavailable")
            .disabled(isRefreshing || service.analyticsPhase != .ready)

        }
        .padding(.horizontal, AnalyticsDesign.windowPadding)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Content

    private var content: some View { totalView }

    private var totalView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Stats cards (top of layout - no extra spacing)
                StatsCardsView(snapshot: service.snapshot, dateRange: dateRange)

                // Primary chart (compact spacing after stats - related content)
                SessionsChartView(
                    data: service.snapshot.timeSeriesData,
                    dateRange: dateRange,
                    metric: $aggregationMetric
                )
                .frame(height: AnalyticsDesign.primaryChartHeight)
                .padding(.top, AnalyticsDesign.statsToChartSpacing)

                // Secondary insights (major section break - more breathing room)
                HStack(alignment: .top, spacing: AnalyticsDesign.insightsGridSpacing) {
                    AgentBreakdownView(
                        breakdown: service.snapshot.agentBreakdown,
                        metric: $aggregationMetric
                    )
                    .frame(maxWidth: .infinity, minHeight: AnalyticsDesign.secondaryCardHeight, maxHeight: AnalyticsDesign.secondaryCardHeight, alignment: .topLeading)

                    TimeOfDayHeatmapView(
                        cells: service.snapshot.heatmapCells,
                        mostActive: service.snapshot.mostActiveTimeRange
                    )
                    .frame(maxWidth: .infinity, minHeight: AnalyticsDesign.secondaryCardHeight, maxHeight: AnalyticsDesign.secondaryCardHeight, alignment: .topLeading)
                }
                .frame(height: AnalyticsDesign.secondaryCardHeight)
                .padding(.top, AnalyticsDesign.chartToInsightsSpacing)
            }
            // Outer padding for scroll content
            .padding(.horizontal, AnalyticsDesign.windowPadding)
            .padding(.bottom, AnalyticsDesign.windowPadding)
            .padding(.top, AnalyticsDesign.windowPadding)
        }
        .background(Color.analyticsBackground)
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(0.8)

            Text("Loading analytics...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func buildStateView(message: String,
                                detail: String?,
                                showProgress: Bool,
                                primaryAction: (title: String, action: () -> Void)? = nil) -> some View {
        VStack(spacing: 16) {
            Spacer()
            if showProgress {
                ProgressView()
                    .controlSize(.large)
            }
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let primaryAction {
                Button(primaryAction.title) {
                    primaryAction.action()
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buildingStateView: some View {
        let progress = service.buildProgress
        return VStack(spacing: 14) {
            Spacer()
            ProgressView(value: progress.percent)
                .frame(maxWidth: 320)
            Text("Building analytics index… \(Int(progress.percent * 100))%")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("\(progress.processedSessions)/\(max(progress.totalSessions, 1)) sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
            if progress.totalSources > 0 {
                Text("Sources \(progress.completedSources)/\(progress.totalSources)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let currentSource = progress.currentSource {
                Text("Current source: \(currentSource)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let start = progress.dateStart, let end = progress.dateEnd {
                Text("Indexed date range: \(start) to \(end)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel Build") {
                service.requestCancelBuild()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholderView(icon: String, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func refreshData() {
        isRefreshing = true

        Task {
            await service.calculate(dateRange: dateRange, agentFilter: agentFilter, projectFilter: projectFilter)

            // Simulate brief delay for animation
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s

            isRefreshing = false
        }
    }

    private var anyAgentDisabled: Bool {
        enabledSources.count < SessionSource.allCases.count
    }

    private var availableAgentFilters: [AnalyticsAgentFilter] {
        [.all] + enabledSources.compactMap(AnalyticsAgentFilter.dedicated(for:))
    }

    private func sanitizeAgentFilterIfNeeded() {
        if availableAgentFilters.contains(agentFilter) { return }
        agentFilter = .all
        refreshData()
    }
}

// MARK: - View Extension for Conditional Modifiers

extension View {
    /// Apply a view modifier conditionally
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool,
                                _ transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// (Tab options removed; single Total view)

// MARK: - Previews

#Preview("Analytics View") {
    // Twelve hand-built indexers collapse into the catalog, which builds all of them.
    let service = AnalyticsService(catalog: SessionProviderCatalog())

    AnalyticsView(service: service)
        .frame(width: 900, height: 650)
}

import SwiftUI

/// Main analytics view with header, stats, charts, and insights
struct AnalyticsView: View {
    @ObservedObject var service: AnalyticsService
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.geminiEnabled) private var geminiAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.copilotEnabled) private var copilotAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.droidEnabled) private var droidAgentEnabled: Bool = true

    @State private var dateRange: AnalyticsDateRange = .last7Days
    @State private var agentFilter: AnalyticsAgentFilter = .all
    @State private var projectFilter: AnalyticsProjectFilter = .all
    @State private var availableProjects: [String] = []
    @State private var isRefreshing: Bool = false
    @State private var aggregationMetric: AnalyticsAggregationMetric = .messages

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch service.analyticsPhase {
            case .idle:
                buildStateView(
                    message: "Analytics index not built yet",
                    detail: "Build once to enable charts. Unified and Cockpit stay fast while analytics is idle.",
                    showProgress: false,
                    primaryAction: ("Build Analytics Index", { service.requestBuild() })
                )
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
        .overlay {
            if service.isParsingSessions {
                parsingProgressOverlay
            }
        }
        .onAppear {
            availableProjects = service.getAvailableProjects()
            if service.analyticsPhase == .ready {
                refreshData()
            }
        }
        .onChange(of: service.analyticsPhase) { _, phase in
            if phase == .ready {
                availableProjects = service.getAvailableProjects()
                refreshData()
            }
        }
        .onChange(of: dateRange) { _, _ in refreshData() }
        .onChange(of: agentFilter) { _, _ in refreshData() }
        .onChange(of: projectFilter) { _, _ in refreshData() }
        .onChange(of: codexAgentEnabled) { _, _ in sanitizeAgentFilterIfNeeded() }
        .onChange(of: claudeAgentEnabled) { _, _ in sanitizeAgentFilterIfNeeded() }
        .onChange(of: geminiAgentEnabled) { _, _ in sanitizeAgentFilterIfNeeded() }
        .onChange(of: openCodeAgentEnabled) { _, _ in sanitizeAgentFilterIfNeeded() }
        .onChange(of: copilotAgentEnabled) { _, _ in sanitizeAgentFilterIfNeeded() }
        .onChange(of: droidAgentEnabled) { _, _ in sanitizeAgentFilterIfNeeded() }
        .onChange(of: service.isParsingSessions) { _, isParsing in
            // Refresh analytics when parsing completes
            if !isParsing {
                refreshData()
            }
        }
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

            if service.analyticsPhase == .ready {
                Button("Update Index") {
                    service.requestUpdate()
                }
                .buttonStyle(.bordered)
                .disabled(service.analyticsPhase == .building || service.analyticsPhase == .queued)
            }
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

    private var parsingProgressOverlay: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            // Progress card
            VStack(spacing: 16) {
                // Progress ring
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                        .frame(width: 60, height: 60)

                    Circle()
                        .trim(from: 0, to: service.parsingProgress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: service.parsingProgress)

                    Text("\(Int(service.parsingProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Status text
                VStack(spacing: 4) {
                    Text("Analyzing Sessions")
                        .font(.headline)

                    Text(service.parsingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Cancel button
                Button("Cancel") {
                    service.cancelParsing()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            .padding(24)
            .frame(width: 280)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color("CardBackground"))
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            )
        }
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
        !(codexAgentEnabled && claudeAgentEnabled && geminiAgentEnabled && openCodeAgentEnabled && copilotAgentEnabled && droidAgentEnabled)
    }

    private var availableAgentFilters: [AnalyticsAgentFilter] {
        var out: [AnalyticsAgentFilter] = [.all]
        if codexAgentEnabled { out.append(.codexOnly) }
        if claudeAgentEnabled { out.append(.claudeOnly) }
        if geminiAgentEnabled { out.append(.geminiOnly) }
        if openCodeAgentEnabled { out.append(.opencodeOnly) }
        if copilotAgentEnabled { out.append(.copilotOnly) }
        if droidAgentEnabled { out.append(.droidOnly) }
        return out
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
    let codexIndexer = SessionIndexer()
    let claudeIndexer = ClaudeSessionIndexer()
    let geminiIndexer = GeminiSessionIndexer()
    let opencodeIndexer = OpenCodeSessionIndexer()
    let copilotIndexer = CopilotSessionIndexer()

    let service = AnalyticsService(
        codexIndexer: codexIndexer,
        claudeIndexer: claudeIndexer,
        geminiIndexer: geminiIndexer,
        opencodeIndexer: opencodeIndexer,
        copilotIndexer: copilotIndexer,
        droidIndexer: DroidSessionIndexer()
    )

    AnalyticsView(service: service)
        .frame(width: 900, height: 650)
}

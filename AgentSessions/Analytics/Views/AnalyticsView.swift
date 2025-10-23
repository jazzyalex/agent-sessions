import SwiftUI

/// Main analytics view with header, stats, charts, and insights
struct AnalyticsView: View {
    @ObservedObject var service: AnalyticsService
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    @State private var dateRange: AnalyticsDateRange = .last7Days
    @State private var agentFilter: AnalyticsAgentFilter = .all
    @State private var isRefreshing: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if service.isLoading {
                loadingState
            } else {
                content
            }
        }
        .overlay {
            if service.isParsingSessions {
                parsingProgressOverlay
            }
        }
        .onAppear {
            // Do not parse all sessions here; indexing provides precomputed metrics (next phase).
            // Keep UI responsive and avoid heavy work on appear.
            refreshData()
        }
        .onChange(of: dateRange) { _, _ in refreshData() }
        .onChange(of: agentFilter) { _, _ in refreshData() }
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
                ForEach(AnalyticsAgentFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 140)

            // Refresh button
            Button(action: { withAnimation { refreshData() } }) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
            }
            .buttonStyle(.plain)
            .help("Refresh analytics")
            .disabled(isRefreshing)
        }
        .padding(.horizontal, AnalyticsDesign.windowPadding)
        .padding(.vertical, 12)
        .frame(height: AnalyticsDesign.headerHeight)
        .background(Color("CardBackground"))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Content

    private var content: some View { totalView }

    private var totalView: some View {
        ScrollView {
            VStack(spacing: AnalyticsDesign.sectionSpacing) {
                // Stats cards
                StatsCardsView(summary: service.snapshot.summary)
                    .padding(.horizontal, AnalyticsDesign.windowPadding)

                // Primary chart
                SessionsChartView(
                    data: service.snapshot.timeSeriesData,
                    dateRange: dateRange
                )
                .frame(height: AnalyticsDesign.primaryChartHeight)
                .padding(.horizontal, AnalyticsDesign.windowPadding)

                // Secondary insights (2-column grid)
                HStack(alignment: .top, spacing: AnalyticsDesign.cardSpacing) {
                    AgentBreakdownView(breakdown: service.snapshot.agentBreakdown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    TimeOfDayHeatmapView(
                        cells: service.snapshot.heatmapCells,
                        mostActive: service.snapshot.mostActiveTimeRange
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: AnalyticsDesign.secondaryCardHeight)
                .padding(.horizontal, AnalyticsDesign.windowPadding)
                .padding(.bottom, AnalyticsDesign.sectionSpacing)
            }
            .padding(.top, AnalyticsDesign.sectionSpacing)
        }
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
            service.calculate(dateRange: dateRange, agentFilter: agentFilter)

            // Simulate brief delay for animation
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s

            isRefreshing = false
        }
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

    let service = AnalyticsService(
        codexIndexer: codexIndexer,
        claudeIndexer: claudeIndexer,
        geminiIndexer: geminiIndexer
    )

    AnalyticsView(service: service)
        .frame(width: 900, height: 650)
}

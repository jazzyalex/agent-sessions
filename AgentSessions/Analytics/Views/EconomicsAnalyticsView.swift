import Charts
import SwiftUI

struct EconomicsAnalyticsView: View {
    let snapshot: EconomicsSnapshot
    let phase: EconomicsAnalysisPhase
    let progress: EconomicsAnalysisProgress

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedConfigurationID: String?
    @State private var metric: EconomicsMetric = .quotaPerHour

    private var displayRows: [EconomicsConfigurationRow] {
        EconomicsRowOrdering.sorted(snapshot.rows, by: metric)
    }

    private var selectedRow: EconomicsConfigurationRow? {
        if let selectedConfigurationID,
           let match = snapshot.rows.first(where: { $0.id == selectedConfigurationID }) {
            return match
        }
        return displayRows.first
    }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                analysisProgress
            case .analyzing:
                if snapshot.rows.isEmpty {
                    analysisProgress
                } else {
                    content
                }
            case .unavailable:
                unavailableState
            case .ready:
                if snapshot.rows.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
        }
        .onAppear { selectFirstRowIfNeeded() }
        .onChange(of: snapshot.rows.map(\.id)) { _, _ in selectFirstRowIfNeeded() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyticsDesign.chartToInsightsSpacing) {
                if phase == .analyzing {
                    HStack(spacing: 10) {
                        ProgressView(value: progress.fraction)
                            .frame(maxWidth: 220)
                        Text("\(progress.completed) of \(progress.total) sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                summaryCards

                HStack(alignment: .top, spacing: AnalyticsDesign.insightsGridSpacing) {
                    configurationCard
                        .frame(maxWidth: .infinity)
                    detailCard
                        .frame(width: 370)
                }

                provenanceNote
            }
            .padding(AnalyticsDesign.windowPadding)
        }
        .background(Color.analyticsBackground)
    }

    private var summaryCards: some View {
        HStack(spacing: AnalyticsDesign.metricsCardSpacing) {
            summaryCard(
                title: "API-equivalent value",
                value: Self.currency(snapshot.totalAPIEquivalentUSD),
                detail: "Published API rates"
            )
            quotaSummaryCard
            summaryCard(
                title: "Timed activity",
                value: AnalyticsSummary.formatDuration(snapshot.totalTimedSeconds),
                detail: "Timestamped usage inside this filter"
            )
            summaryCard(
                title: "Price coverage",
                value: Self.percentage(snapshot.coverage.pricedFraction),
                detail: "\(snapshot.coverage.pricedObservations) of \(snapshot.coverage.totalObservations) usage records"
            )
        }
    }

    private func summaryCard(
        title: LocalizedStringKey,
        value: String,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .analyticsCard(padding: AnalyticsDesign.statsCardPadding, colorScheme: colorScheme)
    }

    private var quotaSummaryCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Attributed quota spent")
                .font(.caption)
                .foregroundStyle(.secondary)

            if quotaSummarySources.isEmpty {
                Text("—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
            } else {
                VStack(spacing: 2) {
                    ForEach(quotaSummarySources, id: \.self) { source in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.quotaProviderName(source))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 6)
                            Text(Self.percentPoints(snapshot.quotaPercentPointsBySource[source] ?? 0))
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                }
            }

            Text("Selected filter · observed windows")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .analyticsCard(padding: AnalyticsDesign.statsCardPadding, colorScheme: colorScheme)
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    configurationHeading
                    Spacer(minLength: 20)
                    metricPicker
                }

                VStack(alignment: .leading, spacing: 12) {
                    configurationHeading
                    metricPicker
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            VStack(spacing: 6) {
                ForEach(displayRows) { row in
                    configurationRow(row)
                }
            }
        }
        .analyticsCard(colorScheme: colorScheme)
    }

    private var configurationHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Model Economics")
                .font(.headline)
            Text("Only the selected date range is analyzed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metricPicker: some View {
        HStack(spacing: 10) {
            Text("Metric")
                .lineLimit(1)
                .fixedSize()
            Picker("Metric", selection: $metric) {
                ForEach(EconomicsMetric.allCases) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func configurationRow(_ row: EconomicsConfigurationRow) -> some View {
        let selected = selectedRow?.id == row.id
        let maximum = max(
            snapshot.rows.compactMap { $0.currentValue(for: metric) }.max() ?? 0,
            0.0001
        )
        let current = row.currentValue(for: metric)
        let previous = row.previousValue(for: metric)

        return Button {
            withAnimation(.easeOut(duration: AnalyticsDesign.hoverDuration)) {
                selectedConfigurationID = row.id
            }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.agentColor(for: row.configuration.source))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.configuration.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.configuration.modelDisplayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(row.configuration.effortDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 170, alignment: .leading)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
                            .frame(height: 7)

                        if let current {
                            Capsule()
                                .fill(Color.agentColor(for: row.configuration.source).opacity(0.70))
                                .frame(width: max(4, geometry.size.width * current / maximum), height: 7)
                        }

                        if let previous {
                            Rectangle()
                                .fill(Color.primary.opacity(0.72))
                                .frame(width: 2, height: 15)
                                .offset(x: min(geometry.size.width - 2,
                                               geometry.size.width * previous / maximum))
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(minWidth: 120, maxWidth: .infinity, minHeight: 18)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.metricValue(current, metric: metric))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                    Text("\(row.sessions) sessions · \(Self.shortDuration(row.timedSeconds(for: metric))) timed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.11) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(configurationAccessibilityLabel(row))
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let row = selectedRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.configuration.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.configuration.modelDisplayName)
                        .font(.title3.weight(.semibold))
                    Text(row.configuration.effortDisplayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: 12) {
                    detailMetric(
                        "Attributed quota / timed hour",
                        value: row.weeklyQuotaPercentPointsPerHour.map(Self.percentPoints) ?? "—"
                    )
                    detailMetric(
                        "API $ / timed hour",
                        value: row.apiCostPerHour.map(Self.currency) ?? "—"
                    )
                }

                if !row.hasSufficientTimedSample(for: .apiCostPerHour)
                    || !row.hasSufficientTimedSample(for: .quotaPerHour) {
                    Text("Each hourly rate needs its own 15-minute covered sample. Total value is still included above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                trendChart(for: row)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    coverageLine("Price coverage", value: row.priceCoverage)
                    coverageLine("Quota coverage", value: row.quotaCoverage)
                    coverageLine("Timed price coverage", value: row.timedPriceCoverage)
                    HStack {
                        Text("API timed activity")
                        Spacer()
                        Text(AnalyticsSummary.formatDuration(row.apiTimedSeconds))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Quota timed activity")
                        Spacer()
                        Text(AnalyticsSummary.formatDuration(row.quotaTimedSeconds))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 430, alignment: .topLeading)
        .analyticsCard(colorScheme: colorScheme)
    }

    private func detailMetric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func trendChart(for row: EconomicsConfigurationRow) -> some View {
        let points = snapshot.trendByConfiguration[row.id] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected-period trend")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(metric == .quotaPerHour ? "attributed % / timed hour" : "$ / timed hour")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(points) { point in
                    if let value = point.value(for: metric) {
                        LineMark(
                            x: .value("Week", point.weekStart),
                            y: .value("Value", value)
                        )
                        .foregroundStyle(Color.agentColor(for: row.configuration.source))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value("Week", point.weekStart),
                            y: .value("Value", value)
                        )
                        .foregroundStyle(Color.agentColor(for: row.configuration.source))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 155)
            .overlay {
                if points.allSatisfy({ $0.value(for: metric) == nil }) {
                    Text(metric == .quotaPerHour
                         ? "Quota history begins with observed provider windows."
                         : "No priced history for this configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
    }

    private func coverageLine(_ title: LocalizedStringKey, value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Self.percentage(value))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var provenanceNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("How to read these numbers")
                    .font(.caption.weight(.semibold))
                Text("API-equivalent value uses published model prices. Hourly rates sum exact request intervals when available and otherwise only nearby same-configuration usage gaps up to 30 minutes, all inside the selected filter. Each metric needs 15 minutes of its own covered time; untimed spend remains in total value but is excluded from rates. Attributed quota converts local model usage with Quota Meter's provider-wide calibration; it is not the provider-reported account total. Work on other devices may affect the estimate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("\(snapshot.coverage.analyzedSessions) transcripts analyzed")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AnalyticsDesign.cardCornerRadius)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
        )
    }

    private var analysisProgress: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: progress.fraction)
                .frame(maxWidth: 320)
            Text("Analyzing transcript economics…")
                .font(.title3)
                .foregroundStyle(.secondary)
            if progress.total > 0 {
                Text("\(progress.completed) of \(progress.total) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Finding sessions with price and quota evidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.analyticsBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No economics data for these filters")
                .font(.title3)
            Text("The selected sessions have no priceable transcript usage yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.analyticsBackground)
    }

    private var unavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Economics analysis is unavailable")
                .font(.title3)
            Text("Refresh Analytics after the session index is ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.analyticsBackground)
    }

    private func selectFirstRowIfNeeded() {
        guard !snapshot.rows.isEmpty else {
            selectedConfigurationID = nil
            return
        }
        if let selectedConfigurationID,
           snapshot.rows.contains(where: { $0.id == selectedConfigurationID }) {
            return
        }
        selectedConfigurationID = displayRows.first?.id
    }

    private func configurationAccessibilityLabel(_ row: EconomicsConfigurationRow) -> String {
        let value = Self.metricValue(row.currentValue(for: metric), metric: metric)
        return "\(row.configuration.source.displayName), \(row.configuration.modelDisplayName), \(row.configuration.effortDisplayName), \(value)"
    }

    private static func metricValue(_ value: Double?, metric: EconomicsMetric) -> String {
        guard let value else { return "—" }
        switch metric {
        case .quotaPerHour: return "\(percentPoints(value))/h"
        case .apiCostPerHour: return "\(currency(value))/h"
        }
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
    }

    private static func percentPoints(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))))%"
    }

    private static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    private static func percentage(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private var quotaSummarySources: [SessionSource] {
        snapshot.quotaPercentPointsBySource.keys.sorted {
            $0.displayName < $1.displayName
        }
    }

    private static func quotaProviderName(_ source: SessionSource) -> String {
        switch source {
        case .codex: return "Codex"
        case .claude: return "Claude"
        default: return source.displayName
        }
    }

}

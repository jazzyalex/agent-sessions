import Charts
import SwiftUI

struct EconomicsAnalyticsView: View {
    let snapshot: EconomicsSnapshot
    let phase: EconomicsAnalysisPhase
    let progress: EconomicsAnalysisProgress
    let catalog: SessionProviderCatalog
    let contributingSessions: (EconomicsConfigurationRow) -> [Session]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var selectedConfigurationID: String?
    @State private var comparisonID: String?
    @State private var sessionsRow: EconomicsConfigurationRow?
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
        .onChange(of: selectedRow?.id) { _, _ in comparisonID = nil }
        .sheet(item: $sessionsRow) { row in
            EconomicsContributingSessionsView(
                configuration: row.configuration,
                sessions: contributingSessions(row),
                catalog: catalog
            )
        }
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
                value: snapshot.pricedAPIEquivalentUSD.map(Self.currency),
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
        value: String?,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            (value.map { Text(verbatim: $0) } ?? Text("Unavailable"))
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
        VStack(alignment: .leading, spacing: 14) {
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

                selectedPeriodSummary(for: row)

                Button("View contributing sessions") { sessionsRow = row }
                    .font(.callout)

                effortComparison(for: row)

                Divider()

                hourlyRateSummary(for: row)

                rateHistory(for: row)

                Divider()

                evidenceSummary(for: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .analyticsCard(colorScheme: colorScheme)
    }

    private func selectedPeriodSummary(for row: EconomicsConfigurationRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected period")
                .font(.caption.weight(.semibold))

            HStack(alignment: .top, spacing: 12) {
                detailMetric(
                    "API-equivalent value",
                    value: row.pricedObservationCount > 0 ? Self.currency(row.apiEquivalentUSD) : nil,
                    detail: "Published model prices"
                )
                detailMetric(
                    "Weekly quota estimate",
                    value: row.weeklyQuotaPercentPoints.map(Self.percentPoints),
                    detail: "\(row.quotaObservationCount) of \(row.observationCount) records covered"
                )
            }

            HStack(alignment: .top, spacing: 12) {
                detailMetric(
                    "Sessions",
                    value: row.sessions.formatted(),
                    detail: "Using this model and effort"
                )
                detailMetric(
                    "Usage records",
                    value: row.observationCount.formatted(),
                    detail: "Transcript-derived evidence"
                )
            }
        }
    }

    @ViewBuilder
    private func effortComparison(for row: EconomicsConfigurationRow) -> some View {
        let options = EconomicsRowOrdering.otherEfforts(for: row, in: snapshot.rows)
        if !options.isEmpty {
            Divider()
            Picker("Compare effort", selection: $comparisonID) {
                Text("None").tag(nil as String?)
                ForEach(options) { option in
                    Text(option.configuration.effortDisplayName).tag(Optional(option.id))
                }
            }
            if let other = options.first(where: { $0.id == comparisonID }) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Effort")
                        Text(row.configuration.effortDisplayName)
                        Text(other.configuration.effortDisplayName)
                    }
                    .fontWeight(.semibold)
                    comparisonRow("Quota per timed hour", row, other) {
                        $0.weeklyQuotaPercentPointsPerHour.map(Self.percentPoints)
                    }
                    comparisonRow("Quota-covered time", row, other) {
                        AnalyticsSummary.formatDuration($0.quotaTimedSeconds)
                    }
                    comparisonRow("API cost per timed hour", row, other) {
                        $0.apiCostPerHour.map(Self.currency)
                    }
                    comparisonRow("Price-covered time", row, other) {
                        AnalyticsSummary.formatDuration($0.apiTimedSeconds)
                    }
                    comparisonRow("Sessions", row, other) { $0.sessions.formatted() }
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
    }

    private func comparisonRow(
        _ title: LocalizedStringKey,
        _ row: EconomicsConfigurationRow,
        _ other: EconomicsConfigurationRow,
        value: (EconomicsConfigurationRow) -> String?
    ) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            comparisonValue(value(row))
            comparisonValue(value(other))
        }
    }

    @ViewBuilder
    private func comparisonValue(_ value: String?) -> some View {
        if let value {
            Text(value)
        } else {
            Text("Unavailable").foregroundStyle(.secondary)
        }
    }

    private func hourlyRateSummary(for row: EconomicsConfigurationRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rates from timed activity")
                .font(.caption.weight(.semibold))

            HStack(spacing: 12) {
                detailMetric(
                    "Attributed quota per hour",
                    value: row.weeklyQuotaPercentPointsPerHour.map(Self.percentPoints),
                    detail: "\(AnalyticsSummary.formatDuration(row.quotaTimedSeconds)) quota-calibrated"
                )
                detailMetric(
                    "API-equivalent cost per hour",
                    value: row.apiCostPerHour.map(Self.currency),
                    detail: "\(AnalyticsSummary.formatDuration(row.apiTimedSeconds)) priced"
                )
            }

            if !row.hasSufficientTimedSample(for: .apiCostPerHour)
                || !row.hasSufficientTimedSample(for: .quotaPerHour) {
                Text("A rate appears only after 15 minutes of covered activity for that metric. Untimed value remains in the selected-period total.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detailMetric(
        _ title: LocalizedStringKey,
        value: String?,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text("Unavailable")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rateHistory(for row: EconomicsConfigurationRow) -> some View {
        let measuredPoints = (snapshot.trendByConfiguration[row.id] ?? [])
            .filter { $0.value(for: metric) != nil }

        if measuredPoints.count >= 2 {
            trendChart(points: measuredPoints, row: row)
        } else {
            Text("Weekly rate history needs at least two weeks with enough covered activity for the selected metric.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trendChart(
        points: [EconomicsTrendPoint],
        row: EconomicsConfigurationRow
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Weekly rates")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(metric == .quotaPerHour ? "attributed % / timed hour" : "$ / timed hour")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(points) { point in
                    if let value = point.value(for: metric) {
                        PointMark(
                            x: .value("Week", point.weekStart),
                            y: .value("Value", value)
                        )
                        .foregroundStyle(Color.agentColor(for: row.configuration.source))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 135)
        }
    }

    private func evidenceSummary(for row: EconomicsConfigurationRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Evidence behind these numbers")
                .font(.caption.weight(.semibold))

            evidenceLine(
                "Priced usage records",
                count: row.pricedObservationCount,
                total: row.observationCount
            )
            evidenceLine(
                "Timed priced records",
                count: row.timedPricedObservationCount,
                total: row.pricedObservationCount
            )
            evidenceLine(
                "Quota-attributed priced records",
                count: row.quotaObservationCount,
                total: row.pricedObservationCount
            )
            evidenceLine(
                "Timed quota records",
                count: row.timedQuotaObservationCount,
                total: row.quotaObservationCount
            )

            Text("Coverage counts usage records. Hourly rates use only the timestamped activity shown above.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidenceLine(
        _ title: LocalizedStringKey,
        count: Int,
        total: Int
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Self.coverageCount(count: count, total: total, locale: locale))
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

    static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "0m" }
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    private static func percentage(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    static func coverageCount(count: Int, total: Int, locale: Locale) -> String {
        guard total > 0 else { return String(localized: "No records", locale: locale) }
        let covered = count.formatted(.number.locale(locale))
        let records = total.formatted(.number.locale(locale))
        let fraction = Double(count) / Double(total)
        let percentage = fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return String(
            localized: "\(covered) of \(records) (\(percentage))",
            locale: locale,
            comment: "Economics coverage: covered record count, eligible record count, and formatted coverage percentage."
        )
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

private struct EconomicsContributingSessionsView: View {
    let configuration: EconomicsConfigurationKey
    let sessions: [Session]
    let catalog: SessionProviderCatalog

    @Environment(\.dismiss) private var dismiss
    @State private var selection: (session: Session, hasStorage: Bool)?
    @StateObject private var focusCoordinator = WindowFocusCoordinator()
    @StateObject private var searchState = UnifiedSearchState()

    var body: some View {
        VStack(alignment: .leading, spacing: AnalyticsDesign.metricsCardSpacing) {
            if let selection {
                let session = selection.session
                Button {
                    focusCoordinator.perform(.closeAllSearch)
                    self.selection = nil
                } label: {
                    Label("Contributing sessions", systemImage: "chevron.left")
                }
                Text(session.listTitle)
                    .font(.headline)
                    .lineLimit(2)
                if selection.hasStorage {
                    TranscriptHostView(
                        kind: session.source,
                        selection: session.id,
                        catalog: catalog,
                        keepsInactiveProvidersMounted: false
                    )
                    .environmentObject(focusCoordinator)
                    .environmentObject(searchState)
                    .environmentObject(SessionArchiveManager.shared)
                    .id(session.id)
                } else {
                    Label("Session file not found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Contributing sessions")
                    .font(.headline)
                Text("\(configuration.modelDisplayName) · \(configuration.effortDisplayName)")
                    .foregroundStyle(.secondary)
                sessionList
            }

            Button("Done", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(AnalyticsDesign.windowPadding)
        .frame(width: 760, height: 560)
    }

    @ViewBuilder
    private var sessionList: some View {
        if sessions.isEmpty {
            Text("These sessions are no longer in the index.")
                .frame(maxHeight: .infinity)
        } else {
            List(sessions) { session in
                Button {
                    let hasStorage = EconomicsTranscriptAvailability.hasStorage(for: session)
                    if hasStorage, session.events.isEmpty || session.isPartiallyHydrated {
                        catalog[session.source].handle.reloadFocusedSession(session.id, false, .selection)
                    }
                    if hasStorage {
                        focusCoordinator.perform(.selectSession(id: session.id))
                    }
                    selection = (session, hasStorage)
                } label: {
                    VStack(alignment: .leading) {
                        Text(session.listTitle).lineLimit(2)
                        if let date = session.endTime ?? session.startTime {
                            Text(date, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

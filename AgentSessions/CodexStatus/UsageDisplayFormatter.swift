import Foundation

// Shared display helpers for reset text across UI surfaces.

private func menuDateOnlyNumeric(_ date: Date) -> String {
    let df = DateFormatter()
    df.locale = .current
    df.timeZone = .autoupdatingCurrent
    df.dateStyle = .short
    df.timeStyle = .none
    return df.string(from: date)
}

private func menuTimeOnlyShort(_ date: Date) -> String {
    let df = DateFormatter()
    df.locale = .current
    df.timeZone = .autoupdatingCurrent
    df.dateStyle = .none
    df.timeStyle = .short
    return df.string(from: date)
}

private func menuDateTimeWithWeekday(_ date: Date) -> String {
    // Prefer numeric date (locale-aware), add weekday, then a short time.
    let dateOnly = menuDateOnlyNumeric(date)
    let weekday = AppDateFormatting.weekdayAbbrev(date)
    let timeOnly = menuTimeOnlyShort(date)
    if dateOnly.isEmpty { return "\(weekday) \(timeOnly)" }
    return "\(dateOnly) \(weekday) \(timeOnly)"
}

private func relativeTimeUntilReset(_ date: Date, now: Date = Date()) -> String {
    let interval = max(0, date.timeIntervalSince(now))
    if interval < 60 { return "<1m" }
    let totalMinutes = Int(ceil(interval / 60.0))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60
    if days > 0 {
        if hours == 0 { return "\(days)d" }
        return "\(days)d \(hours)h"
    }
    if hours <= 0 { return "\(minutes)m" }
    if minutes <= 0 { return "\(hours)h" }
    return "\(hours)h \(minutes)m"
}

func trimResetCopy(_ text: String) -> String {
    var result = text
    if result.hasPrefix("resets ") { result = String(result.dropFirst("resets ".count)) }
    if let parenIndex = result.firstIndex(of: "(") { result = String(result[..<parenIndex]).trimmingCharacters(in: .whitespaces) }
    return result
}

func formatUsageRelativeTimeLabel(_ date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    return relativeTimeUntilReset(date, now: now)
}

func formatUsageWeeklyResetLabel(_ date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    guard date.timeIntervalSince(now) > 0 else { return nil }
    return "\(AppDateFormatting.weekdayAbbrev(date)) \(AppDateFormatting.timeShort(date))"
}

struct UsageLimitProjectionSample: Equatable {
    let source: UsageTrackingSource
    let remainingPercent: Int
    var remainingPercentExact: Double? = nil
    let resetText: String
    let hasRateLimit: Bool
    let freshness: UsageLimitAlertFreshness
    let observedAt: Date
}

struct UsageLimitProjectionEstimate: Equatable {
    let runoutAt: Date
    let observedAt: Date
}

struct UsageLimitProjectionTracker {
    private var previous: ResolvedSample?
    private var lastProjection: Projection?
    private(set) var lastDiagnostics: String = "Waiting for data"
    /// Observed time of the most recent sample whose measured burn projected
    /// run-out at or after the reset — i.e. actively working but fitting the
    /// 5h window. `nil` when running out early or when no burn is measured.
    private(set) var lastOnTrackObservedAt: Date?

    /// How long a retained projection survives with no fresh burn before it is
    /// cleared entirely (not merely gate-hidden). Matches the 3-minute freshness
    /// window in `formatUsageProjectionLabel`, so the published estimate goes nil
    /// in lockstep with the label rather than lingering armed until run-out.
    private static let retentionWindow: TimeInterval = 3 * 60

    mutating func update(with sample: UsageLimitProjectionSample,
                         now: Date = Date()) -> UsageLimitProjectionEstimate? {
        guard sample.hasRateLimit,
              !isResetInfoUnavailable(raw: sample.resetText) else {
            previous = nil
            lastProjection = nil
            lastDiagnostics = "Waiting for 5h limit"
            return nil
        }
        guard let resetDate = UsageResetText.resetDate(
            kind: "5h",
            source: sample.source,
            raw: sample.resetText,
            now: sample.observedAt
        ), resetDate > sample.observedAt,
           resetDate > now else {
            previous = nil
            lastProjection = nil
            lastDiagnostics = "Waiting for valid reset"
            return nil
        }

        let current = ResolvedSample(
            remainingPercent: Self.remainingPercent(for: sample),
            resetDate: resetDate,
            observedAt: sample.observedAt
        )

        guard sample.freshness.allowsProjectedDisplay else {
            previous = nil
            lastProjection = nil
            lastDiagnostics = "Stale data"
            return nil
        }
        guard let previous else {
            self.previous = current
            lastDiagnostics = "Waiting for next sample"
            return nil
        }
        guard abs(previous.resetDate.timeIntervalSince(current.resetDate)) < 120 else {
            lastProjection = nil
            self.previous = current
            lastDiagnostics = "Reset changed; waiting for next sample"
            return nil
        }

        if current.remainingPercent > previous.remainingPercent {
            lastProjection = nil
            self.previous = current
            lastDiagnostics = "Usage recovered; waiting for next burn"
            return nil
        }

        let elapsed = current.observedAt.timeIntervalSince(previous.observedAt)
        guard elapsed >= 60 else { return retainedProjection(for: current, now: now, fallback: "Waiting for 60s sample") }
        guard previous.remainingPercent > current.remainingPercent else {
            return retainedProjection(for: current, now: now, fallback: "Waiting for usage drop")
        }

        let percentBurned = Double(previous.remainingPercent - current.remainingPercent)
        let secondsUntilEmpty = Double(current.remainingPercent) / (percentBurned / elapsed)
        guard secondsUntilEmpty > 0 else {
            lastProjection = nil
            lastDiagnostics = "Waiting for usage drop"
            return nil
        }

        let projectedRunoutAt = current.observedAt.addingTimeInterval(secondsUntilEmpty)
        guard projectedRunoutAt < current.resetDate else {
            lastProjection = nil
            self.previous = current
            lastOnTrackObservedAt = current.observedAt
            lastDiagnostics = "Run-out after reset"
            return nil
        }
        self.previous = current
        lastOnTrackObservedAt = nil
        lastProjection = Projection(
            runoutAt: projectedRunoutAt,
            resetDate: current.resetDate,
            remainingPercent: current.remainingPercent,
            observedAt: current.observedAt
        )
        lastDiagnostics = Self.diagnosticsLabel(runoutAt: projectedRunoutAt, observedAt: current.observedAt, now: now)
        return UsageLimitProjectionEstimate(runoutAt: projectedRunoutAt, observedAt: current.observedAt)
    }

    mutating func reset() {
        previous = nil
        lastProjection = nil
        lastOnTrackObservedAt = nil
        lastDiagnostics = "Waiting for data"
    }

    private mutating func retainedProjection(for current: ResolvedSample, now: Date, fallback: String) -> UsageLimitProjectionEstimate? {
        guard let projection = lastProjection else {
            lastDiagnostics = fallback
            return nil
        }
        // No fresh burn within the display window: clear the projection outright
        // so the published estimate goes nil in lockstep with the hidden label,
        // rather than staying armed (and re-appearing) until run-out.
        guard now.timeIntervalSince(projection.observedAt) <= Self.retentionWindow else {
            lastProjection = nil
            lastOnTrackObservedAt = nil
            lastDiagnostics = "Projection stale"
            return nil
        }
        guard abs(projection.resetDate.timeIntervalSince(current.resetDate)) < 120 else {
            lastProjection = nil
            lastDiagnostics = "Reset changed; waiting for next sample"
            return nil
        }
        guard current.remainingPercent <= projection.remainingPercent else {
            lastProjection = nil
            lastDiagnostics = "Usage recovered; waiting for next burn"
            return nil
        }
        guard projection.runoutAt > now else {
            lastProjection = nil
            lastDiagnostics = fallback
            return nil
        }
        guard projection.runoutAt < current.resetDate else {
            lastProjection = nil
            lastDiagnostics = "Run-out after reset"
            return nil
        }
        lastOnTrackObservedAt = nil
        lastDiagnostics = Self.diagnosticsLabel(runoutAt: projection.runoutAt, observedAt: projection.observedAt, now: now)
        return UsageLimitProjectionEstimate(runoutAt: projection.runoutAt, observedAt: projection.observedAt)
    }

    private static func remainingPercent(for sample: UsageLimitProjectionSample) -> Double {
        let fallback = Double(clampPercent(sample.remainingPercent))
        guard let exact = sample.remainingPercentExact else { return fallback }
        guard exact.isFinite else { return fallback }
        return max(0, min(100, exact))
    }

    private static func diagnosticsLabel(runoutAt: Date, observedAt: Date, now: Date) -> String {
        let label = formatUsageProjectionLabel(runoutAt: runoutAt, observedAt: observedAt, now: now)
        return label.map { "Active \($0)" } ?? "Projection stale"
    }

    private struct ResolvedSample: Equatable {
        let remainingPercent: Double
        let resetDate: Date
        let observedAt: Date
    }

    private struct Projection: Equatable {
        let runoutAt: Date
        let resetDate: Date
        let remainingPercent: Double
        let observedAt: Date
    }
}

/// Whether an on-track observation is recent enough to still trust — mirrors the
/// 3-minute freshness window used by the projected run-out token, so the smile
/// fades back to a calm dot shortly after a session stops burning.
func usageOnTrackIsFresh(observedAt: Date?, now: Date = Date()) -> Bool {
    guard let observedAt else { return false }
    let age = now.timeIntervalSince(observedAt)
    return age >= 0 && age <= 3 * 60
}

func formatUsageProjectionLabel(runoutAt: Date?,
                                observedAt: Date?,
                                now: Date = Date()) -> String? {
    guard let runoutAt, let observedAt else { return nil }
    guard now.timeIntervalSince(observedAt) <= 3 * 60 else { return nil }
    let seconds = runoutAt.timeIntervalSince(now)
    guard seconds > 0 else { return nil }
    if seconds < 60 { return "▸<1m" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes < 60 { return "▸\(minutes)m" }
    let hours = minutes / 60
    // A weekly-window run-out can be days out; render days rather than "▸167h".
    if hours >= 24 {
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "▸\(days)d" : "▸\(days)d \(remainingHours)h"
    }
    let remainingMinutes = minutes % 60
    if remainingMinutes == 0 { return "▸\(hours)h" }
    return "▸\(hours)h \(remainingMinutes)m"
}

func formatUsageProjectionDiagnosticsText(_ diagnostics: String,
                                           runoutAt: Double,
                                           observedAt: Double,
                                           now: Date = Date()) -> String {
    let trimmed = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
    if runoutAt > 0 || observedAt > 0 {
        let runoutDate = runoutAt > 0 ? Date(timeIntervalSince1970: runoutAt) : nil
        let observedDate = observedAt > 0 ? Date(timeIntervalSince1970: observedAt) : nil
        if let label = formatUsageProjectionLabel(runoutAt: runoutDate, observedAt: observedDate, now: now) {
            return "Active \(label)"
        }
        if trimmed.hasPrefix("Active ") {
            return "Projection stale"
        }
    }
    return trimmed.isEmpty ? "Waiting for data" : trimmed
}

/// Formats a reset date as ISO 8601 with "resets " prefix.
/// Used by OAuth and CLI RPC sources so UsageResetText.parse() can round-trip it.
func formatResetISO8601(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    return "resets \(fmt.string(from: date))"
}

func formatResetDisplay(kind: String,
                        source: UsageTrackingSource,
                        raw: String,
                        lastUpdate: Date?,
                        eventTimestamp: Date?,
                        now: Date = Date()) -> String {
    if isResetInfoUnavailable(raw: raw) { return UsageStaleThresholds.unavailableCopy }
    let eff = effectiveEventTimestamp(source: source, eventTimestamp: eventTimestamp, lastUpdate: lastUpdate, now: now)
    let isStale: Bool = {
        switch source {
        case .codex:
            return isResetInfoStale(kind: kind, source: source, lastUpdate: lastUpdate, eventTimestamp: eff, now: now)
        case .claude:
            return isResetInfoStale(kind: kind, source: source, lastUpdate: eff, now: now)
        }
    }()
    if isStale || raw.isEmpty { return UsageStaleThresholds.outdatedCopy }
    return UsageResetText.displayText(kind: kind, source: source, raw: raw, now: now)
}

func formatResetDisplayForMenu(kind: String,
                               source: UsageTrackingSource,
                               raw: String,
                               lastUpdate: Date?,
                               eventTimestamp: Date?,
                               now: Date = Date()) -> String {
    if isResetInfoUnavailable(raw: raw) { return UsageStaleThresholds.unavailableCopy }
    let eff = effectiveEventTimestamp(source: source, eventTimestamp: eventTimestamp, lastUpdate: lastUpdate, now: now)
    let isStale: Bool = {
        switch source {
        case .codex:
            return isResetInfoStale(kind: kind, source: source, lastUpdate: lastUpdate, eventTimestamp: eff, now: now)
        case .claude:
            return isResetInfoStale(kind: kind, source: source, lastUpdate: eff, now: now)
        }
    }()
    guard !isStale, !raw.isEmpty else { return UsageStaleThresholds.outdatedCopy }

    // Prefer a parsed reset date so we can show relative time (matches the cockpit widgets)
    // and also include weekday + numeric date in the menu.
    if let date = UsageResetText.resetDate(kind: kind, source: source, raw: raw, now: now) {
        let relative = relativeTimeUntilReset(date, now: now)
        let absolute = menuDateTimeWithWeekday(date)
        return "\(relative) (\(absolute))"
    }

    // Fallback to the existing formatter (may omit weekday if parsing fails).
    return UsageResetText.displayText(kind: kind, source: source, raw: raw, now: now)
}

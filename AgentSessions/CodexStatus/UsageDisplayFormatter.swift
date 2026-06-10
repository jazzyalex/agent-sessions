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
    let resetText: String
    let hasRateLimit: Bool
    let freshness: UsageLimitAlertFreshness
    let observedAt: Date
}

struct UsageLimitProjectionTracker {
    private var previous: ResolvedSample?
    private var lastProjection: Projection?

    mutating func update(with sample: UsageLimitProjectionSample,
                         now: Date = Date()) -> Date? {
        guard sample.hasRateLimit,
              sample.freshness.allowsProjectedAlerts,
              !isResetInfoUnavailable(raw: sample.resetText) else {
            previous = nil
            lastProjection = nil
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
            return nil
        }

        let current = ResolvedSample(
            remainingPercent: clampPercent(sample.remainingPercent),
            resetDate: resetDate,
            observedAt: sample.observedAt
        )
        defer { previous = current }

        guard let previous else { return nil }
        guard abs(previous.resetDate.timeIntervalSince(current.resetDate)) < 120 else {
            lastProjection = nil
            return nil
        }

        if current.remainingPercent > previous.remainingPercent {
            lastProjection = nil
            return nil
        }

        let elapsed = current.observedAt.timeIntervalSince(previous.observedAt)
        guard elapsed >= 60 else { return retainedProjection(for: current, now: now) }
        guard previous.remainingPercent > current.remainingPercent else {
            return retainedProjection(for: current, now: now)
        }

        let percentBurned = Double(previous.remainingPercent - current.remainingPercent)
        let secondsUntilEmpty = Double(current.remainingPercent) / (percentBurned / elapsed)
        guard secondsUntilEmpty > 0,
              secondsUntilEmpty <= 60 * 60 else {
            lastProjection = nil
            return nil
        }

        let projectedRunoutAt = current.observedAt.addingTimeInterval(secondsUntilEmpty)
        guard projectedRunoutAt < current.resetDate else {
            lastProjection = nil
            return nil
        }
        lastProjection = Projection(
            runoutAt: projectedRunoutAt,
            resetDate: current.resetDate,
            remainingPercent: current.remainingPercent
        )
        return projectedRunoutAt
    }

    mutating func reset() {
        previous = nil
        lastProjection = nil
    }

    private mutating func retainedProjection(for current: ResolvedSample, now: Date) -> Date? {
        guard let projection = lastProjection else { return nil }
        guard abs(projection.resetDate.timeIntervalSince(current.resetDate)) < 120 else {
            lastProjection = nil
            return nil
        }
        guard current.remainingPercent <= projection.remainingPercent else {
            lastProjection = nil
            return nil
        }
        guard projection.runoutAt > now,
              projection.runoutAt < current.resetDate else {
            lastProjection = nil
            return nil
        }
        return projection.runoutAt
    }

    private struct ResolvedSample: Equatable {
        let remainingPercent: Int
        let resetDate: Date
        let observedAt: Date
    }

    private struct Projection: Equatable {
        let runoutAt: Date
        let resetDate: Date
        let remainingPercent: Int
    }
}

func formatUsageProjectionLabel(runoutAt: Date?,
                                observedAt: Date?,
                                now: Date = Date()) -> String? {
    guard let runoutAt, let observedAt else { return nil }
    guard now.timeIntervalSince(observedAt) <= 3 * 60 else { return nil }
    let seconds = runoutAt.timeIntervalSince(now)
    guard seconds > 0, seconds <= 60 * 60 else { return nil }
    if seconds < 60 { return "▸<1m" }
    return "▸\(max(1, Int(ceil(seconds / 60))))m"
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

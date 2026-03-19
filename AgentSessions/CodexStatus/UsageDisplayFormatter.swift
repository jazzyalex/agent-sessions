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
    return "\(AppDateFormatting.timeShort(date)) \(AppDateFormatting.weekdayAbbrev(date))"
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

import Foundation

enum UsageResetText {
    /// Returns a normalized, user-facing reset text **without** the leading "resets " prefix.
    /// Falls back to a trimmed version of the input when parsing fails.
    static func displayText(kind: String, source: UsageTrackingSource, raw: String, now: Date = Date()) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDisplay = trimResetCopy(trimmed)
        guard !fallbackDisplay.isEmpty else { return "" }

        // Parse using the raw string (minus an optional "reset(s) " prefix) so we can respect any
        // explicit timezone suffix like "(America/Los_Angeles)".
        let parseInput = stripResetPrefix(trimmed)
        guard let date = parse(kind: kind, source: source, text: parseInput, now: now) else { return fallbackDisplay }
        return kind.lowercased().contains("wk") ? AppDateFormatting.dateTimeShort(date) : AppDateFormatting.timeShort(date)
    }

    /// Returns a normalized, user-facing reset text **with** the leading "resets " prefix.
    static func displayTextWithPrefix(kind: String, source: UsageTrackingSource, raw: String, now: Date = Date()) -> String {
        let s = displayText(kind: kind, source: source, raw: raw, now: now)
        if s.isEmpty { return "" }
        return "resets \(s)"
    }

    /// Parses the underlying reset time as a `Date` when possible.
    /// Returns `nil` when the string is empty or cannot be parsed.
    static func resetDate(kind: String, source: UsageTrackingSource, raw: String, now: Date = Date()) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDisplay = trimResetCopy(trimmed)
        guard !fallbackDisplay.isEmpty else { return nil }
        let parseInput = stripResetPrefix(trimmed)
        return parse(kind: kind, source: source, text: parseInput, now: now)
    }

    private static func parse(kind: String, source: UsageTrackingSource, text: String, now: Date) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Extract a timezone suffix like "(America/Los_Angeles)" when present, so Codex legacy
        // strings can be interpreted in the correct timezone.
        let split = splitTimezoneIdentifier(trimmed)
        let base = split.base
        let tz = split.tz ?? .autoupdatingCurrent

        // 1) Codex legacy: "HH:mm on d MMM"
        if let d = parseCodexLegacy(base, now: now, tz: tz) { return d }

        // 2) Claude: "MMM d at 2pm" / "MMM d, yyyy at 2pm" / time-only like "1am"
        if let d = parseClaude(trimmed, now: now) { return d }

        // 2.5) Localized numeric date/time (output from Date.FormatStyle(.numeric, .shortened))
        if let d = parseLocalizedNumericDateTime(base, tz: tz) { return d }

        // 3) Time-only "HH:mm" (Codex)
        if let d = parseTimeOnly(base, now: now, tz: tz) { return d }

        return nil
    }

    private static func parseLocalizedNumericDateTime(_ text: String, tz: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let df = DateFormatter()
        df.locale = .current
        df.timeZone = tz

        // Try the most likely locale formats first.
        let attempts: [(DateFormatter.Style, DateFormatter.Style)] = [
            (.short, .short),
            (.short, .medium),
            (.medium, .short),
            (.medium, .medium),
        ]
        for (dateStyle, timeStyle) in attempts {
            df.dateStyle = dateStyle
            df.timeStyle = timeStyle
            if let d = df.date(from: trimmed) { return d }
        }

        return nil
    }

    private static func parseCodexLegacy(_ text: String, now: Date, tz: TimeZone) -> Date? {
        let lower = text.lowercased()
        guard lower.contains(" on ") else { return nil }
        let parts = text.components(separatedBy: " on ")
        guard parts.count == 2 else { return nil }
        let timePart = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let datePart = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        guard let (hour, minute) = parseHourMinute24(timePart) ?? parseHourMinute12(timePart) else { return nil }

        var comps = DateComponents()
        comps.timeZone = tz
        comps.hour = hour
        comps.minute = minute
        comps.second = 0

        // Accept both "d MMM" and "d MMM yyyy"
        if let full = buildDateComponentsFromDayMonthYear(datePart, now: now, tz: tz) {
            comps.year = full.year
            comps.month = full.month
            comps.day = full.day
        } else {
            return nil
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: comps)
    }

    private static func parseClaude(_ text: String, now: Date) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Extract timezone like "(America/Los_Angeles)" when present.
        let split = splitTimezoneIdentifier(trimmed)
        let base = split.base
        let tz: TimeZone = split.tz ?? .autoupdatingCurrent

        // Common formats (English, stable parsing)
        let formats: [String] = [
            "MMM d, yyyy 'at' ha",
            "MMM d, yyyy 'at' h:mma",
            "MMM d, yyyy 'at' h a",
            "MMM d 'at' ha",
            "MMM d 'at' h:mma",
            "MMM d 'at' h a",
            "MMM d 'at' h:mm a",
            "ha",
            "h:mma",
            "h a"
        ]

        for format in formats {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = tz
            parser.dateFormat = format
            guard let parsed = parser.date(from: base) else { continue }

            // If the format doesn't include a month/day, treat it as time-only.
            if format == "ha" || format == "h:mma" || format == "h a" {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = tz
                let hm = cal.dateComponents(in: tz, from: parsed)
                guard let hour = hm.hour else { continue }
                let minute = hm.minute ?? 0

                var today = cal.dateComponents(in: tz, from: now)
                today.timeZone = tz
                today.hour = hour
                today.minute = minute
                today.second = 0
                today.nanosecond = 0
                guard var out = cal.date(from: today) else { continue }
                // If the computed time is already in the past, treat it as the next occurrence.
                if out < now {
                    out = cal.date(byAdding: .day, value: 1, to: out) ?? out
                }
                return out
            }

            // If the format doesn't include a year, assume current year (or next year if needed).
            if !format.contains("yyyy") {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = tz
                let parts = cal.dateComponents(in: tz, from: parsed)
                guard let month = parts.month, let day = parts.day, let hour = parts.hour else { continue }
                let minute = parts.minute ?? 0

                let nowParts = cal.dateComponents(in: tz, from: now)
                let baseYear = nowParts.year ?? 2000

                var comps = DateComponents()
                comps.timeZone = tz
                comps.year = baseYear
                comps.month = month
                comps.day = day
                comps.hour = hour
                comps.minute = minute
                comps.second = 0
                guard var out = cal.date(from: comps) else { continue }

                // If the computed date is meaningfully in the past, roll forward a year (common around New Year).
                if out < now.addingTimeInterval(-24 * 60 * 60) {
                    comps.year = baseYear + 1
                    out = cal.date(from: comps) ?? out
                }
                return out
            }

            return parsed
        }

        return nil
    }

    private static func parseTimeOnly(_ text: String, now: Date, tz: TimeZone) -> Date? {
        if let (h, m) = parseHourMinute24(text) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            guard var out = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
            // If the computed time is already in the past, treat it as the next occurrence.
            if out < now {
                out = cal.date(byAdding: .day, value: 1, to: out) ?? out
            }
            return out
        }
        if let (h, m) = parseHourMinute12(text) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            guard var out = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
            // If the computed time is already in the past, treat it as the next occurrence.
            if out < now {
                out = cal.date(byAdding: .day, value: 1, to: out) ?? out
            }
            return out
        }
        return nil
    }

    private static func stripResetPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("resets ") { return String(trimmed.dropFirst("resets ".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if lower.hasPrefix("reset ") { return String(trimmed.dropFirst("reset ".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmed
    }

    private static func splitTimezoneIdentifier(_ text: String) -> (base: String, tz: TimeZone?) {
        guard let open = text.firstIndex(of: "("),
              let close = text[open...].firstIndex(of: ")"),
              open < close
        else { return (text, nil) }

        let id = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tz = TimeZone(identifier: id) else { return (text, nil) }
        let base = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (base, tz)
    }

    private static func parseHourMinute24(_ text: String) -> (Int, Int)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: ":")
        guard parts.count == 2 else { return nil }
        guard let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    private static func parseHourMinute12(_ text: String) -> (Int, Int)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasAM = s.contains("am")
        let hasPM = s.contains("pm")
        guard hasAM || hasPM else { return nil }
        let cleaned = s
            .replacingOccurrences(of: "am", with: "")
            .replacingOccurrences(of: "pm", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains(":") {
            let parts = cleaned.split(separator: ":")
            guard parts.count == 2 else { return nil }
            guard let hh = Int(parts[0]), let mm = Int(parts[1]), (1...12).contains(hh), (0...59).contains(mm) else { return nil }
            var h = hh % 12
            if hasPM { h += 12 }
            return (h, mm)
        } else {
            guard let hh = Int(cleaned), (1...12).contains(hh) else { return nil }
            var h = hh % 12
            if hasPM { h += 12 }
            return (h, 0)
        }
    }

    private struct YMD { let year: Int; let month: Int; let day: Int }

    private static func buildDateComponentsFromDayMonthYear(_ text: String, now: Date, tz: TimeZone) -> YMD? {
        let formats = ["d MMM yyyy", "d MMM", "d MMMM yyyy", "d MMMM"]
        for fmt in formats {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = tz
            parser.dateFormat = fmt
            guard let parsed = parser.date(from: text) else { continue }

            let cal = Calendar(identifier: .gregorian)
            let parts = cal.dateComponents(in: tz, from: parsed)
            guard let month = parts.month, let day = parts.day else { continue }

            if fmt.contains("yyyy"), let year = parts.year {
                return YMD(year: year, month: month, day: day)
            }

            let nowParts = cal.dateComponents(in: tz, from: now)
            let baseYear = nowParts.year ?? 2000
            var comps = DateComponents()
            comps.timeZone = tz
            comps.year = baseYear
            comps.month = month
            comps.day = day
            comps.hour = 12
            comps.minute = 0
            comps.second = 0
            guard var out = Calendar(identifier: .gregorian).date(from: comps) else { continue }
            if out < now.addingTimeInterval(-24 * 60 * 60) {
                comps.year = baseYear + 1
                out = Calendar(identifier: .gregorian).date(from: comps) ?? out
            }
            let outParts = cal.dateComponents(in: tz, from: out)
            guard let year = outParts.year else { continue }
            return YMD(year: year, month: month, day: day)
        }
        return nil
    }
}

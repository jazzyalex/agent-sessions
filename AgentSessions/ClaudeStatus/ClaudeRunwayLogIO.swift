import Foundation

/// Shared file head/tail reading and lenient JSON field parsing used by the
/// Claude runway parser and scanner. Kept in one place so the two readers can't
/// drift apart.
enum ClaudeRunwayLog {
    static func tailData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    static func headData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// A `message.usage` record's cache-creation tokens, split by TTL, because the
    /// two bill differently: a 5-minute write is 1.25× base input, a 1-hour write 2×.
    ///
    /// A record carries BOTH `cache_creation_input_tokens` (the total) and a
    /// `cache_creation` sub-object breaking that same total down, so the two must
    /// never be summed — the sub-object REPLACES the flat field whenever it carries
    /// anything. The flat field stays the fallback for records that predate the split
    /// (and for a future TTL this build does not know about, where both known buckets
    /// read zero); it is charged at the 5-minute rate, which is what that single
    /// column always meant.
    ///
    /// Shared rather than inlined per call site: the runway `$` view and the weekly
    /// bootstrap must price the same record identically, or the weekly calibration is
    /// built on dollars that disagree with the `$/h` used to weight it.
    static func cacheCreation(usage: [String: Any]) -> (fiveMinute: Double, oneHour: Double) {
        if let split = usage["cache_creation"] as? [String: Any] {
            let fiveMinute = double(split["ephemeral_5m_input_tokens"]) ?? 0
            let oneHour = double(split["ephemeral_1h_input_tokens"]) ?? 0
            if fiveMinute > 0 || oneHour > 0 { return (fiveMinute, oneHour) }
        }
        return (double(usage["cache_creation_input_tokens"]) ?? 0, 0)
    }

    /// Collapses whitespace and truncates a label for a runway row.
    static func compact(_ text: String, limit: Int = 28) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// Parses ISO-8601 timestamps (with or without fractional seconds), the
    /// form Claude writes in transcript lines.
    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }
}

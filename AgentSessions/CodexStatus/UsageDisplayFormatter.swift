import Foundation

// Shared display helpers for reset text across UI surfaces.

func trimResetCopy(_ text: String) -> String {
    var result = text
    if result.hasPrefix("resets ") { result = String(result.dropFirst("resets ".count)) }
    if let parenIndex = result.firstIndex(of: "(") { result = String(result[..<parenIndex]).trimmingCharacters(in: .whitespaces) }
    return result
}

func formatResetDisplay(kind: String,
                        source: UsageTrackingSource,
                        raw: String,
                        lastUpdate: Date?,
                        eventTimestamp: Date?) -> String {
    let eff = effectiveEventTimestamp(source: source, eventTimestamp: eventTimestamp, lastUpdate: lastUpdate)
    let isStale = isResetInfoStale(kind: kind, source: source, lastUpdate: lastUpdate, eventTimestamp: eff)
    if isStale || raw.isEmpty { return UsageStaleThresholds.outdatedCopy }
    return trimResetCopy(raw)
}


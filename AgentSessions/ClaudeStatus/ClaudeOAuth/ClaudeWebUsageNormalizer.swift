import Foundation

// MARK: - Web Usage Normalizer
//
// Converts a ClaudeWebRawUsageResponse into a ClaudeLimitSnapshot.
// Mirrors ClaudeUsageNormalizer exactly, but sets source to .webEndpoint.
// Fails closed: returns nil if neither window has usable data.

struct ClaudeWebUsageNormalizer {
    static func normalize(
        _ raw: ClaudeWebRawUsageResponse,
        bodyHash: String,
        fetchedAt: Date = Date()
    ) -> ClaudeLimitSnapshot? {
        let fiveHour = usedRatio(from: raw.fiveHour)
        let weekly = usedRatio(from: raw.sevenDay)

        guard fiveHour != nil || weekly != nil else { return nil }

        return ClaudeLimitSnapshot(
            fetchedAt: fetchedAt,
            source: .webEndpoint,
            health: .live,
            fiveHourUsedRatio: fiveHour,
            fiveHourResetText: raw.fiveHour?.resetsAt ?? "",
            weeklyUsedRatio: weekly,
            weeklyResetText: raw.sevenDay?.resetsAt ?? "",
            weekOpusUsedRatio: usedRatio(from: raw.sevenDayOpus),
            weekOpusResetText: raw.sevenDayOpus?.resetsAt,
            rawPayloadHash: bodyHash
        )
    }

    private static func usedRatio(from window: ClaudeWebRawUsageResponse.RawWindow?) -> Double? {
        guard let window, let utilization = window.utilization else { return nil }
        return max(0.0, min(1.0, utilization / 100.0))
    }
}

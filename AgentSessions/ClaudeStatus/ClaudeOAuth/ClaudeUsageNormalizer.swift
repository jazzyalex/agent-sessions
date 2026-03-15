import Foundation

// MARK: - Usage Normalizer
//
// Converts a raw OAuth response DTO into a ClaudeLimitSnapshot.
// Fails closed: returns nil if neither window has usable data.
// Ratios are clamped to 0...1. Reset strings are passed through verbatim
// for UsageResetText to handle formatting (matches the tmux path).

struct ClaudeUsageNormalizer {
    static func normalize(
        _ raw: ClaudeOAuthRawUsageResponse,
        bodyHash: String,
        fetchedAt: Date = Date()
    ) -> ClaudeLimitSnapshot? {
        let fiveHour = usedRatio(from: raw.fiveHour)
        let weekly = usedRatio(from: raw.sevenDay)

        // Require at least one usable window
        guard fiveHour != nil || weekly != nil else { return nil }

        return ClaudeLimitSnapshot(
            fetchedAt: fetchedAt,
            source: .oauthEndpoint,
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

    // MARK: - Private

    /// Convert utilization (0-100 percent used) to a used ratio (0...1), clamped.
    private static func usedRatio(from window: ClaudeOAuthRawUsageResponse.RawWindow?) -> Double? {
        guard let window, let utilization = window.utilization else { return nil }
        return max(0.0, min(1.0, utilization / 100.0))
    }
}

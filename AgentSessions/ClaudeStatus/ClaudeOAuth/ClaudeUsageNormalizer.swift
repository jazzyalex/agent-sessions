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
        let fiveHour = ratio(from: raw.session5h)
        let weekly = ratio(from: raw.weekAllModels)

        // Require at least one usable window
        guard fiveHour != nil || weekly != nil else { return nil }

        return ClaudeLimitSnapshot(
            fetchedAt: fetchedAt,
            source: .oauthEndpoint,
            health: .live,
            fiveHourUsedRatio: fiveHour,
            fiveHourResetText: raw.session5h?.resets ?? "",
            weeklyUsedRatio: weekly,
            weeklyResetText: raw.weekAllModels?.resets ?? "",
            weekOpusUsedRatio: ratio(from: raw.weekOpus),
            weekOpusResetText: raw.weekOpus?.resets,
            rawPayloadHash: bodyHash
        )
    }

    // MARK: - Private

    /// Convert pctLeft (0-100 remaining) to a used ratio (0...1), clamped.
    private static func ratio(from window: ClaudeOAuthRawUsageResponse.RawWindow?) -> Double? {
        guard let window, let pctLeft = window.pctLeft else { return nil }
        return max(0.0, min(1.0, Double(100 - pctLeft) / 100.0))
    }
}

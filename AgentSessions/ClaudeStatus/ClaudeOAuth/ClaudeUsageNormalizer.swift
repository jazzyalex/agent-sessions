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

        // The scoped weekly window prefers the `limits` array, which is where a current
        // account reports it. `seven_day_opus` is the fallback for older payloads.
        let scoped = scopedWeekly(from: raw.limits)

        return ClaudeLimitSnapshot(
            fetchedAt: fetchedAt,
            source: .oauthEndpoint,
            health: .live,
            fiveHourUsedRatio: fiveHour,
            fiveHourResetText: raw.fiveHour?.resetsAt ?? "",
            weeklyUsedRatio: weekly,
            weeklyResetText: raw.sevenDay?.resetsAt ?? "",
            weekOpusUsedRatio: scoped?.usedRatio ?? usedRatio(from: raw.sevenDayOpus),
            weekOpusResetText: scoped?.resetText ?? raw.sevenDayOpus?.resetsAt,
            weekScopedLabel: scoped?.label,
            rawPayloadHash: bodyHash
        )
    }

    // MARK: - Scoped weekly window

    struct ScopedWeekly: Equatable {
        var usedRatio: Double
        var resetText: String?
        var label: String?
    }

    /// Picks the model-scoped weekly window out of the response's `limits` array.
    ///
    /// An account can report more than one. The server's `is_active` flag is the
    /// authoritative "this is the binding window", so it wins; with no flag set the most
    /// consumed window is the one worth warning about. An entry with no usable `percent`
    /// is not a window at all and is skipped rather than treated as 0%.
    static func scopedWeekly(from limits: [ClaudeOAuthRawUsageResponse.RawLimit]?) -> ScopedWeekly? {
        guard let limits else { return nil }
        let scoped = limits.filter { $0.kind == "weekly_scoped" && $0.percent != nil }
        guard !scoped.isEmpty else { return nil }

        let chosen = scoped.first(where: { $0.isActive == true })
            ?? scoped.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) })
        guard let chosen, let percent = chosen.percent else { return nil }

        return ScopedWeekly(
            usedRatio: max(0.0, min(1.0, percent / 100.0)),
            resetText: chosen.resetsAt,
            label: chosen.scope?.model?.displayName
        )
    }

    // MARK: - Private

    /// Convert utilization (0-100 percent used) to a used ratio (0...1), clamped.
    private static func usedRatio(from window: ClaudeOAuthRawUsageResponse.RawWindow?) -> Double? {
        guard let window, let utilization = window.utilization else { return nil }
        return max(0.0, min(1.0, utilization / 100.0))
    }
}

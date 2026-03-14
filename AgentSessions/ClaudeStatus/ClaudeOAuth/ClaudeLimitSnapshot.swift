import Foundation

// MARK: - Normalized Claude usage snapshot
//
// Both the OAuth endpoint path and the tmux /usage fallback path produce this model.
// Ratios are normalized to 0...1. UI converts: Int(ratio * 100) = percent used,
// 100 - Int(ratio * 100) = percent remaining.
//
// Reset times are stored as raw strings (as delivered by the source) so that
// UsageResetText can handle formatting and timezone parsing, matching the tmux path.

struct ClaudeLimitSnapshot: Equatable, Codable {
    var fetchedAt: Date
    var source: ClaudeUsageSource
    var health: ClaudeUsageHealth
    var fiveHourUsedRatio: Double?      // 0...1, nil = not available
    var fiveHourResetText: String       // Raw reset string for UsageResetText formatting
    var weeklyUsedRatio: Double?        // 0...1, nil = not available
    var weeklyResetText: String
    var weekOpusUsedRatio: Double?      // 0...1, nil = not available
    var weekOpusResetText: String?
    var rawPayloadHash: String?         // SHA256 of raw response body, for change detection

    // MARK: - Helpers

    var fiveHourRemainingPercent: Int {
        guard let ratio = fiveHourUsedRatio else { return 0 }
        return 100 - Int((ratio * 100).rounded())
    }

    var weeklyRemainingPercent: Int {
        guard let ratio = weeklyUsedRatio else { return 0 }
        return 100 - Int((ratio * 100).rounded())
    }

    var weekOpusRemainingPercent: Int? {
        guard let ratio = weekOpusUsedRatio else { return nil }
        return 100 - Int((ratio * 100).rounded())
    }
}

enum ClaudeUsageSource: String, Codable, CustomStringConvertible {
    case oauthEndpoint   // Live fetch from api.anthropic.com/api/oauth/usage
    case tmuxUsage       // Active tmux /usage probe
    case cachedOAuth     // Served from disk/memory cache of a prior OAuth fetch
    case unavailable     // No data source could produce a result

    var description: String {
        switch self {
        case .oauthEndpoint: return "OAuth"
        case .tmuxUsage: return "tmux"
        case .cachedOAuth: return "OAuth (cached)"
        case .unavailable: return "unavailable"
        }
    }
}

enum ClaudeUsageHealth: String, Codable, CustomStringConvertible {
    case live      // Fresh data from primary source
    case stale     // Data is older than freshness threshold but within hard-expire window
    case degraded  // Primary source failing, using cache or about to fall back
    case failed    // No usable data available

    var description: String { rawValue }
}

enum ClaudeUsageMode: String, CaseIterable {
    case auto       // Prefer OAuth, fall back to tmux on repeated failure (default)
    case oauthOnly  // OAuth endpoint only, no tmux fallback
    case tmuxOnly   // Existing tmux /usage probing only (pre-OAuth behavior)

    var displayName: String {
        switch self {
        case .auto: return "Auto (OAuth + tmux fallback)"
        case .oauthOnly: return "OAuth only"
        case .tmuxOnly: return "tmux only"
        }
    }
}

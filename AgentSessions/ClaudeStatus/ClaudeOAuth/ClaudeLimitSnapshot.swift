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
    /// The model-scoped weekly window. Named `weekOpus` for history and for the persisted
    /// `Codable` shape: it is no longer Opus-specific. On a current account it is fed from
    /// the `weekly_scoped` entry of the response's `limits` array, whichever model that
    /// names — `weekScopedLabel` says which. `seven_day_opus` remains the fallback for
    /// older payloads, and is null on accounts that report `limits`.
    var weekOpusUsedRatio: Double?      // 0...1, nil = not available
    var weekOpusResetText: String?
    /// Display name of the model the scoped weekly window covers ("Fable"). nil when the
    /// window came from the legacy `seven_day_opus` key, which names no model.
    var weekScopedLabel: String?
    var rawPayloadHash: String?         // SHA256 of raw response body, for change detection

    // MARK: - Helpers

    /// The weekly reset text safe to treat as a window IDENTITY, or nil when this
    /// source cannot supply one.
    ///
    /// Calibration needs to know exactly which quota week a percentage belongs to.
    /// The OAuth and web paths pass the provider's own ISO-8601 instant through
    /// untouched, so for them `weeklyResetText` IS that identity.
    ///
    /// The tmux path fails closed, for two independent reasons. Its reset is a
    /// countdown ("in 2d"), which names a different window on every poll — and it
    /// is formatted into a localized date before this snapshot exists, so by the
    /// time anyone sees it the countdown is unrecoverable and it reads as a stated
    /// instant. Preserving the raw countdown would stop the moving keys, but it
    /// would not make the reading trustworthy: the tmux weekly percentage observed
    /// live was 50% while OAuth reported 89% remaining for the same window. A
    /// source that cannot identify the week is not a source to calibrate from, so
    /// `Wk` shows `n/a` on a tmux-only account rather than a confident wrong number.
    var weeklyResetAnchorText: String? {
        switch source {
        case .oauthEndpoint, .cachedOAuth, .webEndpoint, .cachedWeb:
            return weeklyResetText.isEmpty ? nil : weeklyResetText
        case .tmuxUsage, .unavailable:
            return nil
        }
    }

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
    case webEndpoint     // Live fetch from claude.ai/api/organizations/{id}/usage
    case cachedWeb       // Served from cache of a prior Web API fetch
    case unavailable     // No data source could produce a result

    var description: String {
        switch self {
        case .oauthEndpoint: return "OAuth"
        case .tmuxUsage: return "tmux"
        case .cachedOAuth: return "OAuth (cached)"
        case .webEndpoint: return "Web API"
        case .cachedWeb: return "Web API (cached)"
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
    case webOnly    // claude.ai Web API only, no OAuth or tmux

    var displayName: String {
        switch self {
        case .auto: return "Auto (OAuth + Web/tmux)"
        case .oauthOnly: return "OAuth only"
        case .tmuxOnly: return "tmux only"
        case .webOnly: return "Web API only"
        }
    }
}

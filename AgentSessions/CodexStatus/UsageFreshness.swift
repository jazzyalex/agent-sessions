import Foundation

enum FreshUntilKeys {
    static let codex = "FreshUntilCodex"
    static let claude = "FreshUntilClaude"
}

func setFreshUntil(for source: UsageTrackingSource, until: Date) {
    let key = (source == .codex) ? FreshUntilKeys.codex : FreshUntilKeys.claude
    UserDefaults.standard.set(until.timeIntervalSince1970, forKey: key)
}

func freshUntil(for source: UsageTrackingSource, now: Date = Date()) -> Date? {
    let key = (source == .codex) ? FreshUntilKeys.codex : FreshUntilKeys.claude
    let ts = UserDefaults.standard.double(forKey: key)
    guard ts > 0 else { return nil }
    return Date(timeIntervalSince1970: ts)
}

// Unified effective timestamp used for stale checks across UI surfaces.
// - Codex prefers event timestamps from logs; on successful manual probe, a
//   60m TTL allows the UI to treat data as fresh even if logs lag.
// - Claude normally uses lastUpdate (poll time); the same 60m TTL applies after
//   a manual hard probe to keep UI fresh across relaunches.
func effectiveEventTimestamp(source: UsageTrackingSource,
                             eventTimestamp: Date?,
                             lastUpdate: Date?,
                             now: Date = Date()) -> Date? {
    let ttl = freshUntil(for: source, now: now)
    switch source {
    case .codex:
        if let eventTimestamp { return eventTimestamp }
        if let ttl, ttl > now { return now }
        return lastUpdate
    case .claude:
        if let ttl, ttl > now { return now }
        return lastUpdate
    }
}


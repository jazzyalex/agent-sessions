import Foundation

/// One reset credit as surfaced to the UI. Intentionally carries only
/// render-relevant fields — never tokens, account IDs, or credit IDs.
struct CodexResetCredit: Equatable {
    let grantedAt: Date?
    let expiresAt: Date?
    let status: String?
}

/// A normalized snapshot of the reset-credits endpoint.
struct CodexResetCreditsSnapshot: Equatable {
    let available: Int
    let credits: [CodexResetCredit]

    static let empty = CodexResetCreditsSnapshot(available: 0, credits: [])
}

/// Pure formatting + filtering shared by the Quota Meter and menu bar.
enum CodexResetCredits {
    private static let nonRenderableStatuses: Set<String> = ["expired", "redeemed"]

    /// Credits that should be shown: not expired (by status or by date),
    /// not redeemed, sorted by soonest expiry first.
    static func renderable(_ credits: [CodexResetCredit], now: Date) -> [CodexResetCredit] {
        credits
            .filter { credit in
                if let status = credit.status?.lowercased(),
                   nonRenderableStatuses.contains(status) {
                    return false
                }
                if let expiry = credit.expiresAt, expiry <= now { return false }
                return true
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
    }

    /// QM hover: month, day, time (no year) — e.g. "Jul 17, 5:45 PM".
    static func shortExpiry(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Menu bar: month, day, year, time — e.g. "Jul 17, 2026, 5:45 PM".
    static func fullExpiry(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    /// Quota Meter hover line, e.g. "↑ 1 reset credit · expires Jul 17, 5:45 PM"
    /// or "↑ 3 reset credits · next expires Jul 17, 5:45 PM". nil when nothing renderable.
    static func quotaMeterLine(_ credits: [CodexResetCredit], now: Date) -> String? {
        let items = renderable(credits, now: now)
        guard !items.isEmpty else { return nil }
        let n = items.count
        let earliest = items.compactMap(\.expiresAt).min()
        if n == 1 {
            let suffix = earliest.map { " · expires \(shortExpiry($0))" } ?? ""
            return "↑ 1 reset credit\(suffix)"
        } else {
            let suffix = earliest.map { " · next expires \(shortExpiry($0))" } ?? ""
            return "↑ \(n) reset credits\(suffix)"
        }
    }

    /// Menu-bar summary line, e.g. "1 available · expires Jul 17, 2026, 5:45 PM"
    /// or "3 available · next expires Jul 17, 2026, 5:45 PM". nil when nothing renderable.
    static func menuSummaryLine(_ credits: [CodexResetCredit], now: Date) -> String? {
        let items = renderable(credits, now: now)
        guard !items.isEmpty else { return nil }
        let n = items.count
        let earliest = items.compactMap(\.expiresAt).min()
        if n == 1 {
            let suffix = earliest.map { " · expires \(fullExpiry($0))" } ?? ""
            return "1 available\(suffix)"
        } else {
            let suffix = earliest.map { " · next expires \(fullExpiry($0))" } ?? ""
            return "\(n) available\(suffix)"
        }
    }

    /// Per-credit expiry lines for the menu bar when more than one credit exists,
    /// e.g. ["expires Jul 17, 2026, 5:45 PM", "expires Aug 1, 2026, 9:00 AM"].
    static func menuExpiryLines(_ credits: [CodexResetCredit], now: Date) -> [String] {
        renderable(credits, now: now).compactMap { credit in
            credit.expiresAt.map { "expires \(fullExpiry($0))" }
        }
    }
}

import Foundation

// MARK: - Length-based rate-limit window classification
//
// Codex reports rate-limit usage as up to two windows. Historically the provider
// sent them in fixed slots — `primary` = the 5-hour window, `secondary` = the
// weekly window — and every parser trusted that *position*.
//
// On 2026-07-13 OpenAI temporarily dropped the 5-hour window: the *weekly* window
// (window_minutes = 10080) moved into the `primary` slot and `secondary` went
// null. Position-based parsers then painted the weekly window as "5h" (a ~7-day
// reset shown on the 5h line) and left the weekly line empty.
//
// This classifier routes each window into the 5h / weekly slot by the window's
// own *length*, not its slot. Routing is therefore immune to the provider
// reordering, dropping, or renaming slots, and auto-recovers when the 5h window
// returns. Data it cannot confidently place is reported as `suspect` so the UI
// can refuse to show a possibly-wrong number rather than guess.

/// Which bucket a rate-limit window belongs to, decided by its length.
enum CodexRateLimitWindowClass: Equatable {
    case short   // the "5h"-class (short rolling) window
    case long    // the "weekly"-class (long rolling) window
}

/// A provider window, normalized to the fields the classifier needs. Each parse
/// site adapts its own raw shape (Int/Double percent, epoch/ISO reset) into this.
struct CodexRateLimitWindowInput: Equatable {
    /// Percent of the window still available (0–100). May be out of range when
    /// the source data is malformed — the router treats that as suspect.
    var remainingPercent: Double?
    var resetAt: Date?
    /// Declared rolling-window length. Authoritative when present (JSONL /
    /// OAuth carry it); the CLI-RPC path may omit it, in which case the router
    /// falls back to the legacy positional mapping.
    var windowMinutes: Int?
}

/// The outcome of routing a provider's windows into fixed display slots.
struct CodexRateLimitRouting: Equatable {
    /// The window placed in the 5h slot, or nil when no short window classified.
    var fiveHour: CodexRateLimitWindowInput?
    /// The window placed in the weekly slot, or nil when no long window classified.
    var weekly: CodexRateLimitWindowInput?
    /// True when the provider sent rate-limit data we could not confidently
    /// interpret (unclassifiable window, out-of-range percentage, or two windows
    /// of the same class). Drives the UI "can't verify" state — never show a
    /// guessed number when this is set for an empty slot.
    var suspect: Bool
}

enum CodexRateLimitWindowClassifier {
    /// Split between short and long windows. The real windows are 5h (300 min)
    /// and weekly (10080 min) — a 33× gap — so any split between them works; one
    /// day is the memorable midpoint and still classifies plausible future
    /// windows correctly (a 4h or 16h short window lands short; a bi-weekly
    /// window lands long).
    static let shortLongSplitMinutes = 1440

    /// Upper sanity bound on a plausible rolling window. Beyond this the value is
    /// treated as garbage rather than a real (e.g. bi-weekly / monthly) window.
    static let maximumPlausibleWindowMinutes = 62 * 24 * 60   // 62 days

    /// Classify one window by its declared length. Returns nil when the length is
    /// absent or implausible — the caller decides whether that is suspect (a
    /// length-bearing response with one bad window) or a legacy lengthless
    /// response (handled positionally in `route`).
    static func classify(windowMinutes: Int?) -> CodexRateLimitWindowClass? {
        guard let minutes = windowMinutes,
              minutes > 0,
              minutes <= maximumPlausibleWindowMinutes else { return nil }
        return minutes < shortLongSplitMinutes ? .short : .long
    }

    /// Route two candidate windows into the 5h / weekly slots.
    ///
    /// - When at least one window declares a length, route **by length** (immune
    ///   to the provider reordering/dropping slots) and mark `suspect` for any
    ///   window we then can't place: an unclassifiable length, or two windows of
    ///   the same class.
    /// - When *no* window declares a length (a legacy source that never carried
    ///   `window_minutes`, e.g. some CLI-RPC responses), fall back to the historical
    ///   positional mapping — `a` → 5h, `b` → weekly — so length-less sources keep
    ///   working exactly as before. Reset distance is deliberately NOT used to
    ///   classify: a nearly-exhausted weekly window and a fresh 5h window overlap
    ///   there, so guessing from it would show wrong data.
    ///
    /// Either input may be nil (window absent — never suspect on its own). An
    /// out-of-range percentage is always suspect and never placed.
    static func route(_ a: CodexRateLimitWindowInput?,
                      _ b: CodexRateLimitWindowInput?) -> CodexRateLimitRouting {
        let hasAnyLength = (a?.windowMinutes != nil) || (b?.windowMinutes != nil)

        if !hasAnyLength {
            // A lone window in the primary slot with no declared length is
            // ambiguous: historically the 5h window, but a provider that drops the
            // 5h window puts the *weekly* window there. Rather than positionally
            // force it onto the 5h line — re-introducing the exact mislabel this
            // fix exists to prevent — mark it suspect. Two windows keep the
            // historical primary=5h / secondary=weekly mapping; a lone secondary is
            // reliably the weekly window.
            if a != nil, b == nil {
                return CodexRateLimitRouting(fiveHour: nil, weekly: nil, suspect: true)
            }
            return CodexRateLimitRouting(
                fiveHour: placeable(a) ? a : nil,
                weekly: placeable(b) ? b : nil,
                suspect: !placeable(a) || !placeable(b)
            )
        }

        var routing = CodexRateLimitRouting(fiveHour: nil, weekly: nil, suspect: false)
        for input in [a, b] {
            guard let input else { continue }               // absent window: not suspect
            guard placeable(input) else {
                routing.suspect = true                       // out-of-range percentage
                continue
            }
            switch classify(windowMinutes: input.windowMinutes) {
            case .short:
                if routing.fiveHour == nil { routing.fiveHour = input }
                else { routing.suspect = true }             // two short windows: can't disambiguate
            case .long:
                if routing.weekly == nil { routing.weekly = input }
                else { routing.suspect = true }             // two long windows: can't disambiguate
            case nil:
                routing.suspect = true                       // present but unclassifiable length
            }
        }
        return routing
    }

    /// A present window we can show: absent is fine (yields an empty slot); a
    /// percentage far outside [0,100] signals malformed data and is not placed.
    private static func placeable(_ input: CodexRateLimitWindowInput?) -> Bool {
        guard let input, let percent = input.remainingPercent else { return true }
        return percent >= -0.5 && percent <= 100.5
    }
}

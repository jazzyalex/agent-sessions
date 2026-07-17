import Foundation

/// Unified display mode for rate-limit percentages across Codex and Claude.
///
/// The underlying models store **percent remaining** (\"left\").
/// UI layers can choose between showing:
/// - Left % (Codex-style): \"71% left\" with bars filled by percent used
/// - Used % (Claude-style): \"29% used\" with bars filled by percent used
enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case left
    case used

    static let storageKey = PreferencesKey.usageDisplayMode

    var id: String { rawValue }

    /// Human-readable label for Preferences.
    var title: String {
        switch self {
        case .left:
            return "Left % (Codex-style)"
        case .used:
            return "Used % (Claude-style)"
        }
    }

    /// Current mode from UserDefaults, defaulting to `.left`.
    static func current() -> UsageDisplayMode {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return UsageDisplayMode(rawValue: raw ?? "") ?? .left
    }

    /// Clamp a percentage into [0, 100].
    private static func clamp(_ value: Int) -> Int {
        return max(0, min(100, value))
    }

    /// Convert a \"percent left\" value into the value that should be shown
    /// numerically for this mode.
    func numericPercent(fromLeft leftPercent: Int) -> Int {
        let left = Self.clamp(leftPercent)
        switch self {
        case .left:
            return left
        case .used:
            return Self.clamp(100 - left)
        }
    }

    /// Suffix text appropriate for the current mode (\"left\" or \"used\").
    var suffix: String {
        switch self {
        case .left:
            return "left"
        case .used:
            return "used"
        }
    }

    /// Percentage that should drive the filled portion of usage bars.
    /// Bars always represent **percent used** in both modes.
    func barUsedPercent(fromLeft leftPercent: Int) -> Int {
        let left = Self.clamp(leftPercent)
        return Self.clamp(100 - left)
    }
}

/// How the Quota Meter run-out column renders the "on track" state — a session
/// that is actively burning but projected to fit the 5h window. The default
/// shows a smiling face (same color as the row, with an occasional playful
/// spin); the quiet option falls back to the muted dot.
enum QuotaMeterOnTrackGlyph: String, CaseIterable, Identifiable {
    case smile
    case dot

    static let storageKey = PreferencesKey.quotaMeterOnTrackGlyph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smile:
            return "Smile"
        case .dot:
            return "Dot"
        }
    }

    /// One-line explanation shown under the selector for the active option.
    var detail: String {
        switch self {
        case .smile:
            return "Shows a smiling face while you’re working but on track to fit the 5-hour window."
        case .dot:
            return "Shows a quiet dot instead of the smile."
        }
    }

    static func current(raw: String) -> QuotaMeterOnTrackGlyph {
        QuotaMeterOnTrackGlyph(rawValue: raw) ?? .smile
    }
}

/// When the Quota Meter reveals its chrome layer — the toolbar plus the
/// reset-credits line, which are shown and hidden together.
///
/// The governing rule is that the Quota Meter never resizes from *passive*
/// pointer movement. `.onHover` is the one mode that opts into it; `.onDemand`
/// trades it for a deliberate right-click. Data may always resize the window
/// (the runway drawer, credits arriving) — that is not what this governs.
///
/// The rule exists because of dragging. The window is movable by its background
/// (`isMovableByWindowBackground`), so repositioning this pinned widget means
/// putting the pointer on it — which under hover-reveal resizes it mid-grab,
/// shifting the very thing being aimed at. The pointer's job here is to move the
/// window; right-click's job is to summon controls. Anything that re-couples
/// chrome to plain hover brings the fight over the drag target back.
enum QuotaMeterChrome: String, CaseIterable, Identifiable {
    case always
    case onHover = "on_hover"
    case onDemand = "on_demand"

    static let storageKey = PreferencesKey.quotaMeterChrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always:
            return "Always"
        case .onHover:
            return "On Hover"
        case .onDemand:
            return "On Demand"
        }
    }

    /// One-line explanation shown under the selector for the active option.
    var detail: String {
        switch self {
        case .always:
            return "Toolbar stays visible. The window never resizes under the pointer."
        case .onHover:
            return "Toolbar appears while the pointer rests on the window, resizing it."
        case .onDemand:
            return "Toolbar appears on right-click, then collapses when the pointer leaves."
        }
    }

    /// The single decision point for whether chrome is on screen. Each mode
    /// reads exactly one trigger, which is what keeps the pointer from moving
    /// the window in the two modes that promise it won't.
    func showsChrome(pointerDwelled: Bool, demandRevealed: Bool) -> Bool {
        switch self {
        case .always:
            return true
        case .onHover:
            return pointerDwelled
        case .onDemand:
            return demandRevealed
        }
    }

    /// The "Right-click for controls" hint: `.onDemand` only, whenever the pointer
    /// is dwelling and the chrome isn't already out. It recurs on every hover
    /// rather than retiring — right-click is the only route back to the toolbar,
    /// so the reminder has to stay findable, not vanish after the first success.
    func showsRightClickHint(pointerDwelled: Bool, demandRevealed: Bool) -> Bool {
        guard self == .onDemand else { return false }
        return pointerDwelled && !demandRevealed
    }

    /// Only `.onDemand` reveals on an explicit right-click.
    var respondsToRightClick: Bool { self == .onDemand }

    /// Whether the dwell timer has a consumer. `.always` shows chrome
    /// unconditionally, so it needs no timer. `.onHover` and `.onDemand` both watch
    /// the pointer — `.onHover` to reveal the toolbar, `.onDemand` to re-show the
    /// recurring right-click hint on each dwell (it never retires).
    func armsDwellTimer() -> Bool {
        switch self {
        case .always:
            return false
        case .onHover, .onDemand:
            return true
        }
    }

    /// Defaults to `.onDemand`, including for existing installs that predate the
    /// key. Hover-reveal is not a preference being overridden but a defect being
    /// retired — it resizes the window mid-drag — and the on-hover hint teaches
    /// the replacement gesture at exactly the moment a user reaches for the
    /// missing toolbar.
    static func current(raw: String) -> QuotaMeterChrome {
        QuotaMeterChrome(rawValue: raw) ?? .onDemand
    }
}

enum QuotaMeterRunwayVisibility: String, CaseIterable, Identifiable {
    case automatic = "auto"
    case alwaysOn = "always_on"
    case alwaysOff = "always_off"

    static let storageKey = PreferencesKey.quotaMeterRunwayVisibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Auto"
        case .alwaysOn:
            return "Always On"
        case .alwaysOff:
            return "Always Off"
        }
    }

    /// Compact label for the toolbar pill and segmented control.
    var shortLabel: String {
        switch self {
        case .automatic:
            return "Auto"
        case .alwaysOn:
            return "On"
        case .alwaysOff:
            return "Off"
        }
    }

    /// One-line explanation shown under the selector for the active option.
    var detail: String {
        switch self {
        case .automatic:
            return "Shows the session runway only when it’s running low."
        case .alwaysOn:
            return "Always shows the session runway drawer."
        case .alwaysOff:
            return "Hides the session runway drawer."
        }
    }

    static func current(raw: String) -> QuotaMeterRunwayVisibility {
        QuotaMeterRunwayVisibility(rawValue: raw) ?? .automatic
    }
}

/// Which rate the Session Runway rows report. `$` (`.dollar`) resolves to token
/// throughput in Phase 1 (pricing is Phase 2); the case exists so the toolbar
/// control and preference are forward-compatible.
///
/// Declaration order drives the toolbar picker: the two quota-window rates lead,
/// then the two throughput rates.
enum RunwayPresentation: String, CaseIterable, Identifiable {
    case fiveHour = "5h"
    case weekly = "weekly"
    case token = "token"
    case dollar = "dollar"

    static let storageKey = PreferencesKey.quotaMeterRunwayPresentation
    var id: String { rawValue }

    /// Compact label for the toolbar pill.
    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "Wk"
        case .token: return "tk"
        case .dollar: return "$"
        }
    }

    /// Full name shown in the popover.
    var title: String {
        switch self {
        case .fiveHour: return "5-Hour Burn"
        case .weekly: return "Weekly Burn"
        case .token: return "Token Burn"
        case .dollar: return "Dollar Burn"
        }
    }

    /// One-line explanation under the active option.
    var detail: String {
        switch self {
        case .fiveHour: return "Quota-minutes per hour against the 5-hour window."
        case .weekly: return "Share of average weekly burn."
        case .token: return "Tokens generated per hour, per session."
        case .dollar: return "Estimated API-equivalent cost per hour."
        }
    }

    static func current(raw: String) -> RunwayPresentation {
        RunwayPresentation(rawValue: raw) ?? .fiveHour
    }
}

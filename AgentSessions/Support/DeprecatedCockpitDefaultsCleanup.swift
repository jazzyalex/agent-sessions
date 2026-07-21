import Foundation

/// Removes UserDefaults values left behind by the retired Compact and Full
/// Agent Cockpit modes.
///
/// Runs unconditionally at launch. `removeObject(forKey:)` is idempotent and
/// costs nothing when the keys are already gone, so this needs no versioned
/// migration flag — which also keeps it clear of the repo's no-feature-flags
/// policy.
enum DeprecatedCockpitDefaultsCleanup {

    /// Settings keys whose reading code was deleted with the Cockpit modes.
    /// Raw strings rather than `PreferencesKey.Cockpit` constants on purpose:
    /// those constants were deleted in the same change, and a cleanup sweep
    /// naturally outlives the symbols it cleans up after.
    static let removedKeys = [
        "CockpitHUDDisplayMode",
        "CockpitHUDCompact",
        "CockpitHUDCompactBaselineRows",
        "CockpitHUDCompactAutoFitEnabled",
        "CockpitHUDShowAgentNameInCompact",
        "CockpitShowTabSubtitleInFullMode",
        "CockpitHUDShowLimits",
        "CockpitHUDGroupByProject",
        "CockpitCodexLiveFilterMode"
    ]

    /// Per-mode window frames AppKit autosaved for modes that no longer exist.
    ///
    /// `NSWindow Frame AgentCockpitHUDWindow.limits` is deliberately absent — it
    /// holds the live Quota Meter position, and removing it would reset every
    /// existing user's window placement.
    static let removedWindowFrameKeys = [
        "NSWindow Frame AgentCockpitHUDWindow.full",
        "NSWindow Frame AgentCockpitHUDWindow.compact"
    ]

    static func run(defaults: UserDefaults = .standard) {
        for key in removedKeys + removedWindowFrameKeys {
            defaults.removeObject(forKey: key)
        }
    }
}

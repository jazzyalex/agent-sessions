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

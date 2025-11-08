import Foundation

enum PreferencesKey {
    // Persistent tab + global toggles
    static let lastSelectedTab = "PreferencesLastSelectedTab"
    static let showUsageStrip = "ShowUsageStrip"
    static let showClaudeUsageStrip = "ShowClaudeUsageStrip"
    static let codexUsageEnabled = "CodexUsageEnabled"
    static let codexAllowStatusProbe = "CodexAllowStatusProbe"
    static let codexProbeCleanupMode = "CodexProbeCleanupMode"
    static let claudeUsageEnabled = "ClaudeUsageEnabled"
    static let claudeProbeCleanupMode = "ClaudeProbeCleanupMode"
    static let showSystemProbeSessions = "ShowSystemProbeSessions"

    // Menu bar + strips
    static let menuBarEnabled = "MenuBarEnabled"
    static let menuBarScope = "MenuBarScope"
    static let menuBarStyle = "MenuBarStyle"
    static let stripShowResetTime = "StripShowResetTime"
    static let stripMonochromeMeters = "StripMonochromeMeters"

    // Unified window filters
    static let hideZeroMessageSessions = "HideZeroMessageSessions"
    static let hideLowMessageSessions = "HideLowMessageSessions"

    // Polling intervals
    static let codexPollingInterval = "CodexPollingInterval"
    static let claudePollingInterval = "ClaudePollingInterval"

    enum Unified {
        static let showCodexStrip = "UnifiedShowCodexStrip"
        static let showClaudeStrip = "UnifiedShowClaudeStrip"
        static let showSourceColumn = "UnifiedShowSourceColumn"
        static let showSizeColumn = "UnifiedShowSizeColumn"
        static let showStarColumn = "UnifiedShowStarColumn"
        static let hasCommandsOnly = "UnifiedHasCommandsOnly"
        static let skipAgentsPreamble = "SkipAgentsPreamble"
    }

    enum MenuBar {
        static let source = "MenuBarSource"
    }

    enum Paths {
        static let claudeSessionsRootOverride = "ClaudeSessionsRootOverride"
    }
}

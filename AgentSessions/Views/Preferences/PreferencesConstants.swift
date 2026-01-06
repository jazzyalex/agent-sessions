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
    static let usageDisplayMode = "UsageDisplayMode"

    // Menu bar + strips
    static let menuBarEnabled = "MenuBarEnabled"
    static let menuBarScope = "MenuBarScope"
    static let menuBarStyle = "MenuBarStyle"
    static let stripShowResetTime = "StripShowResetTime"
    static let stripMonochromeMeters = "StripMonochromeMeters"

    // Unified window filters
    static let hideZeroMessageSessions = "HideZeroMessageSessions"
    static let hideLowMessageSessions = "HideLowMessageSessions"

    // CLI availability flags (assume installed until a probe fails)
    static let codexCLIAvailable = "CodexCLIAvailable"
    static let claudeCLIAvailable = "ClaudeCLIAvailable"
    static let geminiCLIAvailable = "GeminiCLIAvailable"
    static let openCodeCLIAvailable = "OpenCodeCLIAvailable"
    static let copilotCLIAvailable = "CopilotCLIAvailable"
    static let droidCLIAvailable = "DroidCLIAvailable"

    enum Agents {
        static let didSeedEnabledAgents = "DidSeedEnabledAgents_v1"
        static let codexEnabled = "AgentEnabledCodex"
        static let claudeEnabled = "AgentEnabledClaude"
        static let geminiEnabled = "AgentEnabledGemini"
        static let openCodeEnabled = "AgentEnabledOpenCode"
        static let copilotEnabled = "AgentEnabledCopilot"
        static let droidEnabled = "AgentEnabledDroid"
    }

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
        static let showCodexToolbarFilter = "UnifiedShowCodexToolbarFilter"
        static let showClaudeToolbarFilter = "UnifiedShowClaudeToolbarFilter"
        static let showGeminiToolbarFilter = "UnifiedShowGeminiToolbarFilter"
        static let showOpenCodeToolbarFilter = "UnifiedShowOpenCodeToolbarFilter"
    }

    enum MenuBar {
        static let source = "MenuBarSource"
        static let showCodexResetTimes = "MenuBarShowCodexResetTimes"
        static let showClaudeResetTimes = "MenuBarShowClaudeResetTimes"
        static let showPills = "MenuBarShowPills"
    }

    enum Advanced {
        static let enableGitInspector = "EnableGitInspector"
        static let enableDeepToolOutputSearch = "EnableDeepToolOutputSearch"
        static let enableRecentToolIOIndex = "EnableRecentToolIOIndex"
    }

    enum Paths {
        static let claudeSessionsRootOverride = "ClaudeSessionsRootOverride"
        static let copilotSessionsRootOverride = "CopilotSessionsRootOverride"
        static let droidSessionsRootOverride = "DroidSessionsRootOverride"
        static let droidProjectsRootOverride = "DroidProjectsRootOverride"
    }

    enum Archives {
        static let starPinsSessions = "StarPinsSessions"
        static let stopSyncAfterInactivityMinutes = "ArchiveStopSyncAfterInactivityMinutes"
        static let unstarRemovesArchive = "UnstarRemovesLocalArchive"
    }
}

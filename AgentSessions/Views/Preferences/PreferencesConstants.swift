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
    static let claudeUsageMode = "ClaudeUsageMode"       // ClaudeUsageMode.rawValue, default "auto"
    static let claudeWebApiEnabled = "ClaudeWebApiEnabled"  // Bool, default false
    static let claudeProbeCleanupMode = "ClaudeProbeCleanupMode"
    static let showSystemProbeSessions = "ShowSystemProbeSessions"
    static let showHousekeepingSessions = "ShowHousekeepingSessions"
    static let usageDisplayMode = "UsageDisplayMode"
    static let quotaMeterRunwayVisibility = "QuotaMeterRunwayVisibility"
    static let usageLimitNotificationsEnabled = "UsageLimitNotificationsEnabled"
    static let usageLimitNotificationVisualEnabled = "UsageLimitNotificationVisualEnabled"
    static let usageLimitNotificationSoundEnabled = "UsageLimitNotificationSoundEnabled"
    static let usageLimitNotificationThresholdPercent = "UsageLimitNotificationThresholdPercent"
    static let usageLimitNotificationCodexEnabled = "UsageLimitNotificationCodexEnabled"
    static let usageLimitNotificationClaudeEnabled = "UsageLimitNotificationClaudeEnabled"
    static let usageLimitNotificationApproachingEnabled = "UsageLimitNotificationApproachingEnabled"
    static let usageLimitNotificationProjectedEnabled = "UsageLimitNotificationProjectedEnabled"
    static let usageLimitCockpitProjectionEnabled = "UsageLimitCockpitProjectionEnabled"
    static let usageLimitRunwayMatchMainTextSize = "UsageLimitRunwayMatchMainTextSize"
    static let usageLimitNotificationExhaustedEnabled = "UsageLimitNotificationExhaustedEnabled"
    static let usageLimitNotificationFiveHourResetEnabled = "UsageLimitNotificationFiveHourResetEnabled"
    static let usageLimitDiagnosticsCodexSource = "UsageLimitDiagnosticsCodexSource"
    static let usageLimitDiagnosticsCodexFreshness = "UsageLimitDiagnosticsCodexFreshness"
    static let usageLimitDiagnosticsCodexObservedAt = "UsageLimitDiagnosticsCodexObservedAt"
    static let usageLimitDiagnosticsCodexProjection = "UsageLimitDiagnosticsCodexProjection"
    static let usageLimitDiagnosticsCodexProjectionRunoutAt = "UsageLimitDiagnosticsCodexProjectionRunoutAt"
    static let usageLimitDiagnosticsCodexProjectionObservedAt = "UsageLimitDiagnosticsCodexProjectionObservedAt"
    static let usageLimitDiagnosticsCodexLastAlertSummary = "UsageLimitDiagnosticsCodexLastAlertSummary"
    static let usageLimitDiagnosticsCodexLastAlertAt = "UsageLimitDiagnosticsCodexLastAlertAt"
    static let usageLimitDiagnosticsCodexDelivery = "UsageLimitDiagnosticsCodexDelivery"
    static let usageLimitDiagnosticsCodexDeliveryAt = "UsageLimitDiagnosticsCodexDeliveryAt"
    static let usageLimitDiagnosticsCodexNextResetReminderAt = "UsageLimitDiagnosticsCodexNextResetReminderAt"
    static let usageLimitDiagnosticsClaudeSource = "UsageLimitDiagnosticsClaudeSource"
    static let usageLimitDiagnosticsClaudeFreshness = "UsageLimitDiagnosticsClaudeFreshness"
    static let usageLimitDiagnosticsClaudeObservedAt = "UsageLimitDiagnosticsClaudeObservedAt"
    static let usageLimitDiagnosticsClaudeProjection = "UsageLimitDiagnosticsClaudeProjection"
    static let usageLimitDiagnosticsClaudeProjectionRunoutAt = "UsageLimitDiagnosticsClaudeProjectionRunoutAt"
    static let usageLimitDiagnosticsClaudeProjectionObservedAt = "UsageLimitDiagnosticsClaudeProjectionObservedAt"
    static let usageLimitDiagnosticsClaudeLastAlertSummary = "UsageLimitDiagnosticsClaudeLastAlertSummary"
    static let usageLimitDiagnosticsClaudeLastAlertAt = "UsageLimitDiagnosticsClaudeLastAlertAt"
    static let usageLimitDiagnosticsClaudeDelivery = "UsageLimitDiagnosticsClaudeDelivery"
    static let usageLimitDiagnosticsClaudeDeliveryAt = "UsageLimitDiagnosticsClaudeDeliveryAt"
    static let usageLimitDiagnosticsClaudeNextResetReminderAt = "UsageLimitDiagnosticsClaudeNextResetReminderAt"
    static let codexLimitNotificationsEnabled = "CodexLimitNotificationsEnabled"
    static let codexLimitNotificationVisualEnabled = "CodexLimitNotificationVisualEnabled"
    static let codexLimitNotificationSoundEnabled = "CodexLimitNotificationSoundEnabled"
    static let codexLimitNotificationThresholdPercent = "CodexLimitNotificationThresholdPercent"

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
    static let antigravityCLIAvailable = "AntigravityCLIAvailable"
    static let openCodeCLIAvailable = "OpenCodeCLIAvailable"
    static let hermesCLIAvailable = "HermesCLIAvailable"
    static let copilotCLIAvailable = "CopilotCLIAvailable"
    static let droidCLIAvailable = "DroidCLIAvailable"
    static let cursorCLIAvailable = "CursorCLIAvailable"
    static let piCLIAvailable = "PiCLIAvailable"

    enum Agents {
        static let didSeedEnabledAgents = "DidSeedEnabledAgents_v1"
        static let codexEnabled = "AgentEnabledCodex"
        static let claudeEnabled = "AgentEnabledClaude"
        static let antigravityEnabled = "AgentEnabledAntigravity"
        static let openCodeEnabled = "AgentEnabledOpenCode"
        static let hermesEnabled = "AgentEnabledHermes"
        static let copilotEnabled = "AgentEnabledCopilot"
        static let droidEnabled = "AgentEnabledDroid"
        static let openClawEnabled = "AgentEnabledOpenClaw"
        static let cursorEnabled = "AgentEnabledCursor"
        static let piEnabled = "AgentEnabledPi"
        static let knownAvailableProviders = "KnownAvailableProviders"
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
        static let showArchivedCodexDesktopOnly = "UnifiedShowArchivedCodexDesktopOnly"
        static let collapsedHierarchyParents = "UnifiedCollapsedHierarchyParents"
        static let skipAgentsPreamble = "SkipAgentsPreamble"
        static let sessionViewAutoScrollTarget = "UnifiedSessionViewAutoScrollTarget"
        static let showCodexToolbarFilter = "UnifiedShowCodexToolbarFilter"
        static let showClaudeToolbarFilter = "UnifiedShowClaudeToolbarFilter"
        static let showAntigravityToolbarFilter = "UnifiedShowAntigravityToolbarFilter"
        static let showOpenCodeToolbarFilter = "UnifiedShowOpenCodeToolbarFilter"
        static let showSubagentHierarchy = "UnifiedShowSubagentHierarchy"
        static let showTranscriptWindow = "UnifiedShowSessionDetails"
    }

    enum MenuBar {
        static let source = "MenuBarSource"
        static let showLiveSessionIcons = "MenuBarShowLiveSessionIcons"
        static let showCodexResetTimes = "MenuBarShowCodexResetTimes"
        static let showClaudeResetTimes = "MenuBarShowClaudeResetTimes"
        static let showPills = "MenuBarShowPills"
    }

    enum Advanced {
        static let enableGitInspector = "EnableGitInspector"
        static let enableDeepToolOutputSearch = "EnableDeepToolOutputSearch"
        static let enableRecentToolIOIndex = "EnableRecentToolIOIndex"
        static let includeOpenClawDeletedSessions = "OpenClawIncludeDeletedSessions"
        static let hideDockIcon = "HideDockIcon"
    }

    enum Paths {
        static let claudeSessionsRootOverride = "ClaudeSessionsRootOverride"
        static let opencodeSessionsRootOverride = "OpenCodeSessionsRootOverride"
        static let hermesSessionsRootOverride = "HermesSessionsRootOverride"
        static let copilotSessionsRootOverride = "CopilotSessionsRootOverride"
        static let droidSessionsRootOverride = "DroidSessionsRootOverride"
        static let droidProjectsRootOverride = "DroidProjectsRootOverride"
        static let openClawSessionsRootOverride = "OpenClawSessionsRootOverride"
        static let openClawBinaryOverride = "OpenClawBinaryOverride"
        static let cursorSessionsRootOverride = "CursorSessionsRootOverride"
        static let piSessionsRootOverride = "PiSessionsRootOverride"
    }

    enum Archives {
        static let starPinsSessions = "StarPinsSessions"
        static let stopSyncAfterInactivityMinutes = "ArchiveStopSyncAfterInactivityMinutes"
        static let unstarRemovesArchive = "UnstarRemovesLocalArchive"
    }

    enum Diagnostics {
        static let lastSeenCrashID = "DiagnosticsLastSeenCrashID"
        static let seenCrashIDs = "DiagnosticsSeenCrashIDs"
        static let lastSendAt = "DiagnosticsLastSendAt"
        static let lastSendError = "DiagnosticsLastSendError"
    }

    enum Transcript {
        static let preferredIDETarget = "TranscriptPreferredIDETarget"
        static let ideBinaryOverridePath = "TranscriptIDEBinaryOverridePath"
        static let enableReviewCards = "TranscriptEnableReviewCards"
        static let enableCodeDiffLineNumbers = "TranscriptEnableCodeDiffLineNumbers"
        static let enableLinkification = "TranscriptEnableLinkification"
    }

    enum Cockpit {
        static let codexActiveSessionsEnabled = "CockpitCodexActiveSessionsEnabled"
        static let codexActiveRegistryRootOverride = "CockpitCodexActiveRegistryRootOverride"
        static let hudShowAgentNameInCompact = "CockpitHUDShowAgentNameInCompact"
        static let hudCompactBaselineRows = "CockpitHUDCompactBaselineRows"
        static let hudCompactAutoFitEnabled = "CockpitHUDCompactAutoFitEnabled"
        static let showTabSubtitleInFullMode = "CockpitShowTabSubtitleInFullMode"
        static let codexLiveFilterMode = "CockpitCodexLiveFilterMode"
        static let hudOpen = "CockpitHUDOpen"
        static let hudGroupByProject = "CockpitHUDGroupByProject"
        static let hudDisplayMode = "CockpitHUDDisplayMode"
        static let hudCompact = "CockpitHUDCompact"
        static let hudPinned = "CockpitHUDPinned"
        static let hudShowLimits = "CockpitHUDShowLimits"
        static let showProbeSessionsInHUD = "CockpitShowProbeSessionsInHUD"
        static let hudReduceTransparency = "CockpitHUDReduceTransparency"
    }
}

enum SessionViewAutoScrollTarget: String, CaseIterable, Identifiable {
    case lastUserPrompt
    case firstUserPrompt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastUserPrompt:
            return "Last User Prompt"
        case .firstUserPrompt:
            return "First User Prompt"
        }
    }
}

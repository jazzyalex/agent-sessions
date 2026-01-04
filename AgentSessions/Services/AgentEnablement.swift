import Foundation

enum AgentEnablement {
    static let didChangeNotification = Notification.Name("AgentEnablementDidChange")
    private static let cachedBinaryPresence = Locked<[String: Bool]>([:])
    private static let fastBinarySearchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    static func isEnabled(_ source: SessionSource, defaults: UserDefaults = .standard) -> Bool {
        switch source {
        case .codex:
            return defaults.object(forKey: PreferencesKey.Agents.codexEnabled) as? Bool ?? true
        case .claude:
            return defaults.object(forKey: PreferencesKey.Agents.claudeEnabled) as? Bool ?? true
        case .gemini:
            return defaults.object(forKey: PreferencesKey.Agents.geminiEnabled) as? Bool ?? true
        case .opencode:
            return defaults.object(forKey: PreferencesKey.Agents.openCodeEnabled) as? Bool ?? true
        case .copilot:
            return defaults.object(forKey: PreferencesKey.Agents.copilotEnabled) as? Bool ?? true
        case .droid:
            return defaults.object(forKey: PreferencesKey.Agents.droidEnabled) as? Bool ?? true
        }
    }

    static func enabledSources(defaults: UserDefaults = .standard) -> Set<SessionSource> {
        var out: Set<SessionSource> = []
        for s in SessionSource.allCases where isEnabled(s, defaults: defaults) {
            out.insert(s)
        }
        return out
    }

    @discardableResult
    static func setEnabled(_ source: SessionSource, enabled: Bool, defaults: UserDefaults = .standard) -> Bool {
        let wasEnabled = isEnabled(source, defaults: defaults)
        if wasEnabled == enabled { return false }

        if !enabled {
            let enabledNow = enabledSources(defaults: defaults)
            if enabledNow.count <= 1, enabledNow.contains(source) {
                return false
            }
        }

        setEnabledInternal(source, enabled: enabled, defaults: defaults)
        NotificationCenter.default.post(name: didChangeNotification, object: nil, userInfo: ["source": source.rawValue, "enabled": enabled])
        return true
    }

    static func canDisable(_ source: SessionSource, defaults: UserDefaults = .standard) -> Bool {
        if !isEnabled(source, defaults: defaults) { return true }
        let enabledNow = enabledSources(defaults: defaults)
        return enabledNow.count > 1 || !enabledNow.contains(source)
    }

    static func seedIfNeeded(defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: PreferencesKey.Agents.didSeedEnabledAgents) { return }

        // Migration: if the old "show toolbar filter" keys exist, treat them as the initial enabled set.
        let hasLegacyToolbarPrefs =
            defaults.object(forKey: PreferencesKey.Unified.showCodexToolbarFilter) != nil ||
            defaults.object(forKey: PreferencesKey.Unified.showClaudeToolbarFilter) != nil ||
            defaults.object(forKey: PreferencesKey.Unified.showGeminiToolbarFilter) != nil ||
            defaults.object(forKey: PreferencesKey.Unified.showOpenCodeToolbarFilter) != nil

        if hasLegacyToolbarPrefs {
            let codex = defaults.object(forKey: PreferencesKey.Unified.showCodexToolbarFilter) as? Bool ?? true
            let claude = defaults.object(forKey: PreferencesKey.Unified.showClaudeToolbarFilter) as? Bool ?? true
            let gemini = defaults.object(forKey: PreferencesKey.Unified.showGeminiToolbarFilter) as? Bool ?? true
            let opencode = defaults.object(forKey: PreferencesKey.Unified.showOpenCodeToolbarFilter) as? Bool ?? true

            setEnabledInternal(.codex, enabled: codex, defaults: defaults)
            setEnabledInternal(.claude, enabled: claude, defaults: defaults)
            setEnabledInternal(.gemini, enabled: gemini, defaults: defaults)
            setEnabledInternal(.opencode, enabled: opencode, defaults: defaults)
            setEnabledInternal(.copilot, enabled: true, defaults: defaults)
            setEnabledInternal(.droid, enabled: isAvailable(.droid, defaults: defaults), defaults: defaults)
        } else {
            // Cold start: avoid spawning the user's login shell (can be slow with heavy rc files).
            // Prefer filesystem availability checks and fall back to a fast PATH/common-locations probe.
            let codex = isAvailable(.codex, defaults: defaults)
            let claude = isAvailable(.claude, defaults: defaults)
            let gemini = isAvailable(.gemini, defaults: defaults)
            let opencode = isAvailable(.opencode, defaults: defaults)
            let copilot = isAvailable(.copilot, defaults: defaults)
            let droid = isAvailable(.droid, defaults: defaults)

            setEnabledInternal(.codex, enabled: codex, defaults: defaults)
            setEnabledInternal(.claude, enabled: claude, defaults: defaults)
            setEnabledInternal(.gemini, enabled: gemini, defaults: defaults)
            setEnabledInternal(.opencode, enabled: opencode, defaults: defaults)
            setEnabledInternal(.copilot, enabled: copilot, defaults: defaults)
            setEnabledInternal(.droid, enabled: droid, defaults: defaults)
        }

        // Guarantee at least one enabled agent.
        if enabledSources(defaults: defaults).isEmpty {
            setEnabledInternal(.codex, enabled: true, defaults: defaults)
        }

        defaults.set(true, forKey: PreferencesKey.Agents.didSeedEnabledAgents)
    }

    static func isAvailable(_ source: SessionSource, defaults: UserDefaults = .standard) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let root: URL
        switch source {
        case .codex:
            let custom = defaults.string(forKey: "SessionsRootOverride") ?? ""
            root = CodexSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
        case .claude:
            let custom = defaults.string(forKey: "ClaudeSessionsRootOverride") ?? ""
            root = ClaudeSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
        case .gemini:
            let custom = defaults.string(forKey: "GeminiSessionsRootOverride") ?? ""
            root = GeminiSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
        case .opencode:
            let custom = defaults.string(forKey: "OpenCodeSessionsRootOverride") ?? ""
            root = OpenCodeSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
        case .copilot:
            let custom = defaults.string(forKey: PreferencesKey.Paths.copilotSessionsRootOverride) ?? ""
            root = CopilotSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
        case .droid:
            let sessionsCustom = defaults.string(forKey: PreferencesKey.Paths.droidSessionsRootOverride) ?? ""
            let projectsCustom = defaults.string(forKey: PreferencesKey.Paths.droidProjectsRootOverride) ?? ""
            root = DroidSessionDiscovery(customSessionsRoot: sessionsCustom.isEmpty ? nil : sessionsCustom,
                                         customProjectsRoot: projectsCustom.isEmpty ? nil : projectsCustom).sessionsRoot()
        }
        if fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue { return true }
        if source == .droid {
            let sessionsCustom = defaults.string(forKey: PreferencesKey.Paths.droidSessionsRootOverride) ?? ""
            let projectsCustom = defaults.string(forKey: PreferencesKey.Paths.droidProjectsRootOverride) ?? ""
            let disc = DroidSessionDiscovery(customSessionsRoot: sessionsCustom.isEmpty ? nil : sessionsCustom,
                                             customProjectsRoot: projectsCustom.isEmpty ? nil : projectsCustom)
            let projectsRoot = disc.projectsRoot()
            var isProjectsDir: ObjCBool = false
            if fm.fileExists(atPath: projectsRoot.path, isDirectory: &isProjectsDir), isProjectsDir.boolValue { return true }
        }
        return binaryInstalled(for: source)
    }

    static func binaryInstalled(for source: SessionSource) -> Bool {
        switch source {
        case .codex: return binaryDetectedCached("codex")
        case .claude: return binaryDetectedCached("claude")
        case .gemini: return binaryDetectedCached("gemini")
        case .opencode: return binaryDetectedCached("opencode")
        case .copilot: return binaryDetectedCached("copilot")
        case .droid: return binaryDetectedCached("droid")
        }
    }

    private static func setEnabledInternal(_ source: SessionSource, enabled: Bool, defaults: UserDefaults) {
        switch source {
        case .codex:
            defaults.set(enabled, forKey: PreferencesKey.Agents.codexEnabled)
        case .claude:
            defaults.set(enabled, forKey: PreferencesKey.Agents.claudeEnabled)
        case .gemini:
            defaults.set(enabled, forKey: PreferencesKey.Agents.geminiEnabled)
        case .opencode:
            defaults.set(enabled, forKey: PreferencesKey.Agents.openCodeEnabled)
        case .copilot:
            defaults.set(enabled, forKey: PreferencesKey.Agents.copilotEnabled)
        case .droid:
            defaults.set(enabled, forKey: PreferencesKey.Agents.droidEnabled)
        }
    }

    private static func binaryDetectedCached(_ command: String) -> Bool {
        if let v = cachedBinaryPresence.withLock({ $0[command] }) { return v }
        let v = binaryDetected(command)
        cachedBinaryPresence.withLock { $0[command] = v }
        return v
    }

    private static func binaryDetected(_ command: String) -> Bool {
        // Fast path: common install locations (Homebrew + system)
        for dir in fastBinarySearchPaths {
            let path = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(command, isDirectory: false).path
            if FileManager.default.isExecutableFile(atPath: path) { return true }
        }

        // Next: scan current process PATH (no shell spawn).
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            for component in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(component), isDirectory: true)
                    .appendingPathComponent(command, isDirectory: false).path
                if FileManager.default.isExecutableFile(atPath: candidate) { return true }
            }
        }

        // Last resort: /usr/bin/which (still avoids login shell).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

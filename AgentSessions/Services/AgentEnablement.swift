import Foundation

enum AgentEnablement {
    static let didChangeNotification = Notification.Name("AgentEnablementDidChange")
    private static var cachedBinaryPresence: [String: Bool] = [:]

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
        } else {
            let codex = binaryDetectedCached("codex")
            let claude = binaryDetectedCached("claude")
            let gemini = binaryDetectedCached("gemini")
            let opencode = binaryDetectedCached("opencode")

            setEnabledInternal(.codex, enabled: codex, defaults: defaults)
            setEnabledInternal(.claude, enabled: claude, defaults: defaults)
            setEnabledInternal(.gemini, enabled: gemini, defaults: defaults)
            setEnabledInternal(.opencode, enabled: opencode, defaults: defaults)
        }

        // Guarantee at least one enabled agent.
        if enabledSources(defaults: defaults).isEmpty {
            setEnabledInternal(.codex, enabled: true, defaults: defaults)
        }

        defaults.set(true, forKey: PreferencesKey.Agents.didSeedEnabledAgents)
    }

    static func isAvailable(_ source: SessionSource, defaults: UserDefaults = .standard) -> Bool {
        if binaryInstalled(for: source) { return true }

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
        }
        return fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func binaryInstalled(for source: SessionSource) -> Bool {
        switch source {
        case .codex: return binaryDetectedCached("codex")
        case .claude: return binaryDetectedCached("claude")
        case .gemini: return binaryDetectedCached("gemini")
        case .opencode: return binaryDetectedCached("opencode")
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
        }
    }

    private static func binaryDetectedCached(_ command: String) -> Bool {
        if let v = cachedBinaryPresence[command] { return v }
        let v = binaryDetected(command)
        cachedBinaryPresence[command] = v
        return v
    }

    private static func binaryDetected(_ command: String) -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v \(command) >/dev/null 2>&1"]
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

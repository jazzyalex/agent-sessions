import Foundation

enum AgentEnablement {
    static let didChangeNotification = Notification.Name("AgentEnablementDidChange")
    private static let binaryPresenceCacheCapacity: Int = 64
    private static let cachedBinaryPresence = Locked<BinaryPresenceCache>(.init(capacity: binaryPresenceCacheCapacity))

    private static let fallbackBinarySearchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    private static let userLevelBinarySearchPaths: [String] = [
        "~/.local/bin",
        "~/bin",
        "~/Library/pnpm",
        "~/.npm-global/bin"
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

    static func binaryDetectedInPATH(_ binaryName: String, pathOverride: String? = nil) -> Bool {
        let fileManager = FileManager.default
        let expandedBinaryName = expandTilde(binaryName)

        if expandedBinaryName.contains("/") {
            return fileManager.isExecutableFile(atPath: expandedBinaryName)
        }

        let dirs = normalizedPATHDirectories(pathOverride: pathOverride)
        for dir in dirs {
            let candidatePath = URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent(expandedBinaryName, isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: candidatePath) { return true }
        }
        return false
    }

    private static func binaryDetectedCached(_ command: String) -> Bool {
        let signature = effectivePATHSignature(pathOverride: nil)
        let key = "\(command)|\(signature)"

        if let v = cachedBinaryPresence.withLock({ $0.get(key) }) { return v }

        let v = binaryDetectedInPATH(command, pathOverride: nil)
        cachedBinaryPresence.withLock { $0.set(key, value: v) }
        return v
    }

    private static func effectivePATHSignature(pathOverride: String?) -> String {
        if let pathOverride {
            return normalizedPATHDirectories(pathOverride: pathOverride).joined(separator: ":")
        }
        return normalizedPATHDirectories(pathOverride: nil).joined(separator: ":")
    }

    private static func normalizedPATHDirectories(pathOverride: String?) -> [String] {
        var out: [String] = []

        func appendUnique(_ value: String, seen: inout Set<String>) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            let expanded = expandTilde(trimmed)
            if expanded.isEmpty { return }
            var normalized = expanded
            while normalized.count > 1, normalized.hasSuffix("/") {
                normalized.removeLast()
            }
            if normalized.isEmpty { return }
            if seen.contains(normalized) { return }
            seen.insert(normalized)
            out.append(normalized)
        }

        var seen: Set<String> = []

        if let pathOverride, !pathOverride.isEmpty {
            for component in pathOverride.split(separator: ":") {
                appendUnique(String(component), seen: &seen)
            }
            return out
        }

        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            for component in path.split(separator: ":") {
                appendUnique(String(component), seen: &seen)
            }
        }

        for dir in fallbackBinarySearchPaths {
            appendUnique(dir, seen: &seen)
        }

        for dir in userLevelBinarySearchPaths {
            appendUnique(dir, seen: &seen)
        }

        return out
    }

    private static func expandTilde(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + "/" + String(path.dropFirst(2))
        }
        return path
    }
}

private struct BinaryPresenceCache {
    private let capacity: Int
    private var values: [String: Bool] = [:]
    private var lruKeys: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func get(_ key: String) -> Bool? {
        guard let v = values[key] else { return nil }
        touch(key)
        return v
    }

    mutating func set(_ key: String, value: Bool) {
        values[key] = value
        touch(key)
        trimIfNeeded()
    }

    private mutating func touch(_ key: String) {
        if let idx = lruKeys.firstIndex(of: key) {
            lruKeys.remove(at: idx)
        }
        lruKeys.append(key)
    }

    private mutating func trimIfNeeded() {
        guard values.count > capacity else { return }
        while values.count > capacity, let oldest = lruKeys.first {
            lruKeys.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}

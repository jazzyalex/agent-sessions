import Foundation

enum AgentEnablement {
    enum StoredAvailabilityStatus {
        case installed
        case configured
        case unavailable

        var statusText: String {
            switch self {
            case .installed:
                return "Installed"
            case .configured:
                return "Configured"
            case .unavailable:
                return "Not verified"
            }
        }

        var isAvailable: Bool {
            switch self {
            case .installed, .configured:
                return true
            case .unavailable:
                return false
            }
        }
    }

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
        let key = enablementKey(for: source)
        if let explicit = defaults.object(forKey: key) as? Bool { return explicit }
        switch source {
        case .openclaw:
            // Default OFF unless OpenClaw/Clawdbot is actually present on disk or in PATH.
            return isAvailable(.openclaw, defaults: defaults)
        case .cursor:
            return isAvailable(.cursor, defaults: defaults)
        default:
            return true
        }
    }

    static func enablementKey(for source: SessionSource) -> String {
        switch source {
        case .codex:    return PreferencesKey.Agents.codexEnabled
        case .claude:   return PreferencesKey.Agents.claudeEnabled
        case .gemini:   return PreferencesKey.Agents.geminiEnabled
        case .opencode: return PreferencesKey.Agents.openCodeEnabled
        case .copilot:  return PreferencesKey.Agents.copilotEnabled
        case .droid:    return PreferencesKey.Agents.droidEnabled
        case .openclaw: return PreferencesKey.Agents.openClawEnabled
        case .cursor:   return PreferencesKey.Agents.cursorEnabled
        }
    }

    /// Initialises `KnownAvailableProviders` for users upgrading to the first
    /// version that includes the detection-banner feature.  Runs once (when the
    /// key is nil), independent of `seedIfNeeded()`.
    static func migrateKnownAvailableProvidersIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: PreferencesKey.Agents.knownAvailableProviders) == nil else { return }
        let known = SessionSource.allCases
            .filter { defaults.object(forKey: enablementKey(for: $0)) != nil }
            .map(\.rawValue)
        defaults.set(known, forKey: PreferencesKey.Agents.knownAvailableProviders)
    }

    /// Returns providers that are available on disk but the user has not yet
    /// been notified about.  A provider qualifies when it is available, absent
    /// from `KnownAvailableProviders`, and has no explicit UserDefaults
    /// preference (distinguishing "user chose to enable" from "auto-enabled by
    /// isAvailable fallback").
    static func newlyAvailableProviders(
        availableSources: Set<SessionSource>,
        defaults: UserDefaults = .standard
    ) -> [SessionSource] {
        let known = Set(defaults.stringArray(forKey: PreferencesKey.Agents.knownAvailableProviders) ?? [])
        return availableSources
            .filter { source in
                !known.contains(source.rawValue)
                    && defaults.object(forKey: enablementKey(for: source)) == nil
            }
            .sorted { lhs, rhs in
                let allCases = SessionSource.allCases
                let li = allCases.firstIndex(of: lhs) ?? 0
                let ri = allCases.firstIndex(of: rhs) ?? 0
                return li < ri
            }
    }

    /// Adds providers to the known set so their banner is not shown again.
    static func markProvidersAsKnown(_ sources: [SessionSource], defaults: UserDefaults = .standard) {
        var known = Set(defaults.stringArray(forKey: PreferencesKey.Agents.knownAvailableProviders) ?? [])
        for source in sources {
            known.insert(source.rawValue)
        }
        defaults.set(Array(known), forKey: PreferencesKey.Agents.knownAvailableProviders)
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
        guard !AppRuntime.isHostedByTooling else { return }
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
            setEnabledInternal(.openclaw, enabled: isAvailable(.openclaw, defaults: defaults), defaults: defaults)
            setEnabledInternal(.cursor, enabled: isAvailable(.cursor, defaults: defaults), defaults: defaults)
        } else {
            // Cold start: avoid spawning the user's login shell (can be slow with heavy rc files).
            // Prefer filesystem availability checks and fall back to a fast PATH/common-locations probe.
            let codex = isAvailable(.codex, defaults: defaults)
            let claude = isAvailable(.claude, defaults: defaults)
            let gemini = isAvailable(.gemini, defaults: defaults)
            let opencode = isAvailable(.opencode, defaults: defaults)
            let copilot = isAvailable(.copilot, defaults: defaults)
            let droid = isAvailable(.droid, defaults: defaults)
            let openclaw = isAvailable(.openclaw, defaults: defaults)
            let cursor = isAvailable(.cursor, defaults: defaults)

            setEnabledInternal(.codex, enabled: codex, defaults: defaults)
            setEnabledInternal(.claude, enabled: claude, defaults: defaults)
            setEnabledInternal(.gemini, enabled: gemini, defaults: defaults)
            setEnabledInternal(.opencode, enabled: opencode, defaults: defaults)
            setEnabledInternal(.copilot, enabled: copilot, defaults: defaults)
            setEnabledInternal(.droid, enabled: droid, defaults: defaults)
            setEnabledInternal(.openclaw, enabled: openclaw, defaults: defaults)
            setEnabledInternal(.cursor, enabled: cursor, defaults: defaults)
        }

        // Guarantee at least one enabled agent.
        if enabledSources(defaults: defaults).isEmpty {
            setEnabledInternal(.codex, enabled: true, defaults: defaults)
        }

        defaults.set(true, forKey: PreferencesKey.Agents.didSeedEnabledAgents)
    }

    static func isAvailable(_ source: SessionSource, defaults: UserDefaults = .standard) -> Bool {
        if AppRuntime.isHostedByTooling {
            return storedEnabledPreference(for: source, defaults: defaults) ?? false
        }

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
            // Check opencode.db first (v1.2+ SQLite backend)
            if OpenCodeBackendDetector.isSQLiteAvailable(customRoot: custom.isEmpty ? nil : custom) { return true }
            root = OpenCodeSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
        case .copilot:
            let custom = defaults.string(forKey: PreferencesKey.Paths.copilotSessionsRootOverride) ?? ""
            root = CopilotSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
        case .droid:
            let sessionsCustom = defaults.string(forKey: PreferencesKey.Paths.droidSessionsRootOverride) ?? ""
            let projectsCustom = defaults.string(forKey: PreferencesKey.Paths.droidProjectsRootOverride) ?? ""
            root = DroidSessionDiscovery(customSessionsRoot: sessionsCustom.isEmpty ? nil : sessionsCustom,
                                         customProjectsRoot: projectsCustom.isEmpty ? nil : projectsCustom).sessionsRoot()
        case .openclaw:
            let custom = defaults.string(forKey: PreferencesKey.Paths.openClawSessionsRootOverride) ?? ""
            root = OpenClawSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
        case .cursor:
            let custom = defaults.string(forKey: PreferencesKey.Paths.cursorSessionsRootOverride) ?? ""
            let disc = CursorSessionDiscovery(customRoot: custom.isEmpty ? nil : custom)
            root = disc.sessionsRoot()
            // Also check chats root (DB-only sessions live there)
            var isChatsDir: ObjCBool = false
            let chatsRoot = disc.chatsRoot()
            if fm.fileExists(atPath: chatsRoot.path, isDirectory: &isChatsDir), isChatsDir.boolValue { return true }
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

    private static func storedEnabledPreference(for source: SessionSource, defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: enablementKey(for: source)) as? Bool
    }

    static func binaryInstalled(for source: SessionSource) -> Bool {
        if AppRuntime.isHostedByTooling {
            return storedBinaryPresence(for: source) ?? false
        }

        switch source {
        case .codex: return binaryDetectedCached("codex")
        case .claude: return binaryDetectedCached("claude") || binaryDetectedCached("claude-code")
        case .gemini: return binaryDetectedCached("gemini")
        case .opencode: return binaryDetectedCached("opencode")
        case .copilot: return binaryDetectedCached("copilot")
        case .droid: return binaryDetectedCached("droid")
        case .openclaw:
            return binaryDetectedCached("openclaw") || binaryDetectedCached("clawdbot")
        case .cursor:
            return binaryDetectedCached("agent") || binaryDetectedCached("cursor") || binaryDetectedCached("cursor-agent")
        }
    }

    static func storedAvailabilityStatus(for source: SessionSource, defaults: UserDefaults = .standard) -> StoredAvailabilityStatus {
        if storedBinaryPresence(for: source, defaults: defaults) == true {
            return .installed
        }
        if storedEnabledPreference(for: source, defaults: defaults) == true {
            return .configured
        }
        return .unavailable
    }

    /// Live availability status using filesystem probing when running as the real app,
    /// falling back to stored (non-probing) status under build tooling / test hosts.
    static func availabilityStatus(for source: SessionSource, defaults: UserDefaults = .standard) -> StoredAvailabilityStatus {
        if AppRuntime.isHostedByTooling {
            return storedAvailabilityStatus(for: source, defaults: defaults)
        }
        let installed = binaryInstalled(for: source)
        let available = installed || isAvailable(source, defaults: defaults)
        if installed { return .installed }
        if available { return .configured }
        return .unavailable
    }

    private static func setEnabledInternal(_ source: SessionSource, enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: enablementKey(for: source))
    }

    private static func storedBinaryPresence(for source: SessionSource, defaults: UserDefaults = .standard) -> Bool? {
        switch source {
        case .codex:
            return defaults.object(forKey: PreferencesKey.codexCLIAvailable) as? Bool
        case .claude:
            return defaults.object(forKey: PreferencesKey.claudeCLIAvailable) as? Bool
        case .gemini:
            return defaults.object(forKey: PreferencesKey.geminiCLIAvailable) as? Bool
        case .opencode:
            return defaults.object(forKey: PreferencesKey.openCodeCLIAvailable) as? Bool
        case .copilot:
            return defaults.object(forKey: PreferencesKey.copilotCLIAvailable) as? Bool
        case .droid:
            return defaults.object(forKey: PreferencesKey.droidCLIAvailable) as? Bool
        case .openclaw:
            return nil
        case .cursor:
            return defaults.object(forKey: PreferencesKey.cursorCLIAvailable) as? Bool
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

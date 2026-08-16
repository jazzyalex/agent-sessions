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

    /// The production `AvailabilityContext` for the descriptor detection closures.
    ///
    /// Built here rather than through `AvailabilityContext.live()` on purpose: `live()`
    /// forwards `detectBinary` to the *uncached* `binaryDetectedInPATH`, while this type's
    /// own `binaryDetectedCached` is `private` and therefore invisible to it. The cache is
    /// load-bearing — `seedIfNeeded` asks twelve sources for availability on a cold start,
    /// and the memo is what keeps that off repeated PATH sweeps — so the context is composed
    /// in-file where the cached detector is in scope. `detect` stays a parameter so the
    /// `pathOverride` seam (and the tests that use it) can route its own lookup through
    /// unchanged.
    private static func availabilityContext(defaults: UserDefaults,
                                            detect: @escaping (String) -> Bool) -> AvailabilityContext {
        AvailabilityContext(
            defaults: defaults,
            fileProbe: DefaultFileProbe(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            detectBinary: detect
        )
    }

    static func isEnabled(_ source: SessionSource, defaults: UserDefaults = .standard) -> Bool {
        let descriptor = SessionSourceRegistry.descriptor(for: source)
        if let explicit = defaults.object(forKey: descriptor.enablementKey) as? Bool { return explicit }
        switch descriptor.defaultEnabled {
        case .always:
            return true
        case .whenAvailable:
            // e.g. openclaw: default OFF unless OpenClaw/Clawdbot is actually present on
            // disk or in PATH.
            return isAvailable(source, defaults: defaults)
        }
    }

    /// Every per-agent enablement key, derived from `SessionSource.allCases`.
    ///
    /// Observers must use this rather than listing keys by hand: the
    /// hand-written lists drifted every time a provider was added, and a missed
    /// key means toggling that agent silently leaves dependent state stale.
    static var allEnablementKeys: [String] {
        SessionSource.allCases.map { enablementKey(for: $0) }
    }

    static func enablementKey(for source: SessionSource) -> String {
        SessionSourceRegistry.descriptor(for: source).enablementKey
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
            defaults.object(forKey: PreferencesKey.Unified.showAntigravityToolbarFilter) != nil ||
            defaults.object(forKey: PreferencesKey.Unified.showOpenCodeToolbarFilter) != nil

        if hasLegacyToolbarPrefs {
            // Frozen migration history, not a growth surface: only the four agents that
            // existed when enablement was still a toolbar-filter preference are read from
            // the old keys, and copilot's seed was a literal `true` rather than a probe. A
            // source added today inherits the availability rule below and never appears here.
            let legacyToolbarKeys: [SessionSource: String] = [
                .codex: PreferencesKey.Unified.showCodexToolbarFilter,
                .claude: PreferencesKey.Unified.showClaudeToolbarFilter,
                .antigravity: PreferencesKey.Unified.showAntigravityToolbarFilter,
                .opencode: PreferencesKey.Unified.showOpenCodeToolbarFilter
            ]

            for adapter in SessionSourceRegistry.ordered {
                let source = adapter.descriptor.source
                let enabled: Bool
                if let legacyKey = legacyToolbarKeys[source] {
                    enabled = defaults.object(forKey: legacyKey) as? Bool ?? true
                } else if source == .copilot {
                    enabled = true
                } else {
                    enabled = isAvailable(source, defaults: defaults)
                }
                setEnabledInternal(source, enabled: enabled, defaults: defaults)
            }
        } else {
            // Cold start: avoid spawning the user's login shell (can be slow with heavy rc files).
            // Prefer filesystem availability checks and fall back to a fast PATH/common-locations probe.
            //
            // Probed in one pass and written in a second, exactly as the unrolled form did:
            // no availability answer may observe an enablement key this seed just wrote.
            let seeds: [(SessionSource, Bool)] = SessionSourceRegistry.ordered.map { adapter in
                let source = adapter.descriptor.source
                return (source, isAvailable(source, defaults: defaults))
            }
            for (source, enabled) in seeds {
                setEnabledInternal(source, enabled: enabled, defaults: defaults)
            }
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

        // Each descriptor's `isAvailable` is the source's own arm of the switch this
        // replaced: probe the session root(s), then fall back to the binary. The tooling
        // gate above is *not* part of it — that is global harness policy, so it stays here.
        //
        // The binary fallback reads `binaryDetectedCached`, matching the old tail call to
        // `binaryInstalled(for:)`, whose own tooling gate was already unreachable by then.
        let context = availabilityContext(defaults: defaults, detect: binaryDetectedCached)
        return SessionSourceRegistry.descriptor(for: source).isAvailable(context)
    }

    private static func storedEnabledPreference(for source: SessionSource, defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: enablementKey(for: source)) as? Bool
    }

    static func binaryInstalled(for source: SessionSource) -> Bool {
        if AppRuntime.isHostedByTooling {
            return storedBinaryPresence(for: source) ?? false
        }
        return binaryInstalled(for: source, detect: binaryDetectedCached)
    }

    /// PATH-scoped form of `binaryInstalled(for:)`, mirroring the `pathOverride`
    /// seam already on `binaryDetectedInPATH(_:pathOverride:)`.
    ///
    /// A non-empty `pathOverride` replaces the process `PATH` *and* the built-in
    /// fallback search paths (see `normalizedPATHDirectories`), so the lookup
    /// only ever sees directories the caller named. It deliberately skips the
    /// `isHostedByTooling` early return above: that gate turns the no-argument
    /// form into a `UserDefaults` read under XCTest, which would make a caller
    /// that has just staged a binary on disk assert against a stored preference
    /// instead of against the descriptor's name matching. It also skips
    /// `binaryDetectedCached`, since the cache is process-wide and keyed on the
    /// PATH signature.
    ///
    /// Note the `.grok` case still reads the real `~/.grok`; injecting a home
    /// directory is out of scope here, so do not use this form to assert `.grok`
    /// availability hermetically.
    static func binaryInstalled(for source: SessionSource, pathOverride: String) -> Bool {
        binaryInstalled(for: source, detect: { binaryDetectedInPATH($0, pathOverride: pathOverride) })
    }

    /// Which binary names count as which agent — now the descriptors' own
    /// `isBinaryInstalled`. Still the single source of truth for both forms above;
    /// `detect` decides how a name is looked up and is threaded into the context per call
    /// so the `pathOverride` form keeps looking only where its caller said to.
    ///
    /// `.standard` is the right defaults instance here because no `isBinaryInstalled`
    /// closure reads `ctx.defaults` — the switch this replaced took no defaults at all.
    /// `.grok`'s extra `~/.grok` check comes through the context's real home directory and
    /// `DefaultFileProbe`, i.e. the same `FileManager.default` calls it made inline.
    private static func binaryInstalled(for source: SessionSource,
                                        detect: @escaping (String) -> Bool) -> Bool {
        let context = availabilityContext(defaults: .standard, detect: detect)
        return SessionSourceRegistry.descriptor(for: source).isBinaryInstalled(context)
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

    /// K4: openclaw is the one source with no persisted CLI-detection flag, modeled as a
    /// nil `cliAvailableKey` rather than a fabricated key name — so the nil guard *is* its
    /// old `case .openclaw: return nil` arm.
    private static func storedBinaryPresence(for source: SessionSource, defaults: UserDefaults = .standard) -> Bool? {
        guard let key = SessionSourceRegistry.descriptor(for: source).cliAvailableKey else { return nil }
        return defaults.object(forKey: key) as? Bool
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

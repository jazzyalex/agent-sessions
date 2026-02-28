import Foundation
import SwiftUI
import Darwin

enum CodexLiveState: String, Sendable, CaseIterable {
    case activeWorking
    case openIdle

    var isActiveWorking: Bool {
        self == .activeWorking
    }

    fileprivate var priority: Int {
        switch self {
        case .activeWorking: return 2
        case .openIdle: return 1
        }
    }
}

struct CodexActivePresence: Codable, Equatable, Sendable {
    struct Terminal: Codable, Equatable, Sendable {
        var termProgram: String?
        var itermSessionId: String?
        var revealUrl: String?
    }

    var schemaVersion: Int?
    var publisher: String?
    var kind: String?
    var source: SessionSource = .codex

    /// Codex's internal session id (preferred join key).
    var sessionId: String?

    /// Absolute JSONL log path for the session (best-effort join key).
    var sessionLogPath: String?

    /// Best-effort workspace root (cwd / project root).
    var workspaceRoot: String?

    var pid: Int?
    var tty: String?
    var startedAt: Date?
    var lastSeenAt: Date?
    var terminal: Terminal?

    // Local-only metadata (not part of the on-disk schema).
    var sourceFilePath: String? = nil

    var itermSessionGuid: String? {
        CodexActiveSessionsModel.itermSessionGuid(from: terminal?.itermSessionId)
    }

    var revealURL: URL? {
        if let guid = itermSessionGuid, !guid.isEmpty {
            // iTerm2 session `id` (AppleScript) is the GUID. `ITERM_SESSION_ID` is often `w0t0p0:<GUID>`.
            return URL(string: "iterm2:///reveal?sessionid=\(guid)")
        }
        if let raw = terminal?.revealUrl, let url = URL(string: raw) { return url }
        return nil
    }

    func isStale(now: Date, ttl: TimeInterval) -> Bool {
        guard let lastSeenAt else { return true }
        return now.timeIntervalSince(lastSeenAt) > ttl
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case publisher
        case kind
        case source
        case sessionId
        case sessionLogPath
        case workspaceRoot
        case pid
        case tty
        case startedAt
        case lastSeenAt
        case terminal
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        source = try c.decodeIfPresent(SessionSource.self, forKey: .source) ?? .codex
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        sessionLogPath = try c.decodeIfPresent(String.self, forKey: .sessionLogPath)
        workspaceRoot = try c.decodeIfPresent(String.self, forKey: .workspaceRoot)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        tty = try c.decodeIfPresent(String.self, forKey: .tty)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        terminal = try c.decodeIfPresent(Terminal.self, forKey: .terminal)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(publisher, forKey: .publisher)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(sessionLogPath, forKey: .sessionLogPath)
        try c.encodeIfPresent(workspaceRoot, forKey: .workspaceRoot)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(tty, forKey: .tty)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try c.encodeIfPresent(terminal, forKey: .terminal)
    }
}

@MainActor
final class CodexActiveSessionsModel: ObservableObject {
    static let defaultPollInterval: TimeInterval = 2
    static let defaultStaleTTL: TimeInterval = 10
    static let backgroundPollInterval: TimeInterval = 15
    nonisolated private static let processProbeTimeout: TimeInterval = 0.75
    nonisolated private static let processProbeMinIntervalRegistryEmptyForeground: TimeInterval = 6
    nonisolated private static let processProbeMinIntervalRegistryEmptyBackground: TimeInterval = 45
    nonisolated private static let processProbeMinIntervalRegistryPresentForeground: TimeInterval = 30
    nonisolated private static let processProbeMinIntervalRegistryPresentBackground: TimeInterval = 120
    nonisolated(unsafe) private static let normalizedPathCache = NSCache<NSString, NSString>()
#if DEBUG
    nonisolated(unsafe) private static var normalizedPathCacheHitCount: UInt64 = 0
    nonisolated(unsafe) private static var normalizedPathCacheMissCount: UInt64 = 0
    nonisolated private static let normalizedPathCacheMetricsLock = NSLock()
#endif

    /// Changes only when the active membership (or stable presence metadata) changes.
    /// Used by views that want to refresh the sessions list only when active state changes,
    /// not on every heartbeat.
    @Published private(set) var activeMembershipVersion: UInt64 = 0

    @Published private(set) var presences: [CodexActivePresence] = []
    private(set) var lastRefreshAt: Date? = nil

    private var lastPublishedPresenceSignatures: [String: String] = [:]

    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled)
    private var enabled: Bool = true {
        didSet {
            if enabled { startPollingIfNeeded() }
            else { stopPolling(clear: true) }
        }
    }

    @AppStorage(PreferencesKey.Cockpit.codexActiveRegistryRootOverride)
    private var registryRootOverride: String = "" {
        didSet { refreshSoon() }
    }

    private var pollTask: Task<Void, Never>? = nil
    private var refreshTask: Task<Void, Never>? = nil

    private var bySessionID: [String: CodexActivePresence] = [:]
    private var byLogPath: [String: CodexActivePresence] = [:]
    private var liveStateByPresenceKey: [String: CodexLiveState] = [:]
    private var cachedProcessPresences: [CodexActivePresence] = []
    private var lastProcessProbeAt: Date? = nil
    private var unifiedVisibleConsumerIDs: Set<UUID> = []
    private var cockpitVisibleConsumerIDs: Set<UUID> = []
    private var appIsActive: Bool = true

    private struct SessionLookupCacheEntry {
        var source: SessionSource
        var rawFilePath: String
        var normalizedLogPath: String
        var internalSessionIDHint: String?
        var filenameUUID: String?
        var runtimeSessionIDs: [String]
    }
    private var sessionLookupCacheByID: [String: SessionLookupCacheEntry] = [:]
#if DEBUG
    private struct DebugMetrics {
        var refreshCount: UInt64 = 0
        var refreshTotalDurationMs: Double = 0
        var refreshMaxDurationMs: Double = 0
        var processProbeRuns: UInt64 = 0
        var processProbeSkips: UInt64 = 0
        var processProbeRegistryEmptyRuns: UInt64 = 0
        var processProbeRegistryPresentRuns: UInt64 = 0
        var isActiveCalls: UInt64 = 0
    }
    private var debugMetrics = DebugMetrics()
    private var lastDebugMetricsReportAt: Date = .distantPast
#endif

    init() {
        // Avoid background activity under `xcodebuild test`.
        guard !AppRuntime.isRunningTests else { return }
        startPollingIfNeeded()
    }

    deinit {
        pollTask?.cancel()
        refreshTask?.cancel()
    }

    func isActive(_ session: Session) -> Bool {
        guard enabled, supportsLiveSessions(for: session.source) else { return false }
#if DEBUG
        debugMetrics.isActiveCalls &+= 1
#endif
        return liveState(session)?.isActiveWorking == true
    }

    func isLive(_ session: Session) -> Bool {
        guard enabled, supportsLiveSessions(for: session.source) else { return false }
        let lookup = lookupCacheEntry(for: session)
        if byLogPath[Self.logLookupKey(source: lookup.source, normalizedPath: lookup.normalizedLogPath)] != nil { return true }
        if presenceForSessionIDLookup(lookup) != nil { return true }
        return false
    }

    func liveState(_ session: Session) -> CodexLiveState? {
        guard enabled, supportsLiveSessions(for: session.source) else { return nil }
        guard let presence = presence(for: session) else { return nil }
        return liveState(for: presence)
    }

    func liveState(for presence: CodexActivePresence) -> CodexLiveState {
        let key = Self.presenceKey(for: presence)
        if let cached = liveStateByPresenceKey[key] { return cached }
        return Self.heuristicLiveStateFromLogMTime(
            logPath: presence.sessionLogPath,
            sourceFilePath: presence.sourceFilePath,
            now: Date()
        )
    }

    func presence(for session: Session) -> CodexActivePresence? {
        guard supportsLiveSessions(for: session.source) else { return nil }
        let lookup = lookupCacheEntry(for: session)
        if let p = byLogPath[Self.logLookupKey(source: lookup.source, normalizedPath: lookup.normalizedLogPath)] { return p }
        if let p = presenceForSessionIDLookup(lookup) { return p }
        return nil
    }

    func revealURL(for session: Session) -> URL? {
        presence(for: session)?.revealURL
    }

    func supportsLiveSessions(for source: SessionSource) -> Bool {
        Self.supportsLiveSessionSource(source)
    }

    func setUnifiedConsumerVisible(_ visible: Bool, consumerID: UUID) {
        let hadVisibleConsumer = hasVisibleConsumer
        if visible { unifiedVisibleConsumerIDs.insert(consumerID) }
        else { unifiedVisibleConsumerIDs.remove(consumerID) }
        guard hasVisibleConsumer != hadVisibleConsumer else { return }
        refreshSoon()
    }

    func setCockpitConsumerVisible(_ visible: Bool, consumerID: UUID) {
        let hadVisibleConsumer = hasVisibleConsumer
        if visible { cockpitVisibleConsumerIDs.insert(consumerID) }
        else { cockpitVisibleConsumerIDs.remove(consumerID) }
        guard hasVisibleConsumer != hadVisibleConsumer else { return }
        refreshSoon()
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        refreshSoon()
    }

    private var hasVisibleConsumer: Bool {
        !unifiedVisibleConsumerIDs.isEmpty || !cockpitVisibleConsumerIDs.isEmpty
    }

    func refreshNow() {
        // Manual refresh should bypass probe throttling so live state transitions
        // (active -> open and vice versa) are reflected immediately.
        lastProcessProbeAt = nil
        cachedProcessPresences = []
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshOnce()
        }
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard enabled else { return }
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshOnce()
                try? await Task.sleep(nanoseconds: UInt64(self.pollIntervalSeconds() * 1_000_000_000))
            }
        }
    }

    private func stopPolling(clear: Bool) {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        if clear {
            presences = []
            bySessionID = [:]
            byLogPath = [:]
            liveStateByPresenceKey = [:]
            cachedProcessPresences = []
            lastProcessProbeAt = nil
            lastPublishedPresenceSignatures = [:]
            // Preserve visible-consumer registrations across disable/enable toggles so
            // open windows immediately restore foreground cadence without requiring re-appear.
            sessionLookupCacheByID = [:]
            lastRefreshAt = nil
            activeMembershipVersion &+= 1
        }
    }

    private func refreshSoon() {
        // Coalesce rapid preference edits.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.refreshOnce()
        }
    }

    private func refreshOnce() async {
        guard enabled else { return }

        let now = Date()
#if DEBUG
        let refreshStartedAt = Date()
#endif
        let ttl = Self.defaultStaleTTL
        let rootPaths = registryRoots().map(\.path)
        let codexSessionRoots = codexSessionsRoots().map(\.path)
        let claudeSessionRoots = claudeSessionsRoots().map(\.path)
        let previousLogKeys = Set(byLogPath.keys)
        let previousSessionKeys = Set(bySessionID.keys)
        let previousLiveStates = liveStateByPresenceKey
        let lastProbeAt = lastProcessProbeAt
        let cachedProbeSnapshot = cachedProcessPresences
        let hasVisibleConsumerSnapshot = hasVisibleConsumer
        let appIsActiveSnapshot = appIsActive

        let probeResult: (loaded: [CodexActivePresence], didProbe: Bool, registryHadPresences: Bool) = await Task.detached(priority: .utility) {
            var out: [CodexActivePresence] = []
            let decoder = Self.makeDecoder()
            for path in rootPaths {
                out.append(contentsOf: Self.filterSupportedPresences(
                    Self.loadPresences(from: URL(fileURLWithPath: path), decoder: decoder, now: now, ttl: ttl)
                ))
            }
            let registryHasPresences = !out.isEmpty
            let processProbeMinInterval = Self.processProbeMinIntervalSeconds(
                registryHasPresences: registryHasPresences,
                hasVisibleConsumer: hasVisibleConsumerSnapshot,
                appIsActive: appIsActiveSnapshot
            )
            let shouldProbeProcesses: Bool = {
                guard let last = lastProbeAt else { return true }
                return now.timeIntervalSince(last) >= processProbeMinInterval
            }()
            if shouldProbeProcesses {
                // Periodic fallback probe keeps mixed registry/non-registry environments complete.
                out.append(contentsOf: Self.discoverPresencesFromRunningProcesses(
                    source: .codex,
                    processName: "codex",
                    now: now,
                    sessionsRoots: codexSessionRoots,
                    timeout: Self.processProbeTimeout
                ))
                out.append(contentsOf: Self.discoverPresencesFromRunningProcesses(
                    source: .claude,
                    processName: "claude",
                    now: now,
                    sessionsRoots: claudeSessionRoots,
                    timeout: Self.processProbeTimeout
                ))
                out.append(contentsOf: Self.discoverPresencesFromRunningCommands(
                    source: .claude,
                    commandNeedles: ["claude", "claude-code"],
                    now: now,
                    sessionsRoots: claudeSessionRoots,
                    timeout: Self.processProbeTimeout
                ))
            } else {
                // Reuse recent probe findings between probe intervals.
                out.append(contentsOf: Self.filterSupportedPresences(
                    cachedProbeSnapshot.filter { !$0.isStale(now: now, ttl: ttl) }
                ))
            }
            if hasVisibleConsumerSnapshot {
                out.append(contentsOf: Self.discoverPresencesFromITermSessions(source: .codex, now: now, timeout: Self.processProbeTimeout))
                out.append(contentsOf: Self.discoverPresencesFromITermSessions(source: .claude, now: now, timeout: Self.processProbeTimeout))
            }
            return (out, shouldProbeProcesses, registryHasPresences)
        }.value
        let latestProcessProbe = Self.filterSupportedPresences(
            probeResult.loaded.filter { $0.publisher == "agent-sessions-process" }
        )
        let loaded = Self.coalescePresencesByTTY(
            Self.filterSupportedPresences(probeResult.loaded)
        )

        if probeResult.didProbe {
            cachedProcessPresences = latestProcessProbe
            lastProcessProbeAt = now
        } else {
            cachedProcessPresences = cachedProcessPresences.filter { !$0.isStale(now: now, ttl: ttl) }
        }

        // Deduplicate and merge: keep freshest lastSeenAt, but preserve metadata from any source.
        var sessionMap: [String: CodexActivePresence] = [:]
        var logMap: [String: CodexActivePresence] = [:]
        var fallbackMap: [String: CodexActivePresence] = [:]
        for p in loaded {
            var keyed = false
            if let id = p.sessionId, !id.isEmpty {
                let key = Self.sessionLookupKey(source: p.source, sessionId: id)
                sessionMap[key] = Self.merge(sessionMap[key], p)
                keyed = true
            }
            if let log = p.sessionLogPath, !log.isEmpty {
                let norm = Self.normalizePath(log)
                let key = Self.logLookupKey(source: p.source, normalizedPath: norm)
                logMap[key] = Self.merge(logMap[key], p)
                keyed = true
            }
            if !keyed {
                let key = Self.presenceKey(for: p)
                if key != "unknown" {
                    fallbackMap[key] = Self.merge(fallbackMap[key], p)
                }
            }
        }

        // Use log-path map + session-id map for lookup, but keep a stable list for UI.
        var ui: [CodexActivePresence] = Array(logMap.values)
        for p in sessionMap.values {
            if let log = p.sessionLogPath, !log.isEmpty {
                let key = Self.logLookupKey(source: p.source, normalizedPath: Self.normalizePath(log))
                if logMap[key] != nil { continue }
            }
            ui.append(p)
        }
        ui = Self.reconcileFallbackPresences(Array(fallbackMap.values), into: ui)

        let nextLiveStates = await Task.detached(priority: .utility) {
            Self.classifyLiveStates(
                for: ui,
                now: now,
                probeITerm: hasVisibleConsumerSnapshot,
                timeout: Self.processProbeTimeout
            )
        }.value

        // Always keep lookup maps current, but avoid publishing UI changes on every heartbeat.
        bySessionID = sessionMap
        byLogPath = logMap
        liveStateByPresenceKey = nextLiveStates
        lastRefreshAt = now

        let nextLogKeys = Set(logMap.keys)
        let nextSessionKeys = Set(sessionMap.keys)
        let membershipChanged = (nextLogKeys != previousLogKeys) || (nextSessionKeys != previousSessionKeys)
        let liveStateChanged = nextLiveStates != previousLiveStates

        // Ignore lastSeenAt-only churn; only publish when stable fields that affect UI change.
        let nextSignatures = Self.stablePresenceSignatures(for: ui)
        let metadataChanged = nextSignatures != lastPublishedPresenceSignatures

        if membershipChanged || metadataChanged || liveStateChanged {
            presences = ui.sorted(by: { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) })
            lastPublishedPresenceSignatures = nextSignatures
            activeMembershipVersion &+= 1
        }
#if DEBUG
        let refreshDurationMs = Date().timeIntervalSince(refreshStartedAt) * 1000.0
        debugMetrics.refreshCount &+= 1
        debugMetrics.refreshTotalDurationMs += refreshDurationMs
        debugMetrics.refreshMaxDurationMs = max(debugMetrics.refreshMaxDurationMs, refreshDurationMs)
        if probeResult.didProbe {
            debugMetrics.processProbeRuns &+= 1
            if probeResult.registryHadPresences {
                debugMetrics.processProbeRegistryPresentRuns &+= 1
            } else {
                debugMetrics.processProbeRegistryEmptyRuns &+= 1
            }
        } else {
            debugMetrics.processProbeSkips &+= 1
        }
        if refreshDurationMs > 25 {
            print("[CodexActiveSessionsModel][perf] refreshOnce took \(String(format: "%.1f", refreshDurationMs))ms didProbe=\(probeResult.didProbe) registryHadPresences=\(probeResult.registryHadPresences) loaded=\(loaded.count)")
        }
        maybeReportDebugMetrics(now: now)
#endif
    }

    // MARK: - Registry Root Discovery

    private func registryRoots() -> [URL] {
        var candidates: [URL] = []

        if let override = Self.parsePath(registryRootOverride) {
            candidates.append(override)
        }

        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], let envURL = Self.parsePath(env) {
            candidates.append(envURL.appendingPathComponent("active"))
        }

        if let sessionsOverride = UserDefaults.standard.string(forKey: "SessionsRootOverride"),
           let sessionsURL = Self.parsePath(sessionsOverride) {
            candidates.append(sessionsURL.deletingLastPathComponent().appendingPathComponent("active"))
        }

        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/active"))

        // Dedup by normalized path.
        var out: [URL] = []
        var seen: Set<String> = []
        for u in candidates {
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(u) }
        }
        return out
    }

    private func codexSessionsRoots() -> [URL] {
        var candidates: [URL] = []

        if let sessionsOverride = UserDefaults.standard.string(forKey: "SessionsRootOverride"),
           let sessionsURL = Self.parsePath(sessionsOverride) {
            candidates.append(sessionsURL)
        }

        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], let envURL = Self.parsePath(env) {
            candidates.append(envURL.appendingPathComponent("sessions"))
        }

        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))

        // Dedup by normalized path.
        return dedupRoots(candidates)
    }

    private func claudeSessionsRoots() -> [URL] {
        let defaults = UserDefaults.standard
        let override = defaults.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride)
            ?? defaults.string(forKey: "ClaudeSessionsRootOverride")
            ?? ""
        let discovery = ClaudeSessionDiscovery(customRoot: override.isEmpty ? nil : override)
        return dedupRoots([discovery.sessionsRoot()])
    }

    private func dedupRoots(_ candidates: [URL]) -> [URL] {
        var out: [URL] = []
        var seen: Set<String> = []
        for u in candidates {
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(u) }
        }
        return out
    }

    nonisolated private static func supportsLiveSessionSource(_ source: SessionSource) -> Bool {
        switch source {
        case .codex, .claude:
            return true
        default:
            return false
        }
    }

    nonisolated private static func filterSupportedPresences(_ presences: [CodexActivePresence]) -> [CodexActivePresence] {
        presences.filter { supportsLiveSessionSource($0.source) }
    }

    // MARK: - Loading

    nonisolated static func loadPresences(from root: URL,
                                          decoder: JSONDecoder,
                                          now: Date,
                                          ttl: TimeInterval) -> [CodexActivePresence] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var out: [CodexActivePresence] = []
        for url in items where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard var p = try? decoder.decode(CodexActivePresence.self, from: data) else { continue }
            p.sourceFilePath = url.path
            if p.isStale(now: now, ttl: ttl) { continue }
            out.append(p)
        }
        return out
    }

    // MARK: - Helpers

    private static func merge(_ existing: CodexActivePresence?, _ incoming: CodexActivePresence) -> CodexActivePresence {
        guard let existing else { return incoming }

        let ta = existing.lastSeenAt ?? .distantPast
        let tb = incoming.lastSeenAt ?? .distantPast
        let winner = tb >= ta ? incoming : existing
        let loser = tb >= ta ? existing : incoming

        var merged = winner

        func prefer(_ a: String?, _ b: String?) -> String? {
            if let a, !a.isEmpty { return a }
            if let b, !b.isEmpty { return b }
            return nil
        }

        merged.publisher = prefer(merged.publisher, loser.publisher)
        merged.kind = prefer(merged.kind, loser.kind)
        merged.source = winner.source
        merged.sessionId = prefer(merged.sessionId, loser.sessionId)
        merged.sessionLogPath = prefer(merged.sessionLogPath, loser.sessionLogPath)
        merged.workspaceRoot = prefer(merged.workspaceRoot, loser.workspaceRoot)
        merged.pid = merged.pid ?? loser.pid
        merged.tty = prefer(merged.tty, loser.tty)
        merged.startedAt = merged.startedAt ?? loser.startedAt
        merged.lastSeenAt = max(ta, tb)
        merged.sourceFilePath = prefer(merged.sourceFilePath, loser.sourceFilePath)

        if merged.terminal == nil { merged.terminal = loser.terminal }
        if var t = merged.terminal {
            let other = loser.terminal
            t.termProgram = prefer(t.termProgram, other?.termProgram)
            t.itermSessionId = prefer(t.itermSessionId, other?.itermSessionId)
            t.revealUrl = prefer(t.revealUrl, other?.revealUrl)
            merged.terminal = t
        }

        return merged
    }

    private static func parsePath(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    nonisolated private static func normalizedTTY(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/dev/") { return trimmed }
        if trimmed.hasPrefix("dev/") { return "/" + trimmed }
        return "/dev/\(trimmed)"
    }

    static func coalescePresencesByTTY(_ presences: [CodexActivePresence]) -> [CodexActivePresence] {
        var byTTYIdentity: [String: CodexActivePresence] = [:]
        var withoutTTY: [CodexActivePresence] = []
        withoutTTY.reserveCapacity(presences.count)

        for presence in presences {
            guard let tty = normalizedTTY(presence.tty) else {
                withoutTTY.append(presence)
                continue
            }
            var normalized = presence
            normalized.tty = tty
            let identity = coalesceIdentity(for: normalized)
            let key = "\(tty)|\(identity)"
            byTTYIdentity[key] = merge(byTTYIdentity[key], normalized)
        }

        var out = Array(byTTYIdentity.values)
        out.append(contentsOf: withoutTTY)
        return out
    }

    nonisolated private static func coalesceIdentity(for presence: CodexActivePresence) -> String {
        if let sid = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sid.isEmpty {
            return sessionLookupKey(source: presence.source, sessionId: sid)
        }
        if let log = presence.sessionLogPath, !log.isEmpty {
            let normalized = normalizePath(log)
            if !normalized.isEmpty { return logLookupKey(source: presence.source, normalizedPath: normalized) }
        }
        if let src = presence.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !src.isEmpty {
            let normalized = normalizePath(src)
            if !normalized.isEmpty { return "\(presence.source.rawValue)|src:\(normalized)" }
        }
        if let pid = presence.pid {
            return "\(presence.source.rawValue)|pid:\(pid)"
        }
        return "\(presence.source.rawValue)|tty-only"
    }

    static func reconcileFallbackPresences(_ fallbackPresences: [CodexActivePresence],
                                           into baseUI: [CodexActivePresence]) -> [CodexActivePresence] {
        var ui = baseUI
        var ttyIndex: [String: Int] = [:]
        ttyIndex.reserveCapacity(ui.count)

        for (idx, presence) in ui.enumerated() {
            if let tty = normalizedTTY(presence.tty) {
                let key = "\(presence.source.rawValue)|\(tty)"
                if ttyIndex[key] == nil {
                    ttyIndex[key] = idx
                }
            }
        }

        for fallback in fallbackPresences {
            if shouldMergeTTYOnlyITermFallback(fallback),
               let tty = normalizedTTY(fallback.tty),
               let idx = ttyIndex["\(fallback.source.rawValue)|\(tty)"] {
                ui[idx] = merge(ui[idx], fallback)
                continue
            }

            let newIndex = ui.count
            ui.append(fallback)
            if let tty = normalizedTTY(fallback.tty),
               ttyIndex["\(fallback.source.rawValue)|\(tty)"] == nil {
                ttyIndex["\(fallback.source.rawValue)|\(tty)"] = newIndex
            }
        }

        return ui
    }

    nonisolated private static func shouldMergeTTYOnlyITermFallback(_ presence: CodexActivePresence) -> Bool {
        guard (presence.publisher ?? "") == "agent-sessions-iterm" else { return false }
        guard normalizedTTY(presence.tty) != nil else { return false }

        if let sid = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
            return false
        }
        if let log = presence.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines), !log.isEmpty {
            return false
        }
        if let src = presence.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty {
            return false
        }
        if presence.pid != nil {
            return false
        }
        return true
    }

    nonisolated static func presenceKey(for presence: CodexActivePresence) -> String {
        if let log = presence.sessionLogPath, !log.isEmpty {
            let normalized = normalizePath(log)
            if !normalized.isEmpty { return logLookupKey(source: presence.source, normalizedPath: normalized) }
        }
        if let sid = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sid.isEmpty { return sessionLookupKey(source: presence.source, sessionId: sid) }
        if let src = presence.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !src.isEmpty { return "\(presence.source.rawValue)|src:\(src)" }
        if let pid = presence.pid { return "\(presence.source.rawValue)|pid:\(pid)" }
        if let tty = normalizedTTY(presence.tty) { return "\(presence.source.rawValue)|tty:\(tty)" }
        return "unknown"
    }

    nonisolated static func logLookupKey(source: SessionSource, normalizedPath: String) -> String {
        "\(source.rawValue)|log:\(normalizedPath)"
    }

    nonisolated static func sessionLookupKey(source: SessionSource, sessionId: String) -> String {
        "\(source.rawValue)|sid:\(sessionId)"
    }

    nonisolated static func liveSessionIDCandidates(for session: Session) -> [String] {
        func cleaned(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var out: [String] = []
        out.reserveCapacity(3)

        func appendUnique(_ raw: String?) {
            guard let value = cleaned(raw), !out.contains(value) else { return }
            out.append(value)
        }

        switch session.source {
        case .codex:
            appendUnique(session.codexInternalSessionIDHint)
            appendUnique(session.codexFilenameUUID)
        case .claude:
            appendUnique(session.codexInternalSessionIDHint)
            appendUnique(extractSessionID(fromLogPath: session.filePath, source: .claude))
        case .opencode:
            appendUnique(session.id)
            appendUnique(extractSessionID(fromLogPath: session.filePath, source: .opencode))
        default:
            appendUnique(session.id)
        }

        return out
    }

    nonisolated static func normalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let key = trimmed as NSString
        if let cached = normalizedPathCache.object(forKey: key) {
#if DEBUG
            recordNormalizedPathCacheLookup(hit: true)
#endif
            return cached as String
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        // Preserve symlink-aware canonicalization so registry/session paths join even when roots differ
        // (for example /var/... vs /private/var/...).
        let normalized = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL.path
        normalizedPathCache.setObject(normalized as NSString, forKey: key)
#if DEBUG
        recordNormalizedPathCacheLookup(hit: false)
#endif
        return normalized
    }

    private func lookupCacheEntry(for session: Session) -> SessionLookupCacheEntry {
        let internalSessionIDHint = Self.nonEmptySessionID(session.codexInternalSessionIDHint)
        let runtimeSessionIDs = Self.liveSessionIDCandidates(for: session)
        if let cached = sessionLookupCacheByID[session.id],
           cached.source == session.source,
           cached.rawFilePath == session.filePath,
           cached.internalSessionIDHint == internalSessionIDHint,
           cached.runtimeSessionIDs == runtimeSessionIDs {
            return cached
        }
        let fresh = SessionLookupCacheEntry(
            source: session.source,
            rawFilePath: session.filePath,
            normalizedLogPath: Self.normalizePath(session.filePath),
            internalSessionIDHint: internalSessionIDHint,
            filenameUUID: session.codexFilenameUUID,
            runtimeSessionIDs: runtimeSessionIDs
        )
        sessionLookupCacheByID[session.id] = fresh
        return fresh
    }

    private static func nonEmptySessionID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func presenceForSessionIDLookup(_ lookup: SessionLookupCacheEntry) -> CodexActivePresence? {
        for id in lookup.runtimeSessionIDs {
            if let p = bySessionID[Self.sessionLookupKey(source: lookup.source, sessionId: id)] {
                return p
            }
        }
        return nil
    }

    private func pollIntervalSeconds() -> TimeInterval {
        guard appIsActive else { return Self.backgroundPollInterval }
        return hasVisibleConsumer ? Self.defaultPollInterval : Self.backgroundPollInterval
    }

    nonisolated private static func processProbeMinIntervalSeconds(registryHasPresences: Bool,
                                                                   hasVisibleConsumer: Bool,
                                                                   appIsActive: Bool) -> TimeInterval {
        // Keep process probes warm while a UI consumer is on screen, even if app is backgrounded.
        if hasVisibleConsumer {
            return Self.processProbeMinIntervalRegistryEmptyForeground
        }
        if registryHasPresences {
            return appIsActive
                ? Self.processProbeMinIntervalRegistryPresentForeground
                : Self.processProbeMinIntervalRegistryPresentBackground
        }
        if appIsActive { return Self.processProbeMinIntervalRegistryEmptyBackground }
        return Self.processProbeMinIntervalRegistryEmptyBackground
    }

#if DEBUG
    nonisolated private static func recordNormalizedPathCacheLookup(hit: Bool) {
        normalizedPathCacheMetricsLock.lock()
        if hit {
            normalizedPathCacheHitCount &+= 1
        } else {
            normalizedPathCacheMissCount &+= 1
        }
        normalizedPathCacheMetricsLock.unlock()
    }

    nonisolated private static func drainNormalizedPathCacheLookupCounts() -> (hits: UInt64, misses: UInt64) {
        normalizedPathCacheMetricsLock.lock()
        let hits = normalizedPathCacheHitCount
        let misses = normalizedPathCacheMissCount
        normalizedPathCacheHitCount = 0
        normalizedPathCacheMissCount = 0
        normalizedPathCacheMetricsLock.unlock()
        return (hits, misses)
    }

    private func maybeReportDebugMetrics(now: Date) {
        let reportInterval: TimeInterval = 10
        guard now.timeIntervalSince(lastDebugMetricsReportAt) >= reportInterval else { return }
        guard debugMetrics.refreshCount > 0 else { return }

        let averageRefreshMs = debugMetrics.refreshTotalDurationMs / Double(debugMetrics.refreshCount)
        let cache = Self.drainNormalizedPathCacheLookupCounts()
        print(
            "[CodexActiveSessionsModel][perf] " +
            "refresh count=\(debugMetrics.refreshCount) avgMs=\(String(format: "%.1f", averageRefreshMs)) maxMs=\(String(format: "%.1f", debugMetrics.refreshMaxDurationMs)) " +
            "probe runs=\(debugMetrics.processProbeRuns) skips=\(debugMetrics.processProbeSkips) " +
            "probeRegistryEmptyRuns=\(debugMetrics.processProbeRegistryEmptyRuns) probeRegistryPresentRuns=\(debugMetrics.processProbeRegistryPresentRuns) " +
            "isActiveCalls=\(debugMetrics.isActiveCalls) normalizePathCache hits=\(cache.hits) misses=\(cache.misses)"
        )

        debugMetrics = DebugMetrics()
        lastDebugMetricsReportAt = now
    }
#endif

    nonisolated static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let dt = LenientISO8601.parse(raw) { return dt }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 timestamp: \(raw)")
        }
        return d
    }

    nonisolated private static func stablePresenceSignatures(for presences: [CodexActivePresence]) -> [String: String] {
        // Key by normalized log path when available, else by session id / source path / pid.
        // Excludes lastSeenAt so heartbeats do not trigger UI churn.
        var out: [String: String] = [:]
        out.reserveCapacity(presences.count)
        for p in presences {
            let normalizedLogPath: String? = {
                guard let log = p.sessionLogPath, !log.isEmpty else { return nil }
                return normalizePath(log)
            }()
            let key: String = {
                if let v = normalizedLogPath, !v.isEmpty { return logLookupKey(source: p.source, normalizedPath: v) }
                if let id = p.sessionId, !id.isEmpty { return sessionLookupKey(source: p.source, sessionId: id) }
                if let src = p.sourceFilePath, !src.isEmpty { return "\(p.source.rawValue)|src:\(src)" }
                if let pid = p.pid { return "\(p.source.rawValue)|pid:\(pid)" }
                if let tty = p.tty, !tty.isEmpty { return "\(p.source.rawValue)|tty:\(tty)" }
                return "unknown"
            }()

            var parts: [String] = []
            parts.reserveCapacity(13)
            parts.append(p.publisher ?? "")
            parts.append(p.kind ?? "")
            parts.append(p.source.rawValue)
            parts.append(p.sessionId ?? "")
            parts.append(normalizedLogPath ?? "")
            parts.append(p.workspaceRoot ?? "")
            parts.append(p.pid.map(String.init) ?? "")
            parts.append(p.tty ?? "")
            parts.append(p.startedAt.map { String($0.timeIntervalSince1970) } ?? "")
            parts.append(p.terminal?.termProgram ?? "")
            parts.append(p.terminal?.itermSessionId ?? "")
            parts.append(p.terminal?.revealUrl ?? "")
            parts.append(p.sourceFilePath ?? "")

            out[key] = parts.joined(separator: "|")
        }
        return out
    }

    // MARK: - iTerm2 Focus

    /// iTerm2's AppleScript session id is the GUID portion; env vars are often `w0t0p0:<GUID>`.
    nonisolated static func itermSessionGuid(from raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let idx = trimmed.lastIndex(of: ":") {
            let next = trimmed.index(after: idx)
            let tail = trimmed[next...].trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? nil : String(tail)
        }
        return trimmed
    }

    nonisolated static func canAttemptITerm2Focus(itermSessionId: String?, tty: String?, termProgram _: String?) -> Bool {
        if let guid = itermSessionGuid(from: itermSessionId), !guid.isEmpty { return true }
        guard let tty = tty?.trimmingCharacters(in: .whitespacesAndNewlines), !tty.isEmpty else { return false }
        // A concrete TTY is enough to attempt iTerm lookup by session tty, even when
        // TERM_PROGRAM is proxied (for example, tmux/screen inside iTerm).
        return true
    }

    nonisolated static func canAttemptITerm2TailProbe(itermSessionId: String?, tty: String?, termProgram _: String?) -> Bool {
        if let guid = itermSessionGuid(from: itermSessionId), !guid.isEmpty { return true }
        guard let tty = tty?.trimmingCharacters(in: .whitespacesAndNewlines), !tty.isEmpty else { return false }
        return true
    }

    /// Best-effort focus for iTerm2 sessions that works across windows/tabs (and usually Spaces).
    /// Returns `true` if iTerm2 reported the target session was selected.
    nonisolated static func tryFocusITerm2(itermSessionId: String?, tty: String?) -> Bool {
        let guid = itermSessionGuid(from: itermSessionId) ?? ""
        let ttyValue = (tty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTTY = ttyValue.isEmpty ? "" : ttyValue

        guard !guid.isEmpty || !targetTTY.isEmpty else { return false }

        let scriptLines = [
            "on run argv",
            "set targetGuid to \"\"",
            "set targetTTY to \"\"",
            "if (count of argv) >= 1 then set targetGuid to item 1 of argv",
            "if (count of argv) >= 2 then set targetTTY to item 2 of argv",
            "set targetTTYBase to targetTTY",
            "if targetTTYBase starts with \"/dev/\" then set targetTTYBase to text 6 thru -1 of targetTTYBase",
            "tell application \"iTerm2\"",
            "activate",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sttyBase to stty",
            "if sttyBase starts with \"/dev/\" then set sttyBase to text 6 thru -1 of sttyBase",
            "if ((targetGuid is not \"\" and sid is targetGuid) or (targetTTYBase is not \"\" and (stty is targetTTY or stty is targetTTYBase or sttyBase is targetTTYBase))) then",
            "try",
            "select w",
            "end try",
            "try",
            "select t",
            "end try",
            "select s",
            "return \"ok\"",
            "end if",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "return \"not found\"",
            "end run"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = scriptLines.flatMap { ["-e", $0] } + [guid, targetTTY]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else {
            return false
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out == "ok"
    }

    // MARK: - Live State Classification

    nonisolated static func classifyITermTail(_ tail: String) -> CodexLiveState? {
        let normalized = sanitizeITermTail(tail)
        guard !normalized.isEmpty else { return nil }
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        let recentWindow = nonEmptyLines.suffix(8)
        let recentLower = recentWindow.joined(separator: "\n").lowercased()
        let lastNonEmptyLine = recentWindow.last ?? ""
        let lastLower = lastNonEmptyLine.lowercased()

        // Evaluate only the near-bottom transcript window to avoid stale history causing false-active sessions.
        let busyMarkers = [
            "• working",
            "• waiting",
            "• running",
            "working for ",
            "waiting for background terminal",
            "background terminal running",
            "esc to interrupt",
            "re-connecting",
            "reconnecting"
        ]
        if busyMarkers.contains(where: { recentLower.contains($0) || lastLower.contains($0) }) {
            return .activeWorking
        }

        let isPromptLine = (lastNonEmptyLine == "›" || lastNonEmptyLine.hasPrefix("› "))
        if isPromptLine {
            return .openIdle
        }

        // If no busy marker is present, treat the session as open/idle by default.
        if !lastNonEmptyLine.isEmpty {
            return .openIdle
        }
        return .openIdle
    }

    // Internal for targeted unit tests.
    nonisolated static func classifyGenericITermTail(_ tail: String) -> CodexLiveState? {
        let normalized = sanitizeITermTail(tail)
        guard !normalized.isEmpty else { return nil }

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return nil }

        let recentWindow = nonEmptyLines.suffix(12)
        let lastNonEmptyLine = recentWindow.last ?? ""
        let recentBottomLower = recentWindow.suffix(4).joined(separator: "\n").lowercased()
        let lastTwoLower = recentWindow.suffix(2).joined(separator: "\n").lowercased()

        let strongBusyMarkers = [
            "esc to interrupt",
            "re-connecting",
            "reconnecting"
        ]
        if strongBusyMarkers.contains(where: { recentBottomLower.contains($0) }) {
            return .activeWorking
        }

        // Prompt at the bottom clears weak/historical busy text once strong
        // live markers are absent in the near-bottom transcript window.
        if isLikelyPromptLine(lastNonEmptyLine) {
            return .openIdle
        }

        // Weaker lexical markers are matched only near the bottom to reduce
        // stale-history false-active stickiness.
        let weakBusyMarkers = [
            "working",
            "running",
            "thinking",
            "processing",
            "generating",
            "applying",
            "analyzing"
        ]
        if weakBusyMarkers.contains(where: { lastTwoLower.contains($0) }) {
            return .activeWorking
        }

        // Ambiguous generic terminal output (no explicit busy marker, no clear prompt):
        // defer to log mtime heuristic instead of forcing active.
        return nil
    }

    // Internal for targeted unit tests.
    nonisolated static func classifyClaudeITermTail(_ tail: String) -> CodexLiveState? {
        let normalized = sanitizeITermTail(tail)
        guard !normalized.isEmpty else { return nil }

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return nil }

        let recentWindow = nonEmptyLines.suffix(16)
        let lastNonEmptyLine = recentWindow.last ?? ""
        let recentBottomLower = recentWindow.suffix(6).joined(separator: "\n").lowercased()

        let strongBusyMarkers = [
            "esc to interrupt",
            "re-connecting",
            "reconnecting"
        ]
        if strongBusyMarkers.contains(where: { recentBottomLower.contains($0) }) {
            return .activeWorking
        }

        if isLikelyClaudePromptLine(lastNonEmptyLine) {
            return .openIdle
        }

        // Weaker lexical markers are matched near the bottom only, and only when
        // prompt detection has already failed.
        let weakBusyMarkers = [
            "working",
            "running",
            "thinking",
            "processing",
            "generating",
            "applying",
            "analyzing"
        ]
        if weakBusyMarkers.contains(where: { recentBottomLower.contains($0) }) {
            return .activeWorking
        }

        // Ambiguous Claude output should defer to probe metadata (is processing/prompt)
        // and then log mtime fallback.
        return nil
    }

    nonisolated private static func isLikelyPromptLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if ["›", ">", "$", "#", "%", "❯", "λ"].contains(trimmed) { return true }
        if let range = trimmed.range(of: #".*[\$#%]$"#, options: .regularExpression),
           range.lowerBound == trimmed.startIndex,
           range.upperBound == trimmed.endIndex {
            return true
        }
        return false
    }

    nonisolated private static func isLikelyClaudePromptLine(_ line: String) -> Bool {
        let promptWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}"))
        let trimmed = line.trimmingCharacters(in: promptWhitespace)
        guard !trimmed.isEmpty else { return false }
        if ["›", ">", "$", "#", "%", "❯", "λ"].contains(trimmed) { return true }
        if trimmed.hasPrefix("❯") || trimmed.hasPrefix("›") {
            let remainder = String(trimmed.dropFirst()).trimmingCharacters(in: promptWhitespace)
            if remainder.isEmpty { return true }
            if remainder.hasPrefix("(") { return true }
        }
        if let last = trimmed.last, last == "$" || last == "#" || last == "%" {
            let body = trimmed.dropLast()
            // Prompt-like tails are typically "… <prompt-char>" (for example "user@host %").
            // This avoids treating status percentages like "78%" as prompt lines.
            if body.last?.isWhitespace == true { return true }
        }
        if let range = trimmed.range(of: #".*[\$#]$"#, options: .regularExpression),
           range.lowerBound == trimmed.startIndex,
           range.upperBound == trimmed.endIndex {
            return true
        }
        return false
    }

    nonisolated private static func sanitizeITermTail(_ tail: String) -> String {
        let text = tail.replacingOccurrences(of: "\r", with: "")
        var out = ""
        out.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\u{001B}" {
                let next = text.index(after: i)
                guard next < text.endIndex else { break }
                let control = text[next]

                // CSI: ESC [ ... final-byte
                if control == "[" {
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex {
                        let scalar = text[cursor].unicodeScalars.first?.value ?? 0
                        if (0x40...0x7E).contains(scalar) {
                            cursor = text.index(after: cursor)
                            break
                        }
                        cursor = text.index(after: cursor)
                    }
                    i = cursor
                    continue
                }

                // OSC: ESC ] ... BEL or ESC \
                if control == "]" {
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex {
                        let current = text[cursor]
                        if current == "\u{0007}" {
                            cursor = text.index(after: cursor)
                            break
                        }
                        if current == "\u{001B}" {
                            let oscNext = text.index(after: cursor)
                            if oscNext < text.endIndex, text[oscNext] == "\\" {
                                cursor = text.index(after: oscNext)
                                break
                            }
                        }
                        cursor = text.index(after: cursor)
                    }
                    i = cursor
                    continue
                }

                // Drop unknown escape sequence introducer.
                i = next
                continue
            }

            out.append(ch)
            i = text.index(after: i)
        }
        return out
    }

    // Internal for targeted unit tests.
    nonisolated static func resolveClaudeStateFromITermProbe(isProcessing: Bool?,
                                                             isAtShellPrompt: Bool?,
                                                             tail: String?) -> CodexLiveState? {
        if isProcessing == true { return .activeWorking }
        if isAtShellPrompt == true { return .openIdle }
        guard let tail else { return nil }
        if let classified = classifyClaudeITermTail(tail) { return classified }
        if hasLikelyClaudePromptNearBottom(tail) { return .openIdle }
        // When iTerm probe metadata is inconclusive (common under tmux wrappers),
        // treat non-prompt tails as active to avoid false-open for long-running output.
        return .activeWorking
    }

    nonisolated private static func hasLikelyClaudePromptNearBottom(_ tail: String) -> Bool {
        let normalized = sanitizeITermTail(tail)
        guard !normalized.isEmpty else { return false }
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return false }
        let recentWindow = nonEmptyLines.suffix(8)
        return recentWindow.contains(where: { isLikelyClaudePromptLine($0) })
    }

    nonisolated private static func modificationDateForPath(_ rawPath: String?) -> Date? {
        guard let rawPath, !rawPath.isEmpty else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return mtime
    }

    nonisolated static func heuristicLiveStateFromLogMTime(logPath: String?,
                                                           sourceFilePath: String? = nil,
                                                           now: Date,
                                                           activeWriteWindow: TimeInterval = 2.5) -> CodexLiveState {
        // Prefer true session log writes when available; source file mtime is a
        // secondary fallback only for providers that omit sessionLogPath.
        let mtime = modificationDateForPath(logPath) ?? modificationDateForPath(sourceFilePath)
        guard let mtime else { return .openIdle }
        if now.timeIntervalSince(mtime) <= activeWriteWindow {
            return .activeWorking
        }
        return .openIdle
    }

    nonisolated private static func classifyLiveStates(for presences: [CodexActivePresence],
                                                       now: Date,
                                                       probeITerm: Bool,
                                                       timeout: TimeInterval) -> [String: CodexLiveState] {
        var out: [String: CodexLiveState] = [:]
        out.reserveCapacity(presences.count)

        for presence in presences {
            let key = presenceKey(for: presence)
            guard key != "unknown" else { continue }

            var state: CodexLiveState?
            let canProbeITerm = probeITerm && canAttemptITerm2TailProbe(
                itermSessionId: presence.terminal?.itermSessionId,
                tty: presence.tty,
                termProgram: presence.terminal?.termProgram
            )
            if canProbeITerm, presence.source == .codex {
                if let tail = captureITermTail(
                    itermSessionId: presence.terminal?.itermSessionId,
                    tty: presence.tty,
                    timeout: timeout
                ) {
                    state = classifyITermTail(tail)
                } else {
                    // When a session is known to exist in iTerm but tail capture fails transiently,
                    // prefer open/idle over mtime heuristics to avoid false-active spikes.
                    state = .openIdle
                }
            } else if canProbeITerm, presence.source == .claude {
                if let probe = captureITermProbeResult(
                    itermSessionId: presence.terminal?.itermSessionId,
                    tty: presence.tty,
                    timeout: timeout
                ) {
                    state = resolveClaudeStateFromITermProbe(
                        isProcessing: probe.isProcessing,
                        isAtShellPrompt: probe.isAtShellPrompt,
                        tail: probe.tail
                    )
                }
            }

            let heuristic = heuristicLiveStateFromLogMTime(
                logPath: presence.sessionLogPath,
                sourceFilePath: presence.sourceFilePath,
                now: now,
                activeWriteWindow: activeWriteWindow(for: presence.source)
            )
            let resolved = state ?? heuristic
            if let existing = out[key] {
                if resolved.priority > existing.priority {
                    out[key] = resolved
                }
            } else {
                out[key] = resolved
            }
        }

        return out
    }

    nonisolated private static func activeWriteWindow(for source: SessionSource) -> TimeInterval {
        switch source {
        case .codex:
            return 2.5
        case .claude:
            return 15.0
        default:
            return 2.5
        }
    }

    nonisolated private static func captureITermTail(itermSessionId: String?,
                                                     tty: String?,
                                                     timeout: TimeInterval) -> String? {
        let guid = itermSessionGuid(from: itermSessionId) ?? ""
        let ttyValue = (tty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTTY = ttyValue.isEmpty ? "" : ttyValue
        guard !guid.isEmpty || !targetTTY.isEmpty else { return nil }

        let scriptLines = [
            "on run argv",
            "set targetGuid to \"\"",
            "set targetTTY to \"\"",
            "if (count of argv) >= 1 then set targetGuid to item 1 of argv",
            "if (count of argv) >= 2 then set targetTTY to item 2 of argv",
            "set targetTTYBase to targetTTY",
            "if targetTTYBase starts with \"/dev/\" then set targetTTYBase to text 6 thru -1 of targetTTYBase",
            "tell application \"iTerm2\"",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sttyBase to stty",
            "if sttyBase starts with \"/dev/\" then set sttyBase to text 6 thru -1 of sttyBase",
            "if ((targetGuid is not \"\" and sid is targetGuid) or (targetTTYBase is not \"\" and (stty is targetTTY or stty is targetTTYBase or sttyBase is targetTTYBase))) then",
            "set txt to \"\"",
            "try",
            "set txt to contents of s",
            "on error",
            "set txt to \"\"",
            "end try",
            "set txtLen to length of txt",
            "if txtLen > 4000 then",
            "set txt to text (txtLen - 3999) thru txtLen of txt",
            "end if",
            "return txt",
            "end if",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "return \"\"",
            "end run"
        ]

        guard let out = runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: scriptLines.flatMap { ["-e", $0] } + [guid, targetTTY],
            timeout: timeout
        ) else {
            return nil
        }
        return String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ITermProbeResult {
        let tail: String?
        let isProcessing: Bool?
        let isAtShellPrompt: Bool?
    }

    nonisolated private static func captureITermProbeResult(itermSessionId: String?,
                                                            tty: String?,
                                                            timeout: TimeInterval) -> ITermProbeResult? {
        let guid = itermSessionGuid(from: itermSessionId) ?? ""
        let ttyValue = (tty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTTY = ttyValue.isEmpty ? "" : ttyValue
        guard !guid.isEmpty || !targetTTY.isEmpty else { return nil }

        let scriptLines = [
            "on run argv",
            "set targetGuid to \"\"",
            "set targetTTY to \"\"",
            "if (count of argv) >= 1 then set targetGuid to item 1 of argv",
            "if (count of argv) >= 2 then set targetTTY to item 2 of argv",
            "set targetTTYBase to targetTTY",
            "if targetTTYBase starts with \"/dev/\" then set targetTTYBase to text 6 thru -1 of targetTTYBase",
            "tell application \"iTerm2\"",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sttyBase to stty",
            "if sttyBase starts with \"/dev/\" then set sttyBase to text 6 thru -1 of sttyBase",
            "if ((targetGuid is not \"\" and sid is targetGuid) or (targetTTYBase is not \"\" and (stty is targetTTY or stty is targetTTYBase or sttyBase is targetTTYBase))) then",
            "set txt to \"\"",
            "try",
            "set txt to contents of s",
            "on error",
            "set txt to \"\"",
            "end try",
            "set txtLen to length of txt",
            "if txtLen > 4000 then",
            "set txt to text (txtLen - 3999) thru txtLen of txt",
            "end if",
            "set processing to false",
            "try",
            "set processing to is processing of s",
            "on error",
            "set processing to false",
            "end try",
            "set atPrompt to false",
            "try",
            "set atPrompt to is at shell prompt of s",
            "on error",
            "set atPrompt to false",
            "end try",
            "set sep to (ASCII character 9)",
            "set metadata to ((processing as string) & sep & (atPrompt as string))",
            "return metadata & linefeed & txt",
            "end if",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "return \"\"",
            "end run"
        ]

        guard let out = runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: scriptLines.flatMap { ["-e", $0] } + [guid, targetTTY],
            timeout: timeout
        ) else {
            return nil
        }

        let raw = String(decoding: out, as: UTF8.self)
        let normalized = raw.replacingOccurrences(of: "\r", with: "")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var lines = normalized.components(separatedBy: "\n")
        let metadata = lines.isEmpty ? "" : lines.removeFirst()
        let (isProcessing, isAtShellPrompt) = parseITermProbeMetadata(metadata)
        let tail = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return ITermProbeResult(
            tail: tail.isEmpty ? nil : tail,
            isProcessing: isProcessing,
            isAtShellPrompt: isAtShellPrompt
        )
    }

    // Internal for targeted unit tests.
    nonisolated static func parseITermProbeMetadata(_ metadata: String) -> (isProcessing: Bool?, isAtShellPrompt: Bool?) {
        let trimmed = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        let normalized = trimmed.replacingOccurrences(of: "tab", with: "\t")
        let parts = normalized.components(separatedBy: "\t")
        let isProcessing = parseAppleScriptBool(parts.first)
        let isAtShellPrompt = parseAppleScriptBool(parts.count > 1 ? parts[1] : nil)
        return (isProcessing, isAtShellPrompt)
    }

    nonisolated private static func parseAppleScriptBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "true" { return true }
        if lower == "false" { return false }
        return nil
    }

    // MARK: - Live Session Discovery (Fallback)

    nonisolated static func discoverPresencesFromITermSessions(source: SessionSource,
                                                               now: Date,
                                                               timeout: TimeInterval) -> [CodexActivePresence] {
        let scriptLines = [
            "set outRows to {}",
            "set sep to (ASCII character 9)",
            "tell application \"iTerm2\"",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sname to name of s",
            "set end of outRows to (sid & sep & stty & sep & sname)",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "set AppleScript's text item delimiters to linefeed",
            "return outRows as text"
        ]
        guard let out = runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: scriptLines.flatMap { ["-e", $0] },
            timeout: timeout
        ) else {
            return []
        }
        let raw = String(decoding: out, as: UTF8.self)
        let sessions = parseITermSessionListOutput(raw)
        guard !sessions.isEmpty else { return [] }

        var presences: [CodexActivePresence] = []
        presences.reserveCapacity(sessions.count)
        for session in sessions where isLikelyITermSessionName(session.name, source: source) {
            var p = CodexActivePresence()
            p.schemaVersion = 1
            p.publisher = "agent-sessions-iterm"
            p.kind = "interactive"
            p.source = source
            p.tty = normalizedTTY(session.tty)
            p.startedAt = nil
            p.lastSeenAt = now
            var t = CodexActivePresence.Terminal()
            t.termProgram = "iTerm2"
            t.itermSessionId = session.sessionID
            p.terminal = t
            presences.append(p)
        }
        return presences
    }

    // Live-process scan complements iTerm discovery by attaching PID/cwd/log metadata.
    nonisolated static func discoverPresencesFromRunningProcesses(source: SessionSource,
                                                                  processName: String,
                                                                  now: Date,
                                                                  sessionsRoots: [String],
                                                                  timeout: TimeInterval) -> [CodexActivePresence] {
        let user = NSUserName()
        return discoverPresencesFromLsofQuery(
            source: source,
            queryArguments: ["-w", "-a", "-c", processName, "-u", user, "-nP", "-F", "pftn"],
            now: now,
            sessionsRoots: sessionsRoots,
            timeout: timeout
        )
    }

    // Fallback for CLIs whose live executable name may not be stable for `lsof -c`.
    // We match terminal-backed commands from `ps`, then hydrate metadata via `lsof -p`.
    nonisolated static func discoverPresencesFromRunningCommands(source: SessionSource,
                                                                 commandNeedles: [String],
                                                                 now: Date,
                                                                 sessionsRoots: [String],
                                                                 timeout: TimeInterval) -> [CodexActivePresence] {
        let psPath = "/bin/ps"
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: psPath) else { return [] }
        guard let psOut = runCommand(
            executable: URL(fileURLWithPath: psPath),
            arguments: ["axww", "-o", "pid=,tty=,command="],
            timeout: timeout
        ) else {
            return []
        }
        let psText = String(decoding: psOut, as: UTF8.self)
        let infos = parsePSCommandListOutput(psText)
        let pids = infos
            .filter { info in
                guard info.tty != nil else { return false }
                return commandContainsNeedle(info.command, needles: commandNeedles)
            }
            .map(\.pid)
        guard !pids.isEmpty else { return [] }

        let user = NSUserName()
        let pidCSV = Array(Set(pids)).sorted().map(String.init).joined(separator: ",")
        return discoverPresencesFromLsofQuery(
            source: source,
            queryArguments: ["-w", "-a", "-p", pidCSV, "-u", user, "-nP", "-F", "pftn"],
            now: now,
            sessionsRoots: sessionsRoots,
            timeout: timeout
        )
    }

    nonisolated private static func discoverPresencesFromLsofQuery(source: SessionSource,
                                                                   queryArguments: [String],
                                                                   now: Date,
                                                                   sessionsRoots: [String],
                                                                   timeout: TimeInterval) -> [CodexActivePresence] {
        let lsofPath = "/usr/sbin/lsof"
        let psPath = "/bin/ps"
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: lsofPath), fm.isExecutableFile(atPath: psPath) else { return [] }

        let roots = sessionsRoots.map(normalizePath)
        guard let lsofOut = runCommand(
            executable: URL(fileURLWithPath: lsofPath),
            arguments: queryArguments,
            timeout: timeout
        ) else {
            return []
        }

        let lsofText = String(decoding: lsofOut, as: UTF8.self)
        var infos = parseLsofMachineOutput(lsofText, sessionsRoots: roots, source: source)
        if infos.isEmpty { return [] }

        // Enrich with iTerm session ids via `ps eww -p ...` (env vars).
        let pidCSV = infos.keys.sorted().map(String.init).joined(separator: ",")
        if let psOut = runCommand(
            executable: URL(fileURLWithPath: psPath),
            arguments: ["eww", "-p", pidCSV],
            timeout: timeout
        ) {
            let psText = String(decoding: psOut, as: UTF8.self)
            let env = parsePSEnvironmentOutput(psText)
            for (pid, meta) in env {
                if infos[pid] != nil {
                    infos[pid]?.termProgram = meta.termProgram
                    infos[pid]?.itermSessionId = meta.itermSessionId
                }
            }
        }

        var out: [CodexActivePresence] = []
        out.reserveCapacity(infos.count)
        for info in infos.values {
            var p = CodexActivePresence()
            p.schemaVersion = 1
            p.publisher = "agent-sessions-process"
            p.kind = "interactive"
            p.source = source
            p.sessionId = info.sessionID
            p.sessionLogPath = info.sessionLogPath
            p.workspaceRoot = info.cwd
            p.pid = info.pid
            p.tty = normalizedTTY(info.tty)
            p.startedAt = nil
            p.lastSeenAt = now
            var t = CodexActivePresence.Terminal()
            t.termProgram = info.termProgram
            t.itermSessionId = info.itermSessionId
            // Don't precompute revealUrl; CodexActivePresence will synthesize from itermSessionId.
            p.terminal = t
            out.append(p)
        }
        return out
    }

    /// Compatibility wrapper for existing call sites/tests.
    nonisolated static func discoverPresencesFromRunningCodexProcesses(now: Date,
                                                                       sessionsRoots: [String],
                                                                       timeout: TimeInterval) -> [CodexActivePresence] {
        discoverPresencesFromRunningProcesses(
            source: .codex,
            processName: "codex",
            now: now,
            sessionsRoots: sessionsRoots,
            timeout: timeout
        )
    }

    // MARK: - Command Runner

    struct PSProcessEnvMeta: Equatable, Sendable {
        var termProgram: String?
        var itermSessionId: String?
    }

    struct PSCommandInfo: Equatable, Sendable {
        var pid: Int
        var tty: String?
        var command: String
    }

    struct LsofPIDInfo: Equatable, Sendable {
        var pid: Int
        var cwd: String?
        var tty: String?
        var sessionID: String?
        var sessionLogPath: String?
        var termProgram: String?
        var itermSessionId: String?
    }

    struct ITermSessionInfo: Equatable, Sendable {
        var sessionID: String
        var tty: String?
        var name: String
    }

    /// Run a local command with a small timeout. Returns stdout on success.
    nonisolated private static func runCommand(executable: URL, arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout in the background; `readDataToEndOfFile` blocks until the process closes stdout.
        var outData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            // If SIGTERM doesn't work quickly, force-kill.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = group.wait(timeout: .now() + 0.25)
            return nil
        }

        // Allow non-zero exit codes; `lsof` can return 1 when no matches.
        return outData
    }

    // MARK: - Parsers (Testable)

    nonisolated static func parseITermSessionListOutput(_ text: String) -> [ITermSessionInfo] {
        var out: [ITermSessionInfo] = []
        out.reserveCapacity(16)

        func parseLine(_ line: String, separator: String) -> ITermSessionInfo? {
            guard let first = line.range(of: separator) else { return nil }
            let afterFirst = first.upperBound
            guard let second = line[afterFirst...].range(of: separator) else { return nil }

            let sid = String(line[..<first.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sid.isEmpty else { return nil }
            let ttyRaw = String(line[afterFirst..<second.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(line[second.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ITermSessionInfo(
                sessionID: sid,
                tty: ttyRaw.isEmpty ? nil : ttyRaw,
                name: name
            )
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if let parsed = parseLine(line, separator: "\t") ?? parseLine(line, separator: "tab") {
                out.append(parsed)
            }
        }

        return out
    }

    nonisolated static func isLikelyCodexITermSessionName(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return false }
        if name == "codex" { return true }
        if name.contains("(codex)") { return true }
        if name.hasPrefix("codex ") || name.hasSuffix(" codex") { return true }
        return false
    }

    nonisolated static func isLikelyClaudeITermSessionName(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return false }
        if name == "claude" { return true }
        if name.contains("(claude)") { return true }
        if name.hasPrefix("claude ") || name.hasSuffix(" claude") { return true }
        if name.contains("claude code") { return true }
        return false
    }

    nonisolated static func isLikelyOpenCodeITermSessionName(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return false }
        if name == "opencode" { return true }
        if name.contains("(opencode)") { return true }
        if name.hasPrefix("opencode ") || name.hasSuffix(" opencode") { return true }
        return false
    }

    nonisolated static func isLikelyITermSessionName(_ rawName: String, source: SessionSource) -> Bool {
        switch source {
        case .codex:
            return isLikelyCodexITermSessionName(rawName)
        case .claude:
            return isLikelyClaudeITermSessionName(rawName)
        case .opencode:
            return isLikelyOpenCodeITermSessionName(rawName)
        default:
            return false
        }
    }

    nonisolated static func parseLsofMachineOutput(_ text: String, sessionsRoots: [String]) -> [Int: LsofPIDInfo] {
        parseLsofMachineOutput(text, sessionsRoots: sessionsRoots, source: .codex)
    }

    nonisolated static func parseLsofMachineOutput(_ text: String, sessionsRoots: [String], source: SessionSource) -> [Int: LsofPIDInfo] {
        var infos: [Int: LsofPIDInfo] = [:]

        var currentPID: Int? = nil
        var currentFD: String? = nil
        var currentType: String? = nil

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = rawLine.first else { continue }
            let value = rawLine.dropFirst()

            switch tag {
            case "p":
                if let pid = Int(value) {
                    currentPID = pid
                    infos[pid, default: LsofPIDInfo(pid: pid)].pid = pid
                } else {
                    currentPID = nil
                }
                currentFD = nil
                currentType = nil

            case "f":
                currentFD = String(value)

            case "t":
                currentType = String(value)

            case "n":
                guard let pid = currentPID else { continue }
                let name = String(value)
                var info = infos[pid] ?? LsofPIDInfo(pid: pid)

                // `cwd` record
                if currentFD == "cwd", currentType == "DIR" {
                    info.cwd = name
                    infos[pid] = info
                    continue
                }

                // Heuristic: tty device appears on stdio fd 0/1/2 (often reported as 0u/1w/2r), type CHR.
                let isStdioFD: Bool = {
                    guard let fd = currentFD else { return false }
                    let leadingDigits = fd.prefix { $0.isNumber }
                    guard !leadingDigits.isEmpty, let value = Int(leadingDigits) else { return false }
                    return (0...2).contains(value)
                }()
                if info.tty == nil,
                   isStdioFD,
                   currentType == "CHR" {
                    if let ttyName = normalizedTTY(name),
                       (ttyName.hasPrefix("/dev/ttys") || ttyName.hasPrefix("/dev/pts/")) {
                        info.tty = ttyName
                        infos[pid] = info
                        continue
                    }
                    infos[pid] = info
                    continue
                }

                // Session log path: prefer Codex rollout JSONL under configured sessions roots.
                if matchesSessionLogPath(name, source: source, sessionsRoots: sessionsRoots) {
                    // Prefer a writable fd if present (e.g., 26w).
                    let isWrite = (currentFD?.contains("w") ?? false)
                    if info.sessionLogPath == nil || isWrite {
                        info.sessionLogPath = name
                        info.sessionID = extractSessionID(fromLogPath: name, source: source)
                    }
                    infos[pid] = info
                }

            default:
                continue
            }
        }

        // Keep only entries that look like a live terminal session.
        // Some open Codex sessions have not opened a rollout JSONL yet; keep tty-only rows.
        return infos.filter { _, v in
            v.tty != nil && (v.sessionLogPath != nil || v.cwd != nil)
        }
    }

    nonisolated private static func matchesSessionLogPath(_ path: String,
                                                          source: SessionSource,
                                                          sessionsRoots: [String]) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let fileName = (path as NSString).lastPathComponent.lowercased()
        let normalizedPath = normalizePath(path)
        guard !normalizedPath.isEmpty else { return false }
        let underRoot = sessionsRoots.contains(where: { root in
            let normalizedRoot = normalizePath(root)
            guard !normalizedRoot.isEmpty else { return false }
            let rootPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : (normalizedRoot + "/")
            return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(rootPrefix)
        })
        guard underRoot else { return false }

        switch source {
        case .codex:
            return ext == "jsonl" && fileName.hasPrefix("rollout-")
        case .claude:
            if !(ext == "jsonl" || ext == "ndjson") { return false }
            if fileName == "history.jsonl" { return false }
            return true
        case .opencode:
            return ext == "json" && fileName.hasPrefix("ses_")
        default:
            return false
        }
    }

    nonisolated private static func extractSessionID(fromLogPath path: String, source: SessionSource) -> String? {
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        switch source {
        case .claude:
            // Claude session files are typically <UUID>.jsonl under ~/.claude/projects/<project>/.
            // Keep it strict so arbitrary filenames are not treated as session ids.
            if UUID(uuidString: base) != nil { return base }
            return nil
        case .opencode:
            if base.hasPrefix("ses_") {
                return String(base.dropFirst("ses_".count))
            }
            return nil
        default:
            return nil
        }
    }

    nonisolated static func parsePSEnvironmentOutput(_ text: String) -> [Int: PSProcessEnvMeta] {
        var out: [Int: PSProcessEnvMeta] = [:]
        for (idx, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            // Skip header
            if idx == 0, line.contains("PID") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first, let pid = Int(first) else { continue }

            let raw = String(line)
            func extract(_ key: String) -> String? {
                guard let r = raw.range(of: key + "=") else { return nil }
                let after = raw[r.upperBound...]
                return after.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            }

            let iterm = extract("ITERM_SESSION_ID") ?? extract("TERM_SESSION_ID")
            let termProgram = extract("TERM_PROGRAM")
            if iterm == nil && termProgram == nil { continue }
            out[pid] = PSProcessEnvMeta(termProgram: termProgram, itermSessionId: iterm)
        }
        return out
    }

    nonisolated static func parsePSCommandListOutput(_ text: String) -> [PSCommandInfo] {
        var out: [PSCommandInfo] = []
        out.reserveCapacity(24)

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int(fields[0]) else { continue }

            let ttyRaw = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tty = ttyRaw == "??" || ttyRaw.isEmpty ? nil : ttyRaw
            let command = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }

            out.append(PSCommandInfo(pid: pid, tty: tty, command: command))
        }

        return out
    }

    nonisolated static func commandContainsNeedle(_ command: String, needles: [String]) -> Bool {
        let normalizedNeedles = Set(
            needles
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !normalizedNeedles.isEmpty else { return false }

        let tokens = splitCommandTokens(command)
        guard !tokens.isEmpty else { return false }

        for candidate in executableNeedleCandidates(from: tokens, depth: 0) {
            if normalizedNeedles.contains(candidate) { return true }
        }
        return false
    }

    nonisolated private static func executableNeedleCandidates(from tokens: [String], depth: Int) -> [String] {
        guard !tokens.isEmpty, depth < 2 else { return [] }
        var index = 0

        while index < tokens.count, isEnvironmentAssignmentToken(tokens[index]) {
            index += 1
        }

        if index < tokens.count, commandBasename(tokens[index]) == "env" {
            index += 1
            while index < tokens.count {
                let token = tokens[index]
                if token.hasPrefix("-") {
                    index += 1
                    continue
                }
                if isEnvironmentAssignmentToken(token) {
                    index += 1
                    continue
                }
                break
            }
        }

        guard index < tokens.count else { return [] }
        let executable = commandBasename(tokens[index])
        guard !executable.isEmpty else { return [] }

        var out: [String] = [executable]
        out.reserveCapacity(3)

        if shellExecutables.contains(executable),
           let commandString = shellCommandString(from: tokens, startAt: index + 1) {
            let nested = splitCommandTokens(commandString)
            out.append(contentsOf: executableNeedleCandidates(from: nested, depth: depth + 1))
            return out
        }

        if wrapperExecutables.contains(executable),
           let wrapped = firstWrappedExecutableToken(from: tokens, startAt: index + 1, wrapperExecutable: executable) {
            out.append(commandBasename(wrapped))
        }
        return out
    }

    nonisolated private static func splitCommandTokens(_ command: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(8)
        var current = ""
        current.reserveCapacity(command.count)
        var quote: Character?
        var escaping = false

        for ch in command {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }

            if ch == "\\" && quote != "'" {
                escaping = true
                continue
            }

            if let currentQuote = quote {
                if ch == currentQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }

            if ch == " " || ch == "\t" {
                self.appendToken(current, into: &out)
                current.removeAll(keepingCapacity: true)
                continue
            }
            current.append(ch)
        }

        if escaping { current.append("\\") }
        self.appendToken(current, into: &out)
        return out
    }

    nonisolated private static func appendToken(_ token: String, into out: inout [String]) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        out.append(trimmed)
    }

    nonisolated private static func commandBasename(_ token: String) -> String {
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !stripped.isEmpty else { return "" }
        return URL(fileURLWithPath: stripped).lastPathComponent.lowercased()
    }

    nonisolated private static func isEnvironmentAssignmentToken(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let key = token[..<eq]
        guard !key.isEmpty else { return false }
        guard key.first == "_" || (key.first?.isLetter ?? false) else { return false }
        return key.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    nonisolated private static func firstWrappedExecutableToken(from tokens: [String],
                                                                startAt start: Int,
                                                                wrapperExecutable: String) -> String? {
        guard start < tokens.count else { return nil }
        var idx = start
        var canSkipWrapperSubcommand = true
        let skipSubcommands = wrapperSubcommandSkips[wrapperExecutable] ?? []
        while idx < tokens.count {
            let token = tokens[idx]
            if token.hasPrefix("-") {
                idx += 1
                continue
            }
            if isEnvironmentAssignmentToken(token) {
                idx += 1
                continue
            }
            if canSkipWrapperSubcommand, skipSubcommands.contains(commandBasename(token)) {
                canSkipWrapperSubcommand = false
                idx += 1
                continue
            }
            canSkipWrapperSubcommand = false
            return token
        }
        return nil
    }

    nonisolated private static func shellCommandString(from tokens: [String], startAt start: Int) -> String? {
        guard start < tokens.count else { return nil }
        var idx = start
        while idx < tokens.count {
            let token = tokens[idx]
            if token == "-c" || token == "-lc" || token == "-ic" || token == "-lxc" || token == "-xc" {
                let next = idx + 1
                return next < tokens.count ? tokens[next] : nil
            }
            idx += 1
        }
        return nil
    }

    nonisolated private static let shellExecutables: Set<String> = [
        "bash", "sh", "zsh", "fish", "ksh", "dash", "tcsh"
    ]

    nonisolated private static let wrapperExecutables: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl", "npx", "pnpm", "npm", "yarn", "yarnpkg", "uv", "uvx", "tsx"
    ]

    nonisolated private static let wrapperSubcommandSkips: [String: Set<String>] = [
        "pnpm": ["dlx", "exec"],
        "npm": ["exec", "x"],
        "yarn": ["dlx", "exec"],
        "yarnpkg": ["dlx", "exec"]
    ]
}

private enum LenientISO8601 {
    private static let lock = NSLock()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let d = fractional.date(from: s) { return d }
        return plain.date(from: s)
    }
}

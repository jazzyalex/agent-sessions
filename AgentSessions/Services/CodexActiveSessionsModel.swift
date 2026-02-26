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
        var rawFilePath: String
        var normalizedLogPath: String
        var internalSessionIDHint: String?
        var filenameUUID: String?
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
        guard enabled, session.source == .codex else { return false }
#if DEBUG
        debugMetrics.isActiveCalls &+= 1
#endif
        return liveState(session)?.isActiveWorking == true
    }

    func isLive(_ session: Session) -> Bool {
        guard enabled, session.source == .codex else { return false }
        let lookup = lookupCacheEntry(for: session)
        if byLogPath[lookup.normalizedLogPath] != nil { return true }
        if presenceForSessionIDLookup(lookup) != nil { return true }
        return false
    }

    func liveState(_ session: Session) -> CodexLiveState? {
        guard enabled, session.source == .codex else { return nil }
        guard let presence = presence(for: session) else { return nil }
        return liveState(for: presence)
    }

    func liveState(for presence: CodexActivePresence) -> CodexLiveState {
        let key = Self.presenceKey(for: presence)
        if let cached = liveStateByPresenceKey[key] { return cached }
        return Self.heuristicLiveStateFromLogMTime(logPath: presence.sessionLogPath, now: Date())
    }

    func presence(for session: Session) -> CodexActivePresence? {
        guard session.source == .codex else { return nil }
        let lookup = lookupCacheEntry(for: session)
        if let p = byLogPath[lookup.normalizedLogPath] { return p }
        if let p = presenceForSessionIDLookup(lookup) { return p }
        return nil
    }

    func revealURL(for session: Session) -> URL? {
        presence(for: session)?.revealURL
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
        let sessionsRoots = codexSessionsRoots().map(\.path)
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
                out.append(contentsOf: Self.loadPresences(from: URL(fileURLWithPath: path), decoder: decoder, now: now, ttl: ttl))
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
                out.append(contentsOf: Self.discoverPresencesFromRunningCodexProcesses(
                    now: now,
                    sessionsRoots: sessionsRoots,
                    timeout: Self.processProbeTimeout
                ))
                return (out, true, registryHasPresences)
            } else {
                // Reuse recent probe findings between probe intervals.
                out.append(contentsOf: cachedProbeSnapshot.filter { !$0.isStale(now: now, ttl: ttl) })
                return (out, false, registryHasPresences)
            }
        }.value
        let loaded = probeResult.loaded

        if probeResult.didProbe {
            let latestProbe = loaded.filter { $0.sourceFilePath == nil }
            cachedProcessPresences = latestProbe
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
                sessionMap[id] = Self.merge(sessionMap[id], p)
                keyed = true
            }
            if let log = p.sessionLogPath, !log.isEmpty {
                let norm = Self.normalizePath(log)
                logMap[norm] = Self.merge(logMap[norm], p)
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
            if let log = p.sessionLogPath, !log.isEmpty, logMap[Self.normalizePath(log)] != nil { continue }
            ui.append(p)
        }
        for p in fallbackMap.values {
            ui.append(p)
        }

        let nextLiveStates = await Task.detached(priority: .utility) {
            Self.classifyLiveStates(
                for: ui,
                now: now,
                probeITerm: hasVisibleConsumerSnapshot && appIsActiveSnapshot,
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
        var out: [URL] = []
        var seen: Set<String> = []
        for u in candidates {
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(u) }
        }
        return out
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

    nonisolated static func presenceKey(for presence: CodexActivePresence) -> String {
        if let log = presence.sessionLogPath, !log.isEmpty {
            let normalized = normalizePath(log)
            if !normalized.isEmpty { return normalized }
        }
        if let sid = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sid.isEmpty { return "sid:\(sid)" }
        if let src = presence.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !src.isEmpty { return "src:\(src)" }
        if let pid = presence.pid { return "pid:\(pid)" }
        if let tty = presence.tty?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tty.isEmpty { return "tty:\(tty)" }
        return "unknown"
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
        if let cached = sessionLookupCacheByID[session.id],
           cached.rawFilePath == session.filePath,
           cached.internalSessionIDHint == internalSessionIDHint {
            return cached
        }
        let fresh = SessionLookupCacheEntry(
            rawFilePath: session.filePath,
            normalizedLogPath: Self.normalizePath(session.filePath),
            internalSessionIDHint: internalSessionIDHint,
            filenameUUID: session.codexFilenameUUID
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
        if let id = lookup.internalSessionIDHint, let p = bySessionID[id] { return p }
        if let id = lookup.filenameUUID, id != lookup.internalSessionIDHint, let p = bySessionID[id] { return p }
        return nil
    }

    private func pollIntervalSeconds() -> TimeInterval {
        guard appIsActive else { return Self.backgroundPollInterval }
        return hasVisibleConsumer ? Self.defaultPollInterval : Self.backgroundPollInterval
    }

    nonisolated private static func processProbeMinIntervalSeconds(registryHasPresences: Bool,
                                                                   hasVisibleConsumer: Bool,
                                                                   appIsActive: Bool) -> TimeInterval {
        if registryHasPresences {
            if appIsActive {
                return hasVisibleConsumer
                    ? Self.processProbeMinIntervalRegistryEmptyForeground
                    : Self.processProbeMinIntervalRegistryPresentForeground
            }
            return Self.processProbeMinIntervalRegistryPresentBackground
        }
        if appIsActive {
            return hasVisibleConsumer
                ? Self.processProbeMinIntervalRegistryEmptyForeground
                : Self.processProbeMinIntervalRegistryEmptyBackground
        }
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
                if let v = normalizedLogPath, !v.isEmpty { return v }
                if let id = p.sessionId, !id.isEmpty { return "sid:\(id)" }
                if let src = p.sourceFilePath, !src.isEmpty { return "src:\(src)" }
                if let pid = p.pid { return "pid:\(pid)" }
                if let tty = p.tty, !tty.isEmpty { return "tty:\(tty)" }
                return "unknown"
            }()

            var parts: [String] = []
            parts.reserveCapacity(13)
            parts.append(p.publisher ?? "")
            parts.append(p.kind ?? "")
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

    nonisolated static func canAttemptITerm2Focus(itermSessionId: String?, tty: String?, termProgram: String?) -> Bool {
        if let guid = itermSessionGuid(from: itermSessionId), !guid.isEmpty { return true }
        guard let tty = tty?.trimmingCharacters(in: .whitespacesAndNewlines), !tty.isEmpty else { return false }
        let term = (termProgram ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if term.contains("iterm") { return true }
        // Process env snapshots can miss TERM_PROGRAM; keep tty-based iTerm2 probe available.
        return term.isEmpty
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
        let normalized = tail.replacingOccurrences(of: "\r", with: "")
        guard !normalized.isEmpty else { return nil }
        let lower = normalized.lowercased()

        let busyMarkers = [
            "• working",
            "worked for ",
            "working for ",
            "waiting for background terminal",
            "background terminal",
            "esc to interrupt",
            "re-connecting",
            "reconnecting"
        ]
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let lastNonEmptyLine = lines.reversed().first(where: { !$0.isEmpty }) ?? ""
        let lowerTailWindow = lines.suffix(20).joined(separator: "\n").lowercased()

        if busyMarkers.contains(where: { lowerTailWindow.contains($0) || lastNonEmptyLine.lowercased().contains($0) || lower.contains($0) }) {
            return .activeWorking
        }

        let isPromptLine = (lastNonEmptyLine == "›" || lastNonEmptyLine.hasPrefix("› "))
        if isPromptLine {
            return .openIdle
        }

        // Live session with no visible prompt and no explicit idle marker is usually mid-turn.
        if !lastNonEmptyLine.isEmpty {
            return .activeWorking
        }
        return nil
    }

    nonisolated static func heuristicLiveStateFromLogMTime(logPath: String?,
                                                           now: Date,
                                                           activeWriteWindow: TimeInterval = 2.5) -> CodexLiveState {
        guard let logPath, !logPath.isEmpty else { return .openIdle }
        let expanded = (logPath as NSString).expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              let mtime = attrs[.modificationDate] as? Date else {
            return .openIdle
        }
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
            if probeITerm,
               canAttemptITerm2Focus(
                itermSessionId: presence.terminal?.itermSessionId,
                tty: presence.tty,
                termProgram: presence.terminal?.termProgram
               ),
               let tail = captureITermTail(
                itermSessionId: presence.terminal?.itermSessionId,
                tty: presence.tty,
                timeout: timeout
               ) {
                state = classifyITermTail(tail)
            }

            let resolved = state ?? heuristicLiveStateFromLogMTime(logPath: presence.sessionLogPath, now: now)
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

    // MARK: - Live Process Discovery (Fallback)

    /// Best-effort: infer active sessions by scanning running `codex` processes and the JSONL file they have open.
    /// This is used when Codex CLI itself does not publish a stable active-session registry.
    nonisolated static func discoverPresencesFromRunningCodexProcesses(now: Date,
                                                                       sessionsRoots: [String],
                                                                       timeout: TimeInterval) -> [CodexActivePresence] {
        let lsofPath = "/usr/sbin/lsof"
        let psPath = "/bin/ps"
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: lsofPath), fm.isExecutableFile(atPath: psPath) else { return [] }

        let roots = sessionsRoots.map(normalizePath)
        let user = NSUserName()

        // `lsof -F pftn` gives us PID + per-fd records including `cwd`, tty device, and open JSONL log path.
        guard let lsofOut = runCommand(
            executable: URL(fileURLWithPath: lsofPath),
            arguments: ["-w", "-a", "-c", "codex", "-u", user, "-nP", "-F", "pftn"],
            timeout: timeout
        ) else {
            return []
        }

        let lsofText = String(decoding: lsofOut, as: UTF8.self)
        var infos = parseLsofMachineOutput(lsofText, sessionsRoots: roots)
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
            p.sessionLogPath = info.sessionLogPath
            p.workspaceRoot = info.cwd
            p.pid = info.pid
            p.tty = info.tty
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

    // MARK: - Command Runner

    struct PSProcessEnvMeta: Equatable, Sendable {
        var termProgram: String?
        var itermSessionId: String?
    }

    struct LsofPIDInfo: Equatable, Sendable {
        var pid: Int
        var cwd: String?
        var tty: String?
        var sessionLogPath: String?
        var termProgram: String?
        var itermSessionId: String?
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

    nonisolated static func parseLsofMachineOutput(_ text: String, sessionsRoots: [String]) -> [Int: LsofPIDInfo] {
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
                    let ttyName: String = {
                        if name.hasPrefix("/dev/") { return name }
                        if name.hasPrefix("dev/") { return "/" + name }
                        return name
                    }()
                    if ttyName.hasPrefix("/dev/ttys") || ttyName.hasPrefix("/dev/pts/") {
                        info.tty = ttyName
                        infos[pid] = info
                        continue
                    }
                    infos[pid] = info
                    continue
                }

                // Session log path: prefer Codex rollout JSONL under configured sessions roots.
                if name.hasSuffix(".jsonl"),
                   (name as NSString).lastPathComponent.hasPrefix("rollout-"),
                   sessionsRoots.contains(where: { root in
                       let rp = root.hasSuffix("/") ? root : (root + "/")
                       return name.hasPrefix(rp)
                   }) {
                    // Prefer a writable fd if present (e.g., 26w).
                    let isWrite = (currentFD?.contains("w") ?? false)
                    if info.sessionLogPath == nil || isWrite {
                        info.sessionLogPath = name
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

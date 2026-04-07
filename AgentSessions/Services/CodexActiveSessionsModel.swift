import Foundation
import SwiftUI
import Darwin
import SQLite3

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
        var tabTitle: String?
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
    /// All JSONL log paths open by this process (parent + subagents).
    var openSessionLogPaths: [String] = []

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
    nonisolated static let defaultPollInterval: TimeInterval = 2
    nonisolated static let defaultStaleTTL: TimeInterval = 10
    nonisolated static let backgroundPollInterval: TimeInterval = 15
    nonisolated static let pinnedBackgroundPollInterval: TimeInterval = 3
    nonisolated static let stablePinnedBackgroundPollInterval: TimeInterval = 5
    nonisolated static let pinnedBackgroundITermProbeMinInterval: TimeInterval = 9
    nonisolated static let pinnedBackgroundProcessProbeMinInterval: TimeInterval = 12
    nonisolated private static let stableBackoffActivationCycles: Int = 3
    nonisolated private static let codexInconclusiveTailActiveGraceWindow: TimeInterval = 6
    nonisolated private static let processProbeTimeout: TimeInterval = 0.75
    nonisolated static let subagentRecentWriteWindow: TimeInterval = 45
    nonisolated static let processProbeMinIntervalRegistryEmptyForeground: TimeInterval = 6
    nonisolated private static let processProbeMinIntervalRegistryEmptyBackground: TimeInterval = 45
    nonisolated private static let processProbeMinIntervalRegistryPresentForeground: TimeInterval = 30
    nonisolated private static let processProbeMinIntervalRegistryPresentBackground: TimeInterval = 120
    nonisolated private static let resumeProbeBudgets: [Int] = [1, 2, 4]
    nonisolated private static let steadyStateITermProbeBudget: Int = 4
    nonisolated private static let pinnedBackgroundWaitingITermProbeBudget: Int = 2
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
    @Published private(set) var subagentBadgeVersion: UInt64 = 0

    @Published private(set) var presences: [CodexActivePresence] = []
    private(set) var lastRefreshAt: Date? = nil

    private var lastPublishedPresenceSignatures: [String: String] = [:]
    private var lastCockpitVisibleAt: Date?

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

    @AppStorage(PreferencesKey.Cockpit.hudOpen)
    private var hudOpen: Bool = false

    @AppStorage(PreferencesKey.Cockpit.hudPinned)
    private var hudPinned: Bool = false

    private var pollTask: Task<Void, Never>? = nil
    private var refreshTask: Task<Void, Never>? = nil
    private var refreshInFlight: Bool = false
    private var refreshQueued: Bool = false
    private var refreshGeneration: UInt64 = 0
    private var activeRefreshGeneration: UInt64 = 0
    private var activeRefreshCount: Int = 0

    private var bySessionID: [String: CodexActivePresence] = [:]
    private var byLogPath: [String: CodexActivePresence] = [:]
    private var lastPublishedRuntimeSubagentCountsByPresenceKey: [String: Int] = [:]
    private var liveStateByPresenceKey: [String: CodexLiveState] = [:]
    private var idleReasonByPresenceKey: [String: HUDIdleReason] = [:]
    private var lastActivityByPresenceKey: [String: Date] = [:]
    private var cachedProcessPresences: [CodexActivePresence] = []
    private var cachedITermPresences: [CodexActivePresence] = []
    private var cachedITermTabTitleByTTY: [String: String] = [:]
    private var cachedITermTabTitleBySessionGuid: [String: String] = [:]
    private var lastProcessProbeAt: Date? = nil
    private var lastITermProbeAt: Date? = nil
    private var unifiedVisibleConsumerIDs: Set<UUID> = []
    private var cockpitVisibleConsumerIDs: Set<UUID> = []
    private var cockpitWindowVisibleConsumerIDs: Set<UUID> = []
    private var appIsActive: Bool = true
    private var resumeProbeBudgetIndex: Int? = nil
    private var itermProbeRoundRobinCursor: Int = 0
    private var forceFullProbeNextRefresh: Bool = false
    private var consecutiveStableCycles: Int = 0
    private var consecutiveEmptySuppressedCycles: Int = 0
    private enum ManagedProbeKind: String, Hashable {
        case processDiscovery
        case iTermInventory
        case iTermBatchProbe
    }
    /// Main-actor confined command wrapper used by refresh/cancel paths.
    /// Do not capture instances into detached tasks.
    private final class ManagedProbeCommand {
        let id = UUID()
        let kind: ManagedProbeKind
        let process = Process()
        let stdoutPipe = Pipe()

        init(kind: ManagedProbeKind, executable: URL, arguments: [String]) {
            self.kind = kind
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
        }

        func start() throws {
            try process.run()
        }

        func terminate() {
            guard process.isRunning else { return }
            process.terminate()
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
    private var inFlightProbeCommands: [ManagedProbeKind: ManagedProbeCommand] = [:]

    private struct SessionLookupCacheEntry {
        var source: SessionSource
        var rawFilePath: String
        var normalizedLogPath: String
        var internalSessionIDHint: String?
        var filenameUUID: String?
        var runtimeSessionIDs: [String]
        var lastAccessTick: UInt64
    }
    private static let sessionLookupCacheHardLimit = 500
    private static let sessionLookupCacheTargetSize = 400
    private var sessionLookupCacheByID: [String: SessionLookupCacheEntry] = [:]
    private var sessionLookupAccessTick: UInt64 = 0
#if DEBUG
    private struct DebugMetrics {
        var refreshCount: UInt64 = 0
        var refreshTotalDurationMs: Double = 0
        var refreshMaxDurationMs: Double = 0
        var processProbeRuns: UInt64 = 0
        var processProbeSkips: UInt64 = 0
        var processProbeRegistryEmptyRuns: UInt64 = 0
        var processProbeRegistryPresentRuns: UInt64 = 0
        var suppressedTransientEmptyPublishes: UInt64 = 0
        var isActiveCalls: UInt64 = 0
        var staleRefreshResultsDropped: UInt64 = 0
        var terminatedStaleProbeProcesses: UInt64 = 0
        var maxConcurrentRefreshes: Int = 0
        var maxConcurrentITermScans: Int = 0
        var maxConcurrentITermBatchProbes: Int = 0
        var maxConcurrentProcessProbes: Int = 0
        var latestRefreshGeneration: UInt64 = 0
        var currentITermScans: Int = 0
        var currentITermBatchProbes: Int = 0
        var currentProcessProbes: Int = 0
    }
    private static let debugPerfLoggingEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment["AGENT_SESSIONS_DEBUG_PERF_LOGS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if env == "1" || env == "true" || env == "yes" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "DebugCodexActivePerfLogs")
    }()
    private var debugMetrics = DebugMetrics()
    private var lastDebugMetricsReportAt: Date = .distantPast
#endif

    init() {
        // Avoid background activity under `xcodebuild test`.
        guard !AppRuntime.isRunningTests else { return }
        Task {
            await AppReadyGate.waitUntilReady()
            startPollingIfNeeded()
        }
    }

    deinit {
        pollTask?.cancel()
        refreshTask?.cancel()
    }

#if DEBUG
    enum DebugManagedProbeKind {
        case processDiscovery
        case iTermInventory
        case iTermBatchProbe
    }

    func debugRunManagedCommand(kind: DebugManagedProbeKind = .processDiscovery,
                                executable: URL,
                                arguments: [String],
                                timeout: TimeInterval,
                                generation: UInt64? = nil) async -> Data? {
        let managedKind: ManagedProbeKind
        switch kind {
        case .processDiscovery:
            managedKind = .processDiscovery
        case .iTermInventory:
            managedKind = .iTermInventory
        case .iTermBatchProbe:
            managedKind = .iTermBatchProbe
        }
        return await runManagedCommand(kind: managedKind,
                                       generation: generation ?? activeRefreshGeneration,
                                       executable: executable,
                                       arguments: arguments,
                                       timeout: timeout)
    }
#endif

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

    func idleReason(for presence: CodexActivePresence) -> HUDIdleReason? {
        let key = Self.presenceKey(for: presence)
        return idleReasonByPresenceKey[key]
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

    func lastActivityAt(for presence: CodexActivePresence) -> Date? {
        let key = Self.presenceKey(for: presence)
        if let cached = lastActivityByPresenceKey[key] { return cached }
        return Self.lastActivityAt(logPath: presence.sessionLogPath, sourceFilePath: presence.sourceFilePath)
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
        guard !AppRuntime.isRunningTests else { return }
        let hadVisibleConsumer = hasVisibleConsumer
        if visible { unifiedVisibleConsumerIDs.insert(consumerID) }
        else { unifiedVisibleConsumerIDs.remove(consumerID) }
        guard hasVisibleConsumer != hadVisibleConsumer else { return }
        resetStablePollBackoff()
        if !hadVisibleConsumer, hasVisibleConsumer, appIsActive {
            armForegroundProbeRamp()
        }
        refreshSoon()
    }

    func setCockpitConsumerVisible(_ visible: Bool, consumerID: UUID) {
        guard !AppRuntime.isRunningTests else { return }
        let hadVisibleConsumer = hasVisibleConsumer
        if visible { cockpitVisibleConsumerIDs.insert(consumerID) }
        else {
            cockpitVisibleConsumerIDs.remove(consumerID)
            cockpitWindowVisibleConsumerIDs.remove(consumerID)
        }
        guard hasVisibleConsumer != hadVisibleConsumer else { return }
        resetStablePollBackoff()
        if !hadVisibleConsumer, hasVisibleConsumer, appIsActive {
            armForegroundProbeRamp()
        }
        refreshSoon()
    }

    func setCockpitWindowVisible(_ visible: Bool, consumerID: UUID) {
        guard !AppRuntime.isRunningTests else { return }
        let hadVisibleCockpitWindow = hasVisibleCockpitWindow
        if visible {
            guard cockpitVisibleConsumerIDs.contains(consumerID) else { return }
            cockpitWindowVisibleConsumerIDs.insert(consumerID)
        } else {
            cockpitWindowVisibleConsumerIDs.remove(consumerID)
        }
        if hasVisibleCockpitWindow {
            lastCockpitVisibleAt = Date()
        }
        guard hasVisibleCockpitWindow != hadVisibleCockpitWindow else { return }
        resetStablePollBackoff()
        if !hadVisibleCockpitWindow, hasVisibleCockpitWindow, appIsActive {
            armForegroundProbeRamp()
        }
        refreshSoon()
    }

    func setAppActive(_ active: Bool) {
        guard !AppRuntime.isRunningTests else { return }
        guard appIsActive != active else { return }
        appIsActive = active
        resetStablePollBackoff()
        if active { armForegroundProbeRamp() }
        refreshSoon()
    }

    private var hasVisibleConsumer: Bool {
        !unifiedVisibleConsumerIDs.isEmpty || !cockpitVisibleConsumerIDs.isEmpty
    }

    private var hasVisibleCockpitConsumer: Bool {
        !cockpitVisibleConsumerIDs.isEmpty
    }

    private var hasVisibleCockpitWindow: Bool {
        !cockpitWindowVisibleConsumerIDs.isEmpty
    }

    private var isCockpitVisible: Bool {
        hasVisibleCockpitWindow && hudOpen
    }

    private var isPinnedCockpitVisible: Bool {
        hasVisibleCockpitConsumer && hudOpen && hudPinned
    }

    func refreshNow() {
        guard !AppRuntime.isRunningTests else { return }
        // Manual refresh should bypass probe throttling so live state transitions
        // (active -> open and vice versa) are reflected immediately.
        lastProcessProbeAt = nil
        cachedProcessPresences = []
        lastITermProbeAt = nil
        cachedITermPresences = []
        cachedITermTabTitleByTTY = [:]
        cachedITermTabTitleBySessionGuid = [:]
        forceFullProbeNextRefresh = true
        consecutiveEmptySuppressedCycles = 0
        resetStablePollBackoff()
        armForegroundProbeRamp()
        refreshTask?.cancel()
        cancelAllInFlightProbeCommands(reason: "manual-refresh")
        refreshTask = Task { [weak self] in
            await self?.refreshOnce()
        }
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard !AppRuntime.isRunningTests else { return }
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
        cancelAllInFlightProbeCommands(reason: clear ? "stop-clear" : "stop")
        refreshInFlight = false
        refreshQueued = false
        resetStablePollBackoff()
        if clear {
            presences = []
            bySessionID = [:]
            byLogPath = [:]
            liveStateByPresenceKey = [:]
            idleReasonByPresenceKey = [:]
            lastActivityByPresenceKey = [:]
            cachedProcessPresences = []
            cachedITermPresences = []
            cachedITermTabTitleByTTY = [:]
            cachedITermTabTitleBySessionGuid = [:]
            lastProcessProbeAt = nil
            lastITermProbeAt = nil
            lastPublishedPresenceSignatures = [:]
            // Preserve visible-consumer registrations across disable/enable toggles so
            // open windows immediately restore foreground cadence without requiring re-appear.
            sessionLookupCacheByID = [:]
            sessionLookupAccessTick = 0
            lastRefreshAt = nil
            resumeProbeBudgetIndex = nil
            itermProbeRoundRobinCursor = 0
            forceFullProbeNextRefresh = false
            activeMembershipVersion &+= 1
            refreshGeneration &+= 1
            activeRefreshGeneration = refreshGeneration
        }
    }

    private func refreshSoon() {
        // Coalesce rapid preference edits.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.refreshOnce()
        }
    }

    private func beginRefreshGeneration() -> UInt64 {
        refreshGeneration &+= 1
        activeRefreshGeneration = refreshGeneration
        return activeRefreshGeneration
    }

    private func isCurrentRefreshGeneration(_ generation: UInt64) -> Bool {
        generation == activeRefreshGeneration
    }

    private func markStaleRefreshDrop() {
#if DEBUG
        debugMetrics.staleRefreshResultsDropped &+= 1
#endif
    }

    private func cancelAllInFlightProbeCommands(reason: String) {
        let kinds = Array(inFlightProbeCommands.keys)
        for kind in kinds {
            cancelInFlightProbeCommand(kind: kind, reason: reason)
        }
    }

    private func cancelInFlightProbeCommand(kind: ManagedProbeKind, reason: String) {
        guard let command = inFlightProbeCommands.removeValue(forKey: kind) else { return }
        command.terminate()
#if DEBUG
        switch kind {
        case .processDiscovery:
            debugMetrics.currentProcessProbes = max(0, debugMetrics.currentProcessProbes - 1)
        case .iTermInventory:
            debugMetrics.currentITermScans = max(0, debugMetrics.currentITermScans - 1)
        case .iTermBatchProbe:
            debugMetrics.currentITermBatchProbes = max(0, debugMetrics.currentITermBatchProbes - 1)
        }
        debugMetrics.terminatedStaleProbeProcesses &+= 1
        if Self.debugPerfLoggingEnabled {
            print("[CodexActiveSessionsModel][perf] cancelled in-flight \(kind.rawValue) probe reason=\(reason)")
        }
#endif
    }

    private func beginManagedProbeCommand(kind: ManagedProbeKind, command: ManagedProbeCommand) {
        if inFlightProbeCommands[kind] != nil {
            cancelInFlightProbeCommand(kind: kind, reason: "replaced")
        }
        inFlightProbeCommands[kind] = command
#if DEBUG
        switch kind {
        case .processDiscovery:
            debugMetrics.currentProcessProbes += 1
            debugMetrics.maxConcurrentProcessProbes = max(
                debugMetrics.maxConcurrentProcessProbes,
                debugMetrics.currentProcessProbes
            )
        case .iTermInventory:
            debugMetrics.currentITermScans += 1
            debugMetrics.maxConcurrentITermScans = max(
                debugMetrics.maxConcurrentITermScans,
                debugMetrics.currentITermScans
            )
        case .iTermBatchProbe:
            debugMetrics.currentITermBatchProbes += 1
            debugMetrics.maxConcurrentITermBatchProbes = max(
                debugMetrics.maxConcurrentITermBatchProbes,
                debugMetrics.currentITermBatchProbes
            )
        }
#endif
    }

    private func finishManagedProbeCommand(kind: ManagedProbeKind, id: UUID) {
        guard inFlightProbeCommands[kind]?.id == id else { return }
        inFlightProbeCommands.removeValue(forKey: kind)
#if DEBUG
        switch kind {
        case .processDiscovery:
            debugMetrics.currentProcessProbes = max(0, debugMetrics.currentProcessProbes - 1)
        case .iTermInventory:
            debugMetrics.currentITermScans = max(0, debugMetrics.currentITermScans - 1)
        case .iTermBatchProbe:
            debugMetrics.currentITermBatchProbes = max(0, debugMetrics.currentITermBatchProbes - 1)
        }
#endif
    }

    private enum ManagedProbeWaitResult {
        case exited
        case timedOut
    }

    private final class ManagedProbeWaitState {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ManagedProbeWaitResult, Never>?

        init(_ continuation: CheckedContinuation<ManagedProbeWaitResult, Never>) {
            self.continuation = continuation
        }

        func resumeIfNeeded(_ result: ManagedProbeWaitResult) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    private func runManagedCommand(kind: ManagedProbeKind,
                                   generation: UInt64,
                                   executable: URL,
                                   arguments: [String],
                                   timeout: TimeInterval) async -> Data? {
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return nil
        }

        let command = ManagedProbeCommand(kind: kind, executable: executable, arguments: arguments)
        beginManagedProbeCommand(kind: kind, command: command)

        do {
            try command.start()
        } catch {
            finishManagedProbeCommand(kind: kind, id: command.id)
            return nil
        }

        let stdoutHandle = command.stdoutPipe.fileHandleForReading
        async let drainedOutput = Self.readManagedProbeOutput(from: stdoutHandle)
        let waitResult = await withTaskCancellationHandler {
            await waitForManagedProbeExit(command.process, timeout: timeout)
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelInFlightProbeCommand(kind: kind, reason: "task-cancelled")
            }
        }
        command.process.terminationHandler = nil
        let timedOut = waitResult == .timedOut
        if timedOut {
            cancelInFlightProbeCommand(kind: kind, reason: "timeout")
        }
        let wasCancelled = Task.isCancelled
        let data = await drainedOutput
        let stillOwned = inFlightProbeCommands[kind]?.id == command.id
        let stillCurrent = isCurrentRefreshGeneration(generation)
        finishManagedProbeCommand(kind: kind, id: command.id)
        if !stillCurrent {
            markStaleRefreshDrop()
            return nil
        }
        if wasCancelled || timedOut || !stillOwned { return nil }
        return data
    }

    private nonisolated static func readManagedProbeOutput(from handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close() }
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private func waitForManagedProbeExit(_ process: Process,
                                         timeout: TimeInterval) async -> ManagedProbeWaitResult {
        await withCheckedContinuation { continuation in
            let state = ManagedProbeWaitState(continuation)
            let timeoutItem = DispatchWorkItem {
                state.resumeIfNeeded(.timedOut)
            }

            process.terminationHandler = { _ in
                timeoutItem.cancel()
                state.resumeIfNeeded(.exited)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(timeout, 0),
                execute: timeoutItem
            )

            if !process.isRunning {
                timeoutItem.cancel()
                state.resumeIfNeeded(.exited)
            }
        }
    }

    private struct RefreshDiscoveryResult {
        let loaded: [CodexActivePresence]
        let didProbeProcesses: Bool
        let didProbeITerm: Bool
        let registryHadPresences: Bool
        let itermPresences: [CodexActivePresence]
        let itermTabTitleByTTY: [String: String]
        let itermTabTitleBySessionGuid: [String: String]
    }

    private func performRefreshDiscovery(generation: UInt64,
                                         now: Date,
                                         ttl: TimeInterval,
                                         rootPaths: [String],
                                         codexSessionRoots: [String],
                                         claudeSessionRoots: [String],
                                         opencodeSessionRoots: [String],
                                         lastProcessProbeAtSnapshot: Date?,
                                         lastITermProbeAtSnapshot: Date?,
                                         cachedProcessProbeSnapshot: [CodexActivePresence],
                                         cachedITermPresenceSnapshot: [CodexActivePresence],
                                         cachedITermTabTitleByTTYSnapshot: [String: String],
                                         cachedITermTabTitleBySessionGuidSnapshot: [String: String],
                                         hasVisibleConsumerSnapshot: Bool,
                                         appIsActiveSnapshot: Bool,
                                         isCockpitVisibleSnapshot: Bool,
                                         isPinnedCockpitVisibleSnapshot: Bool,
                                         shouldUseITermSnapshot: Bool,
                                         shouldProbeITermSnapshot: Bool) async -> RefreshDiscoveryResult? {
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return nil
        }

        var out: [CodexActivePresence] = []
        var itermPresences: [CodexActivePresence] = []
        var itermTabTitleByTTY: [String: String] = [:]
        var itermTabTitleBySessionGuid: [String: String] = [:]
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
            appIsActive: appIsActiveSnapshot,
            isCockpitVisible: isCockpitVisibleSnapshot,
            isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
        )
        let processPresenceCacheTTL = Self.effectiveCachedProcessPresenceTTL(
            baseTTL: ttl,
            processProbeMinInterval: processProbeMinInterval,
            pollInterval: Self.effectivePollIntervalSeconds(
                appIsActive: appIsActiveSnapshot,
                hasVisibleConsumer: hasVisibleConsumerSnapshot,
                isCockpitVisible: isCockpitVisibleSnapshot,
                isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
            ),
            hasVisibleConsumer: hasVisibleConsumerSnapshot
        )
        let shouldProbeProcesses: Bool = {
            guard let last = lastProcessProbeAtSnapshot else { return true }
            return now.timeIntervalSince(last) >= processProbeMinInterval
        }()

        if shouldProbeProcesses {
            let processPresences = await discoverProcessPresences(
                generation: generation,
                now: now,
                codexSessionRoots: codexSessionRoots,
                claudeSessionRoots: claudeSessionRoots,
                opencodeSessionRoots: opencodeSessionRoots,
                timeout: Self.processProbeTimeout
            )
            guard isCurrentRefreshGeneration(generation) else {
                markStaleRefreshDrop()
                return nil
            }
            out.append(contentsOf: processPresences)
        } else {
            out.append(contentsOf: Self.filterSupportedPresences(
                cachedProcessProbeSnapshot.filter { !$0.isStale(now: now, ttl: processPresenceCacheTTL) }
            ))
        }

        if shouldProbeITermSnapshot {
            let sessions = await loadITermSessions(
                generation: generation,
                timeout: Self.processProbeTimeout
            )
            guard isCurrentRefreshGeneration(generation) else {
                markStaleRefreshDrop()
                return nil
            }
            if !sessions.isEmpty {
                itermTabTitleByTTY = Self.itermTabTitleByTTY(sessions)
                itermTabTitleBySessionGuid = Self.itermTabTitleBySessionGuid(sessions)
                itermPresences = Self.presencesFromITermSessions(sessions, source: .codex, now: now)
                itermPresences += Self.presencesFromITermSessions(sessions, source: .claude, now: now)
                itermPresences += Self.presencesFromITermSessions(sessions, source: .opencode, now: now)
                out.append(contentsOf: itermPresences)
            }
        } else if shouldUseITermSnapshot {
            itermPresences = Self.filterSupportedPresences(
                cachedITermPresenceSnapshot.filter { !$0.isStale(now: now, ttl: ttl) }
            )
            itermTabTitleByTTY = cachedITermTabTitleByTTYSnapshot
            itermTabTitleBySessionGuid = cachedITermTabTitleBySessionGuidSnapshot
            out.append(contentsOf: itermPresences)
        }

        return RefreshDiscoveryResult(
            loaded: out,
            didProbeProcesses: shouldProbeProcesses,
            didProbeITerm: shouldProbeITermSnapshot,
            registryHadPresences: registryHasPresences,
            itermPresences: itermPresences,
            itermTabTitleByTTY: itermTabTitleByTTY,
            itermTabTitleBySessionGuid: itermTabTitleBySessionGuid
        )
    }

    private func discoverProcessPresences(generation: UInt64,
                                          now: Date,
                                          codexSessionRoots: [String],
                                          claudeSessionRoots: [String],
                                          opencodeSessionRoots: [String],
                                          timeout: TimeInterval) async -> [CodexActivePresence] {
        let user = NSUserName()
        let psData = await runManagedCommand(
            kind: .processDiscovery,
            generation: generation,
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["axww", "-o", "pid=,tty=,command="],
            timeout: timeout
        )
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return []
        }

        let commandInfos = psData.map { Self.parsePSCommandListOutput(String(decoding: $0, as: UTF8.self)) } ?? []
        let claudeCommandPIDs = Array(
            Set(
                commandInfos
                    .filter { info in
                        guard info.tty != nil else { return false }
                        return Self.commandContainsNeedle(info.command, needles: ["claude", "claude-code"])
                    }
                    .map(\.pid)
            )
        ).sorted()
        let opencodeCommandPIDs = Array(
            Set(
                commandInfos
                    .filter { info in
                        guard info.tty != nil else { return false }
                        return Self.commandContainsNeedle(info.command, needles: ["opencode"])
                    }
                    .map(\.pid)
            )
        ).sorted()

        let codexInfos = await discoverLsofPIDInfos(
            generation: generation,
            source: .codex,
            queryArguments: ["-w", "-a", "-c", "codex", "-u", user, "-nP", "-F", "pftn"],
            sessionsRoots: codexSessionRoots,
            timeout: timeout
        )
        // Claude Code sets process.title to its version string (e.g. "2.1.76"),
        // so `lsof -c claude` never matches. Discover via ps-based PID query only.
        let claudeInfos: [Int: LsofPIDInfo]
        if claudeCommandPIDs.isEmpty {
            claudeInfos = [:]
        } else {
            claudeInfos = await discoverLsofPIDInfos(
                generation: generation,
                source: .claude,
                queryArguments: ["-w", "-a", "-p", claudeCommandPIDs.map(String.init).joined(separator: ","), "-u", user, "-nP", "-F", "pftn"],
                sessionsRoots: claudeSessionRoots,
                timeout: timeout
            )
        }
        let opencodeInfos = await discoverLsofPIDInfos(
            generation: generation,
            source: .opencode,
            queryArguments: ["-w", "-a", "-c", "opencode", "-u", user, "-nP", "-F", "pftn"],
            sessionsRoots: opencodeSessionRoots,
            timeout: timeout
        )
        let opencodeCommandInfos: [Int: LsofPIDInfo]
        if opencodeCommandPIDs.isEmpty {
            opencodeCommandInfos = [:]
        } else {
            opencodeCommandInfos = await discoverLsofPIDInfos(
                generation: generation,
                source: .opencode,
                queryArguments: ["-w", "-a", "-p", opencodeCommandPIDs.map(String.init).joined(separator: ","), "-u", user, "-nP", "-F", "pftn"],
                sessionsRoots: opencodeSessionRoots,
                timeout: timeout
            )
        }
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return []
        }
        let pidInfoBySource: [SessionSource: [Int: LsofPIDInfo]] = [
            .codex: codexInfos,
            .claude: claudeInfos,
            .opencode: Self.mergePIDInfos(opencodeInfos, with: opencodeCommandInfos)
        ]
        let allPIDs = Array(pidInfoBySource.values.flatMap(\.keys)).sorted()
        var envByPID: [Int: PSProcessEnvMeta] = [:]
        if !allPIDs.isEmpty,
           let envData = await runManagedCommand(
                kind: .processDiscovery,
                generation: generation,
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["eww", "-p", allPIDs.map(String.init).joined(separator: ",")],
                timeout: timeout
           ) {
            envByPID = Self.parsePSEnvironmentOutput(String(decoding: envData, as: UTF8.self))
        }
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return []
        }

        var out: [CodexActivePresence] = []
        var assignedLogPaths: Set<String> = []
        for (source, infos) in pidInfoBySource {
            for var info in infos.values {
                if let envMeta = envByPID[info.pid] {
                    info.termProgram = envMeta.termProgram
                    info.itermSessionId = envMeta.itermSessionId
                }
                var presence = CodexActivePresence()
                presence.schemaVersion = 1
                presence.publisher = "agent-sessions-process"
                presence.kind = "interactive"
                presence.source = source
                presence.sessionId = info.sessionID
                presence.sessionLogPath = info.sessionLogPath
                presence.workspaceRoot = info.cwd
                // Claude Code doesn't keep the JSONL open, so lsof usually misses it.
                // Infer the session log from the project directory's newest JSONL file.
                // Track assigned paths so two processes in the same cwd get different files.
                if presence.sessionLogPath == nil, source == .claude, let cwd = info.cwd {
                    let root = claudeSessionRoots.first ?? (NSHomeDirectory() + "/.claude")
                    let candidates = Self.claudeSessionLogCandidates(cwd: cwd, claudeRoot: root, recencyCutoff: now.addingTimeInterval(-60))
                    if let match = candidates.first(where: { !assignedLogPaths.contains($0.path) }) {
                        presence.sessionLogPath = match.path
                        presence.sessionId = match.sessionID
                        assignedLogPaths.insert(match.path)
                    }
                } else if let logPath = presence.sessionLogPath {
                    assignedLogPaths.insert(logPath)
                }
                presence.pid = info.pid
                presence.tty = Self.normalizedTTY(info.tty)
                presence.openSessionLogPaths = info.openSessionLogPaths
                presence.lastSeenAt = now
                var terminal = CodexActivePresence.Terminal()
                terminal.termProgram = info.termProgram
                terminal.itermSessionId = info.itermSessionId
                presence.terminal = terminal
                out.append(presence)
            }
        }
        return out
    }

    private func discoverLsofPIDInfos(generation: UInt64,
                                      source: SessionSource,
                                      queryArguments: [String],
                                      sessionsRoots: [String],
                                      timeout: TimeInterval) async -> [Int: LsofPIDInfo] {
        guard let out = await runManagedCommand(
            kind: .processDiscovery,
            generation: generation,
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: queryArguments,
            timeout: timeout
        ) else {
            return [:]
        }
        let roots = sessionsRoots.map(Self.normalizePath)
        return Self.parseLsofMachineOutput(String(decoding: out, as: UTF8.self), sessionsRoots: roots, source: source)
    }

    private static func mergePIDInfos(_ lhs: [Int: LsofPIDInfo], with rhs: [Int: LsofPIDInfo]) -> [Int: LsofPIDInfo] {
        var merged = lhs
        for (pid, info) in rhs {
            if let existing = merged[pid] {
                merged[pid] = mergePIDInfo(existing, info)
            } else {
                merged[pid] = info
            }
        }
        return merged
    }

    private static func mergePIDInfo(_ existing: LsofPIDInfo, _ incoming: LsofPIDInfo) -> LsofPIDInfo {
        let preferredSessionLogPath: String?
        let preferredSessionID: String?
        let preferredSessionLogFD: Int
        if incoming.sessionLogFD < existing.sessionLogFD {
            preferredSessionLogPath = incoming.sessionLogPath
            preferredSessionID = incoming.sessionID
            preferredSessionLogFD = incoming.sessionLogFD
        } else {
            preferredSessionLogPath = existing.sessionLogPath
            preferredSessionID = existing.sessionID
            preferredSessionLogFD = existing.sessionLogFD
        }

        var openSessionLogPaths = existing.openSessionLogPaths
        for path in incoming.openSessionLogPaths where !openSessionLogPaths.contains(path) {
            openSessionLogPaths.append(path)
        }

        return LsofPIDInfo(
            pid: incoming.pid,
            cwd: incoming.cwd ?? existing.cwd,
            tty: incoming.tty ?? existing.tty,
            sessionID: preferredSessionID,
            sessionLogPath: preferredSessionLogPath,
            sessionLogFD: preferredSessionLogFD,
            openSessionLogPaths: openSessionLogPaths,
            termProgram: incoming.termProgram ?? existing.termProgram,
            itermSessionId: incoming.itermSessionId ?? existing.itermSessionId
        )
    }

    private func classifyLiveStatesAsync(for presences: [CodexActivePresence],
                                         generation: UInt64,
                                         now: Date,
                                         probeITerm: Bool,
                                         timeout: TimeInterval,
                                         previousLiveStates: [String: CodexLiveState],
                                         probedITermPresenceKeys: Set<String>) async -> LiveStateClassification {
        let probeTargets = Self.itermProbeTargets(
            from: presences,
            selectedPresenceKeys: probedITermPresenceKeys,
            probeITerm: probeITerm
        )
        let batchProbeResults = await captureBatchedITermProbeResults(
            generation: generation,
            for: probeTargets,
            timeout: timeout
        )
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return LiveStateClassification(liveStates: previousLiveStates, idleReasons: [:])
        }
        return Self.classifyLiveStates(
            for: presences,
            now: now,
            probeITerm: probeITerm,
            previousLiveStates: previousLiveStates,
            probedITermPresenceKeys: probedITermPresenceKeys,
            batchProbeResults: batchProbeResults
        )
    }

    private func refreshOnce() async {
        guard enabled else { return }
        if refreshInFlight {
            refreshQueued = true
            return
        }
        let generation = beginRefreshGeneration()
        refreshInFlight = true
#if DEBUG
        activeRefreshCount += 1
        debugMetrics.maxConcurrentRefreshes = max(debugMetrics.maxConcurrentRefreshes, activeRefreshCount)
        debugMetrics.latestRefreshGeneration = generation
#endif
        defer {
#if DEBUG
            activeRefreshCount = max(0, activeRefreshCount - 1)
#endif
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                refreshTask?.cancel()
                refreshTask = Task { [weak self] in
                    await self?.refreshOnce()
                }
            }
        }

        let now = Date()
#if DEBUG
        let refreshStartedAt = Date()
#endif
        let ttl = Self.defaultStaleTTL
        let rootPaths = registryRoots().map(\.path)
        let codexSessionRoots = codexSessionsRoots().map(\.path)
        let claudeSessionRoots = claudeSessionsRoots().map(\.path)
        let opencodeSessionRoots = opencodeSessionsRoots().map(\.path)
        let previousLogKeys = Set(byLogPath.keys)
        let previousSessionKeys = Set(bySessionID.keys)
        let previousLiveStates = liveStateByPresenceKey
        let lastProcessProbeAtSnapshot = lastProcessProbeAt
        let lastITermProbeAtSnapshot = lastITermProbeAt
        let cachedProcessProbeSnapshot = cachedProcessPresences
        let cachedITermPresenceSnapshot = cachedITermPresences
        let cachedITermTabTitleByTTYSnapshot = cachedITermTabTitleByTTY
        let cachedITermTabTitleBySessionGuidSnapshot = cachedITermTabTitleBySessionGuid
        let hasVisibleConsumerSnapshot = hasVisibleConsumer
        let appIsActiveSnapshot = appIsActive
        let isCockpitVisibleSnapshot = isCockpitVisible
        let isPinnedCockpitVisibleSnapshot = isPinnedCockpitVisible
        let shouldUseITermSnapshot = Self.shouldProbeITermSessions(
            appIsActive: appIsActiveSnapshot,
            hasVisibleConsumer: hasVisibleConsumerSnapshot,
            isCockpitVisible: isCockpitVisibleSnapshot,
            isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
        )
        let shouldProbeITermSnapshot: Bool = {
            guard shouldUseITermSnapshot else { return false }
            let probeMinInterval = Self.itermProbeMinIntervalSeconds(
                appIsActive: appIsActiveSnapshot,
                isCockpitVisible: isCockpitVisibleSnapshot,
                isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
            )
            guard let last = lastITermProbeAtSnapshot else { return true }
            return now.timeIntervalSince(last) >= probeMinInterval
        }()

        guard let probeResult = await performRefreshDiscovery(
            generation: generation,
            now: now,
            ttl: ttl,
            rootPaths: rootPaths,
            codexSessionRoots: codexSessionRoots,
            claudeSessionRoots: claudeSessionRoots,
            opencodeSessionRoots: opencodeSessionRoots,
            lastProcessProbeAtSnapshot: lastProcessProbeAtSnapshot,
            lastITermProbeAtSnapshot: lastITermProbeAtSnapshot,
            cachedProcessProbeSnapshot: cachedProcessProbeSnapshot,
            cachedITermPresenceSnapshot: cachedITermPresenceSnapshot,
            cachedITermTabTitleByTTYSnapshot: cachedITermTabTitleByTTYSnapshot,
            cachedITermTabTitleBySessionGuidSnapshot: cachedITermTabTitleBySessionGuidSnapshot,
            hasVisibleConsumerSnapshot: hasVisibleConsumerSnapshot,
            appIsActiveSnapshot: appIsActiveSnapshot,
            isCockpitVisibleSnapshot: isCockpitVisibleSnapshot,
            isPinnedCockpitVisibleSnapshot: isPinnedCockpitVisibleSnapshot,
            shouldUseITermSnapshot: shouldUseITermSnapshot,
            shouldProbeITermSnapshot: shouldProbeITermSnapshot
        ) else {
            return
        }
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return
        }
        let latestProcessProbe = Self.filterSupportedPresences(
            probeResult.loaded.filter { $0.publisher == "agent-sessions-process" }
        )
        let loaded = Self.coalescePresencesByTTY(
            Self.filterSupportedPresences(probeResult.loaded)
        )
        if probeResult.didProbeITerm {
            cachedITermPresences = probeResult.itermPresences
            self.lastITermProbeAt = now
            // Only update cached title maps when the probe returned data.
            // An empty result is most likely a transient AppleScript failure, not a genuine
            // "no iTerm sessions" state. Caching empty maps overwrites valid titles for all
            // subsequent enrichment passes, producing a brief "—" flash for every Cockpit row.
            if !probeResult.itermTabTitleByTTY.isEmpty || !probeResult.itermTabTitleBySessionGuid.isEmpty {
                cachedITermTabTitleByTTY = probeResult.itermTabTitleByTTY
                cachedITermTabTitleBySessionGuid = probeResult.itermTabTitleBySessionGuid
            }
        } else if shouldUseITermSnapshot {
            cachedITermPresences = cachedITermPresences.filter { !$0.isStale(now: now, ttl: ttl) }
        }

        if probeResult.didProbeProcesses {
            cachedProcessPresences = latestProcessProbe
            self.lastProcessProbeAt = now
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
        let sortedFallbacks = Array(fallbackMap.values).sorted { a, b in
            // Process-discovered presences (with pid) come first so they're indexed in baseUI
            // before iTerm tty-only presences try to merge into them.
            (a.pid != nil ? 0 : 1) < (b.pid != nil ? 0 : 1)
        }
        ui = Self.reconcileFallbackPresences(sortedFallbacks, into: ui)
        let (effectiveTabTitleByTTY, effectiveTabTitleBySessionGuid) = Self.effectiveITermTitleMaps(
            didProbeITerm: probeResult.didProbeITerm,
            probeTitleByTTY: probeResult.itermTabTitleByTTY,
            probeTitleBySessionGuid: probeResult.itermTabTitleBySessionGuid,
            cachedTitleByTTY: cachedITermTabTitleByTTY,
            cachedTitleBySessionGuid: cachedITermTabTitleBySessionGuid
        )
        ui = Self.enrichPresencesWithITermTabTitles(
            ui,
            tabTitleByTTY: effectiveTabTitleByTTY,
            tabTitleBySessionGuid: effectiveTabTitleBySessionGuid
        )

        let probedITermPresenceKeys = plannedITermProbePresenceKeys(
            for: ui,
            previousLiveStates: previousLiveStates,
            hasVisibleConsumer: shouldProbeITermSnapshot,
            appIsActive: appIsActiveSnapshot,
            isCockpitVisible: isCockpitVisibleSnapshot,
            isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
        )

        let classification = await classifyLiveStatesAsync(
            for: ui,
            generation: generation,
            now: now,
            probeITerm: shouldUseITermSnapshot,
            timeout: Self.processProbeTimeout,
            previousLiveStates: previousLiveStates,
            probedITermPresenceKeys: probedITermPresenceKeys
        )
        let nextLiveStates = classification.liveStates
        let rawIdleReasons = classification.idleReasons
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return
        }
        let nextLastActivityByPresenceKey = Self.lastActivityByPresenceKey(for: ui)

        lastRefreshAt = now

        let cockpitRecentlyVisible = lastCockpitVisibleAt.map { now.timeIntervalSince($0) < 10 } ?? false
        let cockpitIsOrWasVisible = isCockpitVisibleSnapshot || isPinnedCockpitVisibleSnapshot || cockpitRecentlyVisible
        let baseSuppressEmptyPublish = Self.shouldSuppressTransientEmptyPublish(
            ui: ui,
            cockpitVisible: isCockpitVisibleSnapshot || isPinnedCockpitVisibleSnapshot,
            cockpitRecentlyVisible: cockpitRecentlyVisible,
            didProbeProcesses: probeResult.didProbeProcesses,
            didProbeITerm: probeResult.didProbeITerm,
            registryHadPresences: probeResult.registryHadPresences
        )
        let shouldSuppressRecentTransition = Self.shouldSuppressEmptyTransition(
            uiIsEmpty: ui.isEmpty,
            hadPreviouslyPublishedPresences: !lastPublishedPresenceSignatures.isEmpty,
            cockpitIsOrWasVisible: cockpitIsOrWasVisible,
            consecutiveSuppressedCycles: consecutiveEmptySuppressedCycles
        )
        let shouldSuppressEmptyPublish = baseSuppressEmptyPublish || shouldSuppressRecentTransition
        if shouldSuppressEmptyPublish, ui.isEmpty {
            consecutiveEmptySuppressedCycles += 1
        } else {
            consecutiveEmptySuppressedCycles = 0
        }

        if !shouldSuppressEmptyPublish {
            bySessionID = sessionMap
            byLogPath = logMap
            liveStateByPresenceKey = nextLiveStates
            lastActivityByPresenceKey = nextLastActivityByPresenceKey

            // Sync idle reasons: remove stale entries, update current ones.
            let idleKeys = Set(rawIdleReasons.keys)
            for key in Array(idleReasonByPresenceKey.keys) where !idleKeys.contains(key) {
                idleReasonByPresenceKey.removeValue(forKey: key)
            }
            for (key, reason) in rawIdleReasons {
                idleReasonByPresenceKey[key] = reason
            }
        }

        let nextLogKeys = Set(logMap.keys)
        let nextSessionKeys = Set(sessionMap.keys)
        let membershipChanged = (nextLogKeys != previousLogKeys) || (nextSessionKeys != previousSessionKeys)
        let liveStateChanged = nextLiveStates != previousLiveStates

        // Ignore lastSeenAt-only churn; only publish when stable fields that affect UI change.
        let nextSignatures = Self.stablePresenceSignatures(for: ui)
        let metadataChanged = nextSignatures != lastPublishedPresenceSignatures
        let stateChanged = Self.shouldResetStablePollBackoff(
            membershipChanged: membershipChanged,
            liveStateChanged: liveStateChanged,
            metadataChanged: metadataChanged
        )

        if !shouldSuppressEmptyPublish, (membershipChanged || metadataChanged || liveStateChanged) {
            presences = ui.sorted(by: { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) })
            lastPublishedPresenceSignatures = nextSignatures
            activeMembershipVersion &+= 1
        }

        let shouldTrackRuntimeSubagentBadges = (isCockpitVisibleSnapshot || isPinnedCockpitVisibleSnapshot)
            && ui.contains(where: { $0.source == .codex })
        if shouldTrackRuntimeSubagentBadges {
            let nextRuntimeSubagentCountsByPresenceKey = Self.runtimeCodexSubagentCountsByPresenceKey(
                presences: ui,
                stateDBURL: nil
            )
            if nextRuntimeSubagentCountsByPresenceKey != lastPublishedRuntimeSubagentCountsByPresenceKey {
                lastPublishedRuntimeSubagentCountsByPresenceKey = nextRuntimeSubagentCountsByPresenceKey
                subagentBadgeVersion &+= 1
            }
        }

        if stateChanged {
            resetStablePollBackoff()
        } else {
            consecutiveStableCycles = min(consecutiveStableCycles + 1, 1_000_000)
        }
#if DEBUG
        let refreshDurationMs = Date().timeIntervalSince(refreshStartedAt) * 1000.0
        debugMetrics.refreshCount &+= 1
        debugMetrics.refreshTotalDurationMs += refreshDurationMs
        debugMetrics.refreshMaxDurationMs = max(debugMetrics.refreshMaxDurationMs, refreshDurationMs)
        if probeResult.didProbeProcesses {
            debugMetrics.processProbeRuns &+= 1
            if probeResult.registryHadPresences {
                debugMetrics.processProbeRegistryPresentRuns &+= 1
            } else {
                debugMetrics.processProbeRegistryEmptyRuns &+= 1
            }
        } else {
            debugMetrics.processProbeSkips &+= 1
        }
        if shouldSuppressEmptyPublish {
            debugMetrics.suppressedTransientEmptyPublishes &+= 1
        }
        if Self.debugPerfLoggingEnabled, refreshDurationMs > 25 {
            print("[CodexActiveSessionsModel][perf] refreshOnce took \(String(format: "%.1f", refreshDurationMs))ms processProbed=\(probeResult.didProbeProcesses) itermProbed=\(probeResult.didProbeITerm) registryHadPresences=\(probeResult.registryHadPresences) loaded=\(loaded.count) itermTailProbed=\(probedITermPresenceKeys.count)")
        }
        if Self.debugPerfLoggingEnabled {
            maybeReportDebugMetrics(now: now)
        }
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

    private func opencodeSessionsRoots() -> [URL] {
        let defaults = UserDefaults.standard
        let override = defaults.string(forKey: PreferencesKey.Paths.opencodeSessionsRootOverride)
            ?? defaults.string(forKey: "OpenCodeSessionsRootOverride")
            ?? ""
        let discovery = OpenCodeSessionDiscovery(customRoot: override.isEmpty ? nil : override)
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
        case .codex, .claude, .opencode:
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
            t.tabTitle = prefer(t.tabTitle, other?.tabTitle)
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

    nonisolated static func activeSubagentCounts(
        presences: [CodexActivePresence],
        sessionsByLogPath: [String: Session],
        now: Date,
        recentWriteWindow: TimeInterval = subagentRecentWriteWindow,
        codexRuntimeStateDBURL: URL? = nil
    ) -> [String: Int] {
        let cutoff = now.addingTimeInterval(-recentWriteWindow)
        let fm = FileManager.default
        var counts: [String: Int] = [:]
        let codexRuntimeSnapshot = codexOpenSubagentSnapshot(stateDBURL: codexRuntimeStateDBURL)

        for presence in presences where presence.source == .claude {
            guard let logPath = presence.sessionLogPath else { continue }
            guard let parentRef = activeSubagentSessionRef(
                forLogPath: logPath,
                source: .claude,
                sessionsByLogPath: sessionsByLogPath
            ) else {
                continue
            }

            let logURL = URL(fileURLWithPath: logPath)
            let subagentsDir = logURL
                .deletingLastPathComponent()
                .appendingPathComponent(logURL.deletingPathExtension().lastPathComponent)
                .appendingPathComponent("subagents")
            guard fm.fileExists(atPath: subagentsDir.path) else { continue }
            guard let contents = try? fm.contentsOfDirectory(
                at: subagentsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            let activeCount = contents.reduce(into: 0) { partialResult, file in
                guard file.pathExtension == "jsonl" else { return }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime > cutoff {
                    partialResult += 1
                }
            }
            if activeCount > 0 {
                for key in parentRef.lookupKeys {
                    counts[key] = max(counts[key] ?? 0, activeCount)
                }
            }
        }

        for presence in presences where presence.source == .codex {
            let resolved = resolveCodexSubagentPresence(presence, sessionsByLogPath: sessionsByLogPath)
            let runtimeKeys = resolved.runtimeLookupIDs
            if codexRuntimeSnapshot.isAvailable {
                let activeCount = runtimeKeys.compactMap { codexRuntimeSnapshot.countsByParentThreadID[$0] }.max() ?? 0
                if activeCount > 0 {
                    let lookupKeys = resolved.parentRef?.lookupKeys ?? runtimeKeys
                    for key in lookupKeys {
                        counts[key] = max(counts[key] ?? 0, activeCount)
                    }
                }
                continue
            }

            guard resolved.resolvedPaths.count > 1 else { continue }
            let fallbackParentRef = resolved.parentRef
            guard let fallbackParentRef else { continue }

            let parentIDs = Set(fallbackParentRef.runtimeIDs)
            var activeCount = 0

            for resolvedPath in resolved.resolvedPaths {
                guard let childRef = resolvedPath.ref else { continue }
                if !fallbackParentRef.sessionID.isEmpty, childRef.sessionID == fallbackParentRef.sessionID { continue }
                guard let rawParentID = childRef.parentSessionID, parentIDs.contains(rawParentID) else { continue }
                let mtime = modificationDateForPath(resolvedPath.path) ?? .distantPast
                if mtime > cutoff {
                    activeCount += 1
                }
            }

            if activeCount > 0 {
                for key in fallbackParentRef.lookupKeys {
                    counts[key] = max(counts[key] ?? 0, activeCount)
                }
            }
        }

        for presence in presences where presence.source == .opencode {
            let uniquePaths = uniqueSessionLogPaths(from: presence.openSessionLogPaths)
            guard uniquePaths.count > 1 else { continue }

            let resolvedPaths = uniquePaths.map { path in
                (
                    path: path,
                    ref: activeSubagentSessionRef(
                        forLogPath: path,
                        source: presence.source,
                        sessionsByLogPath: sessionsByLogPath
                    )
                )
            }

            let parentRef = resolvedPaths.first(where: { $0.ref?.parentSessionID == nil })?.ref
                ?? presence.sessionLogPath.flatMap {
                    activeSubagentSessionRef(
                        forLogPath: $0,
                        source: presence.source,
                        sessionsByLogPath: sessionsByLogPath
                    )
                }
            guard let parentRef else { continue }

            let parentIDs = Set(parentRef.runtimeIDs)
            var activeCount = 0

            for resolved in resolvedPaths {
                guard let childRef = resolved.ref else { continue }
                if !parentRef.sessionID.isEmpty, childRef.sessionID == parentRef.sessionID { continue }
                guard let rawParentID = childRef.parentSessionID, parentIDs.contains(rawParentID) else { continue }
                let mtime = modificationDateForPath(resolved.path) ?? .distantPast
                if mtime > cutoff {
                    activeCount += 1
                }
            }

            if activeCount > 0 {
                for key in parentRef.lookupKeys {
                    counts[key] = max(counts[key] ?? 0, activeCount)
                }
            }
        }

        return counts
    }

    private struct CodexOpenSubagentSnapshot {
        let isAvailable: Bool
        let countsByParentThreadID: [String: Int]
    }

    private struct CodexRuntimeOpenSubagentEdge {
        let parentThreadID: String
        let childThreadID: String
    }

    nonisolated private static func codexOpenSubagentSnapshot(stateDBURL: URL? = nil) -> CodexOpenSubagentSnapshot {
        guard let dbURL = resolvedCodexRuntimeStateDBURL(explicitURL: stateDBURL) else {
            return CodexOpenSubagentSnapshot(isAvailable: false, countsByParentThreadID: [:])
        }
        guard let edges = readCodexRuntimeOpenSubagentEdges(from: dbURL) else {
            return CodexOpenSubagentSnapshot(isAvailable: false, countsByParentThreadID: [:])
        }
        var counts: [String: Int] = [:]
        for edge in edges {
            let parentThreadID = cleanedSessionIdentifier(edge.parentThreadID) ?? edge.parentThreadID
            counts[parentThreadID, default: 0] += 1
        }
        return CodexOpenSubagentSnapshot(isAvailable: true, countsByParentThreadID: counts)
    }

    nonisolated private static func runtimeCodexSubagentCountsByPresenceKey(presences: [CodexActivePresence],
                                                                            stateDBURL: URL? = nil) -> [String: Int] {
        let runtimeSnapshot = codexOpenSubagentSnapshot(stateDBURL: stateDBURL)
        guard runtimeSnapshot.isAvailable else { return [:] }

        var countsByPresenceKey: [String: Int] = [:]
        for presence in presences where presence.source == .codex {
            // This path only needs runtime thread IDs for badge counts. It runs
            // after `runtimeSnapshot.isAvailable`, so session log path fallback is
            // intentionally skipped here.
            let runtimeIDs = resolveCodexSubagentPresence(presence, sessionsByLogPath: [:]).runtimeLookupIDs
            guard !runtimeIDs.isEmpty else { continue }
            let activeCount = runtimeIDs.compactMap { runtimeSnapshot.countsByParentThreadID[$0] }.max() ?? 0
            guard activeCount > 0 else { continue }
            countsByPresenceKey[presenceKey(for: presence)] = activeCount
        }
        return countsByPresenceKey
    }

    nonisolated private static func resolvedCodexRuntimeStateDBURL(explicitURL: URL?) -> URL? {
        if let explicitURL { return explicitURL }
        for codexRoot in codexRuntimeRoots() {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: codexRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            let newestStateDB = urls
                .filter { url in
                    let name = url.lastPathComponent
                    return name.hasPrefix("state_") && name.hasSuffix(".sqlite")
                }
                .sorted { lhs, rhs in
                    let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if leftDate != rightDate { return leftDate > rightDate }
                    return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedDescending
                }
                .first
            if let newestStateDB {
                return newestStateDB
            }
        }
        return nil
    }

    nonisolated private static func codexRuntimeRoots() -> [URL] {
        var candidates: [URL] = []

        if let sessionsOverride = UserDefaults.standard.string(forKey: "SessionsRootOverride"),
           let sessionsURL = parseNonisolatedPath(sessionsOverride) {
            candidates.append(sessionsURL.deletingLastPathComponent())
        }

        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"],
           let envURL = parseNonisolatedPath(env) {
            candidates.append(envURL)
        }

        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
        var roots: [URL] = []
        var seen: Set<String> = []
        for url in candidates {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                roots.append(url)
            }
        }
        return roots
    }

    nonisolated private static func parseNonisolatedPath(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    nonisolated private static func readCodexRuntimeOpenSubagentEdges(from dbURL: URL) -> [CodexRuntimeOpenSubagentEdge]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT parent_thread_id, child_thread_id
            FROM thread_spawn_edges
            WHERE status = 'open';
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var edges: [CodexRuntimeOpenSubagentEdge] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            let parentThreadID = textColumn(stmt, 0)
            let childThreadID = textColumn(stmt, 1)
            if !parentThreadID.isEmpty, !childThreadID.isEmpty {
                edges.append(CodexRuntimeOpenSubagentEdge(
                    parentThreadID: parentThreadID,
                    childThreadID: childThreadID
                ))
            }
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else { return nil }
        return edges
    }

    nonisolated private static func textColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    nonisolated private static func cleanedSessionIdentifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    nonisolated private static func sessionForLogPath(_ rawPath: String,
                                                      source: SessionSource,
                                                      sessionsByLogPath: [String: Session]) -> Session? {
        let normalizedPath = normalizePath(rawPath)
        guard !normalizedPath.isEmpty else { return nil }
        let key = logLookupKey(source: source, normalizedPath: normalizedPath)
        return sessionsByLogPath[key]
    }

    private struct ActiveSubagentSessionRef {
        let sessionID: String
        let parentSessionID: String?
        let lookupKeys: [String]
        let runtimeIDs: [String]
    }

    private typealias ResolvedActiveSubagentPath = (path: String, ref: ActiveSubagentSessionRef?)

    private struct CodexSubagentPresenceResolution {
        let resolvedPaths: [ResolvedActiveSubagentPath]
        let parentRef: ActiveSubagentSessionRef?
        let runtimeLookupIDs: [String]
    }

    nonisolated private static func resolveCodexSubagentPresence(_ presence: CodexActivePresence,
                                                                 sessionsByLogPath: [String: Session]) -> CodexSubagentPresenceResolution {
        let primaryRef = presence.sessionLogPath.flatMap {
            activeSubagentSessionRef(
                forLogPath: $0,
                source: .codex,
                sessionsByLogPath: sessionsByLogPath
            )
        }
        var candidatePaths = presence.openSessionLogPaths
        if let primaryPath = presence.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !primaryPath.isEmpty {
            candidatePaths.insert(primaryPath, at: 0)
        }

        let uniquePaths = uniqueSessionLogPaths(from: candidatePaths)
        let resolvedPaths: [ResolvedActiveSubagentPath] = uniquePaths.map { path in
            (
                path: path,
                ref: activeSubagentSessionRef(
                    forLogPath: path,
                    source: .codex,
                    sessionsByLogPath: sessionsByLogPath
                )
            )
        }

        let parentRef = resolvedPaths.first(where: { $0.ref?.parentSessionID == nil })?.ref
            ?? primaryRef
        let runtimeKeyCandidates = parentRef?.runtimeIDs
            ?? [presence.sessionId, presence.sessionLogPath.flatMap {
                extractSessionID(fromLogPath: $0, source: .codex)
            }].compactMap { $0 }
        let runtimeLookupIDs = Array(Set(runtimeKeyCandidates.compactMap { cleanedSessionIdentifier($0) }))

        return CodexSubagentPresenceResolution(
            resolvedPaths: resolvedPaths,
            parentRef: parentRef,
            runtimeLookupIDs: runtimeLookupIDs
        )
    }

    nonisolated private static func activeSubagentSessionRef(forLogPath rawPath: String,
                                                             source: SessionSource,
                                                             sessionsByLogPath: [String: Session]) -> ActiveSubagentSessionRef? {
        if let session = sessionForLogPath(rawPath, source: source, sessionsByLogPath: sessionsByLogPath) {
            let runtimeIDs = liveSessionIDCandidates(for: session)
            let lookupKeys = Array(Set([session.id] + runtimeIDs))
            return ActiveSubagentSessionRef(
                sessionID: session.id,
                parentSessionID: session.parentSessionID,
                lookupKeys: lookupKeys,
                runtimeIDs: runtimeIDs.isEmpty ? [session.id] : runtimeIDs
            )
        }

        guard let parsed = parseActiveSubagentSessionMeta(fromLogPath: rawPath, source: source) else {
            return nil
        }
        let runtimeIDs = Array(Set([parsed.runtimeSessionID, extractSessionID(fromLogPath: rawPath, source: source)].compactMap { $0 }))
        let lookupKeys = runtimeIDs
        return ActiveSubagentSessionRef(
            sessionID: parsed.runtimeSessionID,
            parentSessionID: parsed.parentSessionID,
            lookupKeys: lookupKeys,
            runtimeIDs: runtimeIDs.isEmpty ? [parsed.runtimeSessionID] : runtimeIDs
        )
    }

    private struct ParsedActiveSubagentSessionMeta {
        let runtimeSessionID: String
        let parentSessionID: String?
    }

    nonisolated private static func parseActiveSubagentSessionMeta(fromLogPath rawPath: String,
                                                                   source: SessionSource) -> ParsedActiveSubagentSessionMeta? {
        guard source == .codex || source == .opencode else { return nil }
        let reader = JSONLReader(url: URL(fileURLWithPath: rawPath))
        var parsed: ParsedActiveSubagentSessionMeta?
        _ = try? reader.forEachLineWhile { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "session_meta",
                  let payload = obj["payload"] as? [String: Any] else {
                return true
            }

            let runtimeSessionID = (payload["id"] as? String)
                ?? (payload["session_id"] as? String)
                ?? (obj["session_id"] as? String)
            guard let runtimeSessionID, !runtimeSessionID.isEmpty else { return false }

            var parentSessionID: String?
            if let sourceMeta = payload["source"] as? [String: Any],
               let subagentInfo = sourceMeta["subagent"] as? [String: Any],
               let threadSpawn = subagentInfo["thread_spawn"] as? [String: Any] {
                parentSessionID = threadSpawn["parent_thread_id"] as? String
            }

            parsed = ParsedActiveSubagentSessionMeta(
                runtimeSessionID: runtimeSessionID,
                parentSessionID: parentSessionID
            )
            return false
        }
        return parsed
    }

    nonisolated private static func uniqueSessionLogPaths(from rawPaths: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        out.reserveCapacity(rawPaths.count)
        for rawPath in rawPaths {
            let normalizedPath = normalizePath(rawPath)
            guard !normalizedPath.isEmpty else { continue }
            if seen.insert(normalizedPath).inserted {
                out.append(rawPath)
            }
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
        let accessTick = nextSessionLookupAccessTick()
        if var cached = sessionLookupCacheByID[session.id],
           cached.source == session.source,
           cached.rawFilePath == session.filePath,
           cached.internalSessionIDHint == internalSessionIDHint,
           cached.runtimeSessionIDs == runtimeSessionIDs {
            cached.lastAccessTick = accessTick
            sessionLookupCacheByID[session.id] = cached
            return cached
        }
        let fresh = SessionLookupCacheEntry(
            source: session.source,
            rawFilePath: session.filePath,
            normalizedLogPath: Self.normalizePath(session.filePath),
            internalSessionIDHint: internalSessionIDHint,
            filenameUUID: session.codexFilenameUUID,
            runtimeSessionIDs: runtimeSessionIDs,
            lastAccessTick: accessTick
        )
        sessionLookupCacheByID[session.id] = fresh
        pruneSessionLookupCacheIfNeeded()
        return fresh
    }

    private func nextSessionLookupAccessTick() -> UInt64 {
        sessionLookupAccessTick &+= 1
        return sessionLookupAccessTick
    }

    private func pruneSessionLookupCacheIfNeeded() {
        guard sessionLookupCacheByID.count > Self.sessionLookupCacheHardLimit else { return }
        let removeCount = sessionLookupCacheByID.count - Self.sessionLookupCacheTargetSize
        guard removeCount > 0 else { return }
        let idsToRemove = sessionLookupCacheByID
            .sorted { lhs, rhs in
                if lhs.value.lastAccessTick == rhs.value.lastAccessTick {
                    return lhs.key < rhs.key
                }
                return lhs.value.lastAccessTick < rhs.value.lastAccessTick
            }
            .prefix(removeCount)
            .map(\.key)
        for id in idsToRemove {
            sessionLookupCacheByID.removeValue(forKey: id)
        }
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

    private func armForegroundProbeRamp() {
        guard hasVisibleConsumer else { return }
        resumeProbeBudgetIndex = 0
        resetStablePollBackoff()
    }

    private func resetStablePollBackoff() {
        consecutiveStableCycles = 0
    }

    private func plannedITermProbePresenceKeys(for presences: [CodexActivePresence],
                                               previousLiveStates: [String: CodexLiveState],
                                               hasVisibleConsumer: Bool,
                                               appIsActive: Bool,
                                               isCockpitVisible: Bool,
                                               isPinnedCockpitVisible: Bool) -> Set<String> {
        guard hasVisibleConsumer else { return [] }
        let candidates = Self.itermProbeCandidateKeys(for: presences).sorted()
        guard !candidates.isEmpty else { return [] }

        if forceFullProbeNextRefresh {
            forceFullProbeNextRefresh = false
            resumeProbeBudgetIndex = nil
            itermProbeRoundRobinCursor = candidates.count == 0 ? 0 : (itermProbeRoundRobinCursor % candidates.count)
            return Set(candidates)
        }

        if !appIsActive, (isPinnedCockpitVisible || isCockpitVisible) {
            let selection = Self.selectPinnedBackgroundITermProbeKeys(
                sortedCandidateKeys: candidates,
                previousLiveStates: previousLiveStates,
                waitingBudget: Self.pinnedBackgroundWaitingITermProbeBudget,
                start: itermProbeRoundRobinCursor
            )
            itermProbeRoundRobinCursor = selection.nextCursor
            return Set(selection.selected)
        }

        let budget = nextITermProbeBudget()
        let selection = Self.selectRoundRobinKeys(
            sortedKeys: candidates,
            start: itermProbeRoundRobinCursor,
            budget: budget
        )
        itermProbeRoundRobinCursor = selection.nextCursor
        return Set(selection.selected)
    }

    private func nextITermProbeBudget() -> Int {
        let next = Self.nextITermProbeBudget(resumeIndex: resumeProbeBudgetIndex)
        resumeProbeBudgetIndex = next.nextResumeIndex
        return next.budget
    }

    private func pollIntervalSeconds() -> TimeInterval {
        let baseInterval = Self.effectivePollIntervalSeconds(
            appIsActive: appIsActive,
            hasVisibleConsumer: hasVisibleConsumer,
            isCockpitVisible: isCockpitVisible,
            isPinnedCockpitVisible: isPinnedCockpitVisible
        )
        return Self.effectiveStableBackoffPollInterval(
            baseInterval: baseInterval,
            consecutiveStableCycles: consecutiveStableCycles,
            appIsActive: appIsActive,
            isCockpitVisible: isCockpitVisible,
            isPinnedCockpitVisible: isPinnedCockpitVisible
        )
    }

    nonisolated static func effectivePollIntervalSeconds(appIsActive: Bool,
                                                         hasVisibleConsumer: Bool,
                                                         isCockpitVisible: Bool,
                                                         isPinnedCockpitVisible: Bool) -> TimeInterval {
        guard appIsActive else {
            if isPinnedCockpitVisible || isCockpitVisible {
                return Self.pinnedBackgroundPollInterval
            }
            return Self.backgroundPollInterval
        }
        return hasVisibleConsumer ? Self.defaultPollInterval : Self.backgroundPollInterval
    }

    nonisolated static func shouldProbeITermSessions(appIsActive: Bool,
                                                     hasVisibleConsumer: Bool,
                                                     isCockpitVisible: Bool,
                                                     isPinnedCockpitVisible: Bool) -> Bool {
        guard hasVisibleConsumer else { return false }
        return appIsActive || isPinnedCockpitVisible || isCockpitVisible
    }

    nonisolated static func effectiveStableBackoffPollInterval(baseInterval: TimeInterval,
                                                               consecutiveStableCycles: Int,
                                                               appIsActive: Bool,
                                                               isCockpitVisible: Bool,
                                                               isPinnedCockpitVisible: Bool) -> TimeInterval {
        guard !appIsActive, (isPinnedCockpitVisible || isCockpitVisible) else { return baseInterval }
        guard consecutiveStableCycles >= Self.stableBackoffActivationCycles else { return baseInterval }
        return max(
            Self.stablePinnedBackgroundPollInterval,
            baseInterval
        )
    }

    nonisolated static func shouldResetStablePollBackoff(membershipChanged: Bool,
                                                         liveStateChanged: Bool,
                                                         metadataChanged: Bool) -> Bool {
        membershipChanged || liveStateChanged || metadataChanged
    }

    nonisolated static func nextITermProbeBudget(resumeIndex: Int?) -> (budget: Int, nextResumeIndex: Int?) {
        guard let resumeIndex else {
            return (Self.steadyStateITermProbeBudget, nil)
        }
        guard !Self.resumeProbeBudgets.isEmpty else {
            return (Self.steadyStateITermProbeBudget, nil)
        }
        let bounded = max(0, min(resumeIndex, Self.resumeProbeBudgets.count - 1))
        let budget = Self.resumeProbeBudgets[bounded]
        let next: Int? = (bounded + 1 < Self.resumeProbeBudgets.count) ? (bounded + 1) : nil
        return (budget, next)
    }

    nonisolated static func selectRoundRobinKeys(sortedKeys: [String],
                                                 start: Int,
                                                 budget: Int) -> (selected: [String], nextCursor: Int) {
        guard !sortedKeys.isEmpty else { return ([], 0) }
        let normalizedBudget = max(1, budget)
        let cappedBudget = min(sortedKeys.count, normalizedBudget)
        var out: [String] = []
        out.reserveCapacity(cappedBudget)

        let startIndex = ((start % sortedKeys.count) + sortedKeys.count) % sortedKeys.count
        for offset in 0..<cappedBudget {
            let index = (startIndex + offset) % sortedKeys.count
            out.append(sortedKeys[index])
        }
        let next = (startIndex + cappedBudget) % sortedKeys.count
        return (out, next)
    }

    nonisolated static func selectPinnedBackgroundITermProbeKeys(sortedCandidateKeys: [String],
                                                                 previousLiveStates: [String: CodexLiveState],
                                                                 waitingBudget: Int,
                                                                 start: Int) -> (selected: [String], nextCursor: Int) {
        guard !sortedCandidateKeys.isEmpty else { return ([], 0) }

        let activeKeys = sortedCandidateKeys.filter { previousLiveStates[$0] == .activeWorking }
        let waitingKeys = sortedCandidateKeys.filter { previousLiveStates[$0] != .activeWorking }
        guard !waitingKeys.isEmpty else { return (activeKeys, 0) }

        let waitingSelection = selectRoundRobinKeys(
            sortedKeys: waitingKeys,
            start: start,
            budget: waitingBudget
        )
        return (activeKeys + waitingSelection.selected, waitingSelection.nextCursor)
    }

    nonisolated static func itermProbeCandidateKeys(for presences: [CodexActivePresence]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(presences.count)
        for presence in presences {
            guard presence.source == .codex || presence.source == .claude || presence.source == .opencode else { continue }
            guard canAttemptITerm2TailProbe(
                itermSessionId: presence.terminal?.itermSessionId,
                tty: presence.tty,
                termProgram: presence.terminal?.termProgram
            ) else { continue }
            let key = presenceKey(for: presence)
            if key == "unknown" { continue }
            out.append(key)
        }
        return out
    }

    nonisolated static func shouldSuppressTransientEmptyPublish(ui: [CodexActivePresence],
                                                                cockpitVisible: Bool,
                                                                cockpitRecentlyVisible: Bool = false,
                                                                didProbeProcesses: Bool,
                                                                didProbeITerm: Bool,
                                                                registryHadPresences: Bool) -> Bool {
        guard cockpitVisible || cockpitRecentlyVisible else { return false }
        guard ui.isEmpty else { return false }
        guard !registryHadPresences else { return true }
        return !(didProbeProcesses && didProbeITerm)
    }

    /// Supplementary suppression: when presences transition from non-empty to empty
    /// while the cockpit is visible, suppress for a few cycles to ride out transient
    /// probe failures (lsof timing, AppleScript timeout, registry I/O race).
    /// Unlike `resetStablePollBackoff()`, the cycle counter is intentionally NOT
    /// reset during visibility or activation transitions — those are exactly the
    /// moments where transient empty results are most likely.
    nonisolated static func shouldSuppressEmptyTransition(
        uiIsEmpty: Bool,
        hadPreviouslyPublishedPresences: Bool,
        cockpitIsOrWasVisible: Bool,
        consecutiveSuppressedCycles: Int,
        maxSuppressedCycles: Int = 3
    ) -> Bool {
        guard uiIsEmpty else { return false }
        guard hadPreviouslyPublishedPresences else { return false }
        guard cockpitIsOrWasVisible else { return false }
        return consecutiveSuppressedCycles < maxSuppressedCycles
    }

    /// When the iTerm probe ran but returned empty title maps (transient AppleScript
    /// failure), fall back to preserved cached maps to avoid a "—" flash. A probe
    /// that returns GUID-keyed titles but no TTY-keyed titles is NOT a failure —
    /// only fall back when both maps are empty.
    nonisolated static func effectiveITermTitleMaps(
        didProbeITerm: Bool,
        probeTitleByTTY: [String: String],
        probeTitleBySessionGuid: [String: String],
        cachedTitleByTTY: [String: String],
        cachedTitleBySessionGuid: [String: String]
    ) -> (tty: [String: String], guid: [String: String]) {
        if didProbeITerm, probeTitleByTTY.isEmpty, probeTitleBySessionGuid.isEmpty {
            return (cachedTitleByTTY, cachedTitleBySessionGuid)
        }
        return (probeTitleByTTY, probeTitleBySessionGuid)
    }

    nonisolated static func effectiveCachedProcessPresenceTTL(baseTTL: TimeInterval,
                                                              processProbeMinInterval: TimeInterval,
                                                              pollInterval: TimeInterval,
                                                              hasVisibleConsumer: Bool) -> TimeInterval {
        let normalizedBaseTTL = max(0, baseTTL)
        guard hasVisibleConsumer else { return normalizedBaseTTL }

        // Keep cached process presences alive through deferred-probe windows so
        // pinned/background UI does not oscillate between partial and full rows.
        // When the probe interval exceeds the base TTL (deferred-probe modes like
        // pinned/background), use 2x the probe interval to survive a missed or
        // delayed cycle. In foreground mode (short probe intervals), the base TTL
        // already provides sufficient coverage.
        let normalizedProbeInterval = max(0, processProbeMinInterval)
        let normalizedPollInterval = max(0, pollInterval)
        let baseBridge = normalizedProbeInterval + normalizedPollInterval
        let bridgedTTL = normalizedProbeInterval > normalizedBaseTTL
            ? normalizedProbeInterval * 2 + normalizedPollInterval
            : baseBridge
        return max(normalizedBaseTTL, bridgedTTL)
    }

    nonisolated static func processProbeMinIntervalSeconds(registryHasPresences: Bool,
                                                           hasVisibleConsumer: Bool,
                                                           appIsActive: Bool,
                                                           isCockpitVisible: Bool,
                                                           isPinnedCockpitVisible: Bool) -> TimeInterval {
        if hasVisibleConsumer {
            if appIsActive {
                return Self.processProbeMinIntervalRegistryEmptyForeground
            }
            if isPinnedCockpitVisible || isCockpitVisible {
                return Self.pinnedBackgroundProcessProbeMinInterval
            }
            return registryHasPresences
                ? Self.processProbeMinIntervalRegistryPresentBackground
                : Self.processProbeMinIntervalRegistryEmptyBackground
        }
        if registryHasPresences {
            return appIsActive
                ? Self.processProbeMinIntervalRegistryPresentForeground
                : Self.processProbeMinIntervalRegistryPresentBackground
        }
        if appIsActive { return Self.processProbeMinIntervalRegistryEmptyBackground }
        return Self.processProbeMinIntervalRegistryEmptyBackground
    }

    nonisolated static func itermProbeMinIntervalSeconds(appIsActive: Bool,
                                                         isCockpitVisible: Bool,
                                                         isPinnedCockpitVisible: Bool) -> TimeInterval {
        guard !appIsActive else { return 0 }
        if isPinnedCockpitVisible || isCockpitVisible {
            return Self.pinnedBackgroundITermProbeMinInterval
        }
        return Self.backgroundPollInterval
    }

#if DEBUG
    struct DebugPerformanceSnapshot {
        let refreshGeneration: UInt64
        let staleRefreshResultsDropped: UInt64
        let terminatedStaleProbeProcesses: UInt64
        let currentProcessProbes: Int
        let currentITermScans: Int
        let currentITermBatchProbes: Int
        let maxConcurrentRefreshes: Int
        let maxConcurrentProcessProbes: Int
        let maxConcurrentITermScans: Int
        let maxConcurrentITermBatchProbes: Int
    }

    func debugPerformanceSnapshot() -> DebugPerformanceSnapshot {
        DebugPerformanceSnapshot(
            refreshGeneration: activeRefreshGeneration,
            staleRefreshResultsDropped: debugMetrics.staleRefreshResultsDropped,
            terminatedStaleProbeProcesses: debugMetrics.terminatedStaleProbeProcesses,
            currentProcessProbes: debugMetrics.currentProcessProbes,
            currentITermScans: debugMetrics.currentITermScans,
            currentITermBatchProbes: debugMetrics.currentITermBatchProbes,
            maxConcurrentRefreshes: debugMetrics.maxConcurrentRefreshes,
            maxConcurrentProcessProbes: debugMetrics.maxConcurrentProcessProbes,
            maxConcurrentITermScans: debugMetrics.maxConcurrentITermScans,
            maxConcurrentITermBatchProbes: debugMetrics.maxConcurrentITermBatchProbes
        )
    }

    static func debugProbeKindName(for kind: String) -> String {
        kind
    }

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
            "suppressedTransientEmptyPublishes=\(debugMetrics.suppressedTransientEmptyPublishes) " +
            "isActiveCalls=\(debugMetrics.isActiveCalls) staleDrops=\(debugMetrics.staleRefreshResultsDropped) " +
            "terminatedStaleProbeProcesses=\(debugMetrics.terminatedStaleProbeProcesses) " +
            "refreshGeneration=\(debugMetrics.latestRefreshGeneration) maxConcurrentRefreshes=\(debugMetrics.maxConcurrentRefreshes) " +
            "processProbeConcurrency=\(debugMetrics.currentProcessProbes)/\(debugMetrics.maxConcurrentProcessProbes) " +
            "iTermScans=\(debugMetrics.currentITermScans)/\(debugMetrics.maxConcurrentITermScans) " +
            "iTermBatchProbes=\(debugMetrics.currentITermBatchProbes)/\(debugMetrics.maxConcurrentITermBatchProbes) " +
            "normalizePathCache hits=\(cache.hits) misses=\(cache.misses)"
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
            parts.reserveCapacity(14)
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
            parts.append(p.terminal?.tabTitle ?? "")
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
            // Pass 1: GUID match only — exact session, no ambiguity
            "if targetGuid is not \"\" then",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "if id of s is targetGuid then",
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
            "end if",
            // Pass 2: TTY fallback — only reached when GUID is absent or stale
            "if targetTTYBase is not \"\" then",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set stty to tty of s",
            "set sttyBase to stty",
            "if sttyBase starts with \"/dev/\" then set sttyBase to text 6 thru -1 of sttyBase",
            "if (stty is targetTTY or stty is targetTTYBase or sttyBase is targetTTYBase) then",
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
            "end if",
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
            process.waitForExit()
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

    private struct LiveStateClassification {
        let liveStates: [String: CodexLiveState]
        let idleReasons: [String: HUDIdleReason]
    }

    nonisolated static func classifyIdleReason(
        tail: String?,
        source: SessionSource,
        lastActivityAt: Date?,
        now: Date
    ) -> HUDIdleReason {
        // Error/stuck: idle for >30 minutes with no detected prompt
        if let lastActivity = lastActivityAt,
           now.timeIntervalSince(lastActivity) > 30 * 60 {
            let hasPrompt = tailHasPrompt(tail, source: source)
            if !hasPrompt {
                return .errorOrStuck
            }
        }
        return .generic
    }

    nonisolated private static func tailHasPrompt(_ tail: String?, source: SessionSource) -> Bool {
        guard let tail, !tail.isEmpty else { return false }
        if source == .claude {
            return hasLikelyClaudePromptNearBottom(tail)
        }
        let normalized = sanitizeITermTail(tail)
        guard !normalized.isEmpty else { return false }
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return false }
        return nonEmptyLines.suffix(8).contains(where: { isLikelyPromptLine($0) })
    }

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

        // Ambiguous non-prompt Codex tails should defer to heuristic fallback.
        return nil
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
            "esc interrupt",      // OpenCode TUI omits "to"
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
        if let last = trimmed.last, last == "$" || last == "#" || last == "%" {
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
        if let last = trimmed.last, last == "$" || last == "#" {
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

    nonisolated private static func lastActivityByPresenceKey(for presences: [CodexActivePresence]) -> [String: Date] {
        var out: [String: Date] = [:]
        out.reserveCapacity(presences.count)
        for presence in presences {
            let key = presenceKey(for: presence)
            guard key != "unknown" else { continue }
            guard let activity = lastActivityAt(logPath: presence.sessionLogPath, sourceFilePath: presence.sourceFilePath) else {
                continue
            }
            if let existing = out[key], existing >= activity { continue }
            out[key] = activity
        }
        return out
    }

    nonisolated private static func modificationDateForPath(_ rawPath: String?) -> Date? {
        guard let rawPath, !rawPath.isEmpty else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return mtime
    }

    nonisolated private static func lastActivityAt(logPath: String?, sourceFilePath: String?) -> Date? {
        modificationDateForPath(logPath) ?? modificationDateForPath(sourceFilePath)
    }

    nonisolated static func heuristicLiveStateFromLogMTime(logPath: String?,
                                                           sourceFilePath: String? = nil,
                                                           now: Date,
                                                           activeWriteWindow: TimeInterval = 2.5) -> CodexLiveState {
        // Prefer true session log writes when available; source file mtime is a
        // secondary fallback only for providers that omit sessionLogPath.
        let mtime = lastActivityAt(logPath: logPath, sourceFilePath: sourceFilePath)
        guard let mtime else { return .openIdle }
        if now.timeIntervalSince(mtime) <= activeWriteWindow {
            return .activeWorking
        }
        return .openIdle
    }

    nonisolated private static func classifyLiveStates(for presences: [CodexActivePresence],
                                                       now: Date,
                                                       probeITerm: Bool,
                                                       previousLiveStates: [String: CodexLiveState],
                                                       probedITermPresenceKeys: Set<String>,
                                                       batchProbeResults: [String: ITermProbeResult]) -> LiveStateClassification {
        var out: [String: CodexLiveState] = [:]
        var idleOut: [String: HUDIdleReason] = [:]
        out.reserveCapacity(presences.count)

        for presence in presences {
            let key = presenceKey(for: presence)
            guard key != "unknown" else { continue }

            var state: CodexLiveState?
            let probeEligible = probeITerm && canAttemptITerm2TailProbe(
                itermSessionId: presence.terminal?.itermSessionId,
                tty: presence.tty,
                termProgram: presence.terminal?.termProgram
            )
            let shouldProbeThisPresence = probeEligible && probedITermPresenceKeys.contains(key)
            let matchedBatchProbe = batchProbeResults[key]
            if shouldProbeThisPresence, presence.source == .codex {
                if let probe = matchedBatchProbe {
                    if let tail = probe.tail {
                        state = classifyITermTail(tail)
                    } else {
                        // When a session is known to exist in iTerm but tail capture fails transiently,
                        // prefer open/idle over mtime heuristics to avoid false-active spikes.
                        state = .openIdle
                    }
                }
            } else if shouldProbeThisPresence, presence.source == .claude {
                if let probe = matchedBatchProbe {
                    state = resolveClaudeStateFromITermProbe(
                        isProcessing: probe.isProcessing,
                        isAtShellPrompt: probe.isAtShellPrompt,
                        tail: probe.tail
                    )
                }
            } else if shouldProbeThisPresence, presence.source == .opencode {
                if let probe = matchedBatchProbe {
                    // iTerm2 `is processing` is the most reliable signal for
                    // TUI apps running in the alternate screen buffer.
                    if probe.isProcessing == true {
                        state = .activeWorking
                    } else if let tail = probe.tail {
                        state = classifyGenericITermTail(tail)
                    }
                    // No match → fall through to mtime heuristic
                }
            }

            var activeWriteWindow = activeWriteWindow(for: presence.source)
            if presence.source == .codex,
               shouldProbeThisPresence,
               state == nil,
               previousLiveStates[key] == .activeWorking {
                // Short grace window for inconclusive tail probes to avoid active->idle flicker.
                activeWriteWindow = max(activeWriteWindow, codexInconclusiveTailActiveGraceWindow)
            }
            let heuristic = heuristicLiveStateFromLogMTime(
                logPath: presence.sessionLogPath,
                sourceFilePath: presence.sourceFilePath,
                now: now,
                activeWriteWindow: activeWriteWindow
            )
            let resolved = resolveLiveState(
                probedState: state,
                previousState: previousLiveStates[key],
                heuristic: heuristic,
                attemptedITermProbe: shouldProbeThisPresence,
                preservePreviousWhenProbeDeferred: probeEligible && !shouldProbeThisPresence
            )
            if let existing = out[key] {
                if resolved.priority > existing.priority {
                    out[key] = resolved
                }
            } else {
                out[key] = resolved
            }

            // Classify idle reason for presences that resolved as idle.
            if resolved == .openIdle {
                let tail = matchedBatchProbe?.tail
                let activityAt = lastActivityAt(logPath: presence.sessionLogPath, sourceFilePath: presence.sourceFilePath)
                idleOut[key] = classifyIdleReason(
                    tail: tail,
                    source: presence.source,
                    lastActivityAt: activityAt,
                    now: now
                )
            }
        }

        // Remove idle reasons for any key that ended up as active due to priority resolution.
        for key in Array(idleOut.keys) where out[key] == .activeWorking {
            idleOut.removeValue(forKey: key)
        }

        return LiveStateClassification(liveStates: out, idleReasons: idleOut)
    }

    // Internal for targeted unit tests.
    nonisolated static func classifyLiveStatesForTesting(for presences: [CodexActivePresence],
                                                         now: Date,
                                                         probeITerm: Bool,
                                                         previousLiveStates: [String: CodexLiveState],
                                                         probedITermPresenceKeys: Set<String>,
                                                         batchProbeResults: [String: ITermProbeResult]) -> [String: CodexLiveState] {
        classifyLiveStates(
            for: presences,
            now: now,
            probeITerm: probeITerm,
            previousLiveStates: previousLiveStates,
            probedITermPresenceKeys: probedITermPresenceKeys,
            batchProbeResults: batchProbeResults
        ).liveStates
    }

    private struct ITermProbeTarget {
        let presenceKey: String
        let source: SessionSource
        let guid: String
        let tty: String
    }

    nonisolated private static func itermProbeTargets(from presences: [CodexActivePresence],
                                                      selectedPresenceKeys: Set<String>,
                                                      probeITerm: Bool) -> [ITermProbeTarget] {
        guard probeITerm, !selectedPresenceKeys.isEmpty else { return [] }

        var out: [ITermProbeTarget] = []
        out.reserveCapacity(selectedPresenceKeys.count)
        var seenKeys: Set<String> = []

        for presence in presences {
            let key = presenceKey(for: presence)
            guard selectedPresenceKeys.contains(key), seenKeys.insert(key).inserted else { continue }
            guard presence.source == .codex || presence.source == .claude || presence.source == .opencode else { continue }
            let guid = itermSessionGuid(from: presence.terminal?.itermSessionId) ?? ""
            let tty = (presence.tty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !guid.isEmpty || !tty.isEmpty else { continue }
            out.append(
                ITermProbeTarget(
                    presenceKey: key,
                    source: presence.source,
                    guid: guid,
                    tty: tty
                )
            )
        }

        return out
    }

    nonisolated static func resolveLiveState(probedState: CodexLiveState?,
                                             previousState: CodexLiveState?,
                                             heuristic: CodexLiveState,
                                             attemptedITermProbe: Bool,
                                             preservePreviousWhenProbeDeferred: Bool) -> CodexLiveState {
        if let probedState { return probedState }
        if preservePreviousWhenProbeDeferred, !attemptedITermProbe, let previousState { return previousState }
        return heuristic
    }

    nonisolated private static func activeWriteWindow(for source: SessionSource) -> TimeInterval {
        switch source {
        case .codex:
            return 2.5
        case .claude:
            return 15.0
        case .opencode:
            return 30.0
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

    struct ITermProbeResult: Equatable {
        let tail: String?
        let isProcessing: Bool?
        let isAtShellPrompt: Bool?
    }

    private func captureBatchedITermProbeResults(generation: UInt64,
                                                 for targets: [ITermProbeTarget],
                                                 timeout: TimeInterval) async -> [String: ITermProbeResult] {
        guard !targets.isEmpty else { return [:] }

        let rowSeparator = String(UnicodeScalar(0x1E)!)
        let fieldSeparator = String(UnicodeScalar(0x1F)!)
        let scriptLines = [
            "on run argv",
            "set rowSep to character id 30",
            "set fieldSep to character id 31",
            "set outRows to {}",
            "set targetCount to ((count of argv) div 3)",
            "tell application \"iTerm2\"",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sttyBase to stty",
            "if sttyBase starts with \"/dev/\" then set sttyBase to text 6 thru -1 of sttyBase",
            "repeat with idx from 1 to targetCount",
            "set baseIndex to ((idx - 1) * 3)",
            "set presenceKey to item (baseIndex + 1) of argv",
            "set targetGuid to item (baseIndex + 2) of argv",
            "set targetTTY to item (baseIndex + 3) of argv",
            "set targetTTYBase to targetTTY",
            "if targetTTYBase starts with \"/dev/\" then set targetTTYBase to text 6 thru -1 of targetTTYBase",
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
            "set end of outRows to (presenceKey & fieldSep & (processing as string) & fieldSep & (atPrompt as string) & fieldSep & txt)",
            "exit repeat",
            "end if",
            "end repeat",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "set AppleScript's text item delimiters to rowSep",
            "return outRows as text",
            "end run"
        ]

        let arguments = scriptLines.flatMap { ["-e", $0] } + targets.flatMap { target in
            [target.presenceKey, target.guid, target.tty]
        }
        guard let out = await runManagedCommand(
            kind: .iTermBatchProbe,
            generation: generation,
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: arguments,
            timeout: timeout
        ) else {
            return [:]
        }

        let raw = String(decoding: out, as: UTF8.self)
        return Self.parseBatchedITermProbeOutput(raw, rowSeparator: rowSeparator, fieldSeparator: fieldSeparator)
    }

    nonisolated static func parseBatchedITermProbeOutput(_ text: String,
                                                         rowSeparator: String = String(UnicodeScalar(0x1E)!),
                                                         fieldSeparator: String = String(UnicodeScalar(0x1F)!)) -> [String: ITermProbeResult] {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }

        var out: [String: ITermProbeResult] = [:]
        for rawRow in normalized.components(separatedBy: rowSeparator) {
            if rawRow.isEmpty { continue }
            let fields = rawRow.components(separatedBy: fieldSeparator)
            guard fields.count >= 4 else { continue }
            let presenceKey = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !presenceKey.isEmpty else { continue }
            let metadata = parseITermProbeMetadata(fields[1] + "\t" + fields[2])
            let tail = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            out[presenceKey] = ITermProbeResult(
                tail: tail.isEmpty ? nil : tail,
                isProcessing: metadata.isProcessing,
                isAtShellPrompt: metadata.isAtShellPrompt
            )
        }
        return out
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
        let sessions = loadITermSessions(timeout: timeout)
        guard !sessions.isEmpty else { return [] }
        return presencesFromITermSessions(sessions, source: source, now: now)
    }

    private func loadITermSessions(generation: UInt64, timeout: TimeInterval) async -> [ITermSessionInfo] {
        let scriptLines = [
            "set outRows to {}",
            "set sep to (ASCII character 9)",
            "tell application \"iTerm2\"",
            "repeat with w in windows",
            "set wname to name of w",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sname to name of s",
            "set ttitle to \"\"",
            "try",
            "set ttitle to title of t",
            "on error",
            "set ttitle to \"\"",
            "end try",
            "if ttitle is missing value then set ttitle to \"\"",
            "set end of outRows to (sid & sep & stty & sep & sname & sep & ttitle & sep & wname)",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "set AppleScript's text item delimiters to linefeed",
            "return outRows as text"
        ]
        guard let out = await runManagedCommand(
            kind: .iTermInventory,
            generation: generation,
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: scriptLines.flatMap { ["-e", $0] },
            timeout: timeout
        ) else {
            return []
        }
        return Self.parseITermSessionListOutput(String(decoding: out, as: UTF8.self))
    }

    nonisolated private static func loadITermSessions(timeout: TimeInterval) -> [ITermSessionInfo] {
        let scriptLines = [
            "set outRows to {}",
            "set sep to (ASCII character 9)",
            "tell application \"iTerm2\"",
            "repeat with w in windows",
            "set wname to name of w",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sname to name of s",
            "set ttitle to \"\"",
            "try",
            "set ttitle to title of t",
            "on error",
            "set ttitle to \"\"",
            "end try",
            "if ttitle is missing value then set ttitle to \"\"",
            "set end of outRows to (sid & sep & stty & sep & sname & sep & ttitle & sep & wname)",
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
        return parseITermSessionListOutput(raw)
    }

    nonisolated static func presencesFromITermSessions(_ sessions: [ITermSessionInfo],
                                                        source: SessionSource,
                                                        now: Date) -> [CodexActivePresence] {
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
            let trimmedName = (session.displayName ?? session.name).trimmingCharacters(in: .whitespacesAndNewlines)
            t.tabTitle = trimmedName.isEmpty ? nil : trimmedName
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
        var sessionLogFD: Int = Int.max       // Numeric FD of sessionLogPath (for lowest-FD selection)
        var openSessionLogPaths: [String] = []  // All JSONL files open by this PID
        var termProgram: String?
        var itermSessionId: String?
    }

    struct ITermSessionInfo: Equatable, Sendable {
        var sessionID: String
        var tty: String?
        var name: String
        var displayName: String?
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
            let fields = line.components(separatedBy: separator)
            guard fields.count >= 3 else { return nil }

            let sid = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sid.isEmpty else { return nil }
            let ttyRaw = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionName = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let tabName: String
            let windowName: String
            if fields.count > 4 {
                tabName = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
                windowName = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                tabName = ""
                windowName = fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            let matchName = firstNonEmpty([sessionName, tabName, windowName])
            let displayName = preferredITermDisplayName(
                sessionName: sessionName,
                tabName: tabName,
                windowName: windowName
            )
            return ITermSessionInfo(
                sessionID: sid,
                tty: ttyRaw.isEmpty ? nil : ttyRaw,
                name: matchName,
                displayName: displayName
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

    nonisolated private static func firstNonEmpty(_ candidates: [String]) -> String {
        for candidate in candidates {
            if !candidate.isEmpty { return candidate }
        }
        return ""
    }

    nonisolated private static func preferredITermDisplayName(sessionName: String,
                                                              tabName: String,
                                                              windowName: String) -> String? {
        let session = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = tabName.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = windowName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSession = normalizeITermSessionNameForMatching(session)
        let shouldPreferContainerTitle = genericITermSessionNameTokens.contains(normalizedSession)

        if !tab.isEmpty, !equalsIgnoringCaseAndDiacritics(tab, session) {
            return tab
        }
        if shouldPreferContainerTitle,
           !window.isEmpty,
           !equalsIgnoringCaseAndDiacritics(window, session) {
            return window
        }

        let fallback = firstNonEmpty([session, tab, window])
        return fallback.isEmpty ? nil : fallback
    }

    nonisolated private static func equalsIgnoringCaseAndDiacritics(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    nonisolated private static let genericITermSessionNameTokens: Set<String> = [
        "codex",
        "claude",
        "claude code",
        "opencode",
        "open code",
        "zsh",
        "bash",
        "fish",
        "sh",
        "shell"
    ]

    nonisolated static func itermTabTitleByTTY(_ sessions: [ITermSessionInfo]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(sessions.count)
        for session in sessions {
            guard let tty = normalizedTTY(session.tty) else { continue }
            let title = (session.displayName ?? session.name).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            if out[tty] == nil {
                out[tty] = title
            }
        }
        return out
    }

    nonisolated static func itermTabTitleBySessionGuid(_ sessions: [ITermSessionInfo]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(sessions.count)
        for session in sessions {
            guard let guid = itermSessionGuid(from: session.sessionID), !guid.isEmpty else { continue }
            let title = (session.displayName ?? session.name).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            if out[guid] == nil {
                out[guid] = title
            }
        }
        return out
    }

    nonisolated static func enrichPresencesWithITermTabTitles(_ presences: [CodexActivePresence],
                                                              tabTitleByTTY: [String: String],
                                                              tabTitleBySessionGuid: [String: String] = [:]) -> [CodexActivePresence] {
        guard !tabTitleByTTY.isEmpty || !tabTitleBySessionGuid.isEmpty else { return presences }
        var out: [CodexActivePresence] = []
        out.reserveCapacity(presences.count)

        for var presence in presences {
            guard presence.source == .codex || presence.source == .claude || presence.source == .opencode else {
                out.append(presence)
                continue
            }
            let existingTitle = presence.terminal?.tabTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let guid = itermSessionGuid(from: presence.terminal?.itermSessionId)
            let lookupTitle = firstNonEmpty([
                guid.flatMap { tabTitleBySessionGuid[$0] } ?? "",
                normalizedTTY(presence.tty).flatMap { tabTitleByTTY[$0] } ?? ""
            ])
            if lookupTitle.isEmpty, !existingTitle.isEmpty {
                out.append(presence)
                continue
            }
            if lookupTitle.isEmpty {
                out.append(presence)
                continue
            }
            if !existingTitle.isEmpty, equalsIgnoringCaseAndDiacritics(existingTitle, lookupTitle) {
                out.append(presence)
                continue
            }
            var terminal = presence.terminal ?? CodexActivePresence.Terminal()
            terminal.tabTitle = lookupTitle
            presence.terminal = terminal
            out.append(presence)
        }

        return out
    }

    nonisolated static func isLikelyCodexITermSessionName(_ rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        let normalized = normalizeITermSessionNameForMatching(rawName)
        guard !normalized.isEmpty else { return false }
        if normalized == "codex" { return true }
        if normalized.hasSuffix(" codex") { return true }
        if trimmed.hasPrefix("codex ") { return true }
        return false
    }

    nonisolated static func isLikelyClaudeITermSessionName(_ rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        let normalized = normalizeITermSessionNameForMatching(rawName)
        guard !normalized.isEmpty else { return false }
        if normalized == "claude" || normalized == "claude code" { return true }
        if normalized.hasSuffix(" claude") || normalized.hasSuffix(" claude code") { return true }
        if trimmed.hasPrefix("claude ") || trimmed.hasPrefix("claude-code ") { return true }
        return false
    }

    nonisolated static func isLikelyOpenCodeITermSessionName(_ rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        let normalized = normalizeITermSessionNameForMatching(rawName)
        guard !normalized.isEmpty else { return false }
        if normalized == "opencode" { return true }
        if normalized.hasSuffix(" opencode") { return true }
        if trimmed.hasPrefix("opencode ") { return true }
        return false
    }

    nonisolated private static func normalizeITermSessionNameForMatching(_ rawName: String) -> String {
        let lowered = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return "" }

        var sanitized = String()
        sanitized.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                sanitized.unicodeScalars.append(scalar)
            } else {
                sanitized.append(" ")
            }
        }

        return sanitized
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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

                // Session log path: pick the lowest numeric FD among matching session logs.
                // The parent session's JSONL is typically opened first (lowest FD), while
                // subagent files get higher FDs. This makes selection deterministic.
                if matchesSessionLogPath(name, source: source, sessionsRoots: sessionsRoots) {
                    if !info.openSessionLogPaths.contains(name) {
                        info.openSessionLogPaths.append(name)
                    }
                    let fdNum: Int = {
                        guard let fd = currentFD else { return Int.max }
                        let digits = fd.prefix { $0.isNumber }
                        return Int(digits) ?? Int.max
                    }()
                    if fdNum < info.sessionLogFD {
                        info.sessionLogFD = fdNum
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

    /// Scan the Claude project directory for JSONL session files, sorted newest-first.
    /// Used to infer session log paths when lsof can't find the file open.
    nonisolated static func claudeSessionLogCandidates(cwd: String, claudeRoot: String, recencyCutoff: Date? = nil) -> [(path: String, sessionID: String?)] {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let projectDir = URL(fileURLWithPath: claudeRoot)
            .appendingPathComponent("projects")
            .appendingPathComponent(encoded)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let contents = try? fm.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, date: Date)] = []
        for file in contents {
            let ext = file.pathExtension.lowercased()
            guard ext == "jsonl" || ext == "ndjson" else { continue }
            guard file.lastPathComponent.lowercased() != "history.jsonl" else { continue }
            let mdate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let cutoff = recencyCutoff, mdate < cutoff { continue }
            candidates.append((file, mdate))
        }

        candidates.sort { $0.date > $1.date }
        return candidates.map { ($0.url.path, extractSessionID(fromLogPath: $0.url.path, source: .claude)) }
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

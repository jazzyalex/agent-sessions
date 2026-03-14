import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Source Manager
//
// Orchestrates Claude usage data collection across OAuth and tmux paths.
//
// auto mode:
//   - Primary: OAuth endpoint (60s cadence)
//   - 1 failure  → health = degraded
//   - 2 failures → serve last cached OAuth snapshot if <3min old
//   - 3 failures → activate tmux fallback; OAuth retry on backoff (30s→60s→120s)
//   - When OAuth recovers → switch back automatically
//
// oauthOnly: OAuth only, no tmux fallback
// tmuxOnly:  Existing ClaudeStatusService behavior, no OAuth

actor ClaudeUsageSourceManager {
    typealias SnapshotHandler = @Sendable (ClaudeLimitSnapshot) -> Void
    typealias AvailabilityHandler = @Sendable (ClaudeServiceAvailability) -> Void

    // MARK: - Thresholds
    private static let oauthRefreshInterval: TimeInterval = 60
    private static let cacheStaleThreshold: TimeInterval = 3 * 60   // 3 minutes
    private static let cacheHardExpire: TimeInterval = 10 * 60      // 10 minutes
    private static let backoffSequence: [TimeInterval] = [30, 60, 120]

    // MARK: - State
    private var mode: ClaudeUsageMode = .auto
    private var snapshotHandler: SnapshotHandler?
    private var availabilityHandler: AvailabilityHandler?

    private let tokenResolver = ClaudeOAuthTokenResolver()
    private let usageClient = ClaudeOAuthUsageClient()
    private let store: ClaudeUsageSnapshotStore
    private var tmuxAdapter: ClaudeTmuxUsageFallbackAdapter?

    init(store: ClaudeUsageSnapshotStore = ClaudeUsageSnapshotStore()) {
        self.store = store
    }

    private struct OAuthVisibilityContext {
        var menuVisible: Bool = false
        var stripVisible: Bool = false
        var appIsActive: Bool = false
        var effectiveVisible: Bool { menuVisible || (stripVisible && appIsActive) }
    }

    private var visibilityContext = OAuthVisibilityContext()
    private var visible: Bool { visibilityContext.effectiveVisible }

    private var oauthFailureCount = 0
    private var usingTmuxFallback = false
    private var lastOAuthSnapshot: ClaudeLimitSnapshot?
    private(set) var lastRawOAuthPayload: String?
    private var refreshTask: Task<Void, Never>?
    private var shouldRun = false

    // MARK: - Lifecycle

    func start(
        mode: ClaudeUsageMode,
        handler: @escaping SnapshotHandler,
        availabilityHandler: @escaping AvailabilityHandler
    ) async {
        self.mode = mode
        self.snapshotHandler = handler
        self.availabilityHandler = availabilityHandler
        self.shouldRun = true

        os_log("ClaudeOAuth: source manager starting, mode=%{public}@", log: log, type: .info, mode.rawValue)

        // Restore cached snapshot for cold-start display
        if let cached = await store.load() {
            let age = Date().timeIntervalSince(cached.fetchedAt)
            if age < Self.cacheHardExpire {
                var serving = cached
                serving.source = .cachedOAuth
                serving.health = age < Self.cacheStaleThreshold ? .live : .stale
                publish(serving)
                lastOAuthSnapshot = cached
                os_log("ClaudeOAuth: restored cached snapshot, age=%.0fs", log: log, type: .info, age)
            }
        }

        switch mode {
        case .auto, .oauthOnly:
            scheduleOAuthRefresh(delay: 0)
        case .tmuxOnly:
            await activateTmuxFallback(reason: "tmuxOnly mode")
        }
    }

    func stop() async {
        shouldRun = false
        refreshTask?.cancel()
        refreshTask = nil
        await tmuxAdapter?.stop()
        tmuxAdapter = nil
        os_log("ClaudeOAuth: source manager stopped", log: log, type: .info)
    }

    func setVisibility(menuVisible: Bool, stripVisible: Bool, appIsActive: Bool) {
        let newContext = OAuthVisibilityContext(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)
        let wasVisible = visible
        visibilityContext = newContext

        if usingTmuxFallback || mode == .tmuxOnly {
            let adapter = tmuxAdapter
            Task.detached {
                await adapter?.setVisibility(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)
            }
            return
        }

        // When transitioning hidden → visible, trigger an immediate refresh
        if !wasVisible && visible {
            scheduleOAuthRefresh(delay: 0)
        }
    }

    func refreshNow() async {
        if usingTmuxFallback || mode == .tmuxOnly {
            await tmuxAdapter?.refreshNow()
            return
        }
        await performOAuthFetch()
    }

    // MARK: - OAuth Fetch Loop

    private func scheduleOAuthRefresh(delay: TimeInterval) {
        refreshTask?.cancel()
        guard shouldRun else { return }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
            guard await self.shouldRun else { return }
            await self.performOAuthFetch()
        }
    }

    private func performOAuthFetch() async {
        guard shouldRun else { return }

        // Resolve token
        guard let resolved = await tokenResolver.resolve() else {
            os_log("ClaudeOAuth: no token available", log: log, type: .info)
            await handleOAuthFailure(reason: "no token")
            return
        }

        // Fetch from endpoint
        do {
            let (raw, bodyHash, rawBody) = try await usageClient.fetch(token: resolved.token)
            lastRawOAuthPayload = rawBody
            guard let snapshot = ClaudeUsageNormalizer.normalize(raw, bodyHash: bodyHash) else {
                os_log("ClaudeOAuth: normalizer returned nil (empty payload)", log: log, type: .error)
                await handleOAuthFailure(reason: "empty payload")
                return
            }

            // Success
            oauthFailureCount = 0
            lastOAuthSnapshot = snapshot
            await store.save(snapshot)

            if usingTmuxFallback {
                os_log("ClaudeOAuth: OAuth recovered, deactivating tmux fallback", log: log, type: .info)
                await deactivateTmuxFallback()
            }

            publish(snapshot)
            os_log("ClaudeOAuth: fetch succeeded, source=%{public}@", log: log, type: .info, resolved.source.rawValue)

            // Schedule next fetch
            scheduleOAuthRefresh(delay: Self.oauthRefreshInterval)

        } catch ClaudeOAuthUsageClientError.unauthorized {
            os_log("ClaudeOAuth: 401, invalidating token cache", log: log, type: .info)
            await tokenResolver.invalidateCache()
            await handleOAuthFailure(reason: "401 unauthorized")
        } catch ClaudeOAuthUsageClientError.rateLimited(let retryAfter) {
            // Rate limited — honor Retry-After, don't count toward tmux failover threshold.
            // Add a 10s buffer to avoid hitting the boundary.
            let delay = retryAfter + 10
            os_log("ClaudeOAuth: rate limited, retrying in %.0fs", log: log, type: .info, delay)
            if var snap = lastOAuthSnapshot {
                snap.health = .stale
                publish(snap)
            }
            scheduleOAuthRefresh(delay: delay)
        } catch {
            os_log("ClaudeOAuth: fetch error: %{public}@", log: log, type: .error, error.localizedDescription)
            await handleOAuthFailure(reason: error.localizedDescription)
        }
    }

    private func handleOAuthFailure(reason: String) async {
        oauthFailureCount += 1
        os_log("ClaudeOAuth: failure #%d: %{public}@", log: log, type: .info, oauthFailureCount, reason)

        let now = Date()

        switch oauthFailureCount {
        case 1:
            // Degraded — keep current display but mark health
            if var snap = lastOAuthSnapshot {
                snap.health = .degraded
                publish(snap)
            }

        case 2:
            // Serve cache if fresh enough
            if let cached = lastOAuthSnapshot, now.timeIntervalSince(cached.fetchedAt) < Self.cacheStaleThreshold {
                var serving = cached
                serving.source = .cachedOAuth
                serving.health = .stale
                publish(serving)
                os_log("ClaudeOAuth: serving %{public}@-old cache after failure #2", log: log, type: .info,
                       String(format: "%.0f", now.timeIntervalSince(cached.fetchedAt)))
            }

        default:
            // 3+ failures: activate tmux fallback (auto mode only)
            if mode == .auto && !usingTmuxFallback {
                await activateTmuxFallback(reason: "OAuth failure #\(oauthFailureCount)")
            }
        }

        // Schedule retry with backoff
        if mode != .tmuxOnly {
            let backoffIndex = min(oauthFailureCount - 1, Self.backoffSequence.count - 1)
            let delay = Self.backoffSequence[max(0, backoffIndex)]
            os_log("ClaudeOAuth: retry in %.0fs", log: log, type: .info, delay)
            scheduleOAuthRefresh(delay: delay)
        }
    }

    // MARK: - Tmux Fallback

    private func activateTmuxFallback(reason: String) async {
        guard tmuxAdapter == nil else { return }
        os_log("ClaudeOAuth: activating tmux fallback: %{public}@", log: log, type: .info, reason)
        usingTmuxFallback = true

        let adapter = ClaudeTmuxUsageFallbackAdapter()
        self.tmuxAdapter = adapter

        let handler = self.snapshotHandler
        let availHandler = self.availabilityHandler
        let ctx = visibilityContext

        await adapter.start(
            handler: { snap in handler?(snap) },
            availabilityHandler: { a in availHandler?(a) }
        )
        await adapter.setVisibility(
            menuVisible: ctx.menuVisible,
            stripVisible: ctx.stripVisible,
            appIsActive: ctx.appIsActive
        )
    }

    private func deactivateTmuxFallback() async {
        guard let adapter = tmuxAdapter else { return }
        os_log("ClaudeOAuth: deactivating tmux fallback", log: log, type: .info)
        await adapter.stop()
        tmuxAdapter = nil
        usingTmuxFallback = false
    }

    // MARK: - Diagnostics

    func currentSourceDescription() -> String {
        if usingTmuxFallback { return "tmux" }
        switch mode {
        case .tmuxOnly: return "tmux"
        case .oauthOnly: return "OAuth only"
        case .auto:
            if let snap = lastOAuthSnapshot {
                return "\(snap.source) / \(snap.health)"
            }
            return "OAuth (no data)"
        }
    }

    func currentHealthDescription() -> String {
        if usingTmuxFallback { return "fallback" }
        if oauthFailureCount >= 2 { return "degraded" }
        if oauthFailureCount == 1 { return "degraded" }
        return lastOAuthSnapshot != nil ? "live" : "pending"
    }

    func diagnosticsSnapshot() -> String {
        var lines = """
        mode: \(mode.rawValue)
        usingTmuxFallback: \(usingTmuxFallback)
        oauthFailureCount: \(oauthFailureCount)
        lastOAuthSnapshotAge: \(lastOAuthSnapshot.map { String(format: "%.0fs", Date().timeIntervalSince($0.fetchedAt)) } ?? "n/a")
        visible: \(visible)
        """
        if let raw = lastRawOAuthPayload {
            lines += "\n\n--- raw OAuth payload ---\n\(raw)"
        }
        return lines
    }

    // MARK: - Private

    private func publish(_ snapshot: ClaudeLimitSnapshot) {
        snapshotHandler?(snapshot)
    }
}

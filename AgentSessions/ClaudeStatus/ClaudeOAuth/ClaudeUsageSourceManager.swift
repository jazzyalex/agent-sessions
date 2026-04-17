import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Source Manager
//
// Orchestrates Claude usage data collection across OAuth, Web API, and tmux paths.
//
// auto mode (Web API disabled, default):
//   - Primary: OAuth endpoint (60s cadence)
//   - 1 failure  → health = degraded
//   - 2 failures → serve last cached OAuth snapshot if <10min old
//   - 3 failures → activate tmux fallback; OAuth retries when credentials change
//   - When OAuth recovers → switch back automatically
//
// auto mode (Web API enabled via claudeWebApiEnabled pref):
//   OAuth → [credential-gated retry] → Web API → [3 web failures] → tmux
//
// oauthOnly: OAuth only, no web or tmux fallback
// tmuxOnly:  Existing ClaudeStatusService behavior, no OAuth
// webOnly:   claude.ai Web API only, no OAuth or tmux
//
// Credential gating replaces blind time-based backoff after the cold-start
// window. The credential watcher polls every 30s and retries OAuth only when
// the Keychain mtime or .credentials.json hash changes.

actor ClaudeUsageSourceManager {
    typealias SnapshotHandler = @Sendable (ClaudeLimitSnapshot) -> Void
    typealias AvailabilityHandler = @Sendable (ClaudeServiceAvailability) -> Void

    enum OAuthRetryPlan: Equatable {
        case coldStart(delay: TimeInterval)
        case timed(delay: TimeInterval)
        case credentialWatch
    }

    // MARK: - Thresholds

    private static let refreshInterval: TimeInterval = 5 * 60         // 5 minutes (OAuth + Web)
    private static let cacheStaleThreshold: TimeInterval = 10 * 60    // 10 minutes
    private static let cacheHardExpire: TimeInterval = 30 * 60        // 30 minutes
    private static let credentialWatchInterval: TimeInterval = 30     // 30s watch poll
    private static let visibleFailureRetryInterval: TimeInterval = 5 * 60
    // Fast retries during cold start (first 90s) to close the blank-screen gap.
    private static let coldStartWindow: TimeInterval = 90
    private static let coldStartRetryDelays: [TimeInterval] = [10, 30]

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

    // OAuth
    private var oauthFailureCount = 0
    private var usingTmuxFallback = false
    private var lastOAuthSnapshot: ClaudeLimitSnapshot?
    private(set) var lastRawOAuthPayload: String?
    private var refreshTask: Task<Void, Never>?
    private var oauthRateLimitRetryDeadline: Date?
    private var shouldRun = false
    private var startedAt: Date?
    private var didAttemptDelegatedRefresh = false

    // Credential gating
    private let credentialWatcher = ClaudeCredentialFingerprint()
    private var lastFailureFingerprint: ClaudeCredentialFingerprint.Fingerprint?
    private var credentialWatchTask: Task<Void, Never>?

    // Delegated refresh
    private let delegatedRefresh = ClaudeDelegatedTokenRefresh()

    // Web API
    private let webCookieResolver = ClaudeWebCookieResolver()
    private let webUsageClient = ClaudeWebUsageClient()
    private var webFailureCount = 0
    private var usingWebFallback = false
    private var webRefreshTask: Task<Void, Never>?

    private var webApiEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreferencesKey.claudeWebApiEnabled)
    }

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
        self.startedAt = Date()

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
        case .webOnly:
            usingWebFallback = true
            scheduleWebRefresh(delay: 0)
        }
    }

    func stop() async {
        shouldRun = false
        refreshTask?.cancel()
        refreshTask = nil
        credentialWatchTask?.cancel()
        credentialWatchTask = nil
        webRefreshTask?.cancel()
        webRefreshTask = nil
        await tmuxAdapter?.stop()
        tmuxAdapter = nil
        os_log("ClaudeOAuth: source manager stopped", log: log, type: .info)
    }

    func setVisibility(menuVisible: Bool, stripVisible: Bool, appIsActive: Bool) {
        let newContext = OAuthVisibilityContext(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)
        let wasVisible = visible
        visibilityContext = newContext
        let becameVisible = !wasVisible && visible
        let shouldRetryOAuth = Self.shouldRetryOAuthOnVisibleTransition(
            wasVisible: wasVisible,
            visible: visible,
            mode: mode,
            rateLimitRetryDeadline: oauthRateLimitRetryDeadline,
            now: Date()
        )

        if usingTmuxFallback || mode == .tmuxOnly {
            let adapter = tmuxAdapter
            Task.detached {
                await adapter?.setVisibility(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)
            }
            if shouldRetryOAuth {
                wakeOAuthForVisibleTransition()
            }
            return
        }

        // When transitioning hidden → visible, bypass credential gate
        if becameVisible {
            if mode == .webOnly {
                scheduleWebRefresh(delay: 0)
            } else if shouldRetryOAuth {
                wakeOAuthForVisibleTransition()
            }
        }
    }

    func refreshNow() async {
        if usingTmuxFallback || mode == .tmuxOnly {
            await tmuxAdapter?.refreshNow()
            return
        }
        if mode == .webOnly {
            await performWebFetch()
            return
        }
        // Bypass credential gate — cancel watch and retry OAuth immediately
        credentialWatchTask?.cancel()
        credentialWatchTask = nil
        await performOAuthFetch()
    }

    // MARK: - OAuth Fetch Loop

    private func scheduleOAuthRefresh(delay: TimeInterval) {
        refreshTask?.cancel()
        guard shouldRun else { return }

        refreshTask = Task {
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
            guard self.shouldRun else { return }
            await self.performOAuthFetch()
        }
    }

    private func performOAuthFetch() async {
        guard shouldRun else { return }

        guard let resolved = await tokenResolver.resolve() else {
            os_log("ClaudeOAuth: no token available", log: log, type: .info)
            await handleOAuthFailure(reason: "no token")
            return
        }

        do {
            let (raw, bodyHash, rawBody) = try await usageClient.fetch(token: resolved.token)
            lastRawOAuthPayload = rawBody
            guard let snapshot = ClaudeUsageNormalizer.normalize(raw, bodyHash: bodyHash) else {
                os_log("ClaudeOAuth: normalizer returned nil (empty payload)", log: log, type: .error)
                await handleOAuthFailure(reason: "empty payload")
                return
            }

            // Success — reset all failure state
            oauthFailureCount = 0
            oauthRateLimitRetryDeadline = nil
            didAttemptDelegatedRefresh = false
            lastFailureFingerprint = nil
            credentialWatchTask?.cancel()
            credentialWatchTask = nil
            lastOAuthSnapshot = snapshot
            await store.save(snapshot)

            if usingWebFallback && mode != .webOnly {
                os_log("ClaudeOAuth: OAuth recovered, deactivating web API fallback", log: log, type: .info)
                usingWebFallback = false
                webRefreshTask?.cancel()
                webRefreshTask = nil
                webFailureCount = 0
            }
            if usingTmuxFallback {
                os_log("ClaudeOAuth: OAuth recovered, deactivating tmux fallback", log: log, type: .info)
                await deactivateTmuxFallback()
            }

            publish(snapshot)
            os_log("ClaudeOAuth: fetch succeeded, source=%{public}@", log: log, type: .info, resolved.source.rawValue)
            scheduleOAuthRefresh(delay: Self.refreshInterval)

        } catch ClaudeOAuthUsageClientError.unauthorized {
            oauthRateLimitRetryDeadline = nil
            os_log("ClaudeOAuth: 401, invalidating token cache", log: log, type: .info)
            await tokenResolver.invalidateCache()

            // Attempt delegated refresh once per failure cycle
            if !didAttemptDelegatedRefresh {
                didAttemptDelegatedRefresh = true
                os_log("ClaudeOAuth: attempting delegated token refresh via CLI", log: log, type: .info)
                let result = await delegatedRefresh.attemptRefresh()
                if case .refreshed = result {
                    os_log("ClaudeOAuth: delegated refresh succeeded, retrying OAuth", log: log, type: .info)
                    await tokenResolver.invalidateCache()
                    await performOAuthFetch()
                    return
                }
                os_log("ClaudeOAuth: delegated refresh result = no change, entering credential-gated mode",
                       log: log, type: .info)
            }
            await handleOAuthFailure(reason: "401 unauthorized")

        } catch ClaudeOAuthUsageClientError.rateLimited(let retryAfter) {
            let delay = retryAfter + 10
            oauthRateLimitRetryDeadline = Date().addingTimeInterval(delay)
            os_log("ClaudeOAuth: rate limited, retrying in %.0fs", log: log, type: .info, delay)
            if var snap = lastOAuthSnapshot {
                snap.health = .stale
                publish(snap)
                // Have cached data — just wait, don't fall back
                scheduleOAuthRefresh(delay: delay)
            } else if var persisted = await store.load(),
                      Date().timeIntervalSince(persisted.fetchedAt) < Self.cacheHardExpire {
                // No in-memory snapshot but the persistent store has one within
                // the hard-expire window. Serve it as stale rather than falling
                // back to tmux (which also gets rate-limited).
                persisted.source = .cachedOAuth
                persisted.health = .stale
                lastOAuthSnapshot = persisted
                publish(persisted)
                os_log("ClaudeOAuth: rate limited — serving persisted snapshot (age %.0fs)",
                       log: log, type: .info, Date().timeIntervalSince(persisted.fetchedAt))
                scheduleOAuthRefresh(delay: delay)
            } else if mode == .auto && !usingTmuxFallback {
                if webApiEnabled && !usingWebFallback {
                    os_log("ClaudeOAuth: no cached data during rate limit, activating web API fallback",
                           log: log, type: .info)
                    usingWebFallback = true
                    scheduleWebRefresh(delay: 0)
                } else if !usingWebFallback {
                    os_log("ClaudeOAuth: no cached data during rate limit, activating tmux fallback",
                           log: log, type: .info)
                    await activateTmuxFallback(reason: "rate limited with no cache")
                }
                scheduleOAuthRefresh(delay: delay)
            } else {
                scheduleOAuthRefresh(delay: delay)
            }

        } catch {
            oauthRateLimitRetryDeadline = nil
            os_log("ClaudeOAuth: fetch error: %{public}@", log: log, type: .error, error.localizedDescription)
            await handleOAuthFailure(reason: error.localizedDescription)
        }
    }

    private func handleOAuthFailure(reason: String) async {
        oauthRateLimitRetryDeadline = nil
        oauthFailureCount += 1
        os_log("ClaudeOAuth: failure #%d: %{public}@", log: log, type: .info, oauthFailureCount, reason)

        let now = Date()

        switch oauthFailureCount {
        case 1:
            if var snap = lastOAuthSnapshot {
                snap.health = .degraded
                publish(snap)
            } else if mode == .auto {
                if webApiEnabled && !usingWebFallback {
                    os_log("ClaudeOAuth: no cache on first failure, activating web API fallback",
                           log: log, type: .info)
                    usingWebFallback = true
                    scheduleWebRefresh(delay: 0)
                } else if !webApiEnabled && !usingTmuxFallback {
                    os_log("ClaudeOAuth: no cache on first failure, activating tmux fallback early",
                           log: log, type: .info)
                    await activateTmuxFallback(reason: "first failure with no cache")
                }
            }

        case 2:
            if let cached = lastOAuthSnapshot, now.timeIntervalSince(cached.fetchedAt) < Self.cacheStaleThreshold {
                var serving = cached
                serving.source = .cachedOAuth
                serving.health = .stale
                publish(serving)
                os_log("ClaudeOAuth: serving %{public}@-old cache after failure #2", log: log, type: .info,
                       String(format: "%.0f", now.timeIntervalSince(cached.fetchedAt)))
            }

        default:
            if mode == .auto {
                if webApiEnabled && !usingWebFallback {
                    os_log("ClaudeOAuth: activating web API fallback after failure #%d",
                           log: log, type: .info, oauthFailureCount)
                    usingWebFallback = true
                    scheduleWebRefresh(delay: 0)
                } else if !webApiEnabled && !usingTmuxFallback {
                    await activateTmuxFallback(reason: "OAuth failure #\(oauthFailureCount)")
                }
            }
        }

        if mode != .tmuxOnly && mode != .webOnly {
            scheduleOAuthRetry()
        }
    }

    private func scheduleOAuthRetry() {
        let plan = Self.oauthRetryPlan(
            usingTmuxFallback: usingTmuxFallback,
            startedAt: startedAt,
            now: Date(),
            failureCount: oauthFailureCount,
            visible: visible
        )

        switch plan {
        case .coldStart(let delay):
            os_log("ClaudeOAuth: cold-start retry in %.0fs", log: log, type: .info, delay)
            scheduleOAuthRefresh(delay: delay)
        case .timed(let delay):
            os_log("ClaudeOAuth: visible failure retry in %.0fs", log: log, type: .info, delay)
            scheduleOAuthRefresh(delay: delay)
        case .credentialWatch:
            // Hidden surfaces avoid background network churn; they wake when credentials change
            // or when the strip/menu/Cockpit becomes visible again.
            os_log("ClaudeOAuth: entering credential-gated retry mode", log: log, type: .info)
            startCredentialWatch()
        }
    }

    static func oauthRetryPlan(usingTmuxFallback: Bool,
                               startedAt: Date?,
                               now: Date,
                               failureCount: Int,
                               visible: Bool) -> OAuthRetryPlan {
        if !usingTmuxFallback,
           let startedAt,
           now.timeIntervalSince(startedAt) < Self.coldStartWindow,
           failureCount > 0,
           failureCount <= Self.coldStartRetryDelays.count {
            return .coldStart(delay: Self.coldStartRetryDelays[failureCount - 1])
        }

        if visible {
            return .timed(delay: Self.visibleFailureRetryInterval)
        }

        return .credentialWatch
    }

    static func shouldRetryOAuthOnVisibleTransition(wasVisible: Bool,
                                                    visible: Bool,
                                                    mode: ClaudeUsageMode,
                                                    rateLimitRetryDeadline: Date? = nil,
                                                    now: Date = Date()) -> Bool {
        guard !wasVisible && visible else { return false }
        if let rateLimitRetryDeadline, rateLimitRetryDeadline > now {
            return false
        }
        switch mode {
        case .auto, .oauthOnly:
            return true
        case .tmuxOnly, .webOnly:
            return false
        }
    }

    private func wakeOAuthForVisibleTransition() {
        // Visibility should wake credential-gated failures, but not cancel a server-imposed 429 backoff.
        if let deadline = oauthRateLimitRetryDeadline, deadline > Date() {
            os_log("ClaudeOAuth: preserving rate-limit retry deadline while becoming visible", log: log, type: .info)
            return
        }
        credentialWatchTask?.cancel()
        credentialWatchTask = nil
        scheduleOAuthRefresh(delay: 0)
    }

    // MARK: - Credential Watch

    private func startCredentialWatch() {
        credentialWatchTask?.cancel()
        guard shouldRun else { return }

        credentialWatchTask = Task {
            let fp = await self.credentialWatcher.capture()
            self.lastFailureFingerprint = fp

            while self.shouldRun {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.credentialWatchInterval * 1_000_000_000))
                } catch { return }
                guard self.shouldRun else { return }

                if await self.credentialWatcher.hasChanged(since: fp) {
                    os_log("ClaudeOAuth: credential change detected, retrying OAuth", log: log, type: .info)
                    self.credentialWatchTask = nil
                    await self.performOAuthFetch()
                    return
                }
            }
        }
    }

    // MARK: - Web API Path

    private func scheduleWebRefresh(delay: TimeInterval) {
        webRefreshTask?.cancel()
        guard shouldRun else { return }

        webRefreshTask = Task {
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
            guard self.shouldRun else { return }
            await self.performWebFetch()
        }
    }

    private func performWebFetch() async {
        guard shouldRun, usingWebFallback || mode == .webOnly else { return }

        guard let cookie = await webCookieResolver.resolve() else {
            os_log("ClaudeOAuth: web API — no session cookie available", log: log, type: .info)
            await handleWebFailure(reason: "no session cookie")
            return
        }

        do {
            let (raw, bodyHash, fromCache) = try await webUsageClient.fetch(sessionKey: cookie.sessionKey)
            guard var snapshot = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: bodyHash) else {
                os_log("ClaudeOAuth: web normalizer returned nil", log: log, type: .error)
                await handleWebFailure(reason: "empty web payload")
                return
            }
            if fromCache { snapshot.source = .cachedWeb }

            webFailureCount = 0
            publish(snapshot)
            await store.save(snapshot)
            os_log("ClaudeOAuth: web API fetch succeeded (fromCache=%{public}@)",
                   log: log, type: .info, fromCache ? "true" : "false")
            scheduleWebRefresh(delay: Self.refreshInterval)

        } catch ClaudeOAuthUsageClientError.rateLimited(let retryAfter) {
            let delay = retryAfter + 10
            os_log("ClaudeOAuth: web API rate limited, retry in %.0fs", log: log, type: .info, delay)
            scheduleWebRefresh(delay: delay)
        } catch ClaudeOAuthUsageClientError.unauthorized {
            os_log("ClaudeOAuth: web API 401, invalidating cookie and org caches", log: log, type: .info)
            await webCookieResolver.invalidateCache()
            await webUsageClient.invalidateOrgId()
            await handleWebFailure(reason: "401 unauthorized")
        } catch {
            os_log("ClaudeOAuth: web API error: %{public}@", log: log, type: .error, error.localizedDescription)
            await handleWebFailure(reason: error.localizedDescription)
        }
    }

    private func handleWebFailure(reason: String) async {
        webFailureCount += 1
        os_log("ClaudeOAuth: web failure #%d: %{public}@", log: log, type: .info, webFailureCount, reason)

        if webFailureCount >= 3, mode == .auto, !usingTmuxFallback {
            os_log("ClaudeOAuth: web API failed %d times, activating tmux fallback",
                   log: log, type: .info, webFailureCount)
            await activateTmuxFallback(reason: "web API failure #\(webFailureCount)")
        } else {
            scheduleWebRefresh(delay: Self.refreshInterval)
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
        let store = self.store

        await adapter.start(
            handler: { snap in
                handler?(snap)
                Task { await store.save(snap) }
            },
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
        case .webOnly: return "Web API"
        case .auto:
            if usingWebFallback { return "Web API (OAuth fallback)" }
            if let snap = lastOAuthSnapshot { return "\(snap.source) / \(snap.health)" }
            return "OAuth (no data)"
        }
    }

    func currentHealthDescription() -> String {
        if usingTmuxFallback { return "fallback" }
        if usingWebFallback { return "web fallback" }
        if oauthFailureCount >= 1 { return "degraded" }
        return lastOAuthSnapshot != nil ? "live" : "pending"
    }

    func diagnosticsSnapshot() -> String {
        var lines = """
        mode: \(mode.rawValue)
        usingTmuxFallback: \(usingTmuxFallback)
        usingWebFallback: \(usingWebFallback)
        webApiEnabled: \(webApiEnabled)
        webFailureCount: \(webFailureCount)
        oauthFailureCount: \(oauthFailureCount)
        credentialWatchActive: \(credentialWatchTask != nil)
        lastOAuthSnapshotAge: \(lastOAuthSnapshot.map { String(format: "%.0fs", Date().timeIntervalSince($0.fetchedAt)) } ?? "n/a")
        visible: \(visible)
        """
        if let raw = lastRawOAuthPayload {
            lines += "\n\n--- raw OAuth payload ---\n\(raw)"
        }
        return lines
    }

    /// Persist a snapshot produced outside the normal OAuth/tmux loop (e.g., hard probe).
    func saveSnapshot(_ snapshot: ClaudeLimitSnapshot) async {
        await store.save(snapshot)
    }

    // MARK: - Private

    private func publish(_ snapshot: ClaudeLimitSnapshot) {
        snapshotHandler?(snapshot)
    }
}

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

    private static let refreshInterval: TimeInterval = 60             // 60 seconds (OAuth + Web)
    private static let cacheStaleThreshold: TimeInterval = 10 * 60    // 10 minutes
    private static let cacheHardExpire: TimeInterval = 30 * 60        // 30 minutes
    private static let credentialWatchInterval: TimeInterval = 30     // 30s watch poll
    private static let visibleFailureRetryInterval: TimeInterval = 3 * 60
    // Fast retries during cold start (first 90s) to close the blank-screen gap.
    private static let coldStartWindow: TimeInterval = 90
    private static let coldStartRetryDelays: [TimeInterval] = [10, 30]
    // Authoritative CLI-status re-probe throttle on the SUCCESS path: at most
    // one `claude auth status` subprocess per this interval. Kept deliberately
    // long (15 min) to minimize auth-endpoint traffic — the failure path already
    // detects a genuinely-unusable token promptly; this success-path probe only
    // adds the "CLI signed out but the cached token still fetches" proactive
    // warning, which does not need to be fast. A live logout is surfaced within
    // one poll of the next re-probe (≤15 min late). The probe never false-fires,
    // so trusting a `.signedOut` from it immediately (no debounce) is safe.
    private static let cliStatusReprobeInterval: TimeInterval = 15 * 60

#if DEBUG
    nonisolated static var refreshIntervalForTesting: TimeInterval {
        refreshInterval
    }
#endif

    // MARK: - State

    private var mode: ClaudeUsageMode = .auto
    private var snapshotHandler: SnapshotHandler?
    private var availabilityHandler: AvailabilityHandler?

    private let tokenResolver = ClaudeOAuthTokenResolver()
    private let usageClient = ClaudeOAuthUsageClient()
    private let store: ClaudeUsageSnapshotStore
    private var tmuxAdapter: ClaudeTmuxUsageFallbackAdapter?

    /// Current auth verdict for this provider. Fed by ClaudeUsageModel/Task 9;
    /// gates the tmux fallback so a signed-out account never spawns a hanging probe.
    private var currentAuthState: UsageAuthState = .unknown

    /// Throttle for the success-path authoritative status probe. Holds the last
    /// `CLIAuthStatus` and when it was taken; re-probed at most every
    /// `cliStatusReprobeInterval`. `nil` until the first success-path probe, in
    /// which case the throttle returns `.unknown` (→ `.ok`, never alarming).
    private var cliStatusCache: (status: CLIAuthStatus, at: Date)?

    /// Monotonic generation for auth-verdict computations (I2). Incremented at the
    /// START of each verdict computation (OAuth success path + `classifyAndPublishAuthState`).
    /// A reentrant older Task that suspended across an `await` compares its captured
    /// generation against this and drops its now-stale `currentAuthState` write when a
    /// newer computation has since started — otherwise concurrent `performOAuthFetch`
    /// invocations (refreshNow, credential watcher, delegated refresh, scheduled loop)
    /// could clobber a newer verdict with a stale one.
    private var authGeneration: UInt64 = 0

    private func nextAuthGeneration() -> UInt64 {
        authGeneration &+= 1
        return authGeneration
    }

    /// Single long-lived classifier instance — it is STATEFUL (debounces the
    /// `signedOut` verdict across polls), so it must never be re-created per call.
    private let authClassifier = ClaudeAuthClassifier()

    /// The tmux `/usage` probe hangs on a login screen when the account is signed
    /// out, the CLI is absent, or the credentials are expired (which triggers a
    /// CLI re-auth prompt that hangs exactly like signed-out), so it must never
    /// run in those states.
    static func shouldSuppressTmuxFallback(_ state: UsageAuthState) -> Bool {
        state == .signedOut || state == .cliNotInstalled || state == .expired
    }

    /// Reentrancy guard (I2): a verdict computation may commit its `currentAuthState`
    /// write / availability emit only if no NEWER computation started while it was
    /// suspended across an `await`. `authGeneration` is monotonic, so the captured
    /// generation matches the current one iff this is still the latest computation.
    static func verdictIsCurrent(captured: UInt64, current: UInt64) -> Bool {
        captured == current
    }

    /// Pure routing for the failure-path fast verdict: a verified 401 while ANY
    /// token (keychain / creds-file / env) is still present is `.expired`. Env-token
    /// inclusion prevents an expired env-token 401 from silently falling through to
    /// `.ok` (the resolver's source #1 is the env token).
    static func hasAnyToken(keychainFound: Bool, credsFilePresentToken: Bool, envTokenPresent: Bool) -> Bool {
        keychainFound || credsFilePresentToken || envTokenPresent
    }

    /// Pure success-path mapping: a healthy OAuth fetch proves the account
    /// works, so ONLY a DEFINITIVE authoritative `.signedOut` overrides to
    /// signed-out. Every other status (`.signedIn` / `.unknown` / `.cliMissing`)
    /// stays `.ok` — a `.cliMissing`-while-fetch-succeeds is contradictory and an
    /// ambiguous/`.unknown` must never false-alarm.
    static func successPathState(cli: CLIAuthStatus) -> UsageAuthState {
        cli == .signedOut ? .signedOut : .ok
    }

    /// Pure throttle predicate: re-probe when never probed (`nil`) or when the
    /// last probe is at least `interval` old; otherwise reuse the cached value.
    static func shouldReprobe(lastAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastAt else { return true }
        return now.timeIntervalSince(lastAt) >= interval
    }

    /// True while we're still inside the post-launch cold-start window. A
    /// transient OAuth miss during this window (e.g. the Keychain `security`
    /// read racing app launch, or a single network hiccup) must retry the —
    /// verified-working — OAuth path rather than immediately spawn the tmux
    /// `/usage` CLI probe, which launches an interactive `claude` that can pop a
    /// browser OAuth login even for a signed-in account. Outside this window a
    /// persistent failure still activates the fallback as a genuine last resort.
    static func isWithinColdStartWindow(startedAt: Date?, now: Date) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) < coldStartWindow
    }

    // MARK: - Cause-aware degradation (P2)

    /// Escalation threshold for publishing `.expired`. The first verified
    /// 401-with-token starts the clock; a later verified 401 at/after this
    /// threshold escalates to the loud banner. The *internal* `currentAuthState`
    /// still flips to `.expired` immediately (see `classifyAndPublishAuthState`)
    /// so `shouldSuppressTmuxFallback` keeps blocking the login-screen hang —
    /// only the *published* banner is debounced. Owner-tunable.
    private static let expiredEscalationThreshold: TimeInterval = 5 * 60

    /// Calm captions for non-alarming failures — shown in `.secondary` on the
    /// strip without raising the banner or firing a notification.
    static let transientUnavailableReason = "Claude usage temporarily unavailable — retrying"
    static let rateLimitedReason = "Rate limited — retrying shortly"

    /// Pure escalation predicate: escalate `.expired` to the banner only once a
    /// verified 401 has persisted from `first401At` to at least `threshold` later.
    /// No first 401 (`nil`) → never escalate.
    static func shouldEscalateExpired(first401At: Date?, now: Date, threshold: TimeInterval) -> Bool {
        guard let first401At else { return false }
        return now.timeIntervalSince(first401At) >= threshold
    }

    /// Pure publication routing for the verified-401-with-token branch.
    /// Pre-escalation: publish NO auth change (`nil` leaves the banner as-is) plus
    /// the calm transient caption. Post-escalation: publish `.expired`, no caption
    /// (the banner speaks for itself).
    static func expiredPublication(escalated: Bool) -> (authState: UsageAuthState?, reason: String?) {
        escalated ? (.expired, nil) : (nil, transientUnavailableReason)
    }

    /// Pure publication routing for the classifier branch: an alarming verdict
    /// publishes as-is (no caption — the banner owns it); a non-alarming verdict
    /// publishes the calm caption so the strip explains the degradation without alarm.
    static func failurePublication(verdict: UsageAuthState) -> (authState: UsageAuthState?, reason: String?) {
        verdict.isAlarming ? (verdict, nil) : (verdict, transientUnavailableReason)
    }

    /// Whether the interactive tmux `/usage` fallback may activate (P4 Task 14).
    /// `.tmuxOnly` is inherently opted in (the user chose the probe as their mode);
    /// every other mode requires the explicit opt-in pref (default OFF) because the
    /// interactive probe is the browser/ban-risk path.
    static func tmuxFallbackPermitted(mode: ClaudeUsageMode, optIn: Bool) -> Bool {
        mode == .tmuxOnly || optIn
    }

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
    /// Timestamp of the first verified 401-with-token in the current failure
    /// episode; drives the debounced `.expired` banner escalation (P2). Cleared
    /// on a successful fetch and whenever the failure path takes the non-401
    /// classifier branch (a different cause the classifier's own debounce owns).
    private var first401At: Date?

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
                serving.source = Self.cachedSource(for: cached.source)
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
            let (raw, bodyHash, rawBody, fromCache, fetchedAt) = try await usageClient.fetch(token: resolved.token)
            lastRawOAuthPayload = rawBody
            guard var snapshot = Self.normalizedOAuthSnapshot(raw, bodyHash: bodyHash, fromCache: fromCache, fetchedAt: fetchedAt) else {
                os_log("ClaudeOAuth: normalizer returned nil (empty payload)", log: log, type: .error)
                await handleOAuthFailure(reason: "empty payload")
                return
            }
            snapshot = await mergeMissingFiveHourWindowIfNeeded(snapshot)

            // Success — reset all failure state
            let recoveredFromFailure = oauthFailureCount > 0
            oauthFailureCount = 0
            oauthRateLimitRetryDeadline = nil
            didAttemptDelegatedRefresh = false
            first401At = nil
            lastFailureFingerprint = nil
            credentialWatchTask?.cancel()
            credentialWatchTask = nil
            lastOAuthSnapshot = snapshot
            await store.save(snapshot)

            // F5: a failure→success transition may mean the user just re-logged in.
            // Drop the throttled CLI-status cache so the authoritative probe below
            // re-runs fresh instead of serving a stale `.signedOut`/`.expired` for
            // up to the 120s throttle window after recovery.
            if recoveredFromFailure { cliStatusCache = nil }

            if !fromCache, usingWebFallback && mode != .webOnly {
                os_log("ClaudeOAuth: OAuth recovered, deactivating web API fallback", log: log, type: .info)
                usingWebFallback = false
                webRefreshTask?.cancel()
                webRefreshTask = nil
                webFailureCount = 0
            }
            if !fromCache, usingTmuxFallback {
                os_log("ClaudeOAuth: OAuth recovered, deactivating tmux fallback", log: log, type: .info)
                await deactivateTmuxFallback()
            }

            publish(snapshot)
            // The OAuth token still fetches, but the CLI may have been logged
            // out live while the resolver's cached token keeps working. Consult
            // the THROTTLED authoritative status probe so a live logout surfaces
            // within one poll instead of after the 10-min token cache. Only a
            // DEFINITIVE `.signedOut` overrides — the probe never false-fires, so
            // no debounce is needed and ambiguous/`.unknown` stays `.ok`.
            let gen = nextAuthGeneration()
            let cli = await throttledClaudeAuthStatus()
            let state = Self.successPathState(cli: cli)
            // I2: if a newer verdict computation started while we were suspended on
            // the probe above, drop this now-stale write instead of clobbering it.
            // The newer computation owns the next-refresh scheduling too.
            guard Self.verdictIsCurrent(captured: gen, current: authGeneration) else {
                os_log("ClaudeOAuth: dropping stale success-path auth verdict (newer computation started)",
                       log: log, type: .info)
                return
            }
            // A confirmed-good fetch (.ok) proves the account works, so clear the
            // classifier's debounce clock: this fast-path bypasses classify(), and
            // a stale firstMissAt from an earlier transient miss must not survive a
            // healthy poll to false-fire .signedOut later. Do NOT reset on
            // .signedOut — that is an authoritative logout the classifier must keep.
            if state == .ok { authClassifier.reset() }
            currentAuthState = state
            if Self.shouldSuppressTmuxFallback(state), usingTmuxFallback { await deactivateTmuxFallback() }
            availabilityHandler?(ClaudeServiceAvailability(cliUnavailable: false, tmuxUnavailable: false,
                                                           loginRequired: state == .signedOut, setupRequired: false, setupHint: nil,
                                                           authState: state))
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
            // classifyAndPublishAuthState (invoked first inside handleOAuthFailure)
            // is now the single 401 publisher — debounced via first401At. The old
            // immediate CLI-auth-required emit (stale login hint that bypassed the
            // debounce) has been removed.
            await handleOAuthFailure(reason: "401 unauthorized")

        } catch ClaudeOAuthUsageClientError.rateLimited(let retryAfter) {
            let delay = retryAfter + 10
            oauthRateLimitRetryDeadline = Date().addingTimeInterval(delay)
            os_log("ClaudeOAuth: rate limited, retrying in %.0fs", log: log, type: .info, delay)
            // Calm caption (authState nil → banner untouched). A rate limit is
            // transient and self-heals; it must never look like an auth failure.
            availabilityHandler?(ClaudeServiceAvailability(cliUnavailable: false, tmuxUnavailable: false,
                                                           transientReason: Self.rateLimitedReason))
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

        // Compute + publish the auth verdict FIRST (I1), before the switch below can
        // call `activateTmuxFallback`. This makes `currentAuthState` reflect THIS poll
        // so the activation guard sees the up-to-date verdict rather than a pre-classify
        // one. `was401` distinguishes an expired-but-present token from a truly absent one.
        await classifyAndPublishAuthState(was401: reason.contains("401"))

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
                    if Self.isWithinColdStartWindow(startedAt: startedAt, now: now) {
                        // Cold start: the OAuth path is almost always transiently
                        // not-ready (Keychain read racing launch, first-request
                        // hiccup). Retry OAuth via the cold-start schedule below
                        // instead of spawning the interactive CLI probe — which is
                        // what pops the browser auth page on a normal relaunch.
                        os_log("ClaudeOAuth: first failure with no cache during cold-start window — retrying OAuth, deferring tmux fallback",
                               log: log, type: .info)
                    } else {
                        os_log("ClaudeOAuth: no cache on first failure, activating tmux fallback early",
                               log: log, type: .info)
                        await activateTmuxFallback(reason: "first failure with no cache")
                    }
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
                    if Self.isWithinColdStartWindow(startedAt: startedAt, now: now) {
                        // Still inside the cold-start window: keep retrying the
                        // working OAuth path rather than spawn the browser-popping
                        // CLI probe. Reaching failure #3 this fast means a genuinely
                        // persistent problem, which the post-window retries (or the
                        // auth banner) will surface without an interactive login.
                        os_log("ClaudeOAuth: OAuth failure #%d during cold-start window — deferring tmux fallback, continuing OAuth retries",
                               log: log, type: .info, oauthFailureCount)
                    } else {
                        await activateTmuxFallback(reason: "OAuth failure #\(oauthFailureCount)")
                    }
                }
            }
        }

        if mode != .tmuxOnly && mode != .webOnly {
            scheduleOAuthRetry()
        }
    }

    /// The second (and only other) writer of `currentAuthState` besides the
    /// OAuth-success `.ok` path. Runs on failed/degraded polls: a verified 401
    /// while a token still exists is an `.expired` session; a 401 after the
    /// token vanished — or any other failure — defers to the stateful classifier.
    /// Then it publishes the verdict and tears down a live tmux fallback if the
    /// new state is one the probe must never run in (signed out / CLI missing).
    private func classifyAndPublishAuthState(was401: Bool) async {
        let gen = nextAuthGeneration()

        // Token evidence (cheap, no subprocess): keychain read + creds-file check.
        let keychain = await tokenResolver.resolveKeychainRead()
        let credsFilePresentToken = await tokenResolver.credsFileHasToken()
        let envTokenPresent = !(ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] ?? "").isEmpty
        // Include the env token: an expired env-token 401 must route to `.expired`,
        // not silently fall through to `.ok` (the env token is the resolver's source #1).
        let keychainFound: Bool = { if case .found = keychain { return true }; return false }()
        let hasToken = Self.hasAnyToken(keychainFound: keychainFound,
                                        credsFilePresentToken: credsFilePresentToken,
                                        envTokenPresent: envTokenPresent)

        let state: UsageAuthState
        if was401 && hasToken {
            // A verified 401 with a token still present = expired credentials.
            // A present token is not an absence, so clear the debounce clock —
            // this .expired verdict bypasses classify() and must not leave a
            // stale firstMissAt behind to false-fire .signedOut on a later miss.
            state = .expired
            authClassifier.reset()
        } else {
            // Non-401 failure, or a 401 after the token vanished (really signed
            // out): run the full stateful classifier for a debounced verdict.
            let cliStatus = await CLIAuthStatusProbe.probeClaudeAuthStatus()
            // Share this authoritative result with the throttled cache so the
            // immediate-suppression backstop in `activateTmuxFallback` (called just
            // below via the failure switch) reuses it instead of spawning a second
            // `claude auth status` subprocess in the same failure handler.
            cliStatusCache = (cliStatus, Date())
            // Deterministic disk existence check for the binary — never the flaky
            // login-shell/brew/npm probe, which can transiently return nil (e.g.
            // post-wake) and false-fire .cliNotInstalled for a signed-in user.
            let override = UserDefaults.standard.string(forKey: ClaudeResumeSettings.Keys.binaryPath)
            let binaryPresent = CLIBinaryPresence.claudeInstalled(overridePath: override)
            state = authClassifier.classify(
                ClaudeAuthInputs(cliStatus: cliStatus,
                                 keychain: keychain,
                                 credsFilePresentToken: credsFilePresentToken,
                                 binaryPresent: binaryPresent,
                                 envTokenPresent: envTokenPresent),
                now: Date()
            )
        }

        // I2: drop this write if a newer verdict computation started while we were
        // suspended on the keychain/creds/probe awaits above — never clobber a newer
        // verdict with this stale one.
        guard Self.verdictIsCurrent(captured: gen, current: authGeneration) else {
            os_log("ClaudeOAuth: dropping stale failure-path auth verdict (newer computation started)",
                   log: log, type: .info)
            return
        }

        currentAuthState = state
        if Self.shouldSuppressTmuxFallback(state), usingTmuxFallback {
            await deactivateTmuxFallback()
        }

        // Route the PUBLISHED verdict through the debounce/caption helpers. The
        // internal `currentAuthState` above is always immediate (protecting the
        // tmux-suppression guarantee); only what reaches the banner is shaped here.
        let published: (authState: UsageAuthState?, reason: String?)
        if was401 && hasToken {
            let now = Date()
            if first401At == nil { first401At = now }
            let escalated = Self.shouldEscalateExpired(first401At: first401At, now: now,
                                                       threshold: Self.expiredEscalationThreshold)
            published = Self.expiredPublication(escalated: escalated)
        } else {
            // A different cause than an expired token (non-401, or the token
            // vanished) — the classifier's own debounce owns this path, so clear
            // the expiry clock.
            first401At = nil
            published = Self.failurePublication(verdict: state)
        }

        // Legacy bools derive from the PUBLISHED authState (nil pre-escalation) so
        // "calm means calm": a debounced/transient emit never flips loginRequired.
        availabilityHandler?(ClaudeServiceAvailability(
            cliUnavailable: published.authState == .cliNotInstalled,
            tmuxUnavailable: false,
            loginRequired: published.authState == .signedOut,
            setupRequired: false,
            setupHint: nil,
            authState: published.authState,
            transientReason: published.reason
        ))
    }

    /// Throttled authoritative `claude auth status` probe for the SUCCESS path.
    /// Re-probes at most once per `cliStatusReprobeInterval` (120s); between
    /// probes returns the cached value; `.unknown` until the first probe. The
    /// probe is subprocess-based but async/cooperative (never blocks the actor),
    /// and it never reports a confident `.signedOut` on ambiguity/timeout.
    private func throttledClaudeAuthStatus() async -> CLIAuthStatus {
        let now = Date()
        if Self.shouldReprobe(lastAt: cliStatusCache?.at, now: now, interval: Self.cliStatusReprobeInterval) {
            let status = await CLIAuthStatusProbe.probeClaudeAuthStatus()
            cliStatusCache = (status, now)
            return status
        }
        return cliStatusCache?.status ?? .unknown
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

    private nonisolated static func normalizedOAuthSnapshot(_ raw: ClaudeOAuthRawUsageResponse,
                                                            bodyHash: String,
                                                            fromCache: Bool,
                                                            fetchedAt: Date) -> ClaudeLimitSnapshot? {
        guard var snapshot = ClaudeUsageNormalizer.normalize(raw, bodyHash: bodyHash, fetchedAt: fetchedAt) else {
            return nil
        }
        if fromCache { snapshot.source = .cachedOAuth }
        return snapshot
    }

    private nonisolated static func cachedSource(for source: ClaudeUsageSource) -> ClaudeUsageSource {
        switch source {
        case .oauthEndpoint, .cachedOAuth:
            return .cachedOAuth
        case .webEndpoint, .cachedWeb:
            return .cachedWeb
        case .tmuxUsage:
            return .tmuxUsage
        case .unavailable:
            return .unavailable
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
            let (raw, bodyHash, fromCache, fetchedAt) = try await webUsageClient.fetch(sessionKey: cookie.sessionKey)
            guard var snapshot = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: bodyHash, fetchedAt: fetchedAt) else {
                os_log("ClaudeOAuth: web normalizer returned nil", log: log, type: .error)
                await handleWebFailure(reason: "empty web payload")
                return
            }
            if fromCache { snapshot.source = .cachedWeb }
            snapshot = await mergeMissingFiveHourWindowIfNeeded(snapshot)

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

    /// Publish an auth verdict through the availability channel so a suppressed or
    /// aborted probe raises the banner instead of failing silently (P4 Task 12).
    private func emitAuthAvailability(_ state: UsageAuthState) {
        availabilityHandler?(ClaudeServiceAvailability(
            cliUnavailable: state == .cliNotInstalled,
            tmuxUnavailable: false,
            loginRequired: state == .signedOut,
            setupRequired: false,
            setupHint: nil,
            authState: state))
    }

    private func activateTmuxFallback(reason: String) async {
        if Self.shouldSuppressTmuxFallback(currentAuthState) {
            os_log("ClaudeOAuth: suppressing tmux fallback (auth state %{public}@)",
                   log: log, type: .info, String(describing: currentAuthState))
            // Don't fail silently: publish the verdict so the banner explains why.
            // A .tmuxOnly signed-out/expired user would otherwise get no probe AND
            // no banner (P4 Task 12).
            emitAuthAvailability(currentAuthState)
            return
        }
        guard tmuxAdapter == nil else { return }
        // I1: at a signed-out cold start (no cached data) or during the transition
        // window, `currentAuthState` may still be `.unknown` because the classifier's
        // debounce hasn't flipped it to `.signedOut` yet — so the guard above passes and
        // the probe would spawn and hang on the login screen. Consult the throttled
        // AUTHORITATIVE status probe as an immediate backstop: it never false-fires
        // `.signedOut`, so suppressing on a definitive signed-out / cli-missing here is
        // safe. The debounce still governs only the loud banner.
        let cli = await throttledClaudeAuthStatus()
        if cli == .signedOut || cli == .cliMissing {
            os_log("ClaudeOAuth: suppressing tmux fallback (authoritative probe %{public}@)",
                   log: log, type: .info, String(describing: cli))
            emitAuthAvailability(cli == .signedOut ? .signedOut : .cliNotInstalled)
            return
        }
        // Re-check after the probe await: a concurrent (reentrant) activation may have
        // created the adapter while we were suspended above, and creating a second one
        // would leak the first. This is the actor-reentrancy sibling of the I2 guard.
        guard tmuxAdapter == nil else { return }
        // P4 Task 14: the auto-mode interactive fallback is opt-in (default OFF) —
        // it's the browser/ban-risk path. Checked AFTER the suppression guards above
        // so a signed-out/expired user still gets the banner emit (Task 12). tmuxOnly
        // mode and the manual double-click hard probe are unaffected.
        let optIn = UserDefaults.standard.bool(forKey: PreferencesKey.claudeTmuxAutoFallbackOptIn)
        guard Self.tmuxFallbackPermitted(mode: mode, optIn: optIn) else {
            os_log("ClaudeOAuth: auto-mode tmux fallback disabled (opt-in off)", log: log, type: .info)
            return
        }
        os_log("ClaudeOAuth: activating tmux fallback: %{public}@", log: log, type: .info, reason)
        usingTmuxFallback = true

        let adapter = ClaudeTmuxUsageFallbackAdapter()
        self.tmuxAdapter = adapter

        let handler = self.snapshotHandler
        let availHandler = self.availabilityHandler
        let ctx = visibilityContext

        await adapter.start(
            handler: { snap in
                handler?(snap)
                Task { await self.recordExternalSnapshot(snap) }
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
        await recordExternalSnapshot(snapshot)
    }

#if DEBUG
    nonisolated static func normalizedOAuthSnapshotForTesting(_ raw: ClaudeOAuthRawUsageResponse,
                                                              bodyHash: String,
                                                              fromCache: Bool,
                                                              fetchedAt: Date) -> ClaudeLimitSnapshot? {
        normalizedOAuthSnapshot(raw, bodyHash: bodyHash, fromCache: fromCache, fetchedAt: fetchedAt)
    }
#endif

    // MARK: - Private

    private func mergeMissingFiveHourWindowIfNeeded(_ snapshot: ClaudeLimitSnapshot) async -> ClaudeLimitSnapshot {
        if let merged = Self.mergeMissingFiveHourWindow(incoming: snapshot, previous: lastOAuthSnapshot, now: Date()) {
            return merged
        }
        guard let persisted = await store.load() else { return snapshot }
        return Self.mergeMissingFiveHourWindow(incoming: snapshot, previous: persisted, now: Date()) ?? snapshot
    }

    private func recordExternalSnapshot(_ snapshot: ClaudeLimitSnapshot) async {
        lastOAuthSnapshot = snapshot
        await store.save(snapshot)
    }

    private func publish(_ snapshot: ClaudeLimitSnapshot) {
        snapshotHandler?(snapshot)
    }
}

extension ClaudeUsageSourceManager {
    nonisolated static func mergeMissingFiveHourWindow(incoming: ClaudeLimitSnapshot,
                                                       previous: ClaudeLimitSnapshot?,
                                                       now: Date = Date()) -> ClaudeLimitSnapshot? {
        guard incoming.fiveHourResetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let previous,
              previous.fiveHourUsedRatio != nil,
              !previous.fiveHourResetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              previous.health != .failed,
              now.timeIntervalSince(previous.fetchedAt) < 30 * 60,
              let previousReset = UsageResetText.resetDate(
                kind: "5h",
                source: .claude,
                raw: previous.fiveHourResetText,
                now: previous.fetchedAt
              ),
              previousReset > now else {
            return nil
        }

        var merged = incoming
        merged.fiveHourUsedRatio = previous.fiveHourUsedRatio
        merged.fiveHourResetText = previous.fiveHourResetText
        return merged
    }
}

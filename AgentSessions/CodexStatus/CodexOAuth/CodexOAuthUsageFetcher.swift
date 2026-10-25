import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "CodexOAuth")

// MARK: - Raw DTOs (defensive decoding)
//
// Mirrors the shape from chatgpt.com/backend-api/wham/usage.
// All fields optional — fail closed in the normalizer, not here.

struct CodexOAuthRawUsageResponse: Decodable {
    let rateLimit: RawRateLimitSnapshot?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    struct RawRateLimitSnapshot: Decodable {
        let primaryWindow: RawWindowDetails?
        let secondaryWindow: RawWindowDetails?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct RawWindowDetails: Decodable {
        let usedPercent: Int?
        let resetAt: Int?               // epoch seconds
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
}

// MARK: - Error

enum CodexOAuthUsageError: Error {
    case noCredentials
    case networkError(Error)
    case httpError(Int)
    case decodingError(Error)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
}

// MARK: - Result-typed fetch outcome

/// Mirrors `fetchUsage`'s outcomes but exposes the cause instead of
/// collapsing everything into `nil`, so the auth-health classifier can
/// distinguish "not logged in" (401) from "we didn't even try yet"
/// (cooldown) from "something else went wrong" (network/decode/429/etc).
enum CodexUsageFetchResult {
    case ok(CodexUsageSnapshot)
    case unauthorized
    case skippedCooldown
    case transient
}

enum CodexAuthRecheckOutcome: Equatable {
    case recovered
    case authenticationRequired
    case unavailable
}

/// Fetch health is separate from sign-in health: a valid token does not prove
/// that the displayed quota is current. Never include tokens or response bodies.
enum CodexQuotaFetchIssue: Equatable, Sendable {
    case network
    case http(Int)
    case invalidResponse
    case noCredentials
    case unauthorized
    case rateLimited

    var detail: LocalizedStringResource {
        switch self {
        case .network: return "Codex usage could not be refreshed because the connection failed."
        case .http(let status): return "Codex usage returned HTTP \(status)."
        case .invalidResponse: return "Codex returned usage data Agent Sessions could not read."
        case .noCredentials: return "Agent Sessions could not find saved Codex credentials."
        case .unauthorized: return "Codex rejected the saved credentials."
        case .rateLimited: return "Codex temporarily limited usage checks. Agent Sessions will retry after the server's waiting period."
        }
    }

    var recovery: LocalizedStringResource {
        switch self {
        case .noCredentials, .unauthorized:
            return "Run codex login in Terminal, then choose Retry."
        case .rateLimited:
            return "Wait for the server's retry period. Existing quota readings cannot be verified during this pause."
        case .invalidResponse:
            return "Update Agent Sessions, then choose Retry. If this continues, report the problem with the app version."
        case .http(401), .http(403):
            return "Check that Codex can access your account, then choose Retry. Sign in again with codex login if Codex also reports a sign-in problem."
        case .network, .http:
            return "Check your internet connection and VPN or proxy, then choose Retry. Agent Sessions also retries automatically within one minute while usage tracking is visible."
        }
    }
}

// MARK: - Fetcher

actor CodexOAuthUsageFetcher {
    private let credentials: CodexOAuthCredentials
    private let session: URLSession
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // Cooldown state
    private var lastFetchAt: Date? = nil
    private var lastFetchFailed: Bool = false
    private var rateLimitedUntil: Date? = nil
    private var lastCredentialSet: CodexTokenSet?
    private(set) var lastFailure: CodexQuotaFetchIssue?
    private let clock: @Sendable () -> Date

    init(credentials: CodexOAuthCredentials, session: URLSession? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.clock = clock
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = session ?? URLSession(configuration: config)
    }

    /// A Retry click bypasses local failure cooldowns, never a server's 429.
    func resetForUserRetry() {
        guard rateLimitedUntil.map({ $0 > clock() }) != true else { return }
        lastFetchAt = nil
        lastFetchFailed = false
    }

    /// Clears only in-memory retry state before an explicit user-initiated
    /// recovery check. A plan change can make the same saved login usable while
    /// this actor is still holding a failure cooldown. A server-directed 429
    /// still applies to the same credentials; resolving changed credentials
    /// below is what invalidates an old account's retry state.
    func resetForUserRecheck() async {
        lastFetchAt = nil
        lastFetchFailed = false
        await credentials.invalidateCache()
    }

#if DEBUG
    func seedRetryStateForTesting(lastFetchAt: Date, failed: Bool, rateLimitedUntil: Date?) {
        self.lastFetchAt = lastFetchAt
        self.lastFetchFailed = failed
        self.rateLimitedUntil = rateLimitedUntil
    }

    func retryStateForTesting() -> (lastFetchAt: Date?, failed: Bool, rateLimitedUntil: Date?) {
        (lastFetchAt, lastFetchFailed, rateLimitedUntil)
    }
#endif

    /// Returns a snapshot on success, nil on any failure (caller falls through).
    func fetchUsage(cooldownSuccess: TimeInterval = 5 * 60,
                    cooldownFailure: TimeInterval = 60) async -> CodexUsageSnapshot? {
        if case .ok(let snapshot) = await fetchUsageResult(
            cooldownSuccess: cooldownSuccess, cooldownFailure: cooldownFailure) {
            return snapshot
        }
        return nil
    }

    /// Result-typed sibling of `fetchUsage` that exposes *why* a fetch did
    /// not produce a snapshot. Mirrors the same rate-limit/cooldown gates
    /// and network call, but maps outcomes to `CodexUsageFetchResult`
    /// instead of `nil`. Shares cooldown/rate-limit state with
    /// `fetchUsage` (same actor instance), so callers of either API back
    /// off the same underlying endpoint.
    func fetchUsageResult(cooldownSuccess: TimeInterval = 5 * 60,
                           cooldownFailure: TimeInterval = 60) async -> CodexUsageFetchResult {
        let now = clock()
        let tokenSet = await currentCredentialsResettingCooldownOnChange()

        // Rate limit gate
        if let until = rateLimitedUntil, until > now {
            os_log("CodexOAuth: rate-limited until %{public}@", log: log, type: .debug,
                   until.description)
            return .skippedCooldown
        }

        // Cooldown gate
        if let last = lastFetchAt {
            let cd = lastFetchFailed ? cooldownFailure : cooldownSuccess
            if now.timeIntervalSince(last) < cd { return .skippedCooldown }
        }

        guard let tokenSet else {
            os_log("CodexOAuth: no credentials available", log: log, type: .info)
            // Record the attempt so the cooldown gate above applies to this path too.
            // Returning without stamping `lastFetchAt` meant a signed-out user never
            // established a cooldown at all, so every tick fell straight through to
            // the CLI-RPC probe — which spawns a `codex app-server` process. On a
            // background tick that is a process spawn per minute, indefinitely.
            lastFetchAt = now
            lastFetchFailed = true
            lastFailure = .noCredentials
            return .transient
        }

        lastFetchAt = now
        do {
            let raw = try await fetch(token: tokenSet.accessToken, accountId: tokenSet.accountId)
            guard var result = Self.normalizeResponse(raw) else {
                lastFetchFailed = true  // nil normalize = response shape changed
                lastFailure = .invalidResponse
                return .transient
            }
            result.limitsAccountHash = WeeklyQuotaCalibrationScope.hashAccount(tokenSet.accountId)
            lastFetchFailed = false
            lastFailure = nil
            return .ok(result)
        } catch CodexOAuthUsageError.unauthorized {
            os_log("CodexOAuth: 401 — token expired, invalidating", log: log, type: .info)
            await credentials.invalidateCache()
            lastFetchFailed = true
            lastFailure = .unauthorized
            return .unauthorized
        } catch CodexOAuthUsageError.rateLimited(let retryAfter) {
            rateLimitedUntil = clock().addingTimeInterval(retryAfter)
            lastFetchFailed = true
            lastFailure = .rateLimited
            return .transient
        } catch {
            switch error {
            case CodexOAuthUsageError.httpError(let status): lastFailure = .http(status)
            case CodexOAuthUsageError.decodingError: lastFailure = .invalidResponse
            default: lastFailure = .network
            }
            let cause: NSError
            if case CodexOAuthUsageError.networkError(let underlying) = error {
                cause = underlying as NSError
            } else { cause = error as NSError }
            os_log("CodexOAuth: fetch failed (%{public}@, code %ld)", log: log, type: .error,
                   cause.domain, cause.code)
            lastFetchFailed = true
            return .transient
        }
    }

    // MARK: - Private

    private func currentCredentialsResettingCooldownOnChange() async -> CodexTokenSet? {
        let current = await credentials.resolve()
        if current != lastCredentialSet {
            lastFetchAt = nil
            lastFetchFailed = false
            rateLimitedUntil = nil
            lastCredentialSet = current
        }
        return current
    }

    private func fetch(token: String, accountId: String?) async throws -> CodexOAuthRawUsageResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentSessions", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexOAuthUsageError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                throw CodexOAuthUsageError.unauthorized
            }
            if http.statusCode == 429 {
                let raw = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init) ?? 0
                throw CodexOAuthUsageError.rateLimited(retryAfter: max(raw, 300))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw CodexOAuthUsageError.httpError(http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(CodexOAuthRawUsageResponse.self, from: data)
        } catch {
            throw CodexOAuthUsageError.decodingError(error)
        }
    }

    private nonisolated static func normalizeResponse(_ raw: CodexOAuthRawUsageResponse) -> CodexUsageSnapshot? {
        guard let rl = raw.rateLimit else { return nil }
        var snap = CodexUsageSnapshot()
        var hasData = false

        // Route by window *length*, not slot position — see
        // CodexRateLimitWindowClassifier for why: the provider does not
        // reliably send the 5h window in `primary_window` and the weekly
        // window in `secondary_window`.
        let routing = CodexRateLimitWindowClassifier.route(
            windowInput(from: rl.primaryWindow),
            windowInput(from: rl.secondaryWindow)
        )

        if let fiveHour = routing.fiveHour {
            if let remaining = fiveHour.remainingPercent {
                snap.fiveHourRemainingPercent = max(0, min(100, Int(remaining.rounded())))
                snap.hasFiveHourRateLimit = true
                hasData = true
            }
            if let resetAt = fiveHour.resetAt {
                snap.fiveHourResetText = formatResetISO8601(resetAt)
                snap.hasFiveHourRateLimit = true
                hasData = true
            }
        }
        if let weekly = routing.weekly {
            if let remaining = weekly.remainingPercent {
                snap.weekRemainingPercent = max(0, min(100, Int(remaining.rounded())))
                snap.hasWeekRateLimit = true
                hasData = true
            }
            if let resetAt = weekly.resetAt {
                snap.weekResetText = formatResetISO8601(resetAt)
                snap.hasWeekRateLimit = true
                hasData = true
            }
        }
        snap.usageFormatSuspect = routing.suspect

        // A response with NOTHING placeable is treated as "no data" — fall through
        // so the app shows its calm reconnecting state, never an alarming
        // "can't verify". (Surfacing zero-window suspect misfired during the normal
        // connect window, e.g. a length-less lone CLI window.) A partial-suspect
        // response still surfaces via hasData: the good window shows, the drifted
        // one is flagged.
        guard hasData else { return nil }
        snap.limitsSource = .oauth
        snap.eventTimestamp = Date()
        return snap
    }

    /// Adapts one raw window DTO into the shared classifier's input shape.
    /// Returns nil when the window is absent, or present but carries none of
    /// the three signals the classifier uses — both are "no window here",
    /// which `route` treats as absent rather than suspect.
    private nonisolated static func windowInput(
        from window: CodexOAuthRawUsageResponse.RawWindowDetails?
    ) -> CodexRateLimitWindowInput? {
        guard let window else { return nil }
        guard window.usedPercent != nil || window.resetAt != nil || window.limitWindowSeconds != nil else {
            return nil
        }
        return CodexRateLimitWindowInput(
            // Intentionally not clamped: the classifier's sanity check flags
            // an out-of-[0,100] value as suspect. Clamping happens only when
            // the routed result is stored into the snapshot above.
            remainingPercent: window.usedPercent.map { 100 - Double($0) },
            resetAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowMinutes: window.limitWindowSeconds.map { $0 / 60 }
        )
    }

#if DEBUG
    nonisolated static func normalizeForTesting(_ raw: CodexOAuthRawUsageResponse) -> CodexUsageSnapshot? {
        normalizeResponse(raw)
    }
#endif
}

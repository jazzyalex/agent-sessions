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

// MARK: - Fetcher

actor CodexOAuthUsageFetcher {
    private let credentials: CodexOAuthCredentials
    private let session: URLSession
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // Cooldown state
    private var lastFetchAt: Date? = nil
    private var lastFetchFailed: Bool = false
    private var rateLimitedUntil: Date? = nil

    init(credentials: CodexOAuthCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    /// Returns a snapshot on success, nil on any failure (caller falls through).
    func fetchUsage(cooldownSuccess: TimeInterval = 5 * 60,
                    cooldownFailure: TimeInterval = 30 * 60) async -> CodexUsageSnapshot? {
        let now = Date()

        // Rate limit gate
        if let until = rateLimitedUntil, until > now {
            os_log("CodexOAuth: rate-limited until %{public}@", log: log, type: .debug,
                   until.description)
            return nil
        }

        // Cooldown gate
        if let last = lastFetchAt {
            let cd = lastFetchFailed ? cooldownFailure : cooldownSuccess
            if now.timeIntervalSince(last) < cd { return nil }
        }

        guard let tokenSet = await credentials.resolve() else {
            os_log("CodexOAuth: no credentials available", log: log, type: .info)
            return nil
        }

        lastFetchAt = now
        do {
            let raw = try await fetch(token: tokenSet.accessToken, accountId: tokenSet.accountId)
            let result = Self.normalizeResponse(raw)
            lastFetchFailed = (result == nil)  // nil normalize = response shape changed
            return result
        } catch CodexOAuthUsageError.unauthorized {
            os_log("CodexOAuth: 401 — token expired, invalidating", log: log, type: .info)
            await credentials.invalidateCache()
            lastFetchFailed = true
            return nil
        } catch CodexOAuthUsageError.rateLimited(let retryAfter) {
            rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            lastFetchFailed = true
            return nil
        } catch {
            os_log("CodexOAuth: fetch failed: %{public}@", log: log, type: .error,
                   error.localizedDescription)
            lastFetchFailed = true
            return nil
        }
    }

    // MARK: - Private

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

        if let primary = rl.primaryWindow {
            if let used = primary.usedPercent {
                snap.fiveHourRemainingPercent = max(0, min(100, 100 - used))
                snap.hasFiveHourRateLimit = true
                hasData = true
            }
            if let epoch = primary.resetAt {
                snap.fiveHourResetText = formatResetISO8601(Date(timeIntervalSince1970: TimeInterval(epoch)))
                snap.hasFiveHourRateLimit = true
                hasData = true
            }
        }
        if let secondary = rl.secondaryWindow {
            if let used = secondary.usedPercent {
                snap.weekRemainingPercent = max(0, min(100, 100 - used))
                snap.hasWeekRateLimit = true
                hasData = true
            }
            if let epoch = secondary.resetAt {
                snap.weekResetText = formatResetISO8601(Date(timeIntervalSince1970: TimeInterval(epoch)))
                snap.hasWeekRateLimit = true
                hasData = true
            }
        }

        guard hasData else { return nil }
        snap.limitsSource = .oauth
        snap.eventTimestamp = Date()
        return snap
    }

#if DEBUG
    nonisolated static func normalizeForTesting(_ raw: CodexOAuthRawUsageResponse) -> CodexUsageSnapshot? {
        normalizeResponse(raw)
    }
#endif
}

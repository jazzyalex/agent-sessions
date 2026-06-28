import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "CodexResetCredits")

// MARK: - Raw DTOs (defensive: all fields optional, fail closed in parser)

private struct RawResetCreditsResponse: Decodable {
    let availableCount: Int?
    let credits: [RawResetCredit]?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }
}

private struct RawResetCredit: Decodable {
    let grantedAt: String?
    let expiresAt: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case status
    }
}

// MARK: - Parser (pure, unit-tested)

enum CodexResetCreditsParser {
    static func parse(_ data: Data) -> CodexResetCreditsSnapshot? {
        guard let raw = try? JSONDecoder().decode(RawResetCreditsResponse.self, from: data) else {
            return nil
        }
        let rawCredits = raw.credits ?? []
        let credits = rawCredits.map { rc in
            CodexResetCredit(
                grantedAt: isoDate(rc.grantedAt),
                expiresAt: isoDate(rc.expiresAt),
                status: rc.status
            )
        }
        let available = raw.availableCount ?? credits.count
        return CodexResetCreditsSnapshot(available: max(0, available), credits: credits)
    }

    private static func isoDate(_ text: String?) -> Date? {
        guard let text, text.contains("T") else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: text) { return d }
        let std = ISO8601DateFormatter()
        std.formatOptions = [.withInternetDateTime]
        return std.date(from: text)
    }
}

// MARK: - Error

private enum CodexResetCreditsError: Error {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    case httpError(Int)
    case needsExtraHeaders
    case networkError(Error)
}

// MARK: - Fetcher

actor CodexResetCreditsFetcher {
    private let credentials: CodexOAuthCredentials
    private let session: URLSession
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    private var lastFetchAt: Date?
    private var lastFetchFailed = false
    private var rateLimitedUntil: Date?

    init(credentials: CodexOAuthCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    /// Returns a snapshot on success, nil on any failure (caller leaves model untouched).
    /// Credits are slow-moving, so the default cooldown is long.
    func fetch(cooldownSuccess: TimeInterval = 6 * 60 * 60,
               cooldownFailure: TimeInterval = 30 * 60) async -> CodexResetCreditsSnapshot? {
        let now = Date()

        if let until = rateLimitedUntil, until > now { return nil }
        if let last = lastFetchAt {
            let cd = lastFetchFailed ? cooldownFailure : cooldownSuccess
            if now.timeIntervalSince(last) < cd { return nil }
        }

        guard let tokenSet = await credentials.resolve() else { return nil }

        lastFetchAt = now
        do {
            let data = try await request(token: tokenSet.accessToken,
                                         accountId: tokenSet.accountId,
                                         extraHeaders: false)
            return finish(data)
        } catch CodexResetCreditsError.needsExtraHeaders {
            // Some accounts require the Codex-Desktop originator headers; retry once.
            do {
                let data = try await request(token: tokenSet.accessToken,
                                             accountId: tokenSet.accountId,
                                             extraHeaders: true)
                return finish(data)
            } catch {
                lastFetchFailed = true
                return nil
            }
        } catch CodexResetCreditsError.unauthorized {
            await credentials.invalidateCache()
            lastFetchFailed = true
            return nil
        } catch CodexResetCreditsError.rateLimited(let retryAfter) {
            rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            lastFetchFailed = true
            return nil
        } catch {
            os_log("CodexResetCredits: fetch failed: %{public}@", log: log, type: .error,
                   String(describing: error))
            lastFetchFailed = true
            return nil
        }
    }

    private func finish(_ data: Data) -> CodexResetCreditsSnapshot? {
        let snap = CodexResetCreditsParser.parse(data)
        lastFetchFailed = (snap == nil)
        return snap
    }

    private func request(token: String, accountId: String?, extraHeaders: Bool) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentSessions", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if extraHeaders {
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexResetCreditsError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw CodexResetCreditsError.unauthorized }
            if http.statusCode == 429 {
                let raw = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 0
                throw CodexResetCreditsError.rateLimited(retryAfter: max(raw, 300))
            }
            // Bare request rejected → signal a single retry with originator headers.
            if !extraHeaders, http.statusCode == 403 || http.statusCode == 404 {
                throw CodexResetCreditsError.needsExtraHeaders
            }
            guard (200..<300).contains(http.statusCode) else {
                throw CodexResetCreditsError.httpError(http.statusCode)
            }
        }
        return data
    }
}

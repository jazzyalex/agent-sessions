import Foundation
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Raw DTOs (defensive decoding)
//
// Mirrors the shape observed from api.anthropic.com/api/oauth/usage.
// Uses optional fields throughout — fail closed in the normalizer, not here.

struct ClaudeOAuthRawUsageResponse: Decodable {
    let session5h: RawWindow?
    let weekAllModels: RawWindow?
    let weekOpus: RawWindow?

    enum CodingKeys: String, CodingKey {
        case session5h = "session_5h"
        case weekAllModels = "week_all_models"
        case weekOpus = "week_opus"
    }

    struct RawWindow: Decodable {
        let pctLeft: Int?
        let resets: String?

        enum CodingKeys: String, CodingKey {
            case pctLeft = "pct_left"
            case resets
        }
    }
}

// MARK: - OAuth Usage Client

enum ClaudeOAuthUsageClientError: Error {
    case networkError(Error)
    case httpError(Int)
    case decodingError(Error)
    case unauthorized           // 401 — token invalid/expired
    case rateLimited(retryAfter: TimeInterval)  // 429 — honor Retry-After
}

actor ClaudeOAuthUsageClient {
    private let session: URLSession
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    func fetch(token: String) async throws -> (response: ClaudeOAuthRawUsageResponse, bodyHash: String, rawBody: String) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.34", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            os_log("ClaudeOAuth: network error: %{public}@", log: log, type: .error, error.localizedDescription)
            throw ClaudeOAuthUsageClientError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                os_log("ClaudeOAuth: 401 unauthorized", log: log, type: .info)
                throw ClaudeOAuthUsageClientError.unauthorized
            }
            if http.statusCode == 429 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                    .flatMap(TimeInterval.init) ?? 300
                os_log("ClaudeOAuth: 429 rate limited, retry-after=%.0fs", log: log, type: .info, retryAfter)
                throw ClaudeOAuthUsageClientError.rateLimited(retryAfter: retryAfter)
            }
            guard (200..<300).contains(http.statusCode) else {
                os_log("ClaudeOAuth: HTTP %d", log: log, type: .error, http.statusCode)
                throw ClaudeOAuthUsageClientError.httpError(http.statusCode)
            }
        }

        let bodyHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        // Pretty-print for diagnostics; fall back to raw string if JSONSerialization fails
        let rawBody: String
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
           let str = String(data: pretty, encoding: .utf8) {
            rawBody = str
        } else {
            rawBody = String(data: data, encoding: .utf8) ?? "<undecodable>"
        }

        let parsed: ClaudeOAuthRawUsageResponse
        do {
            parsed = try JSONDecoder().decode(ClaudeOAuthRawUsageResponse.self, from: data)
        } catch {
            os_log("ClaudeOAuth: decode error: %{public}@", log: log, type: .error, error.localizedDescription)
            throw ClaudeOAuthUsageClientError.decodingError(error)
        }

        os_log("ClaudeOAuth: fetch succeeded", log: log, type: .debug)
        return (parsed, bodyHash, rawBody)
    }
}

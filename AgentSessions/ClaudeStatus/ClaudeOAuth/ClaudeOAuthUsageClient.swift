import Foundation
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Raw DTOs (defensive decoding)
//
// Mirrors the shape observed from api.anthropic.com/api/oauth/usage.
// Uses optional fields throughout — fail closed in the normalizer, not here.

struct ClaudeOAuthRawUsageResponse: Decodable {
    let fiveHour: RawWindow?
    let sevenDay: RawWindow?
    let sevenDayOpus: RawWindow?
    let sevenDaySonnet: RawWindow?  // decoded but not yet surfaced in ClaudeLimitSnapshot

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    struct RawWindow: Decodable {
        let utilization: Double?   // percent used (0-100)
        let resetsAt: String?      // ISO 8601 timestamp

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
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

    // Shared file cache compatible with ClaudeCodeStatusLine
    // (github.com/daniel3303/ClaudeCodeStatusLine). Both tools read/write the
    // same file so the per-account API quota (~few requests per 20 min) is
    // shared across all consumers rather than each one burning quota independently.
    private static let sharedCacheURL = URL(fileURLWithPath: "/tmp/claude/statusline-usage-cache.json")
    private static let cacheMaxAge: TimeInterval = 60  // seconds

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    func fetch(token: String) async throws -> (response: ClaudeOAuthRawUsageResponse, bodyHash: String, rawBody: String) {
        // Check shared file cache first — avoids redundant API calls across
        // AgentSessions restarts and external tools (ClaudeCodeStatusLine).
        if let cached = readSharedCache() {
            os_log("ClaudeOAuth: serving from shared cache (age %.0fs)", log: log, type: .debug, cached.age)
            return cached.result
        }

        // Touch the cache file before fetching so concurrent consumers see
        // a fresh mtime and skip their own fetch (same pattern as ClaudeCodeStatusLine).
        touchSharedCache()

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
                // Clamp to minimum 5 minutes — server sometimes returns 0 which
                // is not actionable and causes rapid retry loops that extend the window.
                let raw = (http.value(forHTTPHeaderField: "Retry-After"))
                    .flatMap(TimeInterval.init) ?? 0
                let retryAfter = max(raw, 300)
                os_log("ClaudeOAuth: 429 rate limited, retry-after=%.0fs (raw=%.0f)", log: log, type: .info, retryAfter, raw)
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

        // Write successful response to shared cache for other consumers
        writeSharedCache(data: data)

        os_log("ClaudeOAuth: fetch succeeded", log: log, type: .debug)
        return (parsed, bodyHash, rawBody)
    }

    // MARK: - Shared File Cache

    private struct CachedResult {
        let result: (response: ClaudeOAuthRawUsageResponse, bodyHash: String, rawBody: String)
        let age: TimeInterval
    }

    /// Read from the shared cache file if it exists and is fresh.
    private func readSharedCache() -> CachedResult? {
        let url = Self.sharedCacheURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }

        // Check mtime freshness
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let age = Date().timeIntervalSince(mtime)
        guard age < Self.cacheMaxAge else { return nil }

        // Parse the cached JSON
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Validate it's a real usage response (has five_hour key), not an error
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["five_hour"] != nil else { return nil }

        guard let parsed = try? JSONDecoder().decode(ClaudeOAuthRawUsageResponse.self, from: data) else { return nil }

        let bodyHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let rawBody: String
        if let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
           let str = String(data: pretty, encoding: .utf8) {
            rawBody = str
        } else {
            rawBody = String(data: data, encoding: .utf8) ?? "<undecodable>"
        }

        return CachedResult(result: (parsed, bodyHash, rawBody), age: age)
    }

    /// Touch the cache file to claim the fetch slot (prevents concurrent fetches).
    private func touchSharedCache() {
        let url = Self.sharedCacheURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } else {
            fm.createFile(atPath: url.path, contents: nil)
        }
    }

    /// Write a successful API response to the shared cache.
    private func writeSharedCache(data: Data) {
        let url = Self.sharedCacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

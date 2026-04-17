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
    private static let sharedCacheTokenURL = URL(fileURLWithPath: "/tmp/claude/statusline-usage-cache.token")
    private static let cacheMaxAge: TimeInterval = 240  // 4 minutes — reduces API calls across shared consumers

    /// Resolved once at init from `claude --version`; falls back to a safe default.
    private let userAgent: String

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
        self.userAgent = Self.resolveUserAgent()
    }

    /// Shell out to `claude --version` with a timeout guard and cache the result.
    private static func resolveUserAgent() -> String {
        let fallback = "claude-code/0.0.0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return fallback }
        // Poll with timeout (matches ClaudeOAuthTokenResolver pattern)
        let maxWait = 20  // 2 seconds max
        var iterations = 0
        while process.isRunning && iterations < maxWait {
            Thread.sleep(forTimeInterval: 0.1)
            iterations += 1
        }
        if process.isRunning { process.terminate(); return fallback }
        guard process.terminationStatus == 0 else { return fallback }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return fallback }
        // Output is like "2.1.90 (Claude Code)" — extract version number
        let version = raw.components(separatedBy: " ").first ?? raw
        return "claude-code/\(version)"
    }

    func fetch(token: String) async throws -> (response: ClaudeOAuthRawUsageResponse, bodyHash: String, rawBody: String) {
        let tokenFP = tokenFingerprint(token)

        // Check shared file cache first — avoids redundant API calls across
        // AgentSessions restarts and external tools (ClaudeCodeStatusLine).
        if let cached = readSharedCache(tokenFingerprint: tokenFP) {
            os_log("ClaudeOAuth: serving from shared cache (age %.0fs)", log: log, type: .debug, cached.age)
            return cached.result
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
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
        writeSharedCache(data: data, tokenFingerprint: tokenFP)

        os_log("ClaudeOAuth: fetch succeeded", log: log, type: .debug)
        return (parsed, bodyHash, rawBody)
    }

    // MARK: - Shared File Cache

    private struct CachedResult {
        let result: (response: ClaudeOAuthRawUsageResponse, bodyHash: String, rawBody: String)
        let age: TimeInterval
    }

    /// Stable 8-hex-char fingerprint of a token for per-account cache scoping.
    private func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Read from the shared cache file if it exists, is fresh, and was produced by the same account.
    private func readSharedCache(tokenFingerprint fp: String) -> CachedResult? {
        let url = Self.sharedCacheURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }

        // Check mtime freshness
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let age = Date().timeIntervalSince(mtime)
        guard age < Self.cacheMaxAge else { return nil }

        // Verify the cache was produced by the same account.
        // Missing sidecar (e.g., written by ClaudeCodeStatusLine or older build) → cache miss.
        // Sidecar format: "{tokenFingerprint}:{contentHash}" — the content hash detects
        // partially-updated pairs (JSON and sidecar are two independent writes).
        guard let sidecar = try? String(contentsOf: Self.sharedCacheTokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let sidecarParts = sidecar.split(separator: ":", maxSplits: 1)
        guard sidecarParts.count == 2, String(sidecarParts[0]) == fp else { return nil }
        let expectedContentHash = String(sidecarParts[1])

        // Parse the cached JSON
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Verify content hash to detect a stale JSON/sidecar pairing
        let actualContentHash = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        guard actualContentHash == expectedContentHash else { return nil }

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

    /// Write a successful API response to the shared cache with token fingerprint.
    /// Sidecar is written AFTER the JSON so readers that see a new sidecar are
    /// guaranteed the JSON is at least as new. Content hash in the sidecar lets
    /// readers detect the reverse race (new JSON, old sidecar).
    private func writeSharedCache(data: Data, tokenFingerprint fp: String) {
        let dir = Self.sharedCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try? data.write(to: Self.sharedCacheURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: Self.sharedCacheURL.path
        )
        let contentHash = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        try? "\(fp):\(contentHash)".write(to: Self.sharedCacheTokenURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: Self.sharedCacheTokenURL.path
        )
    }
}

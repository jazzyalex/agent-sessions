import Foundation
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Web API Raw DTOs
//
// Shape mirrors ClaudeOAuthRawUsageResponse — the claude.ai web API is assumed
// to return the same structure as the OAuth endpoint.

struct ClaudeWebRawUsageResponse: Decodable {
    let fiveHour: RawWindow?
    let sevenDay: RawWindow?
    let sevenDayOpus: RawWindow?
    let sevenDaySonnet: RawWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour      = "five_hour"
        case sevenDay      = "seven_day"
        case sevenDayOpus  = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    struct RawWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

// MARK: - Web API Client
//
// Two-step fetch:
//   1. GET https://claude.ai/api/organizations → extract first org UUID
//   2. GET https://claude.ai/api/organizations/{orgId}/usage → usage data
//
// Shares the same error type as ClaudeOAuthUsageClient (same semantics).
// Org UUID is cached in-memory (doesn't change within a session).
// Response is cached in /tmp/claude/statusline-webapi-cache.json (60s TTL).

actor ClaudeWebUsageClient {
    private let session: URLSession
    private var cachedOrgId: String?

    private static let sharedCacheURL = URL(fileURLWithPath: "/tmp/claude/statusline-webapi-cache.json")
    private static let cacheMaxAge: TimeInterval = 60

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    func invalidateOrgId() {
        cachedOrgId = nil
    }

    func fetch(sessionKey: String) async throws -> (response: ClaudeWebRawUsageResponse, bodyHash: String, fromCache: Bool) {
        if let cached = readSharedCache() {
            os_log("ClaudeOAuth: web API — serving from cache", log: log, type: .debug)
            return (cached.response, cached.bodyHash, true)
        }

        let orgId = try await resolveOrgId(sessionKey: sessionKey)

        var usageRequest = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!)
        usageRequest.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        usageRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        usageRequest.setValue("Mozilla/5.0 AgentSessions", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: usageRequest)
        } catch {
            throw ClaudeOAuthUsageClientError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw ClaudeOAuthUsageClientError.unauthorized }
            if http.statusCode == 429 {
                let raw = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 0
                throw ClaudeOAuthUsageClientError.rateLimited(retryAfter: max(raw, 300))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ClaudeOAuthUsageClientError.httpError(http.statusCode)
            }
        }

        let bodyHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let parsed: ClaudeWebRawUsageResponse
        do {
            parsed = try JSONDecoder().decode(ClaudeWebRawUsageResponse.self, from: data)
        } catch {
            throw ClaudeOAuthUsageClientError.decodingError(error)
        }

        writeSharedCache(data: data)
        os_log("ClaudeOAuth: web API fetch succeeded", log: log, type: .debug)
        return (parsed, bodyHash, false)
    }

    // MARK: - Org ID resolution

    private func resolveOrgId(sessionKey: String) async throws -> String {
        if let cached = cachedOrgId { return cached }

        var request = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 AgentSessions", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeOAuthUsageClientError.networkError(error)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw ClaudeOAuthUsageClientError.unauthorized }
            guard (200..<300).contains(http.statusCode) else {
                throw ClaudeOAuthUsageClientError.httpError(http.statusCode)
            }
        }

        struct OrgEntry: Decodable { let uuid: String }
        guard let orgs = try? JSONDecoder().decode([OrgEntry].self, from: data),
              let first = orgs.first,
              UUID(uuidString: first.uuid) != nil else {
            throw ClaudeOAuthUsageClientError.decodingError(
                NSError(domain: "ClaudeWeb", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No valid organization UUID in response"]))
        }
        cachedOrgId = first.uuid
        return first.uuid
    }

    // MARK: - Shared File Cache

    private struct CachedResult {
        let response: ClaudeWebRawUsageResponse
        let bodyHash: String
    }

    private func readSharedCache() -> CachedResult? {
        let url = Self.sharedCacheURL
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < Self.cacheMaxAge,
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(ClaudeWebRawUsageResponse.self, from: data)
        else { return nil }
        let bodyHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        return CachedResult(response: parsed, bodyHash: bodyHash)
    }

    private func writeSharedCache(data: Data) {
        let dir = Self.sharedCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        try? data.write(to: Self.sharedCacheURL, options: .atomic)
    }
}

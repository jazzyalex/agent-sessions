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
// Responses are cached in memory for the same credential owner only (3m TTL).

actor ClaudeWebUsageClient {
    private let credentials: ClaudeCredentialService
    private let session: URLSession
    private var cachedOrgId: String?
    private var cacheOwner: String?
    private var cachedResponse: CachedResult?

    private static let sharedCacheURL = URL(fileURLWithPath: "/tmp/claude/statusline-webapi-cache.json")
    private static let cacheMaxAge: TimeInterval = 3 * 60

    init(session: URLSession? = nil, credentials: ClaudeCredentialService = .shared) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = session ?? URLSession(configuration: config)
    }

    func invalidateOrgId() {
        cachedOrgId = nil
        cachedResponse = nil
        cacheOwner = nil
    }

    private func checkOwner(
        _ owner: String,
        metrics: SearchResponsivenessMetrics,
        operationID: SearchResponsivenessOperationID?,
        context: SearchResponsivenessMetricContext,
        recordRejectedPublication: Bool = false
    ) throws {
        let isWebOwner = owner.hasPrefix("web:") || owner.hasPrefix("legacy:")
        guard !Task.isCancelled, cacheOwner == owner,
              !isWebOwner || credentials.isCurrentWebOwner(owner) else {
            if recordRejectedPublication {
                metrics.record(.credentialPublicationRejected, operationID: operationID,
                               context: context, status: .rejected)
            }
            throw CancellationError()
        }
    }

    private func checkLease(
        _ lease: ClaudeCredentialRequestLease?,
        metrics: SearchResponsivenessMetrics,
        operationID: SearchResponsivenessOperationID?,
        context: SearchResponsivenessMetricContext,
        recordRejectedPublication: Bool = false
    ) throws {
        do {
            try lease?.check()
        } catch {
            if recordRejectedPublication {
                metrics.record(.credentialPublicationRejected, operationID: operationID,
                               context: context, status: .rejected)
            }
            throw error
        }
    }

    /// - Parameter bypassCache: when true, skip the 3-minute shared file cache and
    ///   force a live request with THIS `sessionKey`. Used by the user-initiated
    ///   self-test so it actually validates the pasted cookie instead of returning
    ///   a recent response fetched with a different cookie.
    func fetch(sessionKey: String, bypassCache: Bool = false, owner suppliedOwner: String? = nil,
               lease: ClaudeCredentialRequestLease? = nil) async throws -> (response: ClaudeWebRawUsageResponse, bodyHash: String, fromCache: Bool, fetchedAt: Date) {
        let owner = suppliedOwner ?? "ephemeral:" + SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let metrics = SearchResponsivenessMetrics.shared
        let metricContext = SearchResponsivenessMetricContext.credentialOwner(owner)
        let operationID = metrics.operation(source: "claude-web-usage", sessionID: owner, start: true)
        try Task.checkCancellation()
        try checkLease(lease, metrics: metrics, operationID: operationID, context: metricContext)
        guard !(owner.hasPrefix("web:") || owner.hasPrefix("legacy:")) || credentials.isCurrentWebOwner(owner) else {
            throw CancellationError()
        }
        if cacheOwner != owner {
            cacheOwner = owner
            cachedOrgId = nil
            cachedResponse = nil
        }
        try checkOwner(owner, metrics: metrics, operationID: operationID, context: metricContext)
        try checkLease(lease, metrics: metrics, operationID: operationID, context: metricContext)
        if !bypassCache, let cached = cachedResponse, Self.isCacheFresh(modificationDate: cached.fetchedAt) {
            metrics.record(.credentialCacheLookup, operationID: operationID,
                           context: metricContext, status: .cacheHit)
            os_log("ClaudeOAuth: web API — serving from cache", log: log, type: .debug)
            metrics.record(.credentialPublicationAccepted, operationID: operationID,
                           context: metricContext, status: .published)
            return (cached.response, cached.bodyHash, true, cached.fetchedAt)
        }
        metrics.record(.credentialCacheLookup, operationID: operationID,
                       context: metricContext, status: .cacheMiss)

        let orgId = try await resolveOrgId(sessionKey: sessionKey, owner: owner, lease: lease,
                                           metrics: metrics, operationID: operationID, context: metricContext)
        try checkOwner(owner, metrics: metrics, operationID: operationID, context: metricContext)
        try checkLease(lease, metrics: metrics, operationID: operationID, context: metricContext)

        var usageRequest = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!)
        usageRequest.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        usageRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        usageRequest.setValue("Mozilla/5.0 AgentSessions", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        let networkSpan = metrics.beginSpan(.credentialNetwork, operationID: operationID, context: metricContext)
        do {
            (data, response) = try await session.data(for: usageRequest)
        } catch {
            if let networkSpan {
                Task.isCancelled ? metrics.cancel(networkSpan) : metrics.fail(networkSpan, code: .unavailable)
            }
            throw ClaudeOAuthUsageClientError.networkError(error)
        }
        if let networkSpan { Task.isCancelled ? metrics.cancel(networkSpan) : metrics.end(networkSpan) }
        try checkOwner(owner, metrics: metrics, operationID: operationID, context: metricContext,
                       recordRejectedPublication: true)
        try checkLease(lease, metrics: metrics, operationID: operationID, context: metricContext,
                       recordRejectedPublication: true)

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

        cachedResponse = CachedResult(response: parsed, bodyHash: bodyHash, fetchedAt: Date())
        metrics.record(.credentialCacheWrite, operationID: operationID,
                       context: metricContext, status: .published)
        os_log("ClaudeOAuth: web API fetch succeeded", log: log, type: .debug)
        metrics.record(.credentialPublicationAccepted, operationID: operationID,
                       context: metricContext, status: .published)
        return (parsed, bodyHash, false, Date())
    }

    // MARK: - Org ID resolution

    private func resolveOrgId(
        sessionKey: String,
        owner: String,
        lease: ClaudeCredentialRequestLease?,
        metrics: SearchResponsivenessMetrics,
        operationID: SearchResponsivenessOperationID?,
        context: SearchResponsivenessMetricContext
    ) async throws -> String {
        try checkOwner(owner, metrics: metrics, operationID: operationID, context: context)
        try checkLease(lease, metrics: metrics, operationID: operationID, context: context)
        if let cached = cachedOrgId {
            metrics.record(.credentialCacheLookup, operationID: operationID,
                           context: context, status: .cacheHit)
            return cached
        }
        metrics.record(.credentialCacheLookup, operationID: operationID,
                       context: context, status: .cacheMiss)

        var request = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 AgentSessions", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        let networkSpan = metrics.beginSpan(.credentialNetwork, operationID: operationID, context: context)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let networkSpan {
                Task.isCancelled ? metrics.cancel(networkSpan) : metrics.fail(networkSpan, code: .unavailable)
            }
            throw ClaudeOAuthUsageClientError.networkError(error)
        }
        if let networkSpan { Task.isCancelled ? metrics.cancel(networkSpan) : metrics.end(networkSpan) }
        try checkOwner(owner, metrics: metrics, operationID: operationID, context: context,
                       recordRejectedPublication: true)
        try checkLease(lease, metrics: metrics, operationID: operationID, context: context,
                       recordRejectedPublication: true)
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
        metrics.record(.credentialCacheWrite, operationID: operationID,
                       context: context, status: .published)
        return first.uuid
    }

    // MARK: - Shared File Cache

    private struct CachedResult {
        let response: ClaudeWebRawUsageResponse
        let bodyHash: String
        let fetchedAt: Date
    }

    private nonisolated static func isCacheFresh(modificationDate: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(modificationDate) < cacheMaxAge
    }

#if DEBUG
    nonisolated static var cacheMaxAgeForTesting: TimeInterval {
        cacheMaxAge
    }

    nonisolated static var sharedCacheURLForTesting: URL {
        sharedCacheURL
    }

    nonisolated static func isCacheFreshForTesting(age: TimeInterval) -> Bool {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        return isCacheFresh(modificationDate: now.addingTimeInterval(-age), now: now)
    }
#endif

}

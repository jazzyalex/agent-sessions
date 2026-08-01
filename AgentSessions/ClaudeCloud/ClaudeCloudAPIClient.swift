import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeCloud")

/// One row of `GET /v1/code/sessions`, reduced to the fields the Runway rows use.
///
/// Every field past `id` is optional on purpose. The endpoint is undocumented, so a
/// missing or renamed field must degrade one row rather than fail the batch.
struct ClaudeCloudRawSession: Equatable, Sendable {
    let id: String
    let title: String?
    let status: String?
    let statusBucket: String?
    let workerStatus: String?
    let connectionStatus: String?
    let environmentKind: String?
    let lastEventAt: Date?
    let unread: Int?
}

/// Read-only client for the Claude Code cloud-session list.
///
/// Endpoint contract verified live 2026-07-31 — see
/// `docs/superpowers/specs/2026-07-31-claude-cloud-session-source-design.md` §3.
///
/// Two things here are load-bearing and easy to "clean up" by mistake:
///
///   * The `anthropic-*` headers are required. This is a different API base from the
///     `/api/organizations/...` chat surface, and the chat surface does not contain
///     code sessions at all.
///   * Requests must go through `URLSession`. curl receives a Cloudflare interstitial
///     (403 text/html) on these paths even with a valid cookie — TLS fingerprinting,
///     not auth — so a shell-based reimplementation of this client would appear broken.
actor ClaudeCloudAPIClient {

    private let session: URLSession
    private var cachedOrgID: String?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: config)
        }
    }

    func invalidateOrgID() {
        cachedOrgID = nil
    }

    // MARK: - Requests

    private func request(url: URL, sessionKey: String, orgID: String?) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 AgentSessions", forHTTPHeaderField: "User-Agent")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("ccr-byoc-2025-07-29", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ccr", forHTTPHeaderField: "anthropic-client-feature")
        if let orgID { req.setValue(orgID, forHTTPHeaderField: "x-organization-uuid") }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ClaudeCloudError.offline
        }
        if let http = response as? HTTPURLResponse {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            if let mapped = Self.mapHTTP(http.statusCode, retryAfter: retryAfter) {
                throw mapped
            }
        }
        return data
    }

    /// Resolve the organization UUID, cached for the lifetime of the actor.
    func resolveOrgID(sessionKey: String) async throws -> String {
        if let cachedOrgID { return cachedOrgID }
        guard let url = URL(string: "https://claude.ai/api/organizations") else {
            throw ClaudeCloudError.contractDrift("bad organizations URL")
        }
        let data = try await send(request(url: url, sessionKey: sessionKey, orgID: nil))
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let uuid = (first["uuid"] as? String) ?? (first["id"] as? String) else {
            throw ClaudeCloudError.contractDrift("organizations payload has no uuid")
        }
        cachedOrgID = uuid
        return uuid
    }

    /// List cloud sessions, following `next_cursor` up to `maxPages`.
    ///
    /// `maxPages` defaults to 3 (300 rows). The active set is a handful of sessions, so
    /// paging further only costs requests; the cap is a bound on a runaway cursor, not a
    /// completeness target.
    func listSessions(sessionKey: String,
                      orgID: String? = nil,
                      maxPages: Int = 3) async throws -> [ClaudeCloudRawSession] {
        // `??` takes an autoclosure, which cannot be async — resolve explicitly.
        let org: String
        if let orgID {
            org = orgID
        } else {
            org = try await resolveOrgID(sessionKey: sessionKey)
        }
        var out: [ClaudeCloudRawSession] = []
        var cursor: String?

        for _ in 0..<max(1, maxPages) {
            var components = URLComponents(string: "https://claude.ai/v1/code/sessions")
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            components?.queryItems = items
            guard let url = components?.url else {
                throw ClaudeCloudError.contractDrift("bad sessions URL")
            }
            let data = try await send(request(url: url, sessionKey: sessionKey, orgID: org))
            let page = try Self.decodeList(data)
            out.append(contentsOf: page.rows)
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return out
    }

    // MARK: - Pure helpers (unit-tested directly)

    /// Map an HTTP status to a cloud error, or `nil` when the response is usable.
    static func mapHTTP(_ status: Int, retryAfter: String?) -> ClaudeCloudError? {
        switch status {
        case 200..<300:
            return nil
        case 401:
            return .expired
        case 403:
            // Deliberately NOT .expired. `expired` clears the row list, and an edge
            // 403 is not proof the cookie died — Cloudflare can challenge an
            // otherwise-valid request. Treating it as terminal made rows vanish and
            // reappear on the next poll. Degrade transiently and keep what we have;
            // a genuinely dead cookie still surfaces as a 401.
            return .offline
        case 429:
            return .rateLimited(until: parseRetryAfter(retryAfter))
        default:
            return .contractDrift("HTTP \(status)")
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date.
    static func parseRetryAfter(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return Date().addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }

    /// Decode one page. Rows that fail individually are skipped; only an unrecognisable
    /// envelope is fatal, so one malformed session cannot blank the whole list.
    static func decodeList(_ data: Data) throws -> (rows: [ClaudeCloudRawSession], nextCursor: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["data"] as? [[String: Any]] else {
            throw ClaudeCloudError.contractDrift("expected {\"data\": [...]}")
        }
        let rows = raw.compactMap(decodeRow)
        if !raw.isEmpty && rows.isEmpty {
            throw ClaudeCloudError.contractDrift("no row in a non-empty page carried an id")
        }
        return (rows, obj["next_cursor"] as? String)
    }

    private static func decodeRow(_ dict: [String: Any]) -> ClaudeCloudRawSession? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        return ClaudeCloudRawSession(
            id: id,
            title: dict["title"] as? String,
            status: dict["status"] as? String,
            statusBucket: dict["status_bucket"] as? String,
            workerStatus: dict["worker_status"] as? String,
            connectionStatus: dict["connection_status"] as? String,
            environmentKind: dict["environment_kind"] as? String,
            lastEventAt: parseTimestamp(dict["last_event_at"] as? String),
            unread: dict["unread"] as? Int
        )
    }

    /// `last_event_at` carries fractional seconds (`2026-08-01T02:19:02.357615Z`).
    /// Fall back to the plain form so a format change costs a timestamp, not the row.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

import Foundation

/// A cloud session reduced to what a live row needs.
struct ClaudeCloudSession: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isWorking: Bool
    let isAwaitingReview: Bool
    let isDisconnected: Bool
    let lastEventAt: Date?
    let unread: Int
}

/// Pure selection rules, kept separate from the polling actor so they can be tested
/// without a network or a main-actor hop.
enum ClaudeCloudFilter {

    /// Environment kinds. `bridge` sessions run against a local device and the local
    /// indexer already surfaces them, so including them would double-render rows.
    private static let cloudKind = "anthropic_cloud"

    /// Keep only true cloud sandboxes.
    ///
    /// Note this filters on `environment_kind`, NOT on the id prefix. Every row the
    /// endpoint returns is `cse_`-prefixed — 177 of 177 when measured — so a prefix
    /// test selects everything, including the 168 bridge rows. An absent kind is
    /// excluded rather than guessed.
    static func cloudOnly(_ rows: [ClaudeCloudRawSession]) -> [ClaudeCloudRawSession] {
        rows.filter { $0.environmentKind == cloudKind }
    }

    /// Reduce to sessions worth a live row: still active, and either working or
    /// waiting on the user. Completed, failed and archived sessions are not live.
    static func activeRows(_ rows: [ClaudeCloudRawSession]) -> [ClaudeCloudSession] {
        rows.compactMap { row -> ClaudeCloudSession? in
            guard row.status == "active" else { return nil }
            let bucket = row.statusBucket
            guard bucket == "working" || bucket == "review_ready" else { return nil }

            // worker_status is authoritative when it says "running". It also takes
            // WORKER_STATUS_UNSPECIFIED (6 of 177 observed), which carries no
            // information — fall back to the bucket rather than rendering a literal.
            let working: Bool
            if row.workerStatus == "running" {
                working = true
            } else if row.workerStatus == "WORKER_STATUS_UNSPECIFIED" {
                working = bucket == "working"
            } else {
                working = false
            }

            return ClaudeCloudSession(
                id: row.id,
                title: (row.title?.isEmpty == false ? row.title! : "Cloud session"),
                isWorking: working,
                isAwaitingReview: bucket == "review_ready",
                isDisconnected: row.connectionStatus == "disconnected",
                lastEventAt: row.lastEventAt,
                unread: row.unread ?? 0
            )
        }
    }
}

/// Polls the cloud session list and exposes the live subset plus a rendered state.
///
/// Isolation is the point: every failure resolves to a `ClaudeCloudSourceState`, and
/// nothing here can throw into a caller that also builds local rows.
@MainActor
final class ClaudeCloudSessionCatalog {

    private(set) var state: ClaudeCloudSourceState = .disabled
    private(set) var sessions: [ClaudeCloudSession] = []

    private let client: ClaudeCloudAPIClient
    private let sessionKeyProvider: () -> String?
    private let isEnabled: () -> Bool

    init(client: ClaudeCloudAPIClient = ClaudeCloudAPIClient(),
         sessionKeyProvider: @escaping () -> String?,
         isEnabled: @escaping () -> Bool) {
        self.client = client
        self.sessionKeyProvider = sessionKeyProvider
        self.isEnabled = isEnabled
    }

    func refresh() async {
        guard isEnabled() else {
            state = .disabled
            sessions = []
            return
        }
        guard let key = sessionKeyProvider(), !key.isEmpty else {
            state = .notConnected
            sessions = []
            return
        }

        do {
            let raw = try await client.listSessions(sessionKey: key)
            let live = ClaudeCloudFilter.activeRows(ClaudeCloudFilter.cloudOnly(raw))
            sessions = live
            state = live.isEmpty ? .empty : .ok(count: live.count)
        } catch let error as ClaudeCloudError {
            apply(error)
        } catch {
            // Any unexpected error is treated as transport rather than swallowed.
            apply(.offline)
        }
    }

    /// Degraded states that are expected to recover keep the rows already on screen
    /// (labelled stale by `state.isStale`); states that invalidate the source clear them.
    private func apply(_ error: ClaudeCloudError) {
        switch error {
        case .rateLimited(let until):
            state = .rateLimited(until: until)
        case .offline:
            state = .offline
        case .expired:
            state = .expired
            sessions = []
        case .notConnected:
            state = .notConnected
            sessions = []
        case .contractDrift(let detail):
            state = .contractDrift(detail)
            sessions = []
        }
    }
}

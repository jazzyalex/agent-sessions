import Foundation
import os.log

private let catalogLog = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeCloud")

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

    /// How recently a session must have emitted an event to count as live.
    ///
    /// Measured against the server, `status == "active"` means only **not archived**.
    /// Two sessions carrying it were last touched 14 hours and 116 days ago, and the
    /// 116-day-old one still reported `status_bucket: "working"` — so neither field
    /// can be trusted as a liveness signal on its own.
    static let liveWindow: TimeInterval = 60 * 60

    /// Reduce to sessions worth a live row: not archived, and either working right
    /// now or active within `liveWindow`.
    ///
    /// Recency is the load-bearing test, chosen over the two obvious alternatives:
    /// `status == "active"` alone admits zombies indefinitely (a session idle since
    /// April), while gating on `worker_status == "running"` makes the row blink out
    /// between turns, since `worker_status` is `idle` for the overwhelming majority
    /// of sessions at any instant. Recency is stable across turns and still expires.
    ///
    /// `worker_status` and `status_bucket` decide how a surviving row is *styled*.
    static func activeRows(_ rows: [ClaudeCloudRawSession],
                           now: Date = Date()) -> [ClaudeCloudSession] {
        rows.compactMap { row -> ClaudeCloudSession? in
            guard row.status == "active" else { return nil }
            let bucket = row.statusBucket

            let isRunning = row.workerStatus == "running"
            let isRecent = row.lastEventAt.map { now.timeIntervalSince($0) <= liveWindow } ?? false
            // A missing timestamp is treated as not-recent rather than assumed live,
            // so a field rename degrades to "hidden" instead of "everything forever".
            guard isRunning || isRecent else { return nil }

            // worker_status is authoritative when it says "running". It also takes
            // WORKER_STATUS_UNSPECIFIED (6 of 177 observed), which carries no
            // information — fall back to the bucket rather than rendering a literal.
            // `status_bucket` alone cannot be trusted: a session idle for 116 days
            // still reported "working". Fall back to it only when `worker_status`
            // carries no information AND the session is recently active.
            let working: Bool
            if isRunning {
                working = true
            } else if row.workerStatus == "WORKER_STATUS_UNSPECIFIED" {
                working = bucket == "working" && isRecent
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
            os_log("cloud: disabled (toggle off)", log: catalogLog, type: .info)
            return
        }
        guard let key = sessionKeyProvider(), !key.isEmpty else {
            state = .notConnected
            sessions = []
            os_log("cloud: no sessionKey — keychain read returned nil/empty",
                   log: catalogLog, type: .error)
            return
        }

        do {
            let raw = try await client.listSessions(sessionKey: key)
            let cloud = ClaudeCloudFilter.cloudOnly(raw)
            let live = ClaudeCloudFilter.activeRows(cloud)
            sessions = live
            state = live.isEmpty ? .empty : .ok(count: live.count)
            // The three counts localise any future "nothing shows up" instantly:
            // raw=0 is fetch/auth, cloud=0 is the environment_kind filter,
            // live=0 is the active predicate.
            os_log("cloud: raw=%{public}d cloud=%{public}d live=%{public}d",
                   log: catalogLog, type: .info, raw.count, cloud.count, live.count)
        } catch let error as ClaudeCloudError {
            apply(error)
            os_log("cloud: refresh failed — %{public}@", log: catalogLog, type: .error,
                   String(describing: error))
        } catch {
            // Any unexpected error is treated as transport rather than swallowed.
            apply(.offline)
            os_log("cloud: refresh failed (unexpected) — %{public}@", log: catalogLog,
                   type: .error, String(describing: error))
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

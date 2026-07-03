import Foundation

/// Immutable result of one `PresenceEngine` publish decision.
///
/// Carries everything `CodexActiveSessionsModel`'s synchronous lookup API
/// (`presence(for:)`, `liveState(...)`, `isActive/isLive`, `idleReason(for:)`,
/// `lastActivityAt(for:)`, badge counts) needs to answer without touching the
/// engine. The facade stores the latest snapshot and reads it on the main actor;
/// the engine computes it off the main actor and only emits when the existing
/// publish-decision (signature diff + suppression heuristics) says to.
struct PresenceSnapshot: Sendable, Equatable {
    /// Stable UI-ordered list (sorted by `lastSeenAt` descending), matching the
    /// facade's historical `presences` @Published value.
    var presences: [CodexActivePresence]

    /// Session-id keyed lookup (mirrors the engine's internal `sessionMap`).
    var bySessionID: [String: CodexActivePresence]

    /// Normalized-log-path keyed lookup (mirrors the engine's internal `logMap`).
    var byLogPath: [String: CodexActivePresence]

    var liveStateByPresenceKey: [String: CodexLiveState]
    var idleReasonByPresenceKey: [String: HUDIdleReason]
    var lastActivityByPresenceKey: [String: Date]
    var runtimeSubagentCountsByPresenceKey: [String: Int]

    /// Bumped only on real membership/metadata/live-state change — identical
    /// semantics to the pre-extraction `activeMembershipVersion`.
    var membershipVersion: UInt64

    /// Bumped only when runtime subagent badge counts change while Cockpit is
    /// visible — identical semantics to the pre-extraction `subagentBadgeVersion`.
    var badgeVersion: UInt64

    static let empty = PresenceSnapshot(
        presences: [],
        bySessionID: [:],
        byLogPath: [:],
        liveStateByPresenceKey: [:],
        idleReasonByPresenceKey: [:],
        lastActivityByPresenceKey: [:],
        runtimeSubagentCountsByPresenceKey: [:],
        membershipVersion: 0,
        badgeVersion: 0
    )
}

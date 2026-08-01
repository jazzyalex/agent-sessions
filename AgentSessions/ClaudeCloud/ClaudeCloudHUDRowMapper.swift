import Foundation

/// Maps live cloud sessions onto the Quota Meter's row type.
///
/// A cloud session has no local process: no pid, no tty, no terminal, no log file,
/// no working directory. `HUDRow`'s initialiser defaults all of those to nil, so the
/// mapping leaves them nil rather than inventing plausible-looking values. Anything
/// downstream that keys off `logPath` or `revealURL` then correctly treats these rows
/// as un-navigable instead of following a fabricated path.
enum ClaudeCloudHUDRowMapper {

    /// Row ids are namespaced so a cloud row can never collide with a local row that
    /// happens to share an identifier.
    static func rowID(for sessionID: String) -> String { "claude-cloud:\(sessionID)" }

    static let projectLabel = "Claude Cloud"

    static func rows(from sessions: [ClaudeCloudSession], now: Date = Date()) -> [HUDRow] {
        sessions.map { session in
            HUDRow(
                id: rowID(for: session.id),
                source: .claude,
                agentType: .claude,
                projectName: projectLabel,
                displayName: session.title,
                liveState: session.isWorking ? .active : .idle,
                preview: preview(for: session),
                elapsed: elapsed(since: session.lastEventAt, now: now),
                lastSeenAt: session.lastEventAt,
                itermSessionId: nil,
                revealURL: nil,
                tty: nil,
                termProgram: nil,
                lastActivityAt: session.lastEventAt,
                idleReason: session.isWorking ? nil : .generic
            )
        }
    }

    private static func preview(for session: ClaudeCloudSession) -> String {
        if session.isDisconnected { return "Disconnected from sandbox" }
        if session.isAwaitingReview { return "Waiting for review" }
        if session.unread > 0 { return session.unread == 1 ? "1 unread" : "\(session.unread) unread" }
        return ""
    }

    /// Compact age string. Returns empty when the server sent no timestamp, so the
    /// column stays blank instead of claiming the session just started.
    private static func elapsed(since date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

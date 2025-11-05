import Foundation

/// Shared configuration and helpers for identifying Agent Sessions' Codex status probe sessions.
enum CodexProbeConfig {
    /// Fixed marker prefix injected as the very first user message of a Codex probe.
    static let markerPrefix: String = "[AS_CX_PROBE v1]"

    /// Absolute path to the dedicated working directory used for Codex probe sessions.
    static func probeWorkingDirectory() -> String {
        if let override = ProcessInfo.processInfo.environment["AS_TEST_CX_PROBE_WD"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let home = NSHomeDirectory() as NSString
        return home.appendingPathComponent("Library/Application Support/AgentSessions/CodexProbeProject")
    }

    /// Returns true if the given session appears to be a Codex probe session.
    /// Heuristics (ordered, short-circuiting):
    /// - Source must be `.codex`.
    /// - If lightweight `cwd` matches the Probe WD (normalized), treat as probe.
    /// - If the lightweight title or first user message contains the marker anywhere,
    ///   treat as probe (during debugging the marker may not be at column 1).
    /// - If any user message contains the marker substring, treat as probe.
    /// - As a pragmatic fallback for cleanup UI, treat tiny '/status' sessions as probes
    ///   (<= 5 messages) since our scripted checks may open a short, command-only session.
    static func isProbeSession(_ session: Session) -> Bool {
        guard session.source == .codex else { return false }
        if let cwd = session.lightweightCwd, !cwd.isEmpty {
            if normalizePath(cwd) == normalizePath(probeWorkingDirectory()) { return true }
        }
        // Marker in lightweight title
        if let t = session.lightweightTitle, t.contains(markerPrefix) { return true }
        // Marker in first user or anywhere in user messages (for fully parsed sessions)
        if !session.events.isEmpty {
            if let firstUser = session.events.first(where: { $0.kind == .user })?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               firstUser.contains(markerPrefix) { return true }
            if session.events.contains(where: { $0.kind == .user && ($0.text?.contains(markerPrefix) ?? false) }) { return true }
        } else {
            // Lightweight preview of first user
            if let preview = session.firstUserPreview, preview.contains(markerPrefix) { return true }
        }
        // Tiny '/status' helper sessions created during probe debugging
        let title = session.events.isEmpty ? (session.lightweightTitle ?? "") : session.title
        if title.trimmingCharacters(in: .whitespacesAndNewlines) == "/status" && session.eventCount <= 5 {
            return true
        }
        return false
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

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
        // Use a stable, human-friendly name for easy filtering
        return home.appendingPathComponent("Library/Application Support/AgentSessions/AgentSessions-codex-usage")
    }

    /// Returns true if the given session appears to be a Codex probe session.
    /// Heuristics (ordered, conservative to avoid false positives):
    /// - Source must be `.codex`.
    /// - If lightweight `cwd` matches the Probe WD (normalized), treat as probe.
    /// - Otherwise, treat as probe only when the marker appears in the FIRST user message
    ///   (or lightweight title/preview), which is how our probes start.
    /// - Tiny '/status' sessions (<= 5 messages) are treated as probe ONLY when `cwd`
    ///   matches the Probe WD. This prevents hiding legitimate user /status snippets.
    static func isProbeSession(_ session: Session) -> Bool {
        guard session.source == .codex else { return false }
        if let cwd = session.lightweightCwd, !cwd.isEmpty {
            if normalizePath(cwd) == normalizePath(probeWorkingDirectory()) { return true }
        }
        // Also check the fully-parsed path when present
        if let cwd = session.cwd, !cwd.isEmpty {
            if normalizePath(cwd) == normalizePath(probeWorkingDirectory()) { return true }
        }
        // Marker in lightweight title or first user PREVIEW
        if let t = session.lightweightTitle, t.contains(markerPrefix) { return true }
        if let preview = session.firstUserPreview, preview.contains(markerPrefix) { return true }
        // Marker in FIRST user of fully parsed sessions
        if !session.events.isEmpty {
            if let firstUser = session.events.first(where: { $0.kind == .user })?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               firstUser.contains(markerPrefix) { return true }
        }
        // Tiny '/status' helper sessions — only when we know they ran in the Probe WD
        let title = session.events.isEmpty ? (session.lightweightTitle ?? "") : session.title
        if let cwd = session.lightweightCwd,
           normalizePath(cwd) == normalizePath(probeWorkingDirectory()),
           title.trimmingCharacters(in: .whitespacesAndNewlines) == "/status",
           session.eventCount <= 5 {
            return true
        }
        return false
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

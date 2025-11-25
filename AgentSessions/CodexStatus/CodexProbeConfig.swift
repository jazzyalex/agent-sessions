import Foundation

/// Shared configuration and helpers for identifying Agent Sessions' Codex status probe sessions.
enum CodexProbeConfig {
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
    ///
    /// Detection strategy (post Nov 24, 2025 - no marker message needed):
    /// - Source must be `.codex`
    /// - Working directory must match the probe WD
    /// - Session characteristics: tiny (≤5 events) and contains `/status` command
    ///
    /// Conservative to avoid false positives: regular user sessions in other directories
    /// won't be mistaken for probes even if they happen to run `/status`.
    static func isProbeSession(_ session: Session) -> Bool {
        guard session.source == .codex else { return false }

        // Primary check: working directory must match probe WD
        let probeWD = normalizePath(probeWorkingDirectory())
        var cwdMatches = false

        if let cwd = session.lightweightCwd, !cwd.isEmpty {
            if normalizePath(cwd) == probeWD { cwdMatches = true }
        }
        if let cwd = session.cwd, !cwd.isEmpty {
            if normalizePath(cwd) == probeWD { cwdMatches = true }
        }

        guard cwdMatches else { return false }

        // Secondary check: must be tiny and contain /status
        // (Prevents hiding legitimate long sessions that happen to run in probe WD)
        guard session.eventCount <= 5 else { return false }

        let title = session.events.isEmpty ? (session.lightweightTitle ?? "") : session.title
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Look for /status in title (most probes)
        if trimmedTitle == "/status" { return true }
        if trimmedTitle.lowercased().contains("/status") { return true }

        // Fallback: check if any event contains "/status" command
        for event in session.events {
            if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if text == "/status" || text.lowercased().contains("/status") {
                    return true
                }
            }
        }

        return false
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

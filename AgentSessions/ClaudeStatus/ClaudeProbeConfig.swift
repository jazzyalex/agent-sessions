import Foundation

/// Shared configuration and helpers for identifying Agent Sessions' Claude usage probe sessions.
enum ClaudeProbeConfig {
    /// Absolute path to the dedicated working directory used for probe sessions.
    /// macOS: ~/Library/Application Support/AgentSessions/ClaudeProbeProject
    static func probeWorkingDirectory() -> String {
        // Test override support: AS_TEST_PROBE_WD
        if let override = ProcessInfo.processInfo.environment["AS_TEST_PROBE_WD"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let home = NSHomeDirectory() as NSString
        return home.appendingPathComponent("Library/Application Support/AgentSessions/ClaudeProbeProject")
    }

    /// Returns true if the given session appears to be an Agent Sessions probe session.
    /// Heuristics (ordered, conservative to avoid false positives):
    /// - Source must be `.claude`.
    /// - Path-based: if the file lives inside the discovered probe project under ~/.claude/projects,
    ///   it is a probe session (fast and definitive when project discovery works).
    /// - Fast path: if lightweight `cwd` matches the Probe WD, treat as probe.
    ///
    /// Note: Probe sessions send no user messages to preserve usage limits.
    /// Identification relies solely on working directory matching.
    static func isProbeSession(_ session: Session) -> Bool {
        guard session.source == .claude else { return false }

        // 1) Path-based classification via discovered probe project id
        if let projectID = ClaudeProbeProject.discoverProbeProjectId(), !projectID.isEmpty {
            let root = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".claude/projects/\(projectID)")
            if session.filePath.hasPrefix(root + "/") || session.filePath == root {
                return true
            }
        }

        // 2) Fast path: cwd match for lightweight sessions
        if let cwd = session.lightweightCwd, !cwd.isEmpty {
            if normalizePath(cwd) == normalizePath(probeWorkingDirectory()) { return true }
        }

        return false
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

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
    /// Heuristics:
    /// - Source must be `.codex`.
    /// - If lightweight `cwd` matches the Probe WD (normalized), treat as probe.
    /// - Otherwise, when events are present, the first user message must start with the marker prefix.
    static func isProbeSession(_ session: Session) -> Bool {
        guard session.source == .codex else { return false }
        if let cwd = session.lightweightCwd, !cwd.isEmpty {
            if normalizePath(cwd) == normalizePath(probeWorkingDirectory()) { return true }
        }
        if !session.events.isEmpty {
            if let firstUser = session.events.first(where: { $0.kind == .user })?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               firstUser.hasPrefix(markerPrefix) {
                return true
            }
        }
        return false
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}


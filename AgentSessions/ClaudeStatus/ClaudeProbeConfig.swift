import Foundation
#if canImport(XCTest)
import AgentSessions
#endif

/// Shared configuration and helpers for identifying Agent Sessions' Claude usage probe sessions.
enum ClaudeProbeConfig {
    /// Absolute path to the dedicated working directory used for probe sessions.
    /// macOS: ~/Library/Application Support/AgentSessions/ClaudeProbeProject
    static func probeWorkingDirectory() -> String {
        // Test override support: AS_TEST_PROBE_WD
        if let override = envValue("AS_TEST_PROBE_WD"), !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let home = NSHomeDirectory() as NSString
        return home.appendingPathComponent("Library/Application Support/AgentSessions/ClaudeProbeProject")
    }

    /// Resolve the verified probe project once for a batch, even when none is
    /// present. A later batch discovers again so it can see a new marker.
    static func makeSessionClassifier(
        discoverProjectID: () -> String? = ClaudeProbeProject.discoverProbeProjectId,
        workingDirectory: String = probeWorkingDirectory()
    ) -> (Session) -> Bool {
        let probePath: String?
        if let projectID = discoverProjectID(), !projectID.isEmpty {
            probePath = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".claude/projects/\(projectID)")
        } else {
            probePath = nil
        }
        let normalizedWorkingDirectory = normalizePath(workingDirectory)
        return { session in
            guard session.source == .claude else { return false }
            if let probePath, session.filePath == probePath || session.filePath.hasPrefix(probePath + "/") {
                return true
            }
            guard let cwd = session.lightweightCwd, !cwd.isEmpty else { return false }
            return normalizePath(cwd) == normalizedWorkingDirectory
        }
    }

    /// Returns true if the given path is the Claude probe working directory.
    static func isProbeWorkingDirectory(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return normalizePath(path) == normalizePath(probeWorkingDirectory())
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    private static func envValue(_ key: String) -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }
}

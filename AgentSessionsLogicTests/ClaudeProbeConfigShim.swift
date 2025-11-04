import Foundation

// Test-only shim to avoid pulling the full app module.
// Provides the minimal API surface used by ClaudeProbeProject.
enum ClaudeProbeConfig {
    static let markerPrefix: String = "[AS_USAGE_PROBE v1]"
    static func probeWorkingDirectory() -> String {
        if let override = ProcessInfo.processInfo.environment["AS_TEST_PROBE_WD"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("as-probe-wd")
    }
}


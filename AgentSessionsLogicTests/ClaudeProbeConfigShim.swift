import Foundation

// Test-only shim to avoid pulling the full app module.
// Provides the minimal API surface used by ClaudeProbeProject.
enum ClaudeProbeConfig {
    static func probeWorkingDirectory() -> String {
        if let override = envValue("AS_TEST_PROBE_WD"), !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("as-probe-wd")
    }

    private static func envValue(_ key: String) -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }
}

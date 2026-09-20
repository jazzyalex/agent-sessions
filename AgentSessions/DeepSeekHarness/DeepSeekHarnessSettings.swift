import Foundation

/// User-facing configuration for the read-only DeepSeek Harness source.
enum DeepSeekHarnessSettings {
    enum Keys {
        static let enabled = "AgentEnabledDeepSeekHarness"
        static let include = "IncludeDeepSeekHarnessSessions"
        static let rootOverride = "DeepSeekHarnessSessionsRootOverride"
        static let cliAvailable = "DeepSeekHarnessCLIAvailable"
    }

    static let defaultHomeName = ".dsh"

    static func configuredRoot(defaults: UserDefaults = .standard,
                               homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let custom = defaults.string(forKey: Keys.rootOverride)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        if let env = environment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(defaultHomeName, isDirectory: true)
    }

    static func sessionsRoot(defaults: UserDefaults = .standard,
                             homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let root = configuredRoot(defaults: defaults,
                                  homeDirectory: homeDirectory,
                                  environment: environment)
        // A custom value is documented as the DSH home, matching DSH_HOME. The
        // app also accepts a direct sessions directory for fixture and archive
        // roots, which keeps tests and Agent Sessions snapshots unambiguous.
        if root.lastPathComponent == "sessions" { return root }
        return root.appendingPathComponent("sessions", isDirectory: true)
    }

    static func normalizedOverride(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

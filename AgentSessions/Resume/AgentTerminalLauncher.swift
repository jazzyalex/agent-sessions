import Foundation
import AppKit

/// Shared terminal launcher used by all agent resume flows.
/// Runs a shell command in Terminal.app or iTerm2 via AppleScript.
@MainActor
enum AgentTerminalLauncher {
    static func launchInTerminal(shellCommand: String, domain: String = "AgentTerminalLauncher") throws {
        let scriptLines = [
            "on run argv",
            "set shellCommand to \"\"",
            "if (count of argv) >= 1 then set shellCommand to item 1 of argv",
            "tell application \"Terminal\"",
            "activate",
            "set newTab to do script shellCommand",
            "delay 0.1",
            "try",
            "  set newWin to (first window whose tabs contains newTab)",
            "  set front window to newWin",
            "  set selected tab of newWin to newTab",
            "end try",
            "end tell",
            "end run"
        ]

        try runAppleScript(scriptLines, arguments: [shellCommand], domain: domain, fallbackMessage: "Terminal launch failed.")
    }

    static func launchInITerm(shellCommand: String, domain: String = "AgentTerminalLauncher") throws {
        let scriptLines = [
            "on run argv",
            "set shellCommand to \"\"",
            "if (count of argv) >= 1 then set shellCommand to item 1 of argv",
            "tell application \"iTerm2\"",
            "activate",
            "set newWin to (create window with default profile)",
            "tell newWin",
            "  tell current session",
            "    write text shellCommand",
            "  end tell",
            "end tell",
            "end tell",
            "end run"
        ]

        try runAppleScript(scriptLines, arguments: [shellCommand], domain: domain, fallbackMessage: "iTerm2 launch failed.")
    }

    /// Opens a new Claude Code agent tab in Warp or WarpPreview using a temporary tab config.
    /// Uses the TOML tab config format with `type = "agent"` so Warp creates a proper
    /// Claude Code tab (avatar icon) rather than a plain terminal tab.
    static func launchInWarp(shellCommand: String, cwd: String?, kind: TerminalKind) throws {
        let scheme: String
        let tabConfigDir: URL
        switch kind {
        case .warpPreview:
            scheme = "warppreview"
            tabConfigDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".warp-preview/tab_configs")
        case .warp:
            scheme = "warp"
            tabConfigDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".warp/tab_configs")
        default:
            throw NSError(domain: "AgentTerminalLauncher", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported kind for Warp launch"])
        }

        try FileManager.default.createDirectory(at: tabConfigDir, withIntermediateDirectories: true)

        let configName = "agent-sessions-resume-\(UUID().uuidString.prefix(8).lowercased())"
        let configFile = tabConfigDir.appendingPathComponent("\(configName).toml")
        let directory = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path

        let toml = """
name = "\(configName)"

[[panes]]
id = "main"
type = "agent"
directory = "\(tomlEscape(directory))"
commands = ["\(tomlEscape(shellCommand))"]
[params]
"""

        try toml.write(to: configFile, atomically: true, encoding: .utf8)

        guard let url = URL(string: "\(scheme)://tab_config/\(configName)") else {
            throw NSError(domain: "AgentTerminalLauncher", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build tab config URL"])
        }

        // If Warp is already running, open the tab config URL directly.
        // If not, launch the app first and wait for it to initialize.
        let appRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == kind.bundleIdentifier
        }

        if appRunning {
            NSWorkspace.shared.open(url)
        } else {
            let configURL = url
            Task.detached {
                await MainActor.run {
                    if let bundleID = kind.bundleIdentifier {
                        NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleID,
                            options: .default, additionalEventParamDescriptor: nil, launchIdentifier: nil)
                    }
                }
                // Wait for app to initialize before opening the tab config
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    NSWorkspace.shared.open(configURL)
                }
            }
        }

        // Clean up the temp config after Warp has had time to read it
        Task.detached {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            try? FileManager.default.removeItem(at: configFile)
        }
    }

    // MARK: - Helpers

    private static nonisolated func tomlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ lines: [String], arguments: [String], domain: String, fallbackMessage: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] } + arguments

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try process.run()
        process.waitForExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: domain, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? fallbackMessage : err])
        }
    }
}

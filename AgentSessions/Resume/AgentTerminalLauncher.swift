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

    /// Opens a new terminal tab in Warp or WarpPreview using a temporary tab config.
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

        // Fail before writing anything if nothing can service the launch. This
        // is the realistic "Warp never opens" case — the user picked Warp in
        // Preferences without having it — and it is the only one the
        // not-yet-running path below can report at all, because that path
        // completes asynchronously long after this function returns.
        //
        // Resolve by URL scheme, not bundle id: the launch mechanism is
        // `warp://tab_config/…`, which LaunchServices routes by scheme. Warp
        // has shipped under more than one id (TerminalKind.infer still maps the
        // legacy `dev.warp.Warp`), so checking the id would hard-fail a user
        // whose scheme handler works perfectly well.
        guard let schemeProbe = URL(string: "\(scheme)://"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: schemeProbe) else {
            throw NSError(domain: "AgentTerminalLauncher", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(kind.displayName) is not installed."])
        }

        try FileManager.default.createDirectory(at: tabConfigDir, withIntermediateDirectories: true)

        let configName = "agent-sessions-resume-\(UUID().uuidString.prefix(8).lowercased())"
        let configFile = tabConfigDir.appendingPathComponent("\(configName).toml")
        let directory = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path

        let toml = warpTabConfigTOML(configName: configName, command: shellCommand, directory: directory)

        try toml.write(to: configFile, atomically: true, encoding: .utf8)

        guard let url = URL(string: "\(scheme)://tab_config/\(configName)") else {
            try? FileManager.default.removeItem(at: configFile)
            throw NSError(domain: "AgentTerminalLauncher", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build tab config URL"])
        }

        // If Warp is already running, open the tab config URL directly.
        // If not, launch the app first and wait for it to initialize.
        // Matched on bundle URL rather than id for the same reason as above —
        // the id varies across Warp builds, the resolved app URL does not.
        // Normalised: raw URL equality compares absolute strings, so a symlink,
        // a `/private` prefix, or Gatekeeper app translocation would report a
        // running Warp as not-running and take the 3-second cold-start path for
        // nothing.
        let resolvedAppURL = appURL.resolvingSymlinksInPath().standardizedFileURL
        let appRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == resolvedAppURL
        }

        if appRunning {
            // Synchronous path, so a refusal is reportable. Note `open` reports
            // only that LaunchServices routed the URL, not that Warp read the
            // config and opened a tab -- so a `true` here is weaker than "the
            // tab exists".
            guard NSWorkspace.shared.open(url) else {
                try? FileManager.default.removeItem(at: configFile)
                throw NSError(domain: "AgentTerminalLauncher", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "\(kind.displayName) refused to route the resume URL."])
            }
        } else {
            // KNOWN GAP: this path still reports success unconditionally. Cold
            // start is asynchronous (Warp must initialise before it will read a
            // tab config), and `launchInTerminal` is synchronous `throws`, so
            // there is nowhere to report to. That is a limit of the current
            // signature, NOT an inherent one — every resume coordinator that
            // calls this is already `async`, so making the `*TerminalLaunching`
            // protocols `async throws` would let both the launch and the
            // deferred open be awaited and reported honestly. It is a ripple
            // across nine launcher files and their mocks, deliberately not
            // bundled here. Until then: the scheme check above rejects the
            // common failure up front, and what remains is logged and cleaned
            // up rather than left looking like success.
            let configURL = url
            Task.detached {
                do {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                } catch {
                    NSLog("AgentTerminalLauncher: failed to launch %@: %@",
                          kind.displayName, error.localizedDescription)
                    try? FileManager.default.removeItem(at: configFile)
                    return
                }
                // Wait for app to initialize before opening the tab config
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let opened = await MainActor.run { NSWorkspace.shared.open(configURL) }
                if !opened {
                    NSLog("AgentTerminalLauncher: %@ launched but refused the resume tab config",
                          kind.displayName)
                    try? FileManager.default.removeItem(at: configFile)
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

    static nonisolated func warpTabConfigTOML(configName: String, command: String, directory: String) -> String {
        """
        name = "\(configName)"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = "\(tomlEscape(directory))"
        commands = ["\(tomlEscape(command))"]
        """
    }

    private static nonisolated func tomlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\r", with: "\\r")
             .replacingOccurrences(of: "\t", with: "\\t")
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

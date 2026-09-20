import Foundation
import AppKit

/// Shared terminal launcher used by all agent resume flows.
/// Runs a shell command in Terminal.app or iTerm2 via AppleScript.
/// Also dispatches shared agent resume commands to other supported terminals.
@MainActor
enum AgentTerminalLauncher {
    /// How long Warp needs after launch before it will read a tab config.
    private static let warpColdStartSettleNanoseconds: UInt64 = 3_000_000_000

    static func launch(
        shellCommand: String,
        displayCommand: String,
        cwd: String?,
        kind: TerminalKind,
        domain: String = "AgentTerminalLauncher"
    ) async throws {
        switch kind {
        case .terminalApp, .unknown:
            try launchInTerminal(shellCommand: shellCommand, domain: domain)
        case .iterm2:
            try launchInITerm(shellCommand: shellCommand, domain: domain)
        case .warp, .warpPreview:
            try await launchInWarp(shellCommand: displayCommand, cwd: cwd, kind: kind)
        case .ghostty:
            try await launchInGhostty(shellCommand: displayCommand, cwd: cwd, domain: domain)
        case .kitty:
            try launchInKitty(shellCommand: displayCommand, cwd: cwd, domain: domain)
        case .wezTerm:
            try launchInWezTerm(shellCommand: displayCommand, cwd: cwd, domain: domain)
        }
    }

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

    static func launchInGhostty(shellCommand: String, cwd: String?, domain: String = "AgentTerminalLauncher") async throws {
        let bundleIdentifier = "com.mitchellh.ghostty"
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw NSError(
                domain: domain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ghostty is not installed."]
            )
        }

        let directory = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
        if !isRunning {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }

        let scriptLines = [
            "on run argv",
            "set workingDirectory to item 1 of argv",
            "set initialInput to item 2 of argv",
            "set configuredCommand to item 3 of argv",
            "set replaceInitialWindow to item 4 of argv",
            "tell application id \"com.mitchellh.ghostty\"",
            "activate",
            "set initialWindow to missing value",
            "if replaceInitialWindow is \"true\" and (count of windows) > 0 then set initialWindow to front window",
            "if replaceInitialWindow is \"true\" then",
            "set surfaceConfig to new surface configuration from {initial working directory:workingDirectory, initial input:initialInput}",
            "else",
            "set surfaceConfig to new surface configuration from {initial working directory:workingDirectory, command:configuredCommand}",
            "end if",
            "set resumeWindow to new window with configuration surfaceConfig",
            "if initialWindow is not missing value then close window initialWindow",
            "activate window resumeWindow",
            "end tell",
            "end run"
        ]
        try runAppleScript(
            scriptLines,
            arguments: [
                directory,
                ghosttyInitialInput(shellCommand),
                ghosttySurfaceCommand(shellCommand),
                isRunning ? "false" : "true"
            ],
            domain: domain,
            fallbackMessage: "Ghostty launch failed."
        )
    }

    static nonisolated func ghosttyInitialInput(_ shellCommand: String) -> String {
        "\(shellCommand)\n"
    }

    static nonisolated func ghosttySurfaceCommand(_ shellCommand: String) -> String {
        "/bin/zsh -lc \(ShellQuoting.quote(shellCommand))"
    }

    static func launchInKitty(shellCommand: String, cwd: String?, domain: String = "AgentTerminalLauncher") throws {
        try launchExecutableTerminal(
            kind: .kitty,
            executablePath: "Contents/MacOS/kitty",
            arguments: kittyArguments(shellCommand: shellCommand, cwd: resolvedDirectory(cwd)),
            domain: domain
        )
    }

    static func launchInWezTerm(shellCommand: String, cwd: String?, domain: String = "AgentTerminalLauncher") throws {
        try launchExecutableTerminal(
            kind: .wezTerm,
            executablePath: "Contents/MacOS/wezterm",
            arguments: wezTermArguments(shellCommand: shellCommand, cwd: resolvedDirectory(cwd)),
            domain: domain
        )
    }

    static nonisolated func kittyArguments(shellCommand: String, cwd: String) -> [String] {
        [
            "--single-instance",
            "--instance-group=agent-sessions",
            "--directory=\(cwd)",
            "/bin/zsh",
            "-lc",
            shellCommand
        ]
    }

    static nonisolated func wezTermArguments(shellCommand: String, cwd: String) -> [String] {
        [
            "start",
            "--cwd",
            cwd,
            "--",
            "/bin/zsh",
            "-lc",
            shellCommand
        ]
    }

    private static func launchExecutableTerminal(
        kind: TerminalKind,
        executablePath: String,
        arguments: [String],
        domain: String
    ) throws {
        guard let bundleIdentifier = kind.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw NSError(
                domain: domain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(kind.displayName) is not installed."]
            )
        }

        let process = Process()
        process.executableURL = appURL.appendingPathComponent(executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func resolvedDirectory(_ cwd: String?) -> String {
        cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Opens a new terminal tab in Warp or WarpPreview using a temporary tab config.
    static func launchInWarp(shellCommand: String, cwd: String?, kind: TerminalKind) async throws {
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

        // Fail before writing anything if nothing can service the launch — the
        // realistic "Warp never opens" case, where the user picked Warp in
        // Preferences without having it. Catching it here also avoids paying
        // the cold-start wait below only to fail anyway.
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

        if !appRunning {
            // Cold start: launch and wait for the app to initialise before it
            // will read a tab config. This is why the whole launcher chain is
            // `async` — the wait used to happen in a detached task that had
            // nowhere to report to, so a Warp that failed to launch looked
            // exactly like one that succeeded.
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            } catch {
                try? FileManager.default.removeItem(at: configFile)
                throw NSError(domain: "AgentTerminalLauncher", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "\(kind.displayName) failed to launch: \(error.localizedDescription)"])
            }
            // Not `try?`: swallowing cancellation here would fall straight
            // through to `open` against a Warp that has not initialised, and
            // report that as success.
            do {
                try await Task.sleep(nanoseconds: warpColdStartSettleNanoseconds)
            } catch {
                try? FileManager.default.removeItem(at: configFile)
                throw error
            }
        }

        // `open` reports only that LaunchServices routed the URL, not that Warp
        // read the config and opened a tab — so a `true` here is weaker than
        // "the tab exists", but a `false` is a definite failure.
        guard NSWorkspace.shared.open(url) else {
            try? FileManager.default.removeItem(at: configFile)
            throw NSError(domain: "AgentTerminalLauncher", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "\(kind.displayName) refused to route the resume URL."])
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

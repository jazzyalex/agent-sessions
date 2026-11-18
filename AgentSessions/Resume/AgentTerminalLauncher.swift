import Foundation
import AppKit

struct MactermLaunchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor MactermLaunchQueue {
    private var launchInProgress = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(_ launch: @Sendable () async throws -> Void) async throws {
        if launchInProgress {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            launchInProgress = true
        }
        defer {
            if waiting.isEmpty {
                launchInProgress = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        try await launch()
    }
}

/// Shared terminal launcher used by all agent resume flows.
/// Runs a shell command in Terminal.app or iTerm2 via AppleScript.
@MainActor
enum AgentTerminalLauncher {
    private nonisolated static let mactermLaunchQueue = MactermLaunchQueue()

    /// How long Warp needs after launch before it will read a tab config.
    private static let warpColdStartSettleNanoseconds: UInt64 = 3_000_000_000

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

    /// Opens a new Ghostty window in `cwd` and types `shellCommand` into its shell.
    /// Uses Ghostty's AppleScript dictionary (surface configuration + new window).
    /// The command goes in as initial input rather than as the surface command so
    /// the user's login shell, and with it their PATH, runs first.
    static func launchInGhostty(shellCommand: String, cwd: String?, domain: String = "AgentTerminalLauncher") async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil else {
            throw NSError(domain: domain, code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Ghostty is not installed."])
        }
        let directory = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        try await runGhosttyAppleScript(ghosttyScriptLines(), arguments: [shellCommand, directory], domain: domain)
    }

    /// Uses Macterm's bundled control CLI rather than Ghostty's AppleScript interface.
    static func launchInMacterm(shellCommand: String, cwd: String?) async throws {
        do { try await performMactermLaunch(shellCommand: shellCommand, cwd: cwd) }
        catch { throw MactermLaunchError(message: error.localizedDescription) }
    }

    private static func performMactermLaunch(shellCommand: String, cwd: String?) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.thdxg.macterm") else {
            throw mactermError("Macterm is not installed.")
        }
        let cliURL = appURL.appendingPathComponent("Contents/Resources/bin/macterm")
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw mactermError("Macterm's control CLI is missing. Update Macterm and try again.")
        }
        let directory = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw mactermError("The session's working directory no longer exists: \(directory)")
        }
        if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.thdxg.macterm" }) {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
        // A running app can still be starting its control socket.
        let deadline = Date().addingTimeInterval(8)
        while true {
            do {
                _ = try await runMactermCLI(cliURL, arguments: ["status", "--json"], timeout: 1)
                break
            } catch {
                try Task.checkCancellation()
                guard Date() < deadline else { throw error }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        try await openMactermTab(cliURL, shellCommand: shellCommand, workingDirectory: directory)
    }

    static nonisolated func openMactermTab(_ cliURL: URL, shellCommand: String, workingDirectory: String) async throws {
        // Hold the queue across the entire operation. Both project creation and
        // activation change state shared by all Resume requests.
        try await mactermLaunchQueue.run {
            try await selectProjectAndOpenMactermTab(cliURL, shellCommand: shellCommand, workingDirectory: workingDirectory)
        }
    }

    private static nonisolated func selectProjectAndOpenMactermTab(
        _ cliURL: URL, shellCommand: String, workingDirectory: String
    ) async throws {
        let listArguments = ["project", "list", "--json"]
        var projects = try await runMactermCLI(cliURL, arguments: listArguments)
        var projectID = try mactermProjectID(in: projects, workingDirectory: workingDirectory)
        if projectID == nil {
            // Creating a project is not idempotent: never retry this command.
            _ = try await runMactermCLI(cliURL, arguments: ["project", "create", workingDirectory, "--json"])
            projects = try await runMactermCLI(cliURL, arguments: listArguments)
            projectID = try mactermProjectID(in: projects, workingDirectory: workingDirectory)
        }
        guard let projectID else {
            throw mactermError("Macterm did not return a project for the session's working directory.")
        }
        // `tab new --project` does not activate a different project. Its shell
        // may never materialize until the project is selected explicitly.
        _ = try await runMactermCLI(cliURL, arguments: ["project", "select", projectID, "--json"])
        // The command builder has already quoted the native ID and working directory.
        // Pass the complete command as one argv value; never interpolate it into a shell here.
        let response = try await runMactermCLI(cliURL, arguments: ["tab", "new", "--project", projectID, "--run", shellCommand, "--json"])
        struct CreatedTab: Decodable { let id: String }
        struct TabResponse: Decodable { let tabs: [CreatedTab] }
        guard let result = try? JSONDecoder().decode(TabResponse.self, from: response),
              result.tabs.count == 1, let tab = result.tabs.first, !tab.id.isEmpty else {
            throw mactermError("Macterm did not identify the new Resume tab. Check its tabs before trying again.")
        }
        // Project selection sets the CLI's active project but can leave the
        // window on another project. The command is queued until its pane starts.
        _ = try await runMactermCLI(cliURL, arguments: ["pane", "focus", "--project", projectID, "--tab", tab.id, "--json"])
    }

    static nonisolated func mactermProjectID(in data: Data, workingDirectory: String) throws -> String? {
        struct Project: Decodable { let id: String; let path: String }
        struct Listing: Decodable { let projects: [Project] }
        let listing: Listing
        do { listing = try JSONDecoder().decode(Listing.self, from: data) }
        catch { throw mactermError("Macterm returned an unreadable project list. Update Macterm and try again.") }
        let directory = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        let matches = listing.projects.compactMap { project -> (String, String)? in
            // Remote projects are deliberately outside this local resume flow.
            guard project.path.hasPrefix("/") else { return nil }
            let path = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().standardizedFileURL.path
            guard directory == path || directory.hasPrefix(path == "/" ? "/" : path + "/") else { return nil }
            return (project.id, path)
        }
        guard let longest = matches.map({ $0.1.count }).max() else { return nil }
        let closest = matches.filter { $0.1.count == longest }
        guard closest.count == 1, let match = closest.first, !match.0.isEmpty else {
            throw mactermError("More than one Macterm project matches this session. Give the projects distinct local folders before resuming.")
        }
        return match.0
    }

    /// Runs away from the UI actor, with bounded waiting and file-backed output.
    static nonisolated func runMactermCLI(_ executable: URL, arguments: [String], timeout: TimeInterval = 10) async throws -> Data {
        try Task.checkCancellation()
        let result = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macterm-resume-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("stdout")
            let errors = directory.appendingPathComponent("stderr")
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let outputHandle = try FileHandle(forWritingTo: output)
            defer { try? outputHandle.close() }
            let errorHandle = try FileHandle(forWritingTo: errors)
            defer { try? errorHandle.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            try process.run()
            guard process.waitForExit(timeout: timeout) else {
                throw mactermError("Macterm did not respond in time. Check its tabs before trying Resume again.")
            }
            guard process.terminationStatus == 0 else {
                let reader = try FileHandle(forReadingFrom: errors)
                defer { try? reader.close() }
                let data = try reader.read(upToCount: 16_384) ?? Data()
                let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw mactermError(detail.isEmpty ? "Macterm could not open the session." : "Macterm: \(detail)")
            }
            let reader = try FileHandle(forReadingFrom: output)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw mactermError("Macterm's response is too large.") }
            return data
        }.value
        try Task.checkCancellation()
        return result
    }

    private static nonisolated func mactermError(_ message: String) -> MactermLaunchError {
        MactermLaunchError(message: message)
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

    /// Ghostty may wait for Automation consent. Keep that wait off the UI actor,
    /// discard stdout, and spool stderr so neither pipe can block the child.
    static nonisolated func runGhosttyAppleScript(_ lines: [String], arguments: [String] = [],
                                                  domain: String = "AgentTerminalLauncher",
                                                  timeout: TimeInterval = 10) async throws {
        try await Task.detached {
            let errorURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostty-resume-\(UUID().uuidString).stderr")
            guard FileManager.default.createFile(atPath: errorURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? FileManager.default.removeItem(at: errorURL) }
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer { try? errorHandle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = lines.flatMap { ["-e", $0] } + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle
            try process.run()
            guard process.waitForExit(timeout: timeout) else {
                throw NSError(domain: domain, code: 5, userInfo: [NSLocalizedDescriptionKey:
                    "Ghostty launch timed out. Check the Automation permission for Agent Sessions in System Settings and try again."])
            }
            guard process.terminationStatus == 0 else {
                let reader = try FileHandle(forReadingFrom: errorURL)
                defer { try? reader.close() }
                let data = try reader.read(upToCount: 16_384) ?? Data()
                let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let message = "Ghostty launch failed. Resume in Ghostty needs a Ghostty build with AppleScript support."
                throw NSError(domain: domain, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                    detail.isEmpty ? message : "\(message)\n\(detail)"])
            }
        }.value
    }

    /// AppleScript for `launchInGhostty`. argv: shell command, working directory.
    static nonisolated func ghosttyScriptLines() -> [String] {
        [
            "on run argv",
            "set shellCommand to item 1 of argv",
            "set workingDirectory to item 2 of argv",
            "tell application \"Ghostty\"",
            "activate",
            "set surfaceConfig to new surface configuration",
            "set initial working directory of surfaceConfig to workingDirectory",
            "set initial input of surfaceConfig to shellCommand & linefeed",
            "new window with configuration surfaceConfig",
            "end tell",
            "end run"
        ]
    }

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

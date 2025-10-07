import Foundation
#if os(macOS)
import IOKit.ps
#endif

// Service for fetching Claude CLI usage via headless script execution
actor ClaudeStatusService {
    private enum State { case idle, running, stopping }

    private nonisolated let updateHandler: @Sendable (ClaudeUsageSnapshot) -> Void
    private nonisolated let availabilityHandler: @Sendable (ClaudeServiceAvailability) -> Void

    private var state: State = .idle
    private var snapshot = ClaudeUsageSnapshot()
    private var shouldRun: Bool = true
    private var visible: Bool = false
    private var refresherTask: Task<Void, Never>?
    private var tmuxAvailable: Bool = false
    private var claudeAvailable: Bool = false

    init(updateHandler: @escaping @Sendable (ClaudeUsageSnapshot) -> Void,
         availabilityHandler: @escaping @Sendable (ClaudeServiceAvailability) -> Void) {
        self.updateHandler = updateHandler
        self.availabilityHandler = availabilityHandler
    }

    func start() async {
        shouldRun = true

        // Check dependencies once at startup
        tmuxAvailable = checkTmuxAvailable()
        claudeAvailable = checkClaudeAvailable()

        let availability = ClaudeServiceAvailability(
            cliUnavailable: !claudeAvailable,
            tmuxUnavailable: !tmuxAvailable
        )
        availabilityHandler(availability)

        guard tmuxAvailable && claudeAvailable else {
            // Don't start refresh loop if dependencies missing
            return
        }

        refresherTask?.cancel()
        refresherTask = Task { [weak self] in
            guard let self else { return }
            while await self.shouldRun {
                await self.refreshTick()
                let interval = await self.nextInterval()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() async {
        shouldRun = false
        refresherTask?.cancel()
        refresherTask = nil
    }

    func setVisible(_ isVisible: Bool) {
        visible = isVisible
    }

    func refreshNow() {
        Task { await self.refreshTick() }
    }

    // MARK: - Core refresh logic

    private func refreshTick() async {
        guard tmuxAvailable && claudeAvailable else { return }

        do {
            let json = try await executeScript()
            if let parsed = parseUsageJSON(json) {
                snapshot = parsed
                updateHandler(snapshot)
            } else {
                print("ClaudeStatusService: Failed to parse JSON: \(json)")
            }
        } catch {
            print("ClaudeStatusService: Script execution failed: \(error)")
            // Silent failure - keep last known good data
        }
    }

    private func executeScript() async throws -> String {
        guard let scriptURL = prepareScript() else {
            throw ClaudeServiceError.scriptNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        // Set environment for script
        var env = ProcessInfo.processInfo.environment
        // Use isolated temp directory to prevent Claude from scanning user folders
        let tempBase = NSTemporaryDirectory()
        let workDir = (tempBase as NSString).appendingPathComponent("AgentSessions-claude-usage")
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        env["WORKDIR"] = workDir
        env["MODEL"] = "sonnet"
        env["TIMEOUT_SECS"] = "10"
        env["SLEEP_BOOT"] = "0.4"
        env["SLEEP_AFTER_USAGE"] = "1.2"

        // Use real HOME for auth credentials (temp WORKDIR prevents file access prompts)
        // No CLAUDE_HOME override - let it use real ~/.claude/ with credentials

        // Pass resolved Claude binary path (same logic as resume)
        let claudeEnv = ClaudeCLIEnvironment()
        if let claudeBin = claudeEnv.resolveBinary(customPath: nil) {
            env["CLAUDE_BIN"] = claudeBin.path
        }

        // Pass resolved tmux path
        if let tmuxPath = resolveTmuxPath() {
            env["TMUX_BIN"] = tmuxPath
        }

        print("ClaudeStatusService: Executing script with WORKDIR=\(workDir), CLAUDE_BIN=\(env["CLAUDE_BIN"] ?? "not set"), TMUX_BIN=\(env["TMUX_BIN"] ?? "not set")")

        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Wait for process with 20s timeout (poll every 0.5s)
        let maxIterations = 40 // 20s / 0.5s
        var iterations = 0
        while process.isRunning && iterations < maxIterations {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            iterations += 1
        }

        if process.isRunning {
            // Timeout - kill process
            print("ClaudeStatusService: Script timed out after 20s, terminating")
            process.terminate()
            throw ClaudeServiceError.scriptFailed(exitCode: 124, output: "Script timed out")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if !errorOutput.isEmpty {
            print("ClaudeStatusService: Script stderr: \(errorOutput)")
        }

        // Check exit code
        let exitCode = process.terminationStatus
        if exitCode == 0 {
            return output
        } else if exitCode == 13 {
            // Auth/login required - notify UI
            let availability = ClaudeServiceAvailability(
                cliUnavailable: false,
                tmuxUnavailable: false,
                loginRequired: true
            )
            availabilityHandler(availability)
            throw ClaudeServiceError.loginRequired
        } else {
            // Script returned error JSON
            throw ClaudeServiceError.scriptFailed(exitCode: Int(exitCode), output: output)
        }
    }

    private func prepareScript() -> URL? {
        // Get script from bundle
        guard let bundledScript = Bundle.main.url(forResource: "claude_usage_capture", withExtension: "sh") else {
            return nil
        }

        // Copy to temp with unique name
        let tempDir = FileManager.default.temporaryDirectory
        let tempScript = tempDir.appendingPathComponent("claude_usage_\(UUID().uuidString).sh")

        do {
            // Copy script to temp
            try? FileManager.default.removeItem(at: tempScript) // Clean up any existing
            try FileManager.default.copyItem(at: bundledScript, to: tempScript)

            // Make executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tempScript.path
            )

            return tempScript
        } catch {
            return nil
        }
    }

    private func parseUsageJSON(_ json: String) -> ClaudeUsageSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }

        do {
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let obj else { return nil }

            // Check if error response
            if let ok = obj["ok"] as? Bool, !ok {
                return nil
            }

            // Parse successful response
            var snapshot = ClaudeUsageSnapshot()

            if let session = obj["session_5h"] as? [String: Any] {
                snapshot.sessionPercent = session["pct_used"] as? Int ?? 0
                snapshot.sessionResetText = formatResetTime(session["resets"] as? String ?? "", isWeekly: false)
            }

            if let weekAll = obj["week_all_models"] as? [String: Any] {
                snapshot.weekAllModelsPercent = weekAll["pct_used"] as? Int ?? 0
                snapshot.weekAllModelsResetText = formatResetTime(weekAll["resets"] as? String ?? "", isWeekly: true)
            }

            if let weekOpus = obj["week_opus"] as? [String: Any] {
                snapshot.weekOpusPercent = weekOpus["pct_used"] as? Int
                snapshot.weekOpusResetText = (weekOpus["resets"] as? String).map { formatResetTime($0, isWeekly: true) }
            }

            return snapshot
        } catch {
            return nil
        }
    }

    private func formatResetTime(_ text: String, isWeekly: Bool) -> String {
        // Claude CLI outputs formats like:
        // - "1am (America/Los_Angeles)" for 5h
        // - "Oct 9 at 2pm (America/Los_Angeles)" for weekly
        // Convert to Codex format:
        // - "resets HH:mm" for 5h
        // - "resets HH:mm on d MMM" for weekly

        guard !text.isEmpty else { return "" }

        // Strip timezone first
        var cleanText = text
        if let parenIndex = text.firstIndex(of: "(") {
            cleanText = String(text[..<parenIndex]).trimmingCharacters(in: .whitespaces)
        }

        // Use Pacific timezone to match Codex
        let tz = TimeZone(identifier: "America/Los_Angeles")!

        if isWeekly {
            // Parse "Oct 9 at 2pm" format
            // Try multiple formats Claude might use
            let formats = [
                "MMM d 'at' ha",      // Oct 9 at 2pm
                "MMM d 'at' h:mma",   // Oct 9 at 2:00pm
                "MMM d 'at' h a",     // Oct 9 at 2 pm
            ]

            for format in formats {
                let parser = DateFormatter()
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.timeZone = tz
                parser.dateFormat = format

                if let date = parser.date(from: cleanText) {
                    // Format as "HH:mm"
                    let timeFmt = DateFormatter()
                    timeFmt.locale = Locale(identifier: "en_US_POSIX")
                    timeFmt.timeZone = tz
                    timeFmt.dateFormat = "HH:mm"
                    let time = timeFmt.string(from: date)

                    // Format as "d MMM"
                    let dateFmt = DateFormatter()
                    dateFmt.locale = Locale(identifier: "en_US_POSIX")
                    dateFmt.timeZone = tz
                    dateFmt.dateFormat = "d MMM"
                    let dateStr = dateFmt.string(from: date)

                    return "resets \(time) on \(dateStr)"
                }
            }
        } else {
            // Parse "1am" or "1:00am" format for 5h
            let formats = [
                "ha",      // 1am
                "h:mma",   // 1:00am
                "h a",     // 1 am
            ]

            for format in formats {
                let parser = DateFormatter()
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.timeZone = tz
                parser.dateFormat = format

                if let date = parser.date(from: cleanText) {
                    // Format as "HH:mm"
                    let timeFmt = DateFormatter()
                    timeFmt.locale = Locale(identifier: "en_US_POSIX")
                    timeFmt.timeZone = tz
                    timeFmt.dateFormat = "HH:mm"
                    let time = timeFmt.string(from: date)

                    return "resets \(time)"
                }
            }
        }

        // Fallback: return original text with "resets" prefix if not already present
        let lower = cleanText.lowercased()
        if lower.hasPrefix("reset") {
            return cleanText
        }
        return "resets \(cleanText)"
    }

    private func nextInterval() -> UInt64 {
        // Policy (same as Codex):
        // - On AC power: 60s when visible, else 300s
        // - On battery: always 300s
        // - Urgency: 60s if session >= 80%
        if !Self.onACPower() {
            return 300 * 1_000_000_000
        }
        var seconds: UInt64 = visible ? 60 : 300
        if snapshot.sessionPercent >= 80 { seconds = 60 }
        return seconds * 1_000_000_000
    }

    // MARK: - Dependency checks

    private func checkTmuxAvailable() -> Bool {
        // Check via login shell to get user's full PATH (mirrors Terminal)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v tmux || true"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    private func checkClaudeAvailable() -> Bool {
        // Use same resolution logic as resume functionality
        let env = ClaudeCLIEnvironment()
        return env.resolveBinary(customPath: nil) != nil
    }

    private func resolveTmuxPath() -> String? {
        // Check via login shell to get full PATH
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v tmux || true"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private static func onACPower() -> Bool {
        #if os(macOS)
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        if let typeCF = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() {
            let type = typeCF as String
            return type == (kIOPSACPowerValue as String)
        }
        #endif
        if #available(macOS 12.0, *) {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        }
        return true
    }
}

enum ClaudeServiceError: Error {
    case scriptNotFound
    case scriptFailed(exitCode: Int, output: String)
    case loginRequired
}

import Foundation

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

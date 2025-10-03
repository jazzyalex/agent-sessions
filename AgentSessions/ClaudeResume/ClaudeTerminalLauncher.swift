import Foundation

@MainActor
final class ClaudeTerminalLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {
        // Escape for AppleScript string literal
        let escaped = package.shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let scriptLines = [
            "tell application \"Terminal\"",
            "activate",
            "set newTab to do script \"\(escaped)\"",
            "delay 0.1",
            "try",
            "  set newWin to (first window whose tabs contains newTab)",
            "  set front window to newWin",
            "  set selected tab of newWin to newTab",
            "end try",
            "end tell"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = scriptLines.flatMap { ["-e", $0] }

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "ClaudeTerminalLauncher", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "Terminal launch failed." : err])
        }
    }

    func launchInITerm(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {
        let escaped = package.shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let scriptLines = [
            "tell application \"iTerm2\"",
            "activate",
            "set newWin to (create window with default profile)",
            "tell newWin",
            "  tell current session",
            "    write text \"\(escaped)\"",
            "  end tell",
            "end tell",
            "end tell"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = scriptLines.flatMap { ["-e", $0] }

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "ClaudeTerminalLauncher", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "iTerm2 launch failed." : err])
        }
    }
}

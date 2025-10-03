import Foundation

@MainActor
final class ClaudeITermLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {
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
            throw NSError(domain: "ClaudeITermLauncher", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "iTerm2 launch failed." : err])
        }
    }
}

import Foundation
import AppKit

@MainActor
final class CodexResumeLauncher: ObservableObject {
    struct ConsoleLine: Identifiable, Equatable {
        enum Kind { case stdout, stderr }
        let id = UUID()
        let text: String
        let kind: Kind
    }

    @Published private(set) var isRunningEmbedded: Bool = false
    @Published private(set) var consoleLines: [ConsoleLine] = []
    @Published var lastError: String? = nil

    private var process: Process?

    func launchEmbedded(_ package: CodexResumeCommandBuilder.CommandPackage,
                        environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isRunningEmbedded else { return }
        consoleLines.removeAll()
        lastError = nil

        let process = Process()
        process.environment = environment
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = package.workingDirectory
        process.arguments = ["bash", "-lc", package.shellCommand]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                Task { @MainActor [chunk] in
                    self?.appendConsole(text: chunk, kind: .stdout)
                }
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                Task { @MainActor [chunk] in
                    self?.appendConsole(text: chunk, kind: .stderr)
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.isRunningEmbedded = false
                self?.process = nil
                if proc.terminationStatus != 0, self?.lastError == nil {
                    self?.lastError = "Codex exited with status \(proc.terminationStatus)"
                }
            }
        }

        do {
            try process.run()
            appendConsole(text: "$ \(package.displayCommand)\n", kind: .stdout)
            self.process = process
            isRunningEmbedded = true
        } catch {
            lastError = error.localizedDescription
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stopEmbedded() {
        guard let process else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            if process.isRunning {
                process.terminate()
            }
            Task { @MainActor in
                self?.isRunningEmbedded = false
                self?.appendConsole(text: "Process interrupted\n", kind: .stderr)
                self?.process = nil
            }
        }
    }

    func launchInTerminal(_ package: CodexResumeCommandBuilder.CommandPackage) throws {
        let escaped = package.shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let scriptLines = [
            "tell application \"Terminal\"",
            "activate",
            // Run the command and capture the newly created tab
            "set newTab to do script \"\(escaped)\"",
            // Give Terminal a brief moment to create/select the UI elements
            "delay 0.1",
            // Try to bring the window containing newTab to the front and select the tab
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

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = err?.isEmpty == false ? err! : "Terminal rejected the launch command (status \(process.terminationStatus))."
            throw NSError(domain: "CodexResumeLauncher", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func appendConsole(text: String, kind: ConsoleLine.Kind) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let newline = index == lines.count - 1 && text.hasSuffix("\n")
            let rendered = newline ? String(line) + "\n" : String(line)
            consoleLines.append(ConsoleLine(text: rendered, kind: kind))
        }
    }
}

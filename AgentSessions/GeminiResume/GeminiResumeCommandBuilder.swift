import Foundation

struct GeminiResumeCommandBuilder {
    struct CommandPackage {
        let shellCommand: String
        let displayCommand: String
        let workingDirectory: URL?
    }

    enum BuildError: Error {
        case missingSessionID
    }

    enum Strategy {
        case resumeByID(id: String)
    }

    func makeCommand(strategy: Strategy,
                     binaryURL: URL,
                     workingDirectory: URL?) throws -> CommandPackage {
        // Use the full path only if it points to a real executable; otherwise
        // fall back to the bare command name so the user's shell can resolve it.
        let binaryPath: String
        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            binaryPath = binaryURL.path
        } else {
            binaryPath = binaryURL.lastPathComponent
        }
        let geminiPath = shellQuote(binaryPath)
        let command: String

        switch strategy {
        case .resumeByID(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BuildError.missingSessionID }
            let quotedID = shellQuote(id)
            command = "\(geminiPath) --resume \(quotedID)"
        }

        let shell: String
        if let wd = workingDirectory?.path, !wd.isEmpty {
            shell = "cd \(shellQuote(wd)) && \(command)"
        } else {
            shell = command
        }

        return CommandPackage(shellCommand: shell, displayCommand: command, workingDirectory: workingDirectory)
    }

    // MARK: - Helpers
    func shellQuote(_ string: String) -> String { ShellQuoting.quote(string) }
    func shellQuoteIfNeeded(_ string: String) -> String { ShellQuoting.quoteIfNeeded(string) }
}

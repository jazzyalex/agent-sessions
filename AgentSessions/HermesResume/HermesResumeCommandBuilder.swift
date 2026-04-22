import Foundation

struct HermesResumeCommandBuilder {
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
        case continueMostRecent
    }

    func makeCommand(strategy: Strategy,
                     binaryURL: URL,
                     workingDirectory: URL?) throws -> CommandPackage {
        let hermesPath = shellQuote(binaryURL.path)
        let command: String
        switch strategy {
        case .resumeByID(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BuildError.missingSessionID }
            command = "\(hermesPath) --resume \(shellQuote(id))"
        case .continueMostRecent:
            command = "\(hermesPath) --continue"
        }

        let shellCommand: String
        if let wd = workingDirectory?.path, !wd.isEmpty {
            shellCommand = "cd \(shellQuote(wd)) && \(command)"
        } else {
            shellCommand = command
        }

        return CommandPackage(shellCommand: shellCommand, displayCommand: command, workingDirectory: workingDirectory)
    }

    func shellQuote(_ string: String) -> String { ShellQuoting.quote(string) }
    func shellQuoteIfNeeded(_ string: String) -> String { ShellQuoting.quoteIfNeeded(string) }
}

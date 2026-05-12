import Foundation

struct PiResumeCommandBuilder {
    struct CommandPackage {
        let shellCommand: String
        let displayCommand: String
        let workingDirectory: URL?
    }

    enum BuildError: Error {
        case missingSessionID
    }

    enum Strategy {
        case sessionByID(id: String)
        case resumeByID(id: String)
        case continueMostRecent
    }

    func makeCommand(strategy: Strategy,
                     binaryURL: URL,
                     workingDirectory: URL?,
                     sessionDirectory: URL? = nil) throws -> CommandPackage {
        let command = try makeCoreCommand(strategy: strategy,
                                          binaryCommand: binaryURL.path,
                                          sessionDirectory: sessionDirectory?.path,
                                          quoteBinary: shellQuote,
                                          quoteArgument: shellQuote)

        let shell: String
        if let wd = workingDirectory?.path, !wd.isEmpty {
            shell = "cd \(shellQuote(wd)) && \(command)"
        } else {
            shell = command
        }

        return CommandPackage(shellCommand: shell, displayCommand: command, workingDirectory: workingDirectory)
    }

    func makeCoreCommand(strategy: Strategy, binaryCommand: String, sessionDirectory: String? = nil) throws -> String {
        try makeCoreCommand(strategy: strategy,
                            binaryCommand: binaryCommand,
                            sessionDirectory: sessionDirectory,
                            quoteBinary: shellQuoteIfNeeded,
                            quoteArgument: shellQuoteIfNeeded)
    }

    private func makeCoreCommand(strategy: Strategy,
                                 binaryCommand: String,
                                 sessionDirectory: String?,
                                 quoteBinary: (String) -> String,
                                 quoteArgument: (String) -> String) throws -> String {
        let invocation = quoteBinary(binaryCommand)
        let sessionDirArgument = sessionDirectory
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : " --session-dir \(quoteArgument($0))" } ?? ""
        switch strategy {
        case .sessionByID(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BuildError.missingSessionID }
            return "\(invocation)\(sessionDirArgument) --session \(quoteArgument(id))"
        case .resumeByID(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BuildError.missingSessionID }
            return "\(invocation)\(sessionDirArgument) --resume \(quoteArgument(id))"
        case .continueMostRecent:
            return "\(invocation)\(sessionDirArgument) --continue"
        }
    }

    func shellQuote(_ string: String) -> String { ShellQuoting.quote(string) }
    func shellQuoteIfNeeded(_ string: String) -> String { ShellQuoting.quoteIfNeeded(string) }
}

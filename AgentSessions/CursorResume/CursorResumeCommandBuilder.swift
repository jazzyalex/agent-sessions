import Foundation

struct CursorResumeCommandBuilder {
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
        let command = try makeCoreCommand(strategy: strategy,
                                          binaryCommand: binaryURL.path,
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

    func makeCoreCommand(strategy: Strategy, binaryCommand: String) throws -> String {
        try makeCoreCommand(strategy: strategy,
                            binaryCommand: binaryCommand,
                            quoteBinary: shellQuoteIfNeeded,
                            quoteArgument: shellQuoteIfNeeded)
    }

    private func makeCoreCommand(strategy: Strategy,
                                 binaryCommand: String,
                                 quoteBinary: (String) -> String,
                                 quoteArgument: (String) -> String) throws -> String {
        let invocation = binaryInvocation(binaryCommand: binaryCommand, quote: quoteBinary)
        switch strategy {
        case .resumeByID(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BuildError.missingSessionID }
            return "\(invocation) --resume \(quoteArgument(id))"
        case .continueMostRecent:
            return "\(invocation) --continue"
        }
    }

    private func binaryInvocation(binaryCommand: String, quote: (String) -> String) -> String {
        let quoted = quote(binaryCommand)
        if isCursorExecutable(binaryCommand) {
            return "\(quoted) agent"
        }
        return quoted
    }

    private func isCursorExecutable(_ binaryCommand: String) -> Bool {
        URL(fileURLWithPath: binaryCommand).lastPathComponent.lowercased() == "cursor"
    }

    // MARK: - Helpers
    func shellQuote(_ string: String) -> String { ShellQuoting.quote(string) }
    func shellQuoteIfNeeded(_ string: String) -> String { ShellQuoting.quoteIfNeeded(string) }
}

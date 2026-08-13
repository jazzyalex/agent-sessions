import Foundation

/// Builds the shell command that reopens a Grok CLI session.
///
/// Verified against `grok --help` at CLI 1.0.0 (3cd0d0cbcebe):
///
///     -r, --resume [<SESSION_ID_OR_TITLE>]
///                          Resume a session by ID or title, or the most recent
///                          if omitted.
///     -c, --continue       Continue the most recent session for the current
///                          working directory.
///
/// `Session.id` is the on-disk session directory name, a bare UUIDv7 with no
/// prefix. `--resume` documents that "UUID-shaped values always mean IDs", so
/// passing the directory name through verbatim resolves unambiguously and never
/// falls back to title matching.
struct GrokResumeCommandBuilder {
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
        case continueMostRecent
    }

    /// Builds the launchable package for a terminal resume. The binary is a
    /// resolved absolute path here, so it is always quoted; `makeCoreCommand`
    /// quotes only when needed because its output is shown to the user.
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
        let invocation = quoteBinary(binaryCommand)
        switch strategy {
        case .sessionByID(let id):
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw BuildError.missingSessionID }
            return "\(invocation) --resume \(quoteArgument(trimmed))"
        case .continueMostRecent:
            return "\(invocation) --continue"
        }
    }

    /// Picks `--resume <id>` when the session carries an id, else falls back to
    /// `--continue`, which reopens the most recent session for the working
    /// directory.
    func strategy(forSessionID sessionID: String) -> Strategy {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .continueMostRecent
            : .sessionByID(id: sessionID)
    }

    func shellQuote(_ string: String) -> String { ShellQuoting.quote(string) }
    func shellQuoteIfNeeded(_ string: String) -> String { ShellQuoting.quoteIfNeeded(string) }
}

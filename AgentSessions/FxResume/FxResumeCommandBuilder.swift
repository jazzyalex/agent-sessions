import Foundation

/// Builds the shell command that reopens an fx CLI session.
///
/// Verified against `fx --help` at fx 0.0.4:
///
///     -c, --continue          Resume the latest workspace session
///     --resume [last|<id>]    Resume the latest workspace session or an exact ID
///
/// `Session.id` is the on-disk session directory name (a
/// `<millis>-<nanos>-<hex>` composite). `--resume <id>` resolves an exact ID,
/// and `--continue` resolves the latest session for the current workspace, so
/// it is only offered when a working directory is known.
struct FxResumeCommandBuilder {
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
    /// `--continue`, which reopens the latest session for the workspace.
    func strategy(forSessionID sessionID: String) -> Strategy {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .continueMostRecent
            : .sessionByID(id: sessionID)
    }

    func shellQuote(_ string: String) -> String { ShellQuoting.quote(string) }
    func shellQuoteIfNeeded(_ string: String) -> String { ShellQuoting.quoteIfNeeded(string) }
}

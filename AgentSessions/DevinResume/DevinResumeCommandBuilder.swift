import Foundation

/// Builds the shell command that reopens a Devin session.
///
/// Verified against `devin --help` at CLI 3000.3.27 (0becb483):
///
///     -c, --continue       Continue the most recent conversation.
///     -r, --resume [<SESSION_ID>]
///                          Resume a conversation by id.
///
/// `Session.id` is the `sessions.id` primary key, a human-readable slug such as
/// `bald-ketch` rather than a UUID, and is passed through verbatim.
struct DevinResumeCommandBuilder {
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
    /// `--continue`.
    ///
    /// The installed help says only "Continue the most recent conversation" — it
    /// promises nothing about scoping that to a directory, unlike Kimi's and
    /// Grok's equivalents, which is where the earlier "directory-scoped" wording
    /// here came from. The launcher still `cd`s into the session's working
    /// directory first, which is the best we can do, but it is not a guarantee
    /// the CLI resolves per directory. That is why the coordinator refuses this
    /// strategy outright when no working directory is known, and why callers
    /// should prefer `--resume <id>` whenever an id exists.
    func strategy(forSessionID sessionID: String) -> Strategy {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .continueMostRecent
            : .sessionByID(id: sessionID)
    }

    func shellQuote(_ string: String) -> String { ShellQuoting.quote(string) }
    func shellQuoteIfNeeded(_ string: String) -> String { ShellQuoting.quoteIfNeeded(string) }
}

import Foundation

/// Builds the shell command that reopens a Kimi Code session.
///
/// Verified against `kimi --help` at CLI 0.29.1:
///
///     -S, --session [id]   Resume a session. With ID: resume that session.
///                          Without ID: interactively pick.
///     -c, --continue       Continue the previous session for the working directory.
///
/// `Session.id` is the on-disk session directory name, which Kimi prefixes
/// (`session_<uuid>`). `kimi -S session_<uuid>` was confirmed against the real
/// CLI to resolve that id, so the prefix is passed through verbatim rather than
/// stripped.
struct KimiResumeCommandBuilder {
    enum BuildError: Error {
        case missingSessionID
    }

    enum Strategy {
        case sessionByID(id: String)
        case continueMostRecent
    }

    func makeCoreCommand(strategy: Strategy, binaryCommand: String) throws -> String {
        let invocation = shellQuoteIfNeeded(binaryCommand)
        switch strategy {
        case .sessionByID(let id):
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw BuildError.missingSessionID }
            return "\(invocation) --session \(shellQuoteIfNeeded(trimmed))"
        case .continueMostRecent:
            return "\(invocation) --continue"
        }
    }

    /// Picks `--session <id>` when the session carries an id, else falls back to
    /// `--continue`, which reopens the most recent session for the working
    /// directory.
    func strategy(forSessionID sessionID: String) -> Strategy {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .continueMostRecent
            : .sessionByID(id: sessionID)
    }

    func shellQuoteIfNeeded(_ string: String) -> String { ShellQuoting.quoteIfNeeded(string) }
}

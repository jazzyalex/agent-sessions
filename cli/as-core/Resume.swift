import Foundation

/// A shell command that resumes a session in its agent's own CLI, built with the same
/// command builders the macOS app uses for "Copy resume command".
struct ResumeCommand {
    let display: String
    let shell: String
    let workingDirectory: String?
}

enum ResumeError: Error, CustomStringConvertible {
    case unsupported(SessionSource)
    case missingSessionID

    var description: String {
        switch self {
        case .unsupported(let source): return "\(source.rawValue) sessions cannot be resumed from the CLI yet"
        case .missingSessionID: return "session ID not found"
        }
    }
}

/// A binary looked up on $PATH by the shell. `URL(fileURLWithPath:)` would anchor a bare
/// name to the current directory; the builders only need `.path` to be the name itself.
private func bareCommand(_ name: String) -> URL {
    URL(string: name)!
}

func resumeCommand(for session: Session) throws -> ResumeCommand {
    switch session.source {
    case .claude:
        guard let id = ClaudeSessionIDHelper.deriveSessionID(from: session) else { throw ResumeError.missingSessionID }
        let wd = ClaudeSessionIDHelper.recordedProjectRoot(for: session)
        let package = try ClaudeResumeCommandBuilder().makeCommand(strategy: .resumeByID(id: id),
                                                                   binaryURL: bareCommand("claude"),
                                                                   workingDirectory: wd)
        return ResumeCommand(display: package.displayCommand, shell: package.shellCommand, workingDirectory: wd?.path)
    case .codex:
        let package = try CodexResumeCommandBuilder().makeCommand(for: session,
                                                                  workingDirectory: session.cwd,
                                                                  binaryURL: bareCommand("codex"),
                                                                  fallbackPath: nil,
                                                                  attemptResumeFirst: false)
        return ResumeCommand(display: package.displayCommand, shell: package.shellCommand, workingDirectory: session.cwd)
    case .opencode:
        let wd = session.cwd.map { URL(fileURLWithPath: $0) }
        let package = try OpenCodeResumeCommandBuilder().makeCommand(strategy: .resumeByID(id: session.id),
                                                                     binaryURL: bareCommand("opencode"),
                                                                     workingDirectory: wd)
        return ResumeCommand(display: package.displayCommand, shell: package.shellCommand, workingDirectory: session.cwd)
    case .copilot:
        let wd = session.cwd.map { URL(fileURLWithPath: $0) }
        let package = try CopilotResumeCommandBuilder().makeCommand(strategy: .resumeByID(id: session.id),
                                                                    binaryURL: bareCommand("copilot"),
                                                                    workingDirectory: wd)
        return ResumeCommand(display: package.displayCommand, shell: package.shellCommand, workingDirectory: session.cwd)
    default:
        throw ResumeError.unsupported(session.source)
    }
}

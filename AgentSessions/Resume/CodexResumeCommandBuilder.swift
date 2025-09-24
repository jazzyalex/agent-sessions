import Foundation

struct CodexResumeCommandBuilder {
    struct CommandPackage {
        let shellCommand: String
        let displayCommand: String
        let workingDirectory: URL?
    }

    enum BuildError: Error {
        case missingSessionID
        case missingSessionFile
    }

    @MainActor
    func makeCommand(for session: Session,
                     settings: CodexResumeSettings,
                     binaryURL: URL,
                     fallbackPath: URL?,
                     attemptResumeFirst: Bool) throws -> CommandPackage {
        guard let sessionID = session.codexFilenameUUID else {
            throw BuildError.missingSessionID
        }

        let workingDirPath = settings.effectiveWorkingDirectory(for: session)
        let workingDirURL = workingDirPath.flatMap { URL(fileURLWithPath: $0) }
        let quotedSessionID = shellQuote(sessionID)
        let codexPath = shellQuote(binaryURL.path)

        let command: String
        if let fallback = fallbackPath {
            let quotedFallback = shellQuote(fallback.path)
            let explicitCommand = "\(codexPath) -c experimental_resume=\(quotedFallback)"
            if attemptResumeFirst {
                let resumeCommand = "\(codexPath) resume \(quotedSessionID)"
                command = "\(resumeCommand) || \(explicitCommand)"
            } else {
                command = explicitCommand
            }
        } else {
            command = "\(codexPath) resume \(quotedSessionID)"
        }

        let shell: String
        if let workingDirPath, !workingDirPath.isEmpty {
            shell = "cd \(shellQuote(workingDirPath)) && \(command)"
        } else {
            shell = command
        }

        return CommandPackage(shellCommand: shell,
                              displayCommand: command,
                              workingDirectory: workingDirURL)
    }

    private func shellQuote(_ string: String) -> String {
        // Wrap in single quotes and escape existing single quotes using POSIX convention
        if string.isEmpty { return "''" }
        if !string.contains("'") {
            return "'\(string)'"
        }
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

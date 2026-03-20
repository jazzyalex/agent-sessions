import Foundation

struct OpenCodeResumeCommandBuilder {
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
        let opencodePath = shellQuote(binaryURL.path)
        let command: String

        switch strategy {
        case .resumeByID(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BuildError.missingSessionID }
            let quotedID = shellQuote(id)
            command = "\(opencodePath) --session \(quotedID)"
        case .continueMostRecent:
            command = "\(opencodePath) --continue"
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
    func shellQuote(_ string: String) -> String {
        if string.isEmpty { return "''" }
        if !string.contains("'") { return "'\(string)'" }
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static let safeChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./~+@:"))

    func shellQuoteIfNeeded(_ string: String) -> String {
        if string.isEmpty { return "''" }
        if string.unicodeScalars.allSatisfy({ Self.safeChars.contains($0) }) { return string }
        return shellQuote(string)
    }
}

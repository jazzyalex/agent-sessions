import Foundation

@MainActor
final class ClaudeITermLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "ClaudeITermLauncher")
    }
}

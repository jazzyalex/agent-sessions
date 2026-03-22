import Foundation

@MainActor
protocol GeminiTerminalLaunching {
    func launchInTerminal(_ package: GeminiResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class GeminiTerminalLauncher: GeminiTerminalLaunching {
    func launchInTerminal(_ package: GeminiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "GeminiTerminalLauncher")
    }
}

@MainActor
final class GeminiITermLauncher: GeminiTerminalLaunching {
    func launchInTerminal(_ package: GeminiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "GeminiITermLauncher")
    }
}

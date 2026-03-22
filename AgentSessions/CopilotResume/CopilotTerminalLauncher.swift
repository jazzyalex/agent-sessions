import Foundation

@MainActor
protocol CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class CopilotTerminalLauncher: CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "CopilotTerminalLauncher")
    }
}

@MainActor
final class CopilotITermLauncher: CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "CopilotITermLauncher")
    }
}

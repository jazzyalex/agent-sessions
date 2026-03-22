import Foundation

@MainActor
protocol OpenCodeTerminalLaunching {
    func launchInTerminal(_ package: OpenCodeResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class OpenCodeTerminalLauncher: OpenCodeTerminalLaunching {
    func launchInTerminal(_ package: OpenCodeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "OpenCodeTerminalLauncher")
    }
}

@MainActor
final class OpenCodeITermLauncher: OpenCodeTerminalLaunching {
    func launchInTerminal(_ package: OpenCodeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "OpenCodeITermLauncher")
    }
}

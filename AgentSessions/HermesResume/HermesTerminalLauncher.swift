import Foundation

@MainActor
protocol HermesTerminalLaunching {
    func launchInTerminal(_ package: HermesResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class HermesTerminalLauncher: HermesTerminalLaunching {
    func launchInTerminal(_ package: HermesResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "HermesTerminalLauncher")
    }
}

@MainActor
final class HermesITermLauncher: HermesTerminalLaunching {
    func launchInTerminal(_ package: HermesResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "HermesITermLauncher")
    }
}

import Foundation

@MainActor
protocol PiTerminalLaunching {
    func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class PiTerminalLauncher: PiTerminalLaunching {
    func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "PiTerminalLauncher")
    }
}

@MainActor
final class PiITermLauncher: PiTerminalLaunching {
    func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "PiITermLauncher")
    }
}

import Foundation

@MainActor
protocol CursorTerminalLaunching {
    func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class CursorTerminalLauncher: CursorTerminalLaunching {
    func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "CursorTerminalLauncher")
    }
}

@MainActor
final class CursorITermLauncher: CursorTerminalLaunching {
    func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "CursorITermLauncher")
    }
}

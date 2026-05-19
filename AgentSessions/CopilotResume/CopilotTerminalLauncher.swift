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

@MainActor
final class CopilotWarpLauncher: CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.shellCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class CopilotWarpPreviewLauncher: CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.shellCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

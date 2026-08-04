import Foundation

@MainActor
protocol CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) async throws
}

@MainActor
final class CopilotTerminalLauncher: CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "CopilotTerminalLauncher")
    }
}

@MainActor
final class CopilotITermLauncher: CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "CopilotITermLauncher")
    }
}

@MainActor
final class CopilotWarpLauncher: CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class CopilotWarpPreviewLauncher: CopilotTerminalLaunching {
    func launchInTerminal(_ package: CopilotResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

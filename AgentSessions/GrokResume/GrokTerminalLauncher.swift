import Foundation

@MainActor
protocol GrokTerminalLaunching {
    func launchInTerminal(_ package: GrokResumeCommandBuilder.CommandPackage) async throws
}

@MainActor
final class GrokTerminalLauncher: GrokTerminalLaunching {
    func launchInTerminal(_ package: GrokResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "GrokTerminalLauncher")
    }
}

@MainActor
final class GrokITermLauncher: GrokTerminalLaunching {
    func launchInTerminal(_ package: GrokResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "GrokITermLauncher")
    }
}

@MainActor
final class GrokWarpLauncher: GrokTerminalLaunching {
    func launchInTerminal(_ package: GrokResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class GrokWarpPreviewLauncher: GrokTerminalLaunching {
    func launchInTerminal(_ package: GrokResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}
